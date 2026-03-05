# Jukebox

Terminal FLAC Player with Kitty graphics for album art!

> [!IMPORTANT]
> This project was entirely created by LLMs, and should not be used as a product nor expect to get any support from its creators.
> 
> As my necessity to have a more functional player locally grew, I began using Claude and Gemini models to implement stuff.
> I actually liked the outcome, which is why this is now being shared with others, even though I take no credit other than the prompts used to create it.


## Features
- Real-time time & progress bar without flickering
- File browsing & search via `fzf`
- Spotify-style "Play Next" dynamic queueing
- Interactive Queue Editor (Jump to tracks, delete from queue)
- Headless `mpv` rendering via Unix Socket IPC with fast-polling (`socat`)
- `chafa` integration for high-quality Kitty terminal graphics over album art

## Dependencies
- `mpv`: Used entirely headless as an audio backend.
- `fzf`: Core interactive menu frontend.
- `chafa`: Converts MP3/FLAC album art to Kitty pixel-perfect images.
- `ffmpeg` / `ffprobe`: Used strictly to grab tags & art instantly.
- `socat` & `jq`: Powers real-time polling to MPV's IPC without Python overhead.

## Setup
Source the setup file inside your `~/.zshrc`:
```bash
source ~/Jukebox/jukebox/jukebox.zsh
```

To configure your music folder, define the variable before sourcing:
```bash
export JUKEBOX_MUSIC_DIR="$HOME/Music"
```
