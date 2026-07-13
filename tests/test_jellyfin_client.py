import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
import threading
import unittest
from argparse import Namespace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "jukebox" / "jellyfin_client.py"
SPEC = importlib.util.spec_from_file_location("jellyfin_client", MODULE_PATH)
jellyfin = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(jellyfin)


class Handler(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_args):
        pass

    def _send(self, payload, content_type="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        type(self).requests.append((self.path, self.headers))
        if self.path.startswith("/Users/user-id/Items?"):
            self._send(
                {
                    "Items": [
                        {
                            "Id": "track-id",
                            "Name": "A Song",
                            "Artists": ["An Artist"],
                            "Album": "An Album",
                            "ProductionYear": 2026,
                            "RunTimeTicks": 125_000_000,
                            "IndexNumber": 2,
                            "ParentIndexNumber": 1,
                        }
                    ]
                }
            )
        elif self.path == "/Items/track-id/Images/Primary?maxWidth=1000":
            self._send(b"fake-image", "image/jpeg")
        elif self.path == "/Audio/track-id/Lyrics":
            self._send({"Lyrics": [{"Text": "First line", "Start": 20_000_000}]})
        elif self.path == "/Users/user-id":
            self._send({"Name": "tester"})
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        type(self).requests.append((self.path, self.headers, body))
        if self.path == "/Users/AuthenticateByName":
            self._send({"AccessToken": "new-token", "User": {"Id": "new-user", "Name": "tester"}})
        else:
            self.send_error(404)


class JellyfinClientTest(unittest.TestCase):
    def setUp(self):
        Handler.requests = []
        self.temp = tempfile.TemporaryDirectory()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.config = Path(self.temp.name) / "jellyfin.json"
        self.config.write_text(
            json.dumps(
                {
                    "server": self.url,
                    "token": "secret-token",
                    "user_id": "user-id",
                    "username": "tester",
                    "device_id": "device-id",
                }
            )
        )
        self.env = mock.patch.dict(os.environ, {"JUKEBOX_JELLYFIN_CONFIG": str(self.config)}, clear=False)
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def test_sync_writes_token_free_stream_and_metadata(self):
        cache = Path(self.temp.name) / "metadata.tsv"
        self.assertEqual(jellyfin.command_sync(Namespace(cache=str(cache))), 0)
        fields = cache.read_text().rstrip().split("\t")
        self.assertEqual(fields[0], f"{self.url}/Audio/track-id/stream?static=true")
        self.assertNotIn("secret-token", cache.read_text())
        self.assertEqual(fields[1:5], ["A Song", "An Artist", "An Album", "2026"])
        self.assertEqual(fields[6:], ["2", "1"])
        self.assertIn('Token="secret-token"', Handler.requests[0][1]["Authorization"])

    def test_login_saves_private_per_user_token(self):
        with mock.patch("getpass.getpass", return_value="password"):
            self.assertEqual(
                jellyfin.command_login(Namespace(server=self.url, username="tester")),
                0,
            )
        saved = json.loads(self.config.read_text())
        self.assertEqual(saved["token"], "new-token")
        self.assertEqual(saved["user_id"], "new-user")
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.assertEqual(Handler.requests[-1][2], {"Username": "tester", "Pw": "password"})

    def test_art_and_synced_lyrics(self):
        reference = f"{self.url}/Audio/track-id/stream?static=true"
        image = Path(self.temp.name) / "cover.jpg"
        self.assertEqual(jellyfin.command_art(Namespace(reference=reference, output=str(image), max_width=1000)), 0)
        self.assertEqual(image.read_bytes(), b"fake-image")
        payload = jellyfin.request(jellyfin.load_config(), "/Audio/track-id/Lyrics")
        self.assertEqual(jellyfin.normalize_lyrics(payload), [(2000, "First line")])

    def test_mpv_config_is_private_and_uses_header(self):
        path = Path(self.temp.name) / "mpv.conf"
        jellyfin.command_mpv_config(Namespace(output=str(path)))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertIn("http-header-fields=X-Emby-Token: secret-token", path.read_text())
        if shutil.which("mpv"):
            parsed = subprocess.run(
                ["mpv", "--no-config", f"--include={path}", "--version"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(parsed.returncode, 0, parsed.stderr)

    def test_lrc_and_plain_lyrics(self):
        self.assertEqual(
            jellyfin.parse_lrc("[00:01.25]Hello\n[00:03.005]World"),
            [(1250, "Hello"), (3005, "World")],
        )
        self.assertEqual(jellyfin.parse_lrc("Hello\nWorld"), [(-1, "Hello"), (-1, "World")])
        track = Path(self.temp.name) / "Song.flac"
        track.touch()
        track.with_suffix(".lrc").write_text("[00:01.00]Sidecar line\n")
        self.assertEqual(jellyfin.local_lyrics(str(track)), [(1000, "Sidecar line")])


if __name__ == "__main__":
    unittest.main()
