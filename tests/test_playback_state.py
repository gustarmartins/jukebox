import os
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

import pytest


APP = Path(__file__).parents[1] / "jukebox"


def zsh(code, **kwargs):
    return subprocess.run(["zsh", "-dfc", code], capture_output=True, text=True, timeout=10, **kwargs)


@pytest.fixture
def player(tmp_path):
    if not shutil.which("mpv"):
        pytest.skip("mpv is required for IPC integration")
    sock = tmp_path / "mpv.sock"
    process = subprocess.Popen(["mpv", "--no-config", "--load-scripts=no", "--ao=null", "--no-video",
                                "--no-terminal", "--idle=yes", f"--input-ipc-server={sock}"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if sock.exists():
                break
            assert process.poll() is None, "mpv exited during startup"
            time.sleep(0.02)
        assert sock.exists()
        yield sock
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def ipc_setup(sock):
    return f'''source {shlex.quote(str(APP / 'src/ipc.zsh'))}
_JUKEBOX_PYTHON={shlex.quote(sys.executable)}
mpvsock={shlex.quote(str(sock))}
_jukebox_runtime={shlex.quote(str(sock.parent))}
_jukebox_log() {{ :; }}
'''


def test_repeat_controls_use_real_mpv_properties(player):
    code = ipc_setup(player) + f'''source {shlex.quote(str(APP / 'src/controls.zsh'))}
_repeat_mode=off
_jukebox_cycle_repeat
_jukebox_batch_get loop-file loop-playlist
_jukebox_cycle_repeat
_jukebox_batch_get loop-file loop-playlist
_jukebox_cycle_repeat
_jukebox_batch_get loop-file loop-playlist
'''
    result = zsh(code)
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == ["inf\x1ffalse", "false\x1finf", "false\x1ffalse"]


def test_session_roundtrip_restores_audio_controls(player, tmp_path):
    state = tmp_path / "session.state"
    playlist = tmp_path / "session.m3u"
    playlist.write_text("/music/song.flac\n")
    code = ipc_setup(player) + f'''source {shlex.quote(str(APP / 'src/session.zsh'))}
_jukebox_source=local
_jukebox_state_file={shlex.quote(str(state))}
_jukebox_state_playlist={shlex.quote(str(playlist))}
_render_path=/music/song.flac
_render_volume=35.5
_render_mute=true
_repeat_mode=queue
_jukebox_save_state
_jukebox_load_state || exit 1
_lyrics_mode=0
_jukebox_apply_resume
_jukebox_batch_get volume mute loop-playlist pause
'''
    result = zsh(code)
    assert result.returncode == 0, result.stderr
    volume, mute, repeat, pause = result.stdout.strip().split("\x1f")
    assert float(volume) == 35.5
    assert (mute, repeat, pause) == ("true", "inf", "false")


def test_corrupt_session_values_are_sanitized_without_execution(tmp_path):
    sentinel = tmp_path / "must-not-exist"
    state = tmp_path / "session.state"
    playlist = tmp_path / "session.m3u"
    playlist.write_text("/music/song.flac\n")
    state.write_text(f"source=local\npath=/music/song.flac\npos=oops\ncount=999999999999999999\n"
                     f"time=1.$(touch {sentinel})\nduration=NaN\nspeed=inf\npitch=0\n"
                     "lyrics=32\nvolume=2000\nmute=invalid\napc=invalid\nrepeat=forever\nrtmode=invalid\n")
    code = f'''source {shlex.quote(str(APP / 'src/session.zsh'))}
_jukebox_source=local
_jukebox_state_file={shlex.quote(str(state))}
_jukebox_state_playlist={shlex.quote(str(playlist))}
_jukebox_load_state || exit 1
print -r -- "$_resume_pos|$_resume_count|$_resume_time|$_resume_duration|$_resume_speed|$_resume_pitch|$_resume_lyrics|$_resume_volume|$_resume_mute|$_resume_apc|$_resume_repeat|$_resume_rtmode"
'''
    result = zsh(code)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "0|0|0|0|1.0|1.0|0||false|true|off|tempo"
    assert not sentinel.exists()


def test_lyrics_honor_milliseconds_and_do_not_highlight_early():
    code = f'''source {shlex.quote(str(APP / 'src/lyrics.zsh'))}
_lyrics_lines=(First Second)
_lyrics_starts=(1250 1750)
_lyrics_active_index=0
for _render_time_pos in 1.200 1.250 1.749 1.750; do
    _jukebox_update_lyric_index
    print -r -- $_lyrics_active_index
done
'''
    result = zsh(code)
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == ["0", "1", "1", "2"]


def test_resume_seeks_to_a_subsecond_position():
    code = f'''source {shlex.quote(str(APP / 'src/session.zsh'))}
_JUKEBOX_PYTHON={shlex.quote(sys.executable)}
_jukebox_set() {{ print -r -- "$1"; }}
_resume_time=0.250
_resume_mute=false
_resume_repeat=off
_lyrics_mode=0
_jukebox_apply_resume
'''
    result = zsh(code)
    assert result.returncode == 0, result.stderr
    commands = [json.loads(line)["command"] for line in result.stdout.splitlines()]
    assert commands[0] == ["seek", 0.25, "absolute"]
    assert commands[-1] == ["set_property", "pause", False]


def test_nightcore_missing_argument_returns_instead_of_looping():
    result = zsh(f"source {shlex.quote(str(APP / 'jukebox.zsh'))}; nightcore --speed")
    assert result.returncode == 1
    assert "Missing value" in result.stderr
