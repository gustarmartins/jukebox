# 🎵 Jukebox

A terminal-based music player for zsh. Browse local audio files or a Jellyfin
music library, build custom queues, see album art and synchronized lyrics in
the terminal, and control playback without leaving the command line.

## Features

- **8 playback modes** — play all, sort A-Z/Z-A, sort by date, browse & pick, shuffle, or build a custom queue
- **Album art** — displays cover art directly in the terminal (via [chafa](https://hpjansson.org/chafa/))
- **Fuzzy browsing** — preview songs with metadata + album art before playing (via [fzf](https://github.com/junegunn/fzf))
- **Queue builder** — TAB to pick songs, Ctrl-A to select all, build your own playlist
- **Live queue picker** — press `L` during playback to see the queue and jump to any track
- **Keyboard controls** — seek, skip, volume, mute, repeat, speed/pitch, and help (`?`)
- **Incremental indexing** — refresh edited files, retry failed probes, and track live library changes
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
| Python 3.10+ | Library indexing, Jellyfin, lyrics, and JSON IPC |
| inotify-tools (optional) | Live local library refresh |

### Install dependencies

**Arch Linux:**
```bash
sudo pacman -S zsh mpv fzf ffmpeg chafa python
```

**Ubuntu / Debian:**
```bash
sudo apt install zsh mpv fzf ffmpeg chafa python3
```

**Fedora:**
```bash
sudo dnf install zsh mpv fzf ffmpeg chafa python3
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

3. **Run `jukebox` once** and choose the folder containing your music files.

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
| `metadata.tsv` / `metadata-jellyfin.tsv` | Persistent library metadata |
| `metadata.tsv.files.json` | Local file size/mtime fingerprints for incremental refresh |
| `player-local.lock` / `player-jellyfin.lock` | Prevent conflicting session writers |
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

### Appearance

Playback shortcuts use spaced keycaps with pale cyan accents and bright action
labels. Enabled pause, mute, repeat, and lyrics controls use a filled keycap;
titles, metadata, and progress use the same restrained palette. Library and
queue selections share the accent. Narrow windows condense the shortcut row,
and `?` always provides the full list of controls.

Tracks without artwork use a transparent vinyl record in the player, Up Next,
and browsing previews, including shuffle mode. See the [asset notes](assets/README.md).

Colors respect `NO_COLOR`. Set `JUKEBOX_COLOR=1` to explicitly enable the
palette, or `JUKEBOX_COLOR=0` to use monochrome keycaps and labels. These settings
apply within Jukebox and do not change your terminal theme.

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
and restores speed, pitch, lyrics view, volume, mute, and repeat state. Playback starts paused internally
so you never hear the beginning of the track before the seek lands.

Sessions are tracked per source — a local session and a Jellyfin session are
saved separately, and only the one matching your current `JUKEBOX_SOURCE` is
offered. Option `x` deletes the saved session.

### Playback controls

| Key | Action |
|-----|--------|
| `SPACE` | Pause / resume |
| `+` / `=` / `-` | Raise / lower mpv volume by 5% |
| `M` | Mute / unmute |
| `T` | Cycle repeat: off → current track → whole queue |
| `?` | Show all playback controls |
| `←` / `→` | Seek ±5 seconds |
| `↑` / `↓` | Seek ±30 seconds |
| `,` / `.` | Previous / next track |
| `<` / `>` | Previous / next track (same keys with Shift) |
| `S` | **Shuffle upcoming queue** on the fly without stopping playback |
| `N` / `B` | **Redo queue** / select a new playlist mode without closing the app |
| `A` | Add songs to play next (inserted right after current track) |
| `L` | Open queue manager (interactive queue editor & reordering) |
| `Y` | Toggle lyrics view |
| `i` | Show detailed audio metadata & stream info overlay |
| `[` / `]` | Decrease / increase playback speed / pitch |
| `P` | Switch realtime effect mode (`tempo`, `nightcore`, `pitch`) |
| `Backspace` / `R` | Reset playback speed and pitch modifiers to 1.0× |
| `q` | Quit (prompts confirmation) |

### Interactive Queue Manager (`L`)

Press `L` during playback to open the live queue manager:

| Key | Action |
|-----|--------|
| `ENTER` | Jump to selected track |
| `DEL` | Remove selected track from playlist & queue |
| `Alt+↑` / `Alt+↓` | Move selected track up or down |
| `Alt+S` | **Shuffle upcoming tracks** in-place |
| `Alt+C` | **Clear upcoming tracks** |
| `Alt+A` | Add more tracks to the queue |
| `Alt+R` | Redo / replace queue with new selection |
| `ESC` | Return to player |

### Queue builder (option 8)

| Key | Action |
|-----|--------|
| `TAB` | Toggle selection on current item |
| `Ctrl-A` | Select all |
| `Ctrl-D` | Deselect all |
| `ENTER` | Start playing selected songs |

## Notes

- **Linux only** — uses Zsh file locks, Unix sockets, and Linux parent-death signals.
- **Local formats:** FLAC, MP3, Ogg, Opus, M4A, AAC, WAV, AIFF (`.aif`/`.aiff`), ALAC, APE, WavPack. Jellyfin exposes the formats available on its server.
- Album art is extracted from embedded metadata (most files have it).

### Library refresh and diagnostics

`jukebox doctor` reports required tools and the configured source/folders;
`jukebox --help` lists commands without starting playback. If inotify-tools is
installed, changes to existing watched folders update metadata under a cache
lock, including edits and deletions. Newly created nested folders or changes
missed by the watcher are reconciled on the next launch.

The first scan probes at most four tracks concurrently; later scans only probe
new or changed files (size and nanosecond mtime). Failed probes keep previous
metadata and are retried. Cache writes are atomic. Vorbis/Opus stream tags,
mixed-case tags, and disc/track numbers are supported.

A second instance using the same data directory and source exits with an
explanation. It does not terminate your current player. Each launch keeps its
socket, artwork, generated scripts, and logs in its own private runtime folder.
Normal exits, menu cancellation, and handled signals clean up that folder. The
mpv child receives SIGTERM if its launching shell dies; SIGKILL can still leave
small runtime/cache temporary files until OS cleanup.

### Known limits

- Metadata still requires one ffprobe per new/edited file. A cold import of a
  large collection can take time, especially on a mechanical disk.
- TSV browsing and line-based playlists cannot faithfully represent filenames
  containing tabs, carriage returns, newlines, or the internal unit separator;
  the local scanner skips those files. Spaces and apostrophes work normally.
- The shell keeps queues and browse lists in memory. There is no fixed file-count
  limit, but this is not yet a paginated database-backed library browser.
- Jellyfin calls and artwork extraction still run synchronously on track changes;
  a slow server can delay input. See the [audit](../docs/AUDIT_AND_IDEAS.md).

## License

Do whatever you want with it. 🎶
