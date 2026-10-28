import os
import shlex
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "jukebox" / "jukebox.zsh"
LIBRARY = SCRIPT.parent / "src" / "library.py"


class LocalLibraryScanTest(unittest.TestCase):
    def test_local_startup_preserves_jellyfin_snapshot_in_progress(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            music = root / "music"
            music.mkdir()
            data = root / "data"
            data.mkdir()
            other_snapshot = data / "session-jellyfin.state.tmp.9876"
            other_snapshot.write_text("active other-source snapshot\n")
            env = {**os.environ, "HOME": str(root), "XDG_CONFIG_HOME": str(root / "config"),
                   "XDG_CACHE_HOME": str(root / "cache"), "JUKEBOX_SOURCE": "local",
                   "JUKEBOX_DATA_DIR": str(data), "JUKEBOX_MUSIC_DIR": str(music)}
            result = subprocess.run(["zsh", "-dfc", f"source {shlex.quote(str(SCRIPT))}; jukebox"],
                                    input="q\n", env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(other_snapshot.read_text(), "active other-source snapshot\n")

    def test_play_from_selection_follows_the_visible_title_order(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            music = root / "music"
            music.mkdir()
            first_by_title = music / "Z filename.flac"
            last_by_title = music / "A filename.flac"
            first_by_title.touch()
            last_by_title.touch()
            fake_bin = root / "bin"
            fake_bin.mkdir()
            scripts = {
                "ffprobe": "#!/usr/bin/env python3\nimport json, os, sys\n"
                           "title = 'Alpha' if os.path.basename(sys.argv[-1]).startswith('Z') else 'Zulu'\n"
                           "print(json.dumps({'format': {'duration':'1', 'tags':{'title':title}}}))\n",
                "fzf": "#!/usr/bin/env python3\nimport sys\nrows=sys.stdin.read().splitlines()\nprint('enter')\nprint(rows[0])\n",
                "mpv": "#!/usr/bin/env python3\nimport os, pathlib, sys\n"
                       "playlist=next(arg.split('=',1)[1] for arg in sys.argv if arg.startswith('--playlist='))\n"
                       "pathlib.Path(os.environ['JUKEBOX_TEST_PLAYLIST']).write_text(pathlib.Path(playlist).read_text())\n",
            }
            for name, content in scripts.items():
                command = fake_bin / name
                command.write_text(content)
                command.chmod(0o755)
            captured = root / "captured.m3u"
            env = {**os.environ, "HOME": str(root), "XDG_CONFIG_HOME": str(root / "config"),
                   "JUKEBOX_DATA_DIR": str(root / "data"), "JUKEBOX_MUSIC_DIR": str(music),
                   "JUKEBOX_SOURCE": "local", "JUKEBOX_TEST_PLAYLIST": str(captured),
                   "PATH": f"{fake_bin}:{os.environ['PATH']}"}
            result = subprocess.run(["zsh", "-dfc", f"source {shlex.quote(str(SCRIPT))}; jukebox"],
                                    input="6\n", env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)  # Stub intentionally never starts a player.
            self.assertTrue(captured.exists(), result.stdout + result.stderr)
            self.assertEqual(captured.read_text().splitlines(), [str(first_by_title), str(last_by_title)])

    def test_scan_indexes_flac_and_mp3_recursively(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            library = root / "library"
            nested = library / "Artist" / "Album"
            nested.mkdir(parents=True)
            flac = nested / "First.FLAC"
            mp3 = nested / "Second.Mp3"
            ignored = nested / "cover.jpg"
            for path in (flac, mp3, ignored):
                path.touch()

            fake_bin = root / "bin"
            fake_bin.mkdir()
            ffprobe = fake_bin / "ffprobe"
            ffprobe.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "name = os.path.splitext(os.path.basename(sys.argv[-1]))[0]\n"
                "print(json.dumps({'format': {'duration': '42.5', "
                "'tags': {'title': name, 'artist': 'Test Artist'}}}))\n",
                encoding="utf-8",
            )
            ffprobe.chmod(0o755)

            cache = root / "metadata.tsv"
            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
            result = subprocess.run(
                ["python3", str(LIBRARY), "scan", str(library), str(cache)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            rows = [line.split("\t") for line in cache.read_text().splitlines()]
            self.assertEqual([row[0] for row in rows], sorted([str(flac), str(mp3)]))
            self.assertTrue(all(len(row) == 8 for row in rows))
            self.assertEqual([row[1] for row in rows], ["First", "Second"])

    def test_quitting_launch_menu_stops_recursive_watcher(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            library = root / "library"
            library.mkdir()
            fake_bin = root / "bin"
            fake_bin.mkdir()
            watcher_pid_file = root / "watcher.pid"

            (fake_bin / "pgrep").write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            (fake_bin / "inotifywait").write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$$\" > \"$JUKEBOX_TEST_WATCHER_PID\"\n"
                "exec sleep 300\n",
                encoding="utf-8",
            )
            for command in ("pgrep", "inotifywait"):
                (fake_bin / command).chmod(0o755)

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(root),
                    "JUKEBOX_DATA_DIR": str(root / "data"),
                    "JUKEBOX_MUSIC_DIR": str(library),
                    "JUKEBOX_TEST_WATCHER_PID": str(watcher_pid_file),
                    "PATH": f"{fake_bin}{os.pathsep}{env['PATH']}",
                }
            )
            command = (
                f"source {shlex.quote(str(SCRIPT))}; "
                "(sleep 0.2; print q) | jukebox"
            )
            result = subprocess.run(
                ["zsh", "-dfc", command],
                env=env,
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(watcher_pid_file.exists(), "watcher did not start")
            watcher_pid = int(watcher_pid_file.read_text().strip())
            for _ in range(20):
                try:
                    os.kill(watcher_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                self.fail(f"watcher process {watcher_pid} survived menu exit")


if __name__ == "__main__":
    unittest.main()
