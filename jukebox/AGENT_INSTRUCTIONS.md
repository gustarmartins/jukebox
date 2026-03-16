# Agent Instructions for Jukebox

Welcome, fellow AI/LLM Coding Assistant! The user has explicitly designated this project as an AI-driven workspace. You have broad powers to manage the code here.

## Core Directives

1. **Full Ownership:** This project belongs entirely to LLMs. You are expected to take initiative and write code to improve the Jukebox application.
2. **Git Operations:** You are fully allowed (and encouraged) to:
   - Read the git commit logs and history to understand context.
   - Create new branches for any fixes or features.
   - Stage and commit your changes with clear, descriptive commit messages.
   - Push your changes and branches to the remote server.
3. **Strict Boundary Constraints:** All your actions MUST be strictly restricted to this repository only. Do not navigate to, modify, or interact with files, repositories, or system configurations outside of this project's directory.
4. **Agentic Methodology:** You don't need to ask for permission for routine git operations. Make a branch, do the work, commit, and push it, as long as you're confident it resolves the user's request and remains sandboxed within this repo.

---

## Project Architecture

Jukebox is a **single-file Zsh function** (`jukebox.zsh`) that runs as a TUI music player inside the user's terminal. It is sourced into `~/.zshrc` and invoked by typing `jukebox`.

### Key Components
- **`jukebox.zsh`** — The entire application (~1400 lines). Contains a single `jukebox()` function with nested helper functions.
- **`_fzf_preview.py`** — External Python script called by fzf for rich song previews.
- **mpv** — Headless audio backend, controlled via Unix socket IPC (`--input-ipc-server`).
- **fzf** — Interactive menu frontend for browsing, sorting, and queue building.
- **chafa** — Renders album art in the terminal using the Kitty graphics protocol.
- **ffmpeg/ffprobe** — Extracts album art and metadata tags from FLAC files.

### Data Flow
1. User launches `jukebox` → startup orphan sweep → incremental cache rebuild → menu
2. User picks a mode → Zsh builds a file array → writes playlist to temp `.m3u` → starts mpv
3. Main loop polls mpv via Python Unix socket IPC (`_jukebox_batch_get`) → renders TUI
4. On exit → `_jukebox_cleanup` kills mpv, removes temp files, unsets env vars

### File Locations
| What | Where | Persistent? |
|------|-------|---|
| Metadata cache | `~/.cache/jukebox/metadata.tsv` | ✅ Yes |
| Playlist | `/tmp/jukebox-XXXXXX.m3u` | No |
| mpv IPC socket | `$XDG_RUNTIME_DIR/jukebox-mpv-XXXXXX.sock` | No |
| Cover art (current) | `/tmp/jukebox-cover-XXXXXX.jpg` | No |
| Cover art (next) | `/tmp/jukebox-cover-next-XXXXXX.jpg` | No |
| Sort scripts | `/tmp/jukebox-sort-XXXXXX/` | No |
| Queue tracker | `/tmp/jukebox-queue-$$.txt` | No |

---

## Critical Zsh Pitfalls (MUST READ)

These are real bugs that have been introduced and fixed in this project's history. **Every single one was caused by an AI agent.** Learn from them.

### 1. `local` inside loops prints variable values
In Zsh, re-declaring a variable with `local` inside a loop acts like `typeset` and **prints its current value to stdout**. This completely trashes the TUI with debug spam.

**Rule:** Declare all `local` variables ONCE, before the main `while` loop. Never use `local` inside the render loop.

> Commit `469af08`: *"The recent PR moved hundreds of variable declarations inside the main render loop, causing them to be evaluated 20 times a second and completely trashing the UI."*

### 2. Zsh collapses adjacent field separators in `read`
If you use `IFS=$'\t' read -r a b c` and field `b` is empty, Zsh collapses the two adjacent tabs and shifts `c` into `b`. This silently corrupts ALL downstream variables.

**Rule:** Use `\x1f` (Unit Separator) as the delimiter instead of `\t`. The `_jukebox_batch_get` function already does this correctly — do NOT change it back to tabs.

> Commit `06d3294`: *"Zsh collapses adjacent tabs in read... This made 'playlist-pos' get assigned an empty string, causing an infinite force_redraw loop (flickering screen)."*

### 3. Glob patterns with no matches cause fatal errors
In Zsh (unlike Bash), `rm -f /tmp/foo-*.txt` will **error and abort** if no files match the glob. You must append `(N)` (null-glob qualifier) to suppress this.

**Rule:** Always use `(N)` on cleanup globs: `rm -f /tmp/jukebox-*.m3u(N)`

### 4. `unfunction` on the currently executing function crashes
If `_jukebox_cleanup` is called by the `EXIT` trap and it `unfunction`s itself, the shell tries to finish executing a deleted function. This causes `zsh: command not found: _jukebox_cleanup`.

**Rule:** Never `unfunction` the cleanup handler. It already `trap -` to untrap itself first.

### 5. `setopt localtraps` means traps die with the function
Traps set with `localtraps` active are scoped to the function. If the function exits abnormally, the trap may not fire. The startup orphan sweep exists as a safety net for this.

---

## mpv IPC Pitfalls

### 6. mpv's Unix socket uses newline-delimited JSON
Every command sent to mpv MUST be a **single line** of JSON. If you use `jq -n` to build JSON, add `-c` (compact output) or mpv will receive multi-line JSON and silently fail.

> Commit `eeede5f`: *"jq -n pretty-prints JSON over multiple lines. MPV's unix socket protocol uses newline as a delimiter, so multi-line JSON resulted in parse failure."*

### 7. Large playlist responses can exceed socat timeouts
For playlists with 200+ tracks, `socat -t 0.5` frequently times out before receiving the full JSON response from mpv. Use the Python-based `_jukebox_batch_get` for heavy property fetches, or increase timeout to `-t 2`.

> Commit `40565e1`: *"For large playlists (263+ tracks, ~38KB), socat -t 0.5 would timeout before receiving the full response."*

### 8. `keep-open=yes` in mpv.conf causes unclean exits
The user's `~/.config/mpv/mpv.conf` has `keep-open=yes`. Jukebox overrides this with `--keep-open=no` so mpv exits when the playlist ends. Do NOT remove this flag.

---

## ffmpeg / Album Art Pitfalls

### 9. Use `-vcodec mjpeg`, never `-vcodec copy` for cover art
Some FLACs (especially from Tidal/Qobuz) embed cover art in non-standard sub-formats. Using `-vcodec copy` produces files that look valid but `chafa` cannot decode. Always re-encode to mjpeg.

> Commit `3b12a89`: *"raw copy silently produces corrupt output for many modern FLACs... chafa cannot decode it, leaving blank art."*

---

## Cache System

The metadata cache at `~/.cache/jukebox/metadata.tsv` is **persistent** and **incremental**:
- Format: `filepath\ttitle\tartist\talbum\tdate\tduration` (tab-separated, 6 fields)
- On launch, the Python builder diffs disk vs cache and only probes NEW files
- An `inotifywait` background watcher hot-appends new files during playback
- The cache is NEVER deleted on exit — only session temp files are cleaned up

**Rule:** Do NOT move the cache back to `/tmp/`. Do NOT delete it in `_jukebox_cleanup`.

---

## Cleanup System

The cleanup system has three layers:
1. **Startup sweep** — kills orphaned mpv processes, removes stale temp files from `/tmp/`
2. **Exit trap** — `_jukebox_cleanup` handles `INT TERM HUP QUIT PIPE EXIT` signals
3. **`setopt nomonitor`** — suppresses `[job] + done` messages from background tasks

**Rule:** When adding new temp files or background processes, add them to BOTH the startup sweep AND `_jukebox_cleanup`. Always use `(N)` null-glob on startup sweep patterns.

**Rule:** When adding new exported env vars, add `unset` calls to BOTH the startup sweep AND `_jukebox_cleanup`.

---

## Testing Checklist

Before pushing any change, mentally verify:
- [ ] No `local` declarations inside the main `while` loop
- [ ] No bare glob patterns without `(N)` in cleanup code
- [ ] No `jq -n` without `-c` flag for mpv IPC
- [ ] No `\t` as IFS delimiter in `read` — use `\x1f`
- [ ] Cover art extraction uses `-vcodec mjpeg`, not `-vcodec copy`
- [ ] New temp files are cleaned up in both startup sweep AND exit cleanup
- [ ] New exported env vars are unset in both startup sweep AND exit cleanup
- [ ] New background processes are killed in `_jukebox_cleanup`
- [ ] The persistent cache (`~/.cache/jukebox/metadata.tsv`) is never deleted

Enjoy building!
