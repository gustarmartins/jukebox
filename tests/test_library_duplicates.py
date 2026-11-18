import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

import pytest


APP = Path(__file__).parents[1] / "jukebox"
SPEC = importlib.util.spec_from_file_location("duplicate_library", APP / "src/library.py")
library = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(library)


def write_cache(cache, rows):
    cache.write_text("".join("\t".join([str(path), *fields]) + "\n" for path, fields in rows.items()))


def test_automatic_queue_prefers_local_mix_over_beatmap_copies(tmp_path):
    music = tmp_path / "music"
    local = music / "Katy Perry - E.T. (Nightcore Mix).mp3"
    osu1 = tmp_path / "osu" / "1622128" / "audio.mp3"
    osu2 = tmp_path / "osu" / "33761" / "Katy Perry - E.T. (Nightcore Mix).mp3"
    rows = {
        local: ["E.T. (Solo Album Version)", "Katy Perry", "Nightcore Mix", "2011", "165", "8", "1"],
        osu1: ["E.T. (Nightcore Mix)", "Katy Perry", "osu! Songs", "0", "78", "0", "1"],
        osu2: ["E.T. (Nightcore Mix)", "Katy Perry", "osu! Songs", "0", "163", "0", "1"],
    }
    for path in rows:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"audio")
    cache = tmp_path / "metadata.tsv"
    write_cache(cache, rows)
    paths = [str(osu1), str(osu2), str(local)]

    assert library.deduplicate_tracks(paths, str(music), cache) == [str(local)]
    # An explicitly picked copy wins over a later automatic continuation.
    assert library.deduplicate_tracks(paths, str(music), cache, keep_prefix=1) == [str(osu1)]
    # Intentional selections/history retain their occurrences and order.
    assert library.deduplicate_tracks(paths, str(music), cache, keep_prefix=2) == paths[:2]
    assert all(path.read_bytes() == b"audio" for path in rows)
    assert len(library.read_cache(cache)) == 3


def test_deduplication_preserves_editions_artists_and_unknown_metadata(tmp_path):
    music = tmp_path / "Nightcore and originals"
    rows = {}
    variants = [
        ("Original.flac", "Song", "Singer", "Album"),
        ("Compilation.mp3", "Song", "Singer", "Compilation"),
        ("Nightcore.mp3", "Song (Nightcore Mix)", "Singer", "Album"),
        ("Live.flac", "Song (Live)", "Singer", "Live Album"),
        ("Remix.flac", "Song (DJ Remix)", "Singer", "Remixes"),
        ("Other.flac", "Song", "Another Singer", "Album"),
        ("Unknown1.mp3", "Song", "Unknown", "Unknown"),
        ("Unknown2.mp3", "Song", "Unknown", "Unknown"),
    ]
    for name, title, artist, album in variants:
        rows[music / name] = [title, artist, album, "2026", "180", "1", "1"]
    cache = tmp_path / "metadata.tsv"
    write_cache(cache, rows)
    paths = [str(path) for path in rows]
    result = library.deduplicate_tracks(paths, str(music), cache)
    assert result == [path for path in paths if not path.endswith("Compilation.mp3")]


@pytest.mark.parametrize("mode", ["1", "6", "7", "8", "0"])
def test_launch_modes_filter_only_automatic_queue_entries(tmp_path, mode):
    music = tmp_path / "music"
    music.mkdir()
    first = music / "A copy.mp3"
    preferred = music / "B copy.flac"
    other = music / "C other.mp3"
    data = tmp_path / "data"
    data.mkdir()
    rows = {
        first: ["Echo", "Singer", "Album", "2026", "180", "1", "1"],
        preferred: ["Echo", "Singer", "Compilation", "2026", "180", "1", "1"],
        other: ["Zulu", "Singer", "Album", "2026", "180", "2", "1"],
    }
    for path in rows:
        path.write_bytes(b"audio")
    cache = data / "metadata.tsv"
    write_cache(cache, rows)
    Path(str(cache) + ".files.json").write_text(json.dumps({
        str(path): [path.stat().st_mtime_ns, path.stat().st_size] for path in rows
    }))
    original = [str(path) for path in rows]
    (data / "session.m3u").write_text("\n".join(original) + "\n")
    (data / "session.state").write_text(f"source=local\npath={first}\npos=0\ncount=3\ntime=0\n")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    commands = {
        "fzf": "#!/usr/bin/env python3\nimport os, sys\nrows=sys.stdin.read().splitlines()\n"
               "if os.environ['TEST_MODE']=='6':\n print('enter'); print(rows[0])\n"
               "else:\n print('\\n'.join(rows))\n",
        "mpv": "#!/usr/bin/env python3\nimport os, pathlib, sys\n"
               "playlist=next(a.split('=',1)[1] for a in sys.argv if a.startswith('--playlist='))\n"
               "pathlib.Path(os.environ['TEST_PLAYLIST']).write_text(pathlib.Path(playlist).read_text())\n",
    }
    for name, content in commands.items():
        command = fake_bin / name
        command.write_text(content)
        command.chmod(0o755)
    captured = tmp_path / "captured.m3u"
    runtime = tmp_path / "run"
    runtime.mkdir()
    env = {**os.environ, "HOME": str(tmp_path), "XDG_CONFIG_HOME": str(tmp_path / "config"),
           "XDG_RUNTIME_DIR": str(runtime), "JUKEBOX_DATA_DIR": str(data), "JUKEBOX_SOURCE": "local",
           "JUKEBOX_MUSIC_DIR": str(music), "TEST_MODE": mode, "TEST_PLAYLIST": str(captured),
           "PATH": f"{fake_bin}:{os.environ['PATH']}"}
    command = f"source {shlex.quote(str(APP / 'jukebox.zsh'))}; jukebox"
    result = subprocess.run(["zsh", "-dfc", command], input=mode + "\n", env=env,
                            capture_output=True, text=True, timeout=12)
    assert captured.exists(), result.stdout + result.stderr
    paths = captured.read_text().splitlines()
    if mode in {"8", "0"}:
        assert paths == original
    elif mode == "6":
        assert paths == [str(first), str(other)]
    else:
        assert set(paths) == {str(preferred), str(other)}
        assert len(paths) == 2


@pytest.mark.parametrize("mode", ["2", "3"])
def test_redo_queue_filters_automatic_entries_but_keeps_custom_selection(tmp_path, mode):
    first = tmp_path / "A.mp3"
    preferred = tmp_path / "B.flac"
    cache = tmp_path / "metadata.tsv"
    write_cache(cache, {
        first: ["Song", "Singer", "Album", "2026", "180", "1", "1"],
        preferred: ["Song", "Singer", "Album", "2026", "180", "1", "1"],
    })
    playlist = tmp_path / "playlist.m3u"
    code = f'''source {shlex.quote(str(APP / 'src/queue.zsh'))}
_JUKEBOX_PYTHON={shlex.quote(sys.executable)}
_JUKEBOX_SCRIPT_DIR={shlex.quote(str(APP))}
_jukebox_source=local
_jukebox_runtime={shlex.quote(str(tmp_path))}
musicdir={shlex.quote(str(tmp_path))}
cachefile={shlex.quote(str(cache))}
playlist={shlex.quote(str(playlist))}
queuefile={shlex.quote(str(tmp_path / 'queue.txt'))}
_jukebox_wait_cache() {{ :; }}
_jukebox_source_files() {{ print -rl -- {shlex.quote(str(first))} {shlex.quote(str(preferred))}; }}
_jukebox_setup_fzf_sort() {{ _fzf_sort_dir=$(mktemp -d "$_jukebox_runtime/sort.XXXXXXXX"); }}
_jukebox_get_input_list() {{ print -rl -- "$@"; }}
_jukebox_fzf() {{ cat; }}
_jukebox_set() {{ :; }}
_jukebox_batch_get() {{ :; }}
_jukebox_clear_next_meta() {{ :; }}
_jukebox_snapshot_playlist() {{ :; }}
_jukebox_save_state() {{ :; }}
_jukebox_redo_queue
'''
    result = subprocess.run(["zsh", "-dfc", code], input=mode + "\n",
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result.stderr
    assert playlist.read_text().splitlines() == ([str(first), str(preferred)] if mode == "2" else [str(preferred)])
