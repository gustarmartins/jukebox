import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest import mock


MODULE = Path(__file__).parents[1] / "jukebox" / "src" / "library.py"
SPEC = importlib.util.spec_from_file_location("jukebox_library", MODULE)
library = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(library)


def test_incremental_refresh_reprobes_edits_and_removes_deleted_tracks(tmp_path):
    music = tmp_path / "music"
    music.mkdir()
    track = music / "Song.OPUS"
    track.write_bytes(b"original")
    cache = tmp_path / "metadata.tsv"
    with mock.patch.object(library, "probe", return_value=(str(track), ["Old", "Artist", "Album", "2026", "1", "1", "1"])) as probe:
        library.refresh(str(music), cache)
        library.refresh(str(music), cache)
        assert probe.call_count == 1
        track.write_bytes(b"edited song")
        probe.return_value = (str(track), ["New", "Artist", "Album", "2026", "2", "1", "1"])
        library.refresh(str(music), cache)
        assert probe.call_count == 2
        assert library.read_cache(cache)[str(track)][0] == "New"
        track.unlink()
        library.refresh(str(music), cache)
        assert library.read_cache(cache) == {}


def test_failed_probe_keeps_old_metadata_and_retries(tmp_path):
    track = tmp_path / "song.flac"
    track.touch()
    cache = tmp_path / "metadata.tsv"
    cache.write_text(f"{track}\tOld\tArtist\tAlbum\t2026\t1\t0\t1\n")
    with mock.patch.object(library, "probe", return_value=(str(track), None)) as probe:
        library.refresh(str(tmp_path), cache)
        library.refresh(str(tmp_path), cache)
        assert probe.call_count == 2
        assert library.read_cache(cache)[str(track)][0] == "Old"


def test_vorbis_stream_tags_cannot_corrupt_tsv_or_terminal():
    payload = {"format": {"duration": "2.5"}, "streams": [{"codec_type": "audio", "tags": {
        "TiTlE": "Title\twith\ncontrol\x1b", "ARTIST": "Artist", "TRACKNUMBER": "2/12", "DISCNUMBER": "1/2",
    }}]}
    result = subprocess.CompletedProcess([], 0, json.dumps(payload), "")
    with mock.patch.object(library.subprocess, "run", return_value=result):
        path, fields = library.probe("/music/song.ogg")
    assert fields == ["Title with control ", "Artist", "Unknown", "0", "2.5", "2", "1"]
    assert path == "/music/song.ogg"


def test_discovery_supports_formats_spaces_and_avoids_line_break_paths(tmp_path):
    expected = []
    for suffix in library.AUDIO_EXTENSIONS:
        track = tmp_path / f"It's a song{suffix.upper()}"
        track.touch()
        expected.append(str(track))
    (tmp_path / "not a song.jpg").touch()
    (tmp_path / "bad\nname.flac").touch()
    assert set(library.discover(str(tmp_path))) == set(expected)


def test_concurrent_watcher_updates_are_atomic_and_deduplicated(tmp_path):
    music = tmp_path / "music"
    music.mkdir()
    cache = tmp_path / "metadata.tsv"
    paths = [music / "one.flac", music / "two.flac"]
    for path in paths:
        path.touch()
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    probe = fake_bin / "ffprobe"
    probe.write_text('#!/usr/bin/env python3\nimport json\nprint(json.dumps({"format":{"duration":"1"}}))\n')
    probe.chmod(0o755)
    env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"}
    children = [subprocess.Popen([sys.executable, str(MODULE), "update", str(music), str(cache), "--path", str(path)],
                                 env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                for path in paths * 2]
    for child in children:
        _out, error = child.communicate(timeout=10)
        assert child.returncode == 0, error
    assert set(library.read_cache(cache)) == {str(path) for path in paths}
    assert len(cache.read_text().splitlines()) == 2


def test_list_includes_extra_source_and_date_order(tmp_path):
    music = tmp_path / "music"
    music.mkdir()
    old = music / "z.flac"
    new = music / "a.flac"
    extra = tmp_path / "osu!.ogg"
    for track in (old, new, extra):
        track.touch()
    os.utime(old, ns=(1, 1))
    os.utime(new, ns=(2, 2))
    os.utime(extra, ns=(3, 3))
    cache = tmp_path / "metadata.tsv"
    cache.write_text(f"{extra}\tSong\tArtist\tosu! Songs\t0\t1\t0\t1\n")
    assert library.source_files(str(music), cache, "date_asc") == [str(old), str(new), str(extra)]


def test_up_next_probes_once_and_reports_actual_codec(tmp_path):
    track = tmp_path / "song.opus"
    track.touch()
    payload = {"format": {"duration": "95.5"}, "streams": [{"codec_type": "audio", "codec_name": "opus",
               "sample_rate": "48000", "channels": 2, "tags": {"title": "Song", "artist": "Artist"}}]}
    result = subprocess.CompletedProcess([], 0, json.dumps(payload), "")
    with mock.patch.object(library.subprocess, "run", return_value=result) as probe:
        fields = library.details(str(track), tmp_path / "cache.tsv")
    assert probe.call_count == 1
    assert fields[:4] == ["Song", "Artist", "", "01:35"]
    assert fields[4] == "OPUS · 48 kHz · Stereo"
