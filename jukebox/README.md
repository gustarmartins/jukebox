# 🎵 Jukebox

A terminal-based music player for zsh. Browse local FLAC/MP3 files or a Jellyfin
music library, build custom queues, see album art and synchronized lyrics in
the terminal, and control playback without leaving the command line.

## Features

- **8 playback modes** — play all, sort A-Z/Z-A, sort by date, browse & pick, shuffle, or build a custom queue
- **Album art** — displays cover art directly in the terminal (via [chafa](https://hpjansson.org/chafa/))
- **Fuzzy browsing** — preview songs with metadata + album art before playing (via [fzf](https://github.com/junegunn/fzf))
- **Queue builder** — TAB to pick songs, Ctrl-A to select all, build your own playlist
- **Live queue picker** — press `L` during playback to see the queue and jump to any track
- **Keyboard controls** — seek, skip, speed up/down, all from the keyboard
- **Jellyfin streaming** — browse and direct-stream a server over LAN or Tailscale
- **Lyrics** — `.lrc`, `.elrc`, `.txt`, embedded tags, and Jellyfin lyrics

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

3. **Run `jukebox` once** and choose the folder containing your FLAC files.

4. **Reload your shell:**
   ```bash
   source ~/.zshrc
   ```

5. **Run it:**
   ```bash
   jukebox
   ```

## Configuration

On the first local launch, Jukebox asks for the music folder and saves the
choice in its own configuration file. It does not edit `~/.zshrc`. Change the
saved folder later with:

```zsh
jukebox setup
```

Set `JUKEBOX_MUSIC_DIR` before the source line in your `~/.zshrc` only when
you want a non-interactive or temporary override:

```bash
export JUKEBOX_MUSIC_DIR="$HOME/my-flacs"
source ~/jukebox/jukebox.zsh
```

Default: `~/Music`

### Data directory

Jukebox keeps its metadata cache and saved sessions in `~/.jukebox-app/`:

| File | What |
|------|------|
| `metadata.tsv` / `metadata-jellyfin.tsv` | Persistent, incremental library metadata cache |
| `session.state` / `session-jellyfin.state` | Last playback position (see [Resuming a session](#resuming-a-session)) |
| `session.m3u` / `session-jellyfin.m3u` | The queue that belongs to that session |

Override it with `JUKEBOX_DATA_DIR`:

```bash
export JUKEBOX_DATA_DIR="$HOME/.local/share/jukebox-tui"
```

These files used to live in `~/.cache/jukebox/`. They are none of them
disposable — losing the cache means re-probing the whole library, and losing
the session state means losing your place — and `~/.cache` is regularly wiped
by cleaners and shared with any other app that calls itself "jukebox". An
existing `~/.cache/jukebox/` is migrated automatically on the next launch.

### Jellyfin over LAN or Tailscale

Log in once using the URL that is reachable from the laptop:

```zsh
jukebox jellyfin-login http://arch-desktop:8096
```

If Tailscale MagicDNS is unavailable, use the server's Tailscale IP instead:

```zsh
jukebox jellyfin-login http://100.x.y.z:8096
```

Then choose Jellyfin as the library source before sourcing or launching the
player:

```zsh
export JUKEBOX_SOURCE=jellyfin
source "$HOME/Software Repositories/gustarmartins/Jukebox/jukebox/jukebox.zsh"
jukebox
```

`JUKEBOX_SOURCE` accepts `local` (the default) or `jellyfin`. Useful connection
commands are:

```zsh
jukebox jellyfin-status
jukebox jellyfin-logout
```

The login creates `~/.config/jukebox/jellyfin.json` with permissions `0600`.
Jukebox generates token-free stream URLs and passes the token to `mpv` through
a private, short-lived configuration file. Environment overrides are available
for non-interactive setups: `JUKEBOX_JELLYFIN_URL`,
`JUKEBOX_JELLYFIN_TOKEN`, and `JUKEBOX_JELLYFIN_USER_ID`.

Jellyfin playback uses the range-capable item download endpoint and therefore
streams the untouched original file without transcoding or reducing quality.

### Lyrics

Press `Y` during playback to toggle the dedicated lyrics view. Synchronized
lyrics highlight the current line and redraw only when that line changes, so
the ordinary render loop remains lightweight. For unsynchronized lyrics,
`j`/`k` scroll down/up while the lyrics view is open.

For local music, Jukebox checks for a same-name `.lrc`, `.elrc`, or `.txt` file
beside the track and then falls back to embedded `LYRICS`/`UNSYNCEDLYRICS` tags.
For Jellyfin, it uses the server's lyrics endpoint. Jellyfin recognizes the
same sidecar naming convention, for example `Song.flac` with `Song.lrc`.

## Usage

Run `jukebox` and pick a mode:

```
🎵 Jukebox - Select playback mode:
  0) ▶ Resume: Young Turks — Rod Stewart  [0:26/5:02 · track 3/40 · interrupted]
  1) Play all (original order)
  2) Sort by filename (A-Z)
  3) Sort by filename (Z-A)
  4) Sort by date (oldest first)
  5) Sort by date (newest first)
  6) Browse & pick (plays from selection onward)
  7) Shuffle
  8) Build queue (TAB to pick, ENTER to play)
  x) Forget saved session
  q) Quit
```

### Resuming a session

Jukebox writes a snapshot of what it is playing to
`~/.jukebox-app/session.state` (plus `session.m3u` for the queue) roughly
every two seconds. The write is atomic and never depends on a clean exit, so a
`SIGKILL`, an OOM-kill, a closed terminal, or a reboot all still leave a
resumable session behind.

On the next launch, option `0` appears at the top of the menu. Picking it
restores the whole queue (including anything added with `A` or reordered in the
queue picker), jumps to the track you were on, seeks back to the exact second,
and restores speed/pitch/lyrics-view state. Playback starts paused internally
so you never hear the beginning of the track before the seek lands.

Sessions are tracked per source — a local session and a Jellyfin session are
saved separately, and only the one matching your current `JUKEBOX_SOURCE` is
offered. Option `x` deletes the saved session.

### Playback controls

| Key | Action |
|-----|--------|
| `SPACE` | Pause / resume |
| `←` / `→` | Seek ±5 seconds |
| `↑` / `↓` | Seek ±30 seconds |
| `,` / `.` | Previous / next track |
| `<` / `>` | Previous / next track (same keys with Shift) |
| `L` | Open queue picker (fzf) — jump to any track |
| `Y` | Toggle lyrics view |
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
- **Local mode supports FLAC and MP3** — Jellyfin mode supports the audio formats exposed by the server.
- Album art is extracted from embedded metadata (most files have it).

### Known Limits
Because Jukebox runs natively in Zsh without a heavy backend, it is subject to certain shell and OS-level limits when scanning massive libraries:
- **The Patience Limit (~3,000 to 5,000 files)**: Jukebox spawns an `ffprobe` subprocess for every file to build the metadata cache for sorting and fzf previews. Extracting metadata for 5,000 files takes roughly 50-100 seconds sequentially. It won't crash, but startup for the `Browse` or `Queue` menus will be noticeably slow.
- **The OS `ARG_MAX` Limit (~30,000 to 40,000 files)**: Jukebox expands glob patterns directly in the shell (e.g., `**/*.flac`). If a library contains tens of thousands of files, the resulting string of absolute file paths will exceed the Linux kernel's `ARG_MAX` limit (typically ~2MB), causing the shell to crash with a `zsh: argument list too long` error before Jukebox can even start.

## License

Do whatever you want with it. 🎶
