import json
import os
import random
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(REPO_ROOT / "jukebox" / "src"))
import api_client  # noqa: E402

SCRIPT = REPO_ROOT / "jukebox" / "jukebox.zsh"


class ApiClientUnitTest(unittest.TestCase):
    def test_split_genres_matches_rhythm_delimiters(self):
        self.assertEqual(api_client.split_genres("Electronic; Nightcore"), {"electronic", "nightcore"})
        self.assertEqual(api_client.split_genres("Video Game, Rock / Soundtrack"), {"video game", "rock", "soundtrack"})
        self.assertEqual(api_client.split_genres("Other; Unknown"), set())

    def test_parse_ttml_produces_sorted_timestamps(self):
        xml = (
            '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
            '<p begin="00:12.500">Second line</p>'
            '<p begin="00:05.100">First <span>line</span></p>'
            "</div></body></tt>"
        )
        self.assertEqual(api_client.parse_ttml(xml), [(5100, "First line"), (12500, "Second line")])

    def test_recommendations_rank_lastfm_and_multi_genre_highest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache = root / "metadata.tsv"
            rows = [
                "/m/seed.flac\tJust Dance\tLady Gaga\tThe Fame\t2008\t240\t1\t1",
                "/m/lfm_track.flac\tBad Romance\tLady Gaga\tThe Fame Monster\t2009\t294\t1\t1",
                "/m/lfm_artist.flac\tTeenage Dream\tKaty Perry\tTeenage Dream\t2010\t227\t1\t1",
                "/m/genre_only.flac\tBlinding Lights\tThe Weeknd\tAfter Hours\t2020\t200\t1\t1",
                "/m/nightcore.mp3\tPinball (Nightcore Mix)\tCCK\tNightcore Mix\t2008\t180\t1\t1",
                "/m/metal.flac\tMaster of Puppets\tMetallica\tMaster of Puppets\t1986\t515\t1\t1",
            ]
            cache.write_text("\n".join(rows) + "\n", encoding="utf-8")
            Path(str(cache) + ".genres.json").write_text(
                json.dumps(
                    {
                        "/m/seed.flac": "Pop; Dance",
                        "/m/lfm_track.flac": "Pop; Dance",
                        "/m/lfm_artist.flac": "Pop; Dance",
                        "/m/genre_only.flac": "Pop",
                        "/m/nightcore.mp3": "Electronic; Nightcore",
                        "/m/metal.flac": "Metal",
                    }
                ),
                encoding="utf-8",
            )

            def fake_get_json(url, **_kw):
                if "track.getSimilar" in url:
                    return {
                        "similartracks": {
                            "track": [
                                {"name": "Bad Romance", "artist": {"name": "Lady Gaga"}, "match": "0.95"},
                            ]
                        }
                    }
                if "artist.getSimilar" in url:
                    return {
                        "similarartists": {
                            "artist": [
                                {"name": "Katy Perry", "match": "0.90"},
                            ]
                        }
                    }
                return None

            cfg = {"online_enabled": True, "lastfm_enabled": True, "lastfm_api_key": "testkey"}
            candidates = [r.split("\t")[0] for r in rows]
            with mock.patch.object(api_client, "http_get_json", side_effect=fake_get_json), \
                 mock.patch.object(api_client, "_LAST_LASTFM_REQUEST", 0.0), \
                 mock.patch("time.sleep"):
                ordered = api_client.build_recommendations(
                    seed_paths=["/m/seed.flac"],
                    candidate_paths=candidates,
                    cache_path=cache,
                    cfg=cfg,
                    base_data_dir=root / "data",
                    rng=random.Random(42),
                )

            self.assertNotIn("/m/seed.flac", ordered)
            # Last.fm track & artist matches must come first; Nightcore should be penalized for a non-Nightcore seed.
            self.assertEqual(ordered[0], "/m/lfm_track.flac")
            self.assertEqual(ordered[1], "/m/lfm_artist.flac")
            self.assertEqual(ordered[-1], "/m/nightcore.mp3")

    def test_recommendations_keep_nightcore_and_game_soundtrack_affinity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache = root / "metadata.tsv"
            rows = [
                "/m/head1.flac\tChange\tConor & Jay\tGrand Theft Auto III: Head Radio\t2001\t200\t1\t1",
                "/m/head2.flac\tFade Away\tCraig Gray\tGrand Theft Auto III: Head Radio\t2001\t210\t2\t1",
                "/m/pop.flac\tHello\tAdele\t25\t2015\t295\t1\t1",
            ]
            cache.write_text("\n".join(rows) + "\n", encoding="utf-8")
            Path(str(cache) + ".genres.json").write_text(
                json.dumps(
                    {
                        "/m/head1.flac": "Video Game; Rock",
                        "/m/head2.flac": "Video Game; Rock",
                        "/m/pop.flac": "Pop",
                    }
                ),
                encoding="utf-8",
            )
            cfg = {"online_enabled": False}
            ordered = api_client.build_recommendations(
                seed_paths=["/m/head1.flac"],
                candidate_paths=["/m/head1.flac", "/m/head2.flac", "/m/pop.flac"],
                cache_path=cache,
                cfg=cfg,
                base_data_dir=root / "data",
                rng=random.Random(1),
            )
            self.assertEqual(ordered[0], "/m/head2.flac")

    def test_online_lyrics_fallback_and_disk_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls = []

            def fake_get_json(url, **_kw):
                calls.append(url)
                if "betterlyrics.org" in url:
                    return None
                if "lrclib.net" in url:
                    return [
                        {
                            "artistName": "Lady Gaga",
                            "trackName": "Just Dance",
                            "syncedLyrics": "[00:01.20]RedOne\n[00:04.50]Konvict",
                        }
                    ]
                return None

            cfg = {"online_enabled": True, "online_lyrics": True}
            with mock.patch.object(api_client, "http_get_json", side_effect=fake_get_json):
                first = api_client.fetch_online_lyrics("Lady Gaga", "Just Dance", "The Fame", 240, cfg, root)
                self.assertEqual(first, [(1200, "RedOne"), (4500, "Konvict")])
                call_count = len(calls)
                # Second call must come from disk cache with zero network calls.
                second = api_client.fetch_online_lyrics("Lady Gaga", "Just Dance", "The Fame", 240, cfg, root)
                self.assertEqual(second, first)
                self.assertEqual(len(calls), call_count)

    def test_online_art_deezer_verified_match_and_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out1 = root / "out1.jpg"
            out2 = root / "out2.jpg"
            fake_jpg = b"\xff\xd8\xff\xe0" + b"0" * 512

            def fake_get_json(url, **_kw):
                if "api.deezer.com/search?" in url:
                    return {
                        "data": [
                            {
                                "title": "Just Dance",
                                "artist": {"name": "Lady Gaga"},
                                "album": {"cover_xl": "https://cdn.example/cover.jpg"},
                            }
                        ]
                    }
                return None

            cfg = {"online_enabled": True, "online_art": True}
            with mock.patch.object(api_client, "http_get_json", side_effect=fake_get_json), \
                 mock.patch.object(api_client, "http_get_bytes", return_value=fake_jpg) as m_bytes:
                ok1 = api_client.fetch_online_art("Lady Gaga", "Just Dance", "The Fame", out1, cfg, root)
                self.assertTrue(ok1)
                self.assertEqual(out1.read_bytes(), fake_jpg)
                self.assertEqual(m_bytes.call_count, 1)

                # Cache-only lookup must succeed without network calls.
                ok2 = api_client.fetch_online_art("Lady Gaga", "Just Dance", "The Fame", out2, cfg, root, cache_only=True)
                self.assertTrue(ok2)
                self.assertEqual(out2.read_bytes(), fake_jpg)
                self.assertEqual(m_bytes.call_count, 1)

    def test_lastfm_config_roundtrip_and_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg_file = Path(tmp) / "jukebox" / "api.json"
            with mock.patch.dict(os.environ, {"JUKEBOX_API_CONFIG": str(cfg_file)}, clear=False):
                rc = api_client.main_with_args(["lastfm-setup", "secret_key_12345"]) if hasattr(api_client, "main_with_args") else None
                if rc is None:
                    args = api_client.build_parser().parse_args(["lastfm-setup", "secret_key_12345"])
                    rc = args.func(args)
                self.assertEqual(rc, 0)
                self.assertEqual(stat.S_IMODE(cfg_file.stat().st_mode), 0o600)
                self.assertEqual(api_client.load_config()["lastfm_api_key"], "secret_key_12345")

                args = api_client.build_parser().parse_args(["lastfm-logout"])
                self.assertEqual(args.func(args), 0)
                self.assertNotIn("lastfm_api_key", api_client.load_config())

    def test_mode_6_alt_r_builds_smart_recommended_playlist(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            music = root / "music"
            music.mkdir()
            seed = music / "Alpha.flac"
            related = music / "Beta.flac"
            unrelated = music / "Gamma.flac"
            for p in (seed, related, unrelated):
                p.touch()

            fake_bin = root / "bin"
            fake_bin.mkdir()
            scripts = {
                "ffprobe": (
                    "#!/usr/bin/env python3\nimport json, os, sys\n"
                    "name = os.path.splitext(os.path.basename(sys.argv[-1]))[0]\n"
                    "meta = {'Alpha': ('Alpha', 'ArtistA', 'AlbA', 'Pop; Dance'), "
                    "'Beta': ('Beta', 'ArtistB', 'AlbB', 'Pop; Dance'), "
                    "'Gamma': ('Gamma', 'ArtistC', 'AlbC', 'Metal')}[name]\n"
                    "print(json.dumps({'format': {'duration':'180', "
                    "'tags':{'title':meta[0],'artist':meta[1],'album':meta[2],'genre':meta[3]}}}))\n"
                ),
                "fzf": (
                    "#!/usr/bin/env python3\nimport sys\n"
                    "rows=sys.stdin.read().splitlines()\n"
                    "print('alt-r')\n"
                    "print(rows[0])\n"
                ),
                "mpv": (
                    "#!/usr/bin/env python3\nimport os, pathlib, sys\n"
                    "playlist=next(arg.split('=',1)[1] for arg in sys.argv if arg.startswith('--playlist='))\n"
                    "pathlib.Path(os.environ['JUKEBOX_TEST_PLAYLIST']).write_text(pathlib.Path(playlist).read_text())\n"
                ),
            }
            for name, content in scripts.items():
                cmd = fake_bin / name
                cmd.write_text(content, encoding="utf-8")
                cmd.chmod(0o755)

            captured = root / "captured.m3u"
            env = {
                **os.environ,
                "HOME": str(root),
                "XDG_CONFIG_HOME": str(root / "config"),
                "JUKEBOX_DATA_DIR": str(root / "data"),
                "JUKEBOX_MUSIC_DIR": str(music),
                "JUKEBOX_SOURCE": "local",
                "JUKEBOX_ONLINE_APIS": "0",
                "JUKEBOX_TEST_PLAYLIST": str(captured),
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
            }
            result = subprocess.run(
                ["zsh", "-dfc", f"source {shlex.quote(str(SCRIPT))}; jukebox"],
                input="6\n",
                env=env,
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertTrue(captured.exists(), result.stdout + result.stderr)
            playlist = captured.read_text(encoding="utf-8").splitlines()
            self.assertEqual(playlist[0], str(seed))
            self.assertEqual(playlist[1], str(related))
            self.assertEqual(playlist[2], str(unrelated))


if __name__ == "__main__":
    unittest.main()
