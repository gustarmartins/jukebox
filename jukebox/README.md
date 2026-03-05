# 🎵 Jukebox

A terminal-based FLAC music player for zsh. Browse your library with fuzzy search, build custom queues, see album art in the terminal, and control playback — all without leaving the command line.

## Features

- **8 playback modes** — play all, sort A-Z/Z-A, sort by date, browse & pick, shuffle, or build a custom queue
- **Album art** — displays cover art directly in the terminal (via [chafa](https://hpjansson.org/chafa/))
- **Fuzzy browsing** — preview songs with metadata + album art before playing (via [fzf](https://github.com/junegunn/fzf))
- **Queue builder** — TAB to pick songs, Ctrl-A to select all, build your own playlist
- **Live queue picker** — press `L` during playback to see the queue and jump to any track
- **Keyboard controls** — seek, skip, speed up/down, all from the keyboard

## Dependencies

| Tool | What it does |
|------|-------------|
| [zsh](https://www.zsh.org/) | Shell (required) |
| [mpv](https://mpv.io/) | Audio playback |
| [fzf](https://github.com/junegunn/fzf) | Fuzzy finder for browsing & queue |
| [ffmpeg](https://ffmpeg.org/) | Extracts album art + metadata |
| [chafa](https://hpjansson.org/chafa/) | Renders album art as text in the terminal |
| [socat](http://www.dest-unreach.org/socat/) | IPC communication with mpv |
| [jq](https://jqlang.github.io/jq/) | Parses JSON responses from mpv |
| [bc](https://www.gnu.org/software/bc/) | Duration formatting |

### Install dependencies

**Arch Linux:**
```bash
sudo pacman -S zsh mpv fzf ffmpeg chafa socat jq bc
```

**Ubuntu / Debian:**
```bash
sudo apt install zsh mpv fzf ffmpeg chafa socat jq bc
```

**Fedora:**
```bash
sudo dnf install zsh mpv fzf ffmpeg chafa socat jq bc
```

## Setup

1. **Clone or copy** this folder somewhere (e.g. `~/jukebox`):
   ```bash
   git clone <url> ~/jukebox
   # or just copy jukebox.zsh wherever you want
   ```

2. **Add to your `~/.zshrc`:**
   ```bash
   source ~/jukebox/jukebox.zsh
   ```

3. **Put FLAC files** in `~/Music` (or configure a custom path — see below).

4. **Reload your shell:**
   ```bash
   source ~/.zshrc
   ```

5. **Run it:**
   ```bash
   jukebox
   ```

## Configuration

Set `JUKEBOX_MUSIC_DIR` before the source line in your `~/.zshrc` to use a custom music folder:

```bash
export JUKEBOX_MUSIC_DIR="$HOME/my-flacs"
source ~/jukebox/jukebox.zsh
```

Default: `~/Music`

## Usage

Run `jukebox` and pick a mode:

```
🎵 Jukebox - Select playback mode:
  1) Play all (original order)
  2) Sort by filename (A-Z)
  3) Sort by filename (Z-A)
  4) Sort by date (oldest first)
  5) Sort by date (newest first)
  6) Browse & pick (plays from selection onward)
  7) Shuffle
  8) Build queue (TAB to pick, ENTER to play)
  q) Quit
```

### Playback controls

| Key | Action |
|-----|--------|
| `SPACE` | Pause / resume |
| `←` / `→` | Seek ±5 seconds |
| `↑` / `↓` | Seek ±30 seconds |
| `,` / `.` | Previous / next track |
| `<` / `>` | Previous / next track (same keys with Shift) |
| `L` | Open queue picker (fzf) — jump to any track |
| `[` / `]` | Decrease / increase playback speed |
| `Backspace` | Reset speed to 1.0× |
| `q` | Quit |

### Queue builder (option 8)

| Key | Action |
|-----|--------|
| `TAB` | Toggle selection on current item |
| `Ctrl-A` | Select all |
| `Ctrl-D` | Deselect all |
| `ENTER` | Start playing selected songs |

## Notes

- **Linux only** — uses GNU `find -printf` for date sorting. Not compatible with macOS.
- **FLAC files only** — scans for `*.flac` files in your music directory.
- Album art is extracted from embedded metadata (most FLAC files have it).

## License

Do whatever you want with it. 🎶
