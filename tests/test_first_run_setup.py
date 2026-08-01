import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "jukebox" / "jukebox.zsh"


class FirstRunSetupTest(unittest.TestCase):
    def run_zsh(self, home: Path, command: str, music_dir: str | None = None):
        env = os.environ.copy()
        env.update({"HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config")})
        env.pop("JUKEBOX_MUSIC_DIR", None)
        if music_dir is not None:
            env["JUKEBOX_MUSIC_DIR"] = music_dir
        return subprocess.run(
            ["zsh", "-dfc", f'source "{SCRIPT}"; {command}'],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_saved_directory_is_loaded_without_running_shell_code(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            library = home / "My Music"
            library.mkdir()

            saved = self.run_zsh(home, f'_jukebox_save_music_dir "{library}"')
            self.assertEqual(saved.returncode, 0, saved.stderr)
            settings = home / ".config" / "jukebox" / "settings"
            self.assertEqual(settings.read_text(), f"music_dir\t{library}\n")
            self.assertEqual(oct(settings.stat().st_mode & 0o777), "0o600")

            loaded = self.run_zsh(home, '[[ "$JUKEBOX_MUSIC_DIR" == "$HOME/My Music" ]]')
            self.assertEqual(loaded.returncode, 0, loaded.stderr)

    def test_environment_override_wins_over_saved_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            saved_library = home / "Saved"
            override_library = home / "Override"
            saved_library.mkdir()
            override_library.mkdir()

            saved = self.run_zsh(home, f'_jukebox_save_music_dir "{saved_library}"')
            self.assertEqual(saved.returncode, 0, saved.stderr)
            loaded = self.run_zsh(
                home,
                '[[ "$JUKEBOX_MUSIC_DIR" == "$HOME/Override" ]]',
                str(override_library),
            )
            self.assertEqual(loaded.returncode, 0, loaded.stderr)


if __name__ == "__main__":
    unittest.main()
