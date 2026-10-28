# Jukebox audit and ideas

Reviewed 2026-10-12. This refresh keeps the Zsh/fzf/mpv player, existing music
data, Jellyfin credential scheme, and unfinished osu! library integration.

## Delivered changes

| Finding | Change |
| --- | --- |
| Startup killed every matching Jukebox mpv and removed shared temporary files | Per-source writer lock; private mode-0700 runtime directory; cleanup only of owned resources |
| Early menu returns left artwork/playlist files behind | Zsh `always` cleanup covers every return and handled signal |
| A killed shell could leave its audio backend alive | Linux parent-death signal installed before exec of the owned mpv process |
| Metadata cache only noticed new/deleted FLAC/MP3 files | Shared Python indexer supports additional formats and nanosecond mtime/size fingerprints |
| Watcher appends could race a cache replacement and miss edited/deleted tracks | Scanner and watcher use one cache lock and atomic replacement; failures retain old metadata and retry |
| Ogg/Opus tags often live on streams rather than format metadata | Indexer reads audio-stream tags and handles mixed-case tag names |
| Browse-from-selection continued in filename order despite a title-sorted display | Queue continuation follows the exact visible order |
| No direct volume, mute, repeat, or help controls | `+`/`-`, `M`, `T`, `?`, visible state, and resume persistence |
| Session validation accepted malformed numeric suffixes and arbitrary speed/pitch values | Entire numeric strings, bounds, booleans, and enums are validated before use |
| Lyrics ignored milliseconds, shared timestamps, and offsets | Millisecond selection, repeated LRC timestamps, offset tags, BOMs, and enhanced word timestamp stripping |
| Next-track details spawned many ffprobe processes and labeled everything FLAC | One bounded metadata probe; actual codec/rate/channel details; cached tag fallback |
| Metadata/control characters could disrupt TSV rows or terminal output | Indexer, Jellyfin adapter, previews, and polled values remove control characters |
| Setup replaced settings and erased other library preferences | Updating `music_dir` preserves osu! and unknown settings |
| Nightcore options without values could loop after a failed shift | Immediate argument error with a help hint |
| Arch package omitted fallback artwork and Python source helpers | Recipe installs assets and all source modules |
| Pytest collected duplicate tests from makepkg source copies | Collection limited to `tests/`; silent isolated mpv tests; GitHub Actions checks |

The eight-column TSV layout and existing saved sessions remain compatible.
The original osu! scanner is retained; the indexer invokes it under its cache
lock and local queue modes include the added songs.

## Research and priorities

These are suggestions for later work, with dependencies and tradeoffs made
explicit. They are not claims that those features were implemented here.

| Priority | Idea | Why it fits / implementation direction |
| --- | --- | --- |
| High | Named playlists, favorites, queue undo | Save multiple portable M3U8 queues; preserve duplicate occurrences; store Jellyfin item identity without credentials. CLIAMP provides a useful reference for playlist import/export and undo. |
| High | Persistent mpv event subscriber | Observe properties over one long-lived IPC connection, replacing repeated Python polling processes. Keep input responsive and bound reconnection time. |
| High | Media keys and desktop integration | Optional MPRIS bridge so playerctl and desktop controls work even when the terminal is unfocused. ncspot documents this model. Keep it opt-in and avoid conflicting with other players. |
| Medium | ReplayGain selector | Offer off/track/album through mpv's native tags, with explicit UI and persistence. Preserve the user's current audio processing and leave normalization opt-in. |
| Medium | Artist/album browser and album shuffle | Group by album artist + album + disc, play tracks numerically, and shuffle albums rather than splitting them. Existing disc/track cache columns provide a starting point. |
| Medium | Optional lyrics discovery | Consider LRCLIB as an explicit online fallback with per-track caching, timeouts, and a visible source. Offline/sidecar behavior should continue to work by itself. |
| Medium | Asynchronous artwork/Jellyfin lookups | Perform bounded fetches outside the input loop, cancel stale track requests, and publish results only for the matching track. |
| Later | SQLite library/search/history | Consider only after measuring large-library startup and browse memory. Use versioned migration and preserve the current TSV/session data. |

Primary sources consulted:

- [mpv stable manual](https://mpv.io/manual/stable/): native looping, volume,
  ReplayGain, and gapless audio behavior.
- [mpv JSON IPC documentation](https://github.com/mpv-player/mpv/blob/master/DOCS/man/ipc.rst):
  persistent property observation and request IDs. Observation ends when the
  connection closes, so separate short-lived calls cannot provide subscriptions.
- [ncspot](https://github.com/hrkfdn/ncspot): terminal help, media keys, and MPRIS.
- [termusic](https://github.com/tramhao/termusic): terminal library, playlist,
  and lyrics workflows.
- [CLIAMP](https://www.cliamp.stream/): playlist import/export, favorites,
  queue undo, and lyrics timing controls.
- [Zsh module documentation](https://zsh.sourceforge.io/Doc/Release/Zsh-Modules.html):
  advisory locks and file descriptor lifetime.

## Remaining audit findings

- The input loop still starts a Python IPC client and runs terminal-size queries
  repeatedly. A persistent subscriber is a useful future performance change;
  CPU savings have not been measured in this refresh.
- Jellyfin API calls and cover extraction can block input during track changes.
  Local metadata probes now have a ten-second bound, but artwork extraction in
  Zsh is still synchronous and remote requests can wait for their timeout.
- Queue-editor mutations still contain duplicated inline socket clients.
  Extracting them should use actual mpv regressions, including duplicate songs
  and track changes during edits, rather than simulated copies of the algorithm.
- inotify recursion does not fully solve newly created nested directory watches
  or paths containing line delimiters. Startup reconciles the library again.
- The first fingerprint scan reprobes an existing legacy cache once. Subsequent
  scans reuse unchanged files; this does not remove cold-library disk costs.
- Fingerprints use mtime and size, not content hashes. An edit deliberately
  preserving both will need a future explicit forced-refresh command.
- The existing osu! scanner chooses the first beatmap in each folder and derives
  duration from hit objects. Multiple audio files, preview clips, and actual
  audio duration deserve a dedicated follow-up without discarding that work.
- Linux SIGKILL cannot run cleanup; small runtime/index temporary files can
  remain. Normal returns and handled signals remove owned runtime resources.
- Shell arrays and TSV sorting are not a paginated browser. Very large libraries
  need measurement before claiming a particular supported collection size.

## Verification

Run `python3 -m pytest -q`, `zsh -n` for each Zsh module, and `bash -n` for the
Arch recipe. Tests cover incremental indexing, concurrent cache updates, formats,
metadata sanitation, visible queue order, saved settings, corrupt session data,
lyrics, actual mpv repeat/resume properties, terminal controls and cleanup,
conflicting launches, and parent-death behavior. Test mpv instances use
`--no-config --load-scripts=no --ao=null`.

The Arch recipe is checked by staging its install into a temporary package
directory. No release tag, package publication, system installation, or listening
acceptance is implied by these checks. Listening through the real desktop audio
path and album-art appearance in the owner's terminal remain manual acceptance.
