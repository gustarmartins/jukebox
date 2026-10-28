import fcntl
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time
import wave

import pytest


APP = Path(__file__).parents[1] / "jukebox"


def test_terminal_controls_session_and_concurrent_launch(tmp_path):
    if not shutil.which("mpv"):
        pytest.skip("mpv is required")
    music = tmp_path / "music"
    music.mkdir()
    with wave.open(str(music / "Silence.wav"), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(b"\x00\x00" * 8000 * 60)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    mpv = fake_bin / "mpv"
    mpv.write_text(f'#!/bin/sh\nexec {shlex.quote(shutil.which("mpv"))} --no-config --load-scripts=no --ao=null "$@"\n')
    mpv.chmod(0o755)
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    data = tmp_path / "data"
    env = {**os.environ, "HOME": str(tmp_path), "XDG_CONFIG_HOME": str(tmp_path / "config"),
           "XDG_RUNTIME_DIR": str(runtime), "JUKEBOX_DATA_DIR": str(data), "JUKEBOX_SOURCE": "local",
           "JUKEBOX_MUSIC_DIR": str(music), "JUKEBOX_COLOR": "1", "TERM": "xterm-256color", "PATH": f"{fake_bin}:{os.environ['PATH']}"}
    command = f"source {shlex.quote(str(APP / 'jukebox.zsh'))}; jukebox"
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    child = subprocess.Popen(["zsh", "-dfc", command], stdin=slave, stdout=slave, stderr=slave,
                             env=env, start_new_session=True,
                             preexec_fn=lambda: fcntl.ioctl(slave, termios.TIOCSCTTY, 0))
    os.close(slave)
    output = bytearray()

    def drain():
        while select.select([master], [], [], 0)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                return
            if not chunk:
                return
            output.extend(chunk)

    def wait_for(predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            drain()
            if predicate():
                return
            assert child.poll() is None, output.decode(errors="replace")
            time.sleep(0.05)
        pytest.fail(output.decode(errors="replace"))

    def state():
        try:
            return dict(line.split("=", 1) for line in (data / "session.state").read_text().splitlines() if "=" in line)
        except FileNotFoundError:
            return {}

    try:
        wait_for(lambda: b"Choose [1-8, q]" in output)
        os.write(master, b"1\n")
        wait_for(lambda: bool(state().get("path")))
        # A second launch must fail without touching this player's live socket.
        second = subprocess.run(["zsh", "-dfc", command], input="q\n", env=env, capture_output=True, text=True, timeout=5)
        assert second.returncode == 1
        assert "already using" in second.stderr
        assert child.poll() is None
        os.write(master, b"-mt")
        wait_for(lambda: state().get("mute") == "true" and state().get("repeat") == "track")
        assert float(state()["volume"]) == 95
        wait_for(lambda: b"\x1b[1;38;2;19;34;43;48;2;142;211;216m[M]" in output)
        os.write(master, b"?")
        wait_for(lambda: b"Jukebox controls" in output)
        os.write(master, b"x")
        time.sleep(0.2)
        os.write(master, b"qy")
        # Drain graphics/color output while waiting: a richer frame can fill
        # the PTY buffer and block the player before it reads the quit key.
        wait_for(lambda: child.poll() is not None)
        child.wait(timeout=2)
        drain()
        assert child.returncode == 0, output.decode(errors="replace")
        assert state()["ended"] == "clean"
        assert not list(runtime.iterdir())
        # A released lock allows another launch and menu cancellation.
        third = subprocess.run(["zsh", "-dfc", command], input="q\n", env=env, capture_output=True, text=True, timeout=5)
        assert third.returncode == 0, third.stderr
        assert not list(runtime.iterdir())
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        os.close(master)


def test_owned_child_exits_when_parent_is_killed():
    launcher = APP / "src/process.py"
    code = "import subprocess, sys, time; child = subprocess.Popen(sys.argv[1:]); print(child.pid, flush=True); time.sleep(300)"
    parent = subprocess.Popen([sys.executable, "-c", code, sys.executable, str(launcher), "sleep", "300"],
                              stdout=subprocess.PIPE, text=True)
    child_pid = int(parent.stdout.readline())
    try:
        # Allow the wrapper to install its Linux parent-death signal.
        time.sleep(0.2)
        parent.kill()
        parent.wait(timeout=3)
        for _ in range(100):
            try:
                status = Path(f"/proc/{child_pid}/stat").read_text().split(")", 1)[1].split()[0]
            except FileNotFoundError:
                break
            if status == "Z":
                break
            time.sleep(0.02)
        else:
            pytest.fail("owned child survived the launching shell")
    finally:
        if parent.poll() is None:
            parent.kill()
            parent.wait(timeout=3)
        parent.stdout.close()
        try:
            os.kill(child_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
