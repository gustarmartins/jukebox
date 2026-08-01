# Jukebox

Terminal music player with local FLAC and first-class Jellyfin streaming, Kitty
graphics for album art, fuzzy browsing, queues, and synchronized lyrics.

> [!IMPORTANT]
> This project was entirely created by LLMs and should not be used as a production-ready application. Please do not expect support or maintenance from its creators.
> 
> As my need for a more functional local terminal player grew, I began using Claude and Gemini models to implement the features I wanted. I've been really happy with the outcome, which is why I'm sharing this with others. I claim no credit for this code other than drafting the prompts used to generate it!


## Features
- Real-time time & progress bar without flickering
- File browsing & search via `fzf`
- Spotify-style "Play Next" dynamic queueing
- Interactive Queue Editor (Jump to tracks, delete from queue)
- Headless `mpv` rendering via Unix Socket IPC with fast-polling (`socat`)
- `chafa` integration for high-quality Kitty terminal graphics over album art
- Jellyfin library browsing and direct streaming over LAN or Tailscale
- Local sidecar/embedded lyrics and Jellyfin synchronized lyrics (`Y`)

## Dependencies
- `mpv`: Used entirely headless as an audio backend.
- `fzf`: Core interactive menu frontend.
- `chafa`: Converts MP3/FLAC album art to Kitty pixel-perfect images.
- `ffmpeg` / `ffprobe`: Used strictly to grab tags & art instantly.
- `socat` & `jq`: Powers real-time polling to MPV's IPC.
- `python`: Runs the Jellyfin client and fast MPV IPC helpers.

## Install

### Arch Linux

Once the AUR package is available, install it with an AUR helper:

```bash
yay -S jukebox
# or: paru -S jukebox
```

This installs the `jukebox` and `nightcore` commands system-wide. On the first
local launch, Jukebox asks where your music lives and saves that choice in its
own private configuration directory. It never edits your shell profile.

### From Git

Install the dependencies with your distribution's package manager, then clone
the repository and source the setup file inside `~/.zshrc`:

```bash
git clone https://github.com/gustarmartins/jukebox.git ~/Jukebox
source ~/Jukebox/jukebox/jukebox.zsh
```

Jukebox asks for the music folder on its first local launch. To change it
later, run:

```bash
jukebox setup
```

For non-interactive use or a temporary override, define the variable before
sourcing:
```bash
export JUKEBOX_MUSIC_DIR="$HOME/Music"
```

For Jellyfin, authenticate once and select the remote source:

```zsh
jukebox jellyfin-login http://arch-desktop:8096
export JUKEBOX_SOURCE=jellyfin
```

Use the desktop's `100.x.y.z` Tailscale address instead when MagicDNS is not
enabled. The per-user access token is stored in
`~/.config/jukebox/jellyfin.json` with mode `0600` and is never written into a
playlist URL.
