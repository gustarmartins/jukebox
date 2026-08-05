import os
import shlex
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "jukebox" / "jukebox.zsh"
SCAN_START = '    "$_JUKEBOX_PYTHON" -c "\n'
SCAN_END = '\n" "${JUKEBOX_MUSIC_DIR:-$HOME/Music}" "$cachefile" &'


def local_scan_source() -> str:
    shell_source = SCRIPT.read_text(encoding="utf-8")
    return shell_source.split(SCAN_START, 1)[1].split(SCAN_END, 1)[0]


class LocalLibraryScanTest(unittest.TestCase):
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
                ["python3", "-c", local_scan_source(), str(library), str(cache)],
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
