#!/usr/bin/env zsh
# ╔══════════════════════════════════════════════════════════════════╗
# ║  🎵 Jukebox — Terminal FLAC Player                             ║
# ║  A zsh function that plays FLAC files with album art,          ║
# ║  queue building, fzf browsing, and interactive controls.       ║
# ║  Also includes a `nightcore` command for speed/pitch remixing. ║
# ║                                                                ║
# ║  Dependencies: mpv, fzf, chafa, ffmpeg, socat, jq, sox         ║
# ║                                                                ║
# ║  Setup: Add this line to your ~/.zshrc:                        ║
# ║    source ~/Jukebox/jukebox/jukebox.zsh                        ║
# ║                                                                ║
# ║  Configuration (optional, add before the source line):         ║
# ║    export JUKEBOX_MUSIC_DIR="$HOME/Music"                      ║
# ║    export JUKEBOX_DATA_DIR="$HOME/.jukebox-app"                ║
# ║                                                                ║
# ║  Usage: run `jukebox` in your terminal.                        ║
# ╚══════════════════════════════════════════════════════════════════╝

typeset -g _JUKEBOX_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/jukebox"
typeset -g _JUKEBOX_SETTINGS_FILE="${_JUKEBOX_CONFIG_DIR}/settings"
typeset -g _JUKEBOX_MUSIC_DIR_EXPLICIT=0
typeset -g _JUKEBOX_MUSIC_DIR_CONFIGURED=0

if (( ${+parameters[JUKEBOX_MUSIC_DIR]} )) && [[ -n "$JUKEBOX_MUSIC_DIR" ]]; then
    _JUKEBOX_MUSIC_DIR_EXPLICIT=1
elif [[ -r "$_JUKEBOX_SETTINGS_FILE" ]]; then
    while IFS=$'\t' read -r _jukebox_setting _jukebox_value; do
        if [[ "$_jukebox_setting" == "music_dir" && -n "$_jukebox_value" ]]; then
            JUKEBOX_MUSIC_DIR="$_jukebox_value"
            _JUKEBOX_MUSIC_DIR_CONFIGURED=1
            break
        fi
    done < "$_JUKEBOX_SETTINGS_FILE"
fi

: ${JUKEBOX_MUSIC_DIR:="$HOME/Music"}
: ${JUKEBOX_SOURCE:="local"}
# Own directory rather than ~/.cache/jukebox: the metadata cache and the saved
# session are things you want back after a reboot, and ~/.cache is routinely
# wiped by cleaners/tmpfiles — plus "jukebox" is a name other apps also use.
: ${JUKEBOX_DATA_DIR:="$HOME/.jukebox-app"}
_JUKEBOX_SCRIPT_DIR="${0:A:h}"
_JUKEBOX_JELLYFIN_CLIENT="${_JUKEBOX_SCRIPT_DIR}/jellyfin_client.py"

# --- fzf preview command (calls external Python script) ---
_jukebox_fzf_preview="'${_JUKEBOX_SCRIPT_DIR}/_fzf_preview.py' {1}"

_jukebox_save_music_dir() {
    local music_dir="$1" config_tmp

    mkdir -p "$_JUKEBOX_CONFIG_DIR" || return 1
    chmod 700 "$_JUKEBOX_CONFIG_DIR" 2>/dev/null
    config_tmp=$(mktemp "${_JUKEBOX_CONFIG_DIR}/settings.XXXXXX") || return 1
    chmod 600 "$config_tmp" 2>/dev/null
    print -r -- $'music_dir\t'"$music_dir" > "$config_tmp"
    command mv -f "$config_tmp" "$_JUKEBOX_SETTINGS_FILE"
    chmod 600 "$_JUKEBOX_SETTINGS_FILE" 2>/dev/null
}

_jukebox_configure_music_dir() {
    local force="${1:-0}" default_dir="$JUKEBOX_MUSIC_DIR" answer selected_dir

    if (( ! force )) && [[ -d "$JUKEBOX_MUSIC_DIR" ]] && \
        (( _JUKEBOX_MUSIC_DIR_EXPLICIT || _JUKEBOX_MUSIC_DIR_CONFIGURED )); then
        return 0
    fi

    if [[ ! -t 0 || ! -t 1 ]]; then
        echo "❌ Music directory is not configured. Run 'jukebox setup' in an interactive terminal or set JUKEBOX_MUSIC_DIR."
        return 1
    fi

    echo "🎵 First-time Jukebox setup"
    echo "Choose the folder that contains your FLAC music library."
    while true; do
        print -n "Music directory [$default_dir]: "
        IFS= read -r answer || return 1
        selected_dir="${answer:-$default_dir}"
        if [[ "$selected_dir" == "~" ]]; then
            selected_dir="$HOME"
        elif [[ "$selected_dir" == "~/"* ]]; then
            selected_dir="$HOME/${selected_dir#\~/}"
        fi
        selected_dir="${selected_dir:A}"

        if [[ ! -d "$selected_dir" ]]; then
            echo "❌ '$selected_dir' is not an existing directory. Try again."
            continue
        fi
        if [[ ! -r "$selected_dir" ]]; then
            echo "❌ '$selected_dir' cannot be read. Choose another directory."
            continue
        fi

        JUKEBOX_MUSIC_DIR="$selected_dir"
        _JUKEBOX_MUSIC_DIR_EXPLICIT=0
        _JUKEBOX_MUSIC_DIR_CONFIGURED=1
        if ! _jukebox_save_music_dir "$JUKEBOX_MUSIC_DIR"; then
            echo "❌ Could not save Jukebox settings in $_JUKEBOX_CONFIG_DIR"
            return 1
        fi
        echo "✓ Music library set to $JUKEBOX_MUSIC_DIR"
        return 0
    done
}

# --- main function ---
jukebox() {
    # Suppress zsh job control messages ("+ done" etc) for background tasks
    setopt localoptions localtraps nomonitor

    local _jukebox_debug=0
    local _jukebox_debuglog="/tmp/jukebox-debug.log"
    local _jukebox_show_formatnames=1
    local _jukebox_source="${JUKEBOX_SOURCE:l}"

    # Connection management intentionally runs before any player temp files or
    # terminal state are created.
    case "$1" in
        setup|configure)
            _jukebox_configure_music_dir 1
            return $?
            ;;
        jellyfin-login)
            shift
            command python3 "$_JUKEBOX_JELLYFIN_CLIENT" login "$@"
            return $?
            ;;
        jellyfin-status)
            command python3 "$_JUKEBOX_JELLYFIN_CLIENT" status
            return $?
            ;;
        jellyfin-logout)
            command python3 "$_JUKEBOX_JELLYFIN_CLIENT" logout
            return $?
            ;;
    esac

    if [[ "$_jukebox_source" != "local" && "$_jukebox_source" != "jellyfin" ]]; then
        echo "❌ JUKEBOX_SOURCE must be 'local' or 'jellyfin'"
        return 1
    fi

    if [[ "$_jukebox_source" == "local" ]] && ! _jukebox_configure_music_dir; then
        return 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --debug|-d)
                _jukebox_debug=1
                : > "$_jukebox_debuglog"
                echo "🔧 Debug mode ON → tail -f $_jukebox_debuglog"
                shift
                ;;
            --show-filenames)
                _jukebox_show_formatnames=0
                shift
                ;;
            --show-formatnames)
                _jukebox_show_formatnames=1
                shift
                ;;
            *)
                echo "❌ Unknown argument: $1"
                return 1
                ;;
        esac
    done

    # --- clean up orphaned files from previous crashed sessions ---
    # Runs on every launch as a safety net for scenarios where exit
    # cleanup cannot fire (SIGKILL, terminal crash, compositor restart,
    # OOM-kill, power loss, etc.)
    if pgrep -f 'input-ipc-server=.*jukebox-mpv' >/dev/null 2>&1; then
        pkill -f 'input-ipc-server=.*jukebox-mpv' 2>/dev/null
        sleep 0.2
        pkill -9 -f 'input-ipc-server=.*jukebox-mpv' 2>/dev/null
    fi
    command rm -f /tmp/jukebox-cover-*.jpg(N) /tmp/jukebox-cover-next-*.jpg(N) 2>/dev/null
    command rm -f /tmp/jukebox-fzf-preview-*.jpg(N) 2>/dev/null
    command rm -f /tmp/jukebox-queue-*.txt(N) 2>/dev/null
    command rm -f /tmp/jukebox-*.m3u(N) /tmp/jukebox-py.log 2>/dev/null
    command rm -f /tmp/jukebox-watch-*.fifo(N) 2>/dev/null
    command rm -f /tmp/jukebox-mpv-auth-*.conf(N) 2>/dev/null
    command rm -rf /tmp/jukebox-sort-*(N) /tmp/jukebox-scripts-*(N) 2>/dev/null
    command rm -f /tmp/jukebox-sort-state-*(N) 2>/dev/null
    command rm -f "${XDG_RUNTIME_DIR:-/tmp}"/jukebox-mpv-*.sock(N) 2>/dev/null
    unset _JUKEBOX_PYTHON _JUKEBOX_PREVTMP _JUKEBOX_CACHE \
          _JUKEBOX_SHOW_FORMATNAMES _JUKEBOX_SOCK _JUKEBOX_QUEUEFILE 2>/dev/null


    _jukebox_log() {
        (( _jukebox_debug )) && printf '[%s] %s\n' "$SECONDS" "$*" >> "$_jukebox_debuglog"
    }

    # --- detect python3 interpreter (full path for subshells) ---
    local _JUKEBOX_PYTHON
    _JUKEBOX_PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
    if [[ -z "$_JUKEBOX_PYTHON" ]]; then
        echo "❌ Error: python3 (or python) not found in PATH"
        return 1
    fi
    export _JUKEBOX_PYTHON
    export _JUKEBOX_SCRIPT_DIR

    local playlist=$(mktemp /tmp/jukebox-XXXXXX.m3u)
    local mpvsock=$(mktemp -u "${XDG_RUNTIME_DIR:-/tmp}/jukebox-mpv-XXXXXX.sock")
    local coverfile=$(mktemp /tmp/jukebox-cover-XXXXXX.jpg)
    local coverfile_next=$(mktemp /tmp/jukebox-cover-next-XXXXXX.jpg)
    local _jukebox_prevtmp="/tmp/jukebox-fzf-preview-$$.jpg"
    local queuefile="/tmp/jukebox-queue-$$.txt"
    local mpv_auth_config=""
    local _jukebox_datadir="${JUKEBOX_DATA_DIR:-$HOME/.jukebox-app}"
    mkdir -p "$_jukebox_datadir"
    # One-time migration from the pre-0.x location. ~/.cache is fair game for
    # cleaners (and shared with any other app named "jukebox"), so the library
    # cache and saved sessions moved out of it. Existing files are carried over
    # instead of being re-probed from scratch.
    local _jukebox_olddir="${XDG_CACHE_HOME:-$HOME/.cache}/jukebox" _mig_f
    if [[ -d "$_jukebox_olddir" && "$_jukebox_olddir" != "$_jukebox_datadir" ]]; then
        for _mig_f in "$_jukebox_olddir"/*(N); do
            [[ -e "$_jukebox_datadir/${_mig_f:t}" ]] || command mv -f "$_mig_f" "$_jukebox_datadir/" 2>/dev/null
        done
        command rmdir "$_jukebox_olddir" 2>/dev/null
    fi
    local cachefile="$_jukebox_datadir/metadata.tsv"
    local _jukebox_state_file="$_jukebox_datadir/session.state"
    local _jukebox_state_playlist="$_jukebox_datadir/session.m3u"
    if [[ "$_jukebox_source" == "jellyfin" ]]; then
        cachefile="$_jukebox_datadir/metadata-jellyfin.tsv"
        _jukebox_state_file="$_jukebox_datadir/session-jellyfin.state"
        _jukebox_state_playlist="$_jukebox_datadir/session-jellyfin.m3u"
    fi
    # Half-written snapshots from a session that died mid-save (the exact
    # scenario this feature guards against) never get an atomic mv.
    command rm -f "$_jukebox_datadir"/session*.tmp.*(N) \
        "$cachefile".tmp.*(N) 2>/dev/null

    # Saved-session state, populated by _jukebox_load_state (src/session.zsh).
    local _jukebox_resuming=0
    local _resume_source="" _resume_ended="" _resume_pos=0 _resume_count=0
    local _resume_time=0 _resume_duration=0 _resume_speed="1.0" _resume_pitch="1.0"
    local _resume_apc="true" _resume_rtmode="tempo" _resume_lyrics=0
    local _resume_path="" _resume_title="" _resume_artist="" _resume_album=""
    export _JUKEBOX_PREVTMP="$_jukebox_prevtmp"
    export _JUKEBOX_CACHE="$cachefile"
    export _JUKEBOX_SHOW_FORMATNAMES="$_jukebox_show_formatnames"

    # --- Load Modules ---
    for mod in "$_JUKEBOX_SCRIPT_DIR/src/"*.zsh; do
        source "$mod"
    done

    local _jukebox_cleaned=""
    local _jukebox_art_text=""
    local saved_stty=$(stty -g 2>/dev/null)

    local _cache_pid=""
    local _watcher_pid=""
    local _watcher_reader_pid=""
    local _watcher_fifo="/tmp/jukebox-watch-$$.fifo"

    # Cache sync and the recursive watcher start before the launch menu. Keep
    # their cleanup available to every early return, and arm it for signals.
    # The full player cleanup trap replaces this one later.
    _jukebox_stop_startup_jobs() {
        if [[ -n "$_cache_pid" ]]; then
            if kill -0 "$_cache_pid" 2>/dev/null; then
                kill "$_cache_pid" 2>/dev/null
            fi
            wait "$_cache_pid" 2>/dev/null
            _cache_pid=""
            command rm -f "$cachefile".tmp.*(N) 2>/dev/null
        fi
        if [[ -n "$_watcher_pid" ]]; then
            if kill -0 "$_watcher_pid" 2>/dev/null; then
                kill "$_watcher_pid" 2>/dev/null
            fi
            wait "$_watcher_pid" 2>/dev/null
            _watcher_pid=""
        fi
        if [[ -n "$_watcher_reader_pid" ]]; then
            if kill -0 "$_watcher_reader_pid" 2>/dev/null; then
                kill "$_watcher_reader_pid" 2>/dev/null
            fi
            wait "$_watcher_reader_pid" 2>/dev/null
            _watcher_reader_pid=""
        fi
        command rm -f "$_watcher_fifo" 2>/dev/null
    }
    trap _jukebox_stop_startup_jobs INT TERM HUP QUIT PIPE

    if [[ "$_jukebox_source" == "jellyfin" ]]; then
        echo "⏳ Syncing Jellyfin music library..."
        if ! "$_JUKEBOX_PYTHON" "$_JUKEBOX_JELLYFIN_CLIENT" sync --cache "$cachefile"; then
            return 1
        fi
    else
    # --- build/update persistent metadata cache (incremental) ---
    # On first run: full scan. On subsequent runs: only probe NEW files,
    # remove entries for DELETED files. Makes repeated launches near-instant.
    "$_JUKEBOX_PYTHON" -c "
import subprocess, json, os, sys
from concurrent.futures import ThreadPoolExecutor
musicdir = sys.argv[1]
cache_path = sys.argv[2]

# Discover all supported local audio files on disk
disk_files = set()
for root, dirs, files in os.walk(musicdir):
    for f in sorted(files):
        f_lower = f.lower()
        if f_lower.endswith('.flac') or f_lower.endswith('.mp3'):
            disk_files.add(os.path.join(root, f))

# Load existing cache entries.
# Cache value layout: title\tartist\talbum\tdate\tdur\ttrack\tdisc (7 fields).
# Entries written by an older format (fewer fields) are dropped so they get
# re-probed, which transparently migrates the cache on first launch.
cached = {}
if os.path.exists(cache_path):
    with open(cache_path) as fh:
        for line in fh:
            parts = line.rstrip('\n').split('\t', 1)
            if len(parts) == 2 and parts[1].count('\t') == 6:
                cached[parts[0]] = parts[1]

# Find new files that need probing
new_files = disk_files - set(cached.keys())
# Remove entries for files that no longer exist
deleted = set(cached.keys()) - disk_files
for d in deleted:
    del cached[d]

# Probe new files concurrently. A small pool keeps HDD pressure reasonable but
# avoids making a large first MP3 import look permanently stuck.
def probe(fp):
    try:
        r = subprocess.run(['ffprobe','-v','quiet','-print_format','json','-show_format',fp],
                           capture_output=True, text=True, timeout=10)
        d = json.loads(r.stdout)
        tags = d.get('format',{}).get('tags',{})
        get = lambda k: tags.get(k, tags.get(k.upper(), ''))
        def numtag(default, *keys):
            for k in keys:
                v = str(get(k)).split('/')[0].strip()
                if v:
                    try: return str(int(v))
                    except ValueError: pass
            return default
        f = os.path.basename(fp)
        title = get('title') or os.path.splitext(f)[0]
        artist = get('artist') or 'Unknown'
        album = get('album') or 'Unknown'
        date = get('date') or '0'
        dur = d.get('format',{}).get('duration','0')
        track = numtag('0','track','tracknumber')   # 0 = unknown, sorts first
        disc = numtag('1','disc','discnumber')       # 1 = assume single-disc
        value = f'{title}\t{artist}\t{album}\t{date}\t{dur}\t{track}\t{disc}'
        return fp, value
    except Exception:
        return fp, None

ordered_new = sorted(new_files)
if ordered_new:
    print(f'Library cache: probing {len(ordered_new)} new tracks...', file=sys.stderr, flush=True)
    with ThreadPoolExecutor(max_workers=min(4, len(ordered_new))) as executor:
        for index, (fp, value) in enumerate(executor.map(probe, ordered_new), 1):
            if value is not None:
                cached[fp] = value
            if index % 25 == 0 or index == len(ordered_new):
                print(f'Library cache: {index}/{len(ordered_new)} tracks', file=sys.stderr, flush=True)

# Replace the cache atomically. Startup cleanup may stop this background sync;
# an interrupted refresh must never truncate the last known-good library.
cache_tmp = f'{cache_path}.tmp.{os.getpid()}'
try:
    with open(cache_tmp, 'w') as out:
        for fp in sorted(cached.keys()):
            out.write(f'{fp}\t{cached[fp]}\n')
    os.replace(cache_tmp, cache_path)
finally:
    try:
        os.unlink(cache_tmp)
    except FileNotFoundError:
        pass

if new_files or deleted:
    print(f'Cache: +{len(new_files)} new, -{len(deleted)} removed', file=sys.stderr)
" "${JUKEBOX_MUSIC_DIR:-$HOME/Music}" "$cachefile" &
    _cache_pid=$!

    # --- live directory watcher (detects new .flac files during playback) ---
    if command -v inotifywait >/dev/null 2>&1 && command mkfifo "$_watcher_fifo"; then
        inotifywait -m -r -e close_write,moved_to --format '%w%f' \
            "${JUKEBOX_MUSIC_DIR:-$HOME/Music}" > "$_watcher_fifo" 2>/dev/null &
        _watcher_pid=$!
        (
            while read -r newfile; do
                [[ "${newfile:l}" != *.flac && "${newfile:l}" != *.mp3 ]] && continue
                # Check if already in cache
                grep -qF "$newfile" "$cachefile" 2>/dev/null && continue
                # Probe and append
                "$_JUKEBOX_PYTHON" -c "
import subprocess, json, os, sys
fp = sys.argv[1]
cache_path = sys.argv[2]
try:
    r = subprocess.run(['ffprobe','-v','quiet','-print_format','json','-show_format',fp],
                       capture_output=True, text=True, timeout=10)
    d = json.loads(r.stdout)
    tags = d.get('format',{}).get('tags',{})
    get = lambda k: tags.get(k, tags.get(k.upper(), ''))
    def numtag(default, *keys):
        for k in keys:
            v = str(get(k)).split('/')[0].strip()
            if v:
                try: return str(int(v))
                except ValueError: pass
        return default
    f = os.path.basename(fp)
    title = get('title') or os.path.splitext(f)[0]
    artist = get('artist') or 'Unknown'
    album = get('album') or 'Unknown'
    date = get('date') or '0'
    dur = d.get('format',{}).get('duration','0')
    track = numtag('0','track','tracknumber')
    disc = numtag('1','disc','discnumber')
    with open(cache_path, 'a') as out:
        out.write(f'{fp}\t{title}\t{artist}\t{album}\t{date}\t{dur}\t{track}\t{disc}\n')
except: pass
" "$newfile" "$cachefile"
            done
        ) < "$_watcher_fifo" &
        _watcher_reader_pid=$!
    fi
    fi

    _jukebox_setup_fzf_sort() {
        if [[ -n "$_cache_pid" ]]; then
            if kill -0 "$_cache_pid" 2>/dev/null; then
                echo "⏳ Building music library metadata cache..."
            fi
            local _cache_status=0
            wait "$_cache_pid" || _cache_status=$?
            _cache_pid=""
            command rm -f "$cachefile".tmp.*(N) 2>/dev/null
            if (( _cache_status != 0 )); then
                echo "⚠️  Library metadata refresh failed; using the existing cache."
            fi
        fi

        _fzf_sort_dir=$(mktemp -d /tmp/jukebox-sort-XXXXXX)
        local sort_state_file="/tmp/jukebox-sort-state-$$"
        _gen_sort() {
            cat > "$_fzf_sort_dir/$2.sh" << SORTEOF
#!/usr/bin/env bash
echo "$2" > "$sort_state_file"
if (( \$_JUKEBOX_SHOW_FORMATNAMES )); then
    $1 "\$_JUKEBOX_CACHE" | awk -F'\\t' '{ printf "%s\\t%s - %s\\n", \$1, \$2, \$3 }'
else
    $1 "\$_JUKEBOX_CACHE" | awk -F'\\t' '{ printf "%s\\t%s\\n", \$1, \$1 }'
fi
SORTEOF
        }

        # Cache fields: 1=path 2=title 3=artist 4=album 5=date 6=dur 7=track 8=disc
        # All multi-track groupings resolve to album -> disc -> track order so a
        # given album always reads Track 1 -> Track N (disc-aware, numeric).
        local _ADT="-k4,4f -k8,8n -k7,7n"   # album, disc, track
        _gen_sort "sort -t$'\t' -k2,2f $_ADT" "by_title"
        _gen_sort "sort -t$'\t' -k2,2fr $_ADT" "by_title_rev"
        _gen_sort "sort -t$'\t' -k3,3f $_ADT" "by_artist"
        _gen_sort "sort -t$'\t' -k3,3fr $_ADT" "by_artist_rev"
        _gen_sort "sort -t$'\t' $_ADT" "by_album"
        _gen_sort "sort -t$'\t' -k4,4fr -k8,8n -k7,7n" "by_album_rev"
        _gen_sort "sort -t$'\t' -k5,5nr $_ADT" "by_date"
        _gen_sort "sort -t$'\t' -k5,5n $_ADT" "by_date_rev"
        _gen_sort "sort -t$'\t' -k6,6n -k3,3f $_ADT" "by_length"
        _gen_sort "sort -t$'\t' -k6,6nr -k3,3f $_ADT" "by_length_rev"
        chmod +x "$_fzf_sort_dir"/*.sh

        _fzf_binds=()
        if [[ -s "$_JUKEBOX_CACHE" ]]; then
            _fzf_binds=(
                --bind "alt-t:reload($_fzf_sort_dir/by_title.sh)"
                --bind "alt-T:reload($_fzf_sort_dir/by_title_rev.sh)"
                --bind "alt-a:reload($_fzf_sort_dir/by_artist.sh)"
                --bind "alt-A:reload($_fzf_sort_dir/by_artist_rev.sh)"
                --bind "alt-b:reload($_fzf_sort_dir/by_album.sh)"
                --bind "alt-B:reload($_fzf_sort_dir/by_album_rev.sh)"
                --bind "alt-d:reload($_fzf_sort_dir/by_date.sh)"
                --bind "alt-D:reload($_fzf_sort_dir/by_date_rev.sh)"
                --bind "alt-l:reload($_fzf_sort_dir/by_length.sh)"
                --bind "alt-L:reload($_fzf_sort_dir/by_length_rev.sh)"
            )
        fi
    }

    _jukebox_get_input_list() {
        if [[ -s "$cachefile" ]]; then
            if (( _jukebox_show_formatnames )); then
                sort -t$'\t' -k2 -f "$cachefile" | awk -F'\t' '{ printf "%s\t%s - %s\n", $1, $2, $3 }'
            else
                sort -t$'\t' -k2 -f "$cachefile" | awk -F'\t' '{ printf "%s\t%s\n", $1, $1 }'
            fi
        else
            if (( _jukebox_show_formatnames )); then
                for f in "$@"; do printf "%s\t%s\n" "$f" "${f##*/}"; done
            else
                for f in "$@"; do printf "%s\t%s\n" "$f" "$f"; done
            fi
        fi
    }

    _jukebox_source_files() {
        local order="${1:-original}"
        if [[ "$_jukebox_source" == "jellyfin" ]]; then
            case "$order" in
                name_asc)  sort -t$'\t' -k2,2f "$cachefile" | cut -f1 ;;
                name_desc) sort -t$'\t' -k2,2fr "$cachefile" | cut -f1 ;;
                date_asc)  sort -t$'\t' -k5,5n -k4,4f -k8,8n -k7,7n "$cachefile" | cut -f1 ;;
                date_desc) sort -t$'\t' -k5,5nr -k4,4f -k8,8n -k7,7n "$cachefile" | cut -f1 ;;
                *) cut -f1 "$cachefile" ;;
            esac
        else
            setopt localoptions extendedglob nocaseglob
            local _raw_files=()
            case "$order" in
                name_asc)  _raw_files=("$musicdir"/**/*.(flac|mp3)(N.on)) ;;
                name_desc) _raw_files=("$musicdir"/**/*.(flac|mp3)(N.On)) ;;
                date_asc)  _raw_files=("$musicdir"/**/*.(flac|mp3)(N.Om)) ;;
                date_desc) _raw_files=("$musicdir"/**/*.(flac|mp3)(N.om)) ;;
                *) _raw_files=("$musicdir"/**/*.(flac|mp3)(N.)) ;;
            esac
            for f in "${_raw_files[@]}"; do
                printf '%s\n' "$f"
            done
        fi
    }

    local choice files=() start_idx=0
    local musicdir="${JUKEBOX_MUSIC_DIR:-$HOME/Music}"

    local _resume_available=0
    _jukebox_load_state && _resume_available=1

    echo "🎵 Jukebox - Select playback mode:"
    if (( _resume_available )); then
        echo "  0) ▶ Resume: $(_jukebox_resume_label)"
    fi
    echo "  1) Play all (original order)"
    echo "  2) Sort by filename (A-Z)"
    echo "  3) Sort by filename (Z-A)"
    echo "  4) Sort by date (oldest first)"
    echo "  5) Sort by date (newest first)"
    echo "  6) Browse & pick (plays from selection onward)"
    echo "  7) Shuffle"
    echo "  8) Build queue (TAB to pick, ENTER to play)"
    (( _resume_available )) && echo "  x) Forget saved session"
    echo "  q) Quit"
    echo ""
    if (( _resume_available )); then
        read "choice?Choose [0-8, x, q]: "
    else
        read "choice?Choose [1-8, q]: "
    fi

    case "$choice" in
        0|r|R)
            if (( ! _resume_available )); then
                echo "Nothing to resume"
                _jukebox_stop_startup_jobs
                return 1
            fi
            files=("${(@f)$(<"$_jukebox_state_playlist")}")
            files=("${(@)files:#}")   # drop blank lines
            if [[ ${#files[@]} -eq 0 ]]; then
                echo "Saved session playlist is empty"
                _jukebox_stop_startup_jobs
                return 1
            fi
            start_idx=$_resume_pos
            (( start_idx >= ${#files[@]} )) && start_idx=0
            _jukebox_resuming=1
            ;;
        x|X)
            if (( _resume_available )); then
                command rm -f "$_jukebox_state_file" "$_jukebox_state_playlist" 2>/dev/null
                echo "🗑  Saved session discarded"
            fi
            _jukebox_stop_startup_jobs
            return
            ;;
        1) files=("${(@f)$(_jukebox_source_files original)}") ;;
        2) files=("${(@f)$(_jukebox_source_files name_asc)}") ;;
        3) files=("${(@f)$(_jukebox_source_files name_desc)}") ;;
        4) files=("${(@f)$(_jukebox_source_files date_asc)}") ;;
        5) files=("${(@f)$(_jukebox_source_files date_desc)}") ;;
        6)
            local all_files=("${(@f)$(_jukebox_source_files name_asc)}")
            if [[ ${#all_files[@]} -eq 0 ]]; then
                echo "No music found in the $_jukebox_source library"
                _jukebox_stop_startup_jobs
                return 1
            fi
            
            _jukebox_setup_fzf_sort
            
            local fzf_header="TAB=toggle  ENTER=play/queue  Alt-s=play (shuffle rest)  ESC=cancel"
            if [[ -s "$cachefile" ]]; then
                fzf_header="$fzf_header
─── Sort ↑  Alt: T=Title  A=Artist  B=Album  D=Date  L=Length ──
─── Sort ↓  Shift+Alt: T  A  B  D  L ──────────────────────────"
            fi

            local input_list
            input_list=$(_jukebox_get_input_list "${all_files[@]}")

            # Overwrite all_files with the exact visual order presented to fzf
            # (Because _jukebox_get_input_list sorts by title from cache)
            local visual_paths
            visual_paths=$(echo "$input_list" | cut -f1)
            all_files=("${(@f)visual_paths}")

# Ratings (column 4): set a 0-5 star rating on a track.
_jukebox_rate_track() {
    # Args: rating [path]. Without a path, rate the currently playing track.
    local rating="$1" path="$2"
    if [[ -z "$rating" || "$rating" != <-> || "$rating" -gt 5 ]]; then
        _jukebox_log WARN "invalid rating: ${rating:-<empty>}"
        print -r -- "jukebox: rating must be an integer 0-5" >&2
        return 1
    fi
    [[ -n "$path" ]] || path=$(_jukebox_current_file)
    if [[ -z "$path" ]]; then
        _jukebox_log WARN "no track to rate"
        print -r -- "jukebox: no track to rate (nothing playing)" >&2
        return 1
    fi
    local id
    id=$(_jukebox_id_for "$path")
    _jukebox_meta_set_field "$id" "$path" 4 "$rating"
    _jukebox_log INFO "rating=$rating for $path"
    print -r -- "Rated ${rating}/5: ${path:t}"
}
            echo "default" > "/tmp/jukebox-sort-state-$$"
            output=$(echo "$input_list" | \
                fzf -i --multi \
                    --delimiter=$'\t' --with-nth=2 \
                    --prompt="Pick start song(s): " \
                    --header="$fzf_header" \
                    --marker="✔ " \
                    --preview "$_jukebox_fzf_preview" \
                    --preview-window=right:50% \
                    --expect=enter,alt-s \
                    "${_fzf_binds[@]}")
                    
            if [[ -z "$output" ]]; then
                command rm -rf "$_fzf_sort_dir"
                _jukebox_stop_startup_jobs
                return
            fi
            
            local key_pressed=$(echo "$output" | head -n 1)
            local selected=$(echo "$output" | sed '1d')
            if [[ -z "$selected" ]]; then
                _jukebox_stop_startup_jobs
                return
            fi
            
            # Reconstruct the true visual order if the user changed the sort
            local current_sort
            current_sort=$(cat "/tmp/jukebox-sort-state-$$" 2>/dev/null)
            if [[ -n "$current_sort" && "$current_sort" != "default" && -s "$cachefile" ]]; then
                # Re-run the exact sort script to get the ordered file list
                local sorted_paths
                sorted_paths=$("$_fzf_sort_dir/$current_sort.sh" | cut -f1)
                all_files=("${(@f)sorted_paths}")
            fi
            command rm -rf "$_fzf_sort_dir"
            
            # Extract first column (filepath)
            local picked_arr=("${(@f)${$(echo "$selected" | cut -f1)}}")
            local last_picked="${picked_arr[-1]}"
            local last_idx=-1
            for i in {1..${#all_files[@]}}; do
                [[ "${all_files[$i]}" == "$last_picked" ]] && { last_idx=$i; break; }
            done
            
            files=("${picked_arr[@]}")
            if (( last_idx != -1 && last_idx < ${#all_files[@]} )); then
                local -A seen
                for x in "${picked_arr[@]}"; do seen[$x]=1; done
                local remaining_files=()
                for ((i=last_idx+1; i<=${#all_files[@]}; i++)); do
                    local f="${all_files[$i]}"
                    if [[ -z "${seen[$f]}" ]]; then
                        remaining_files+=("$f")
                    fi
                done
                
                if [[ "$key_pressed" == "alt-s" ]]; then
                    local r_i r_j r_tmp_val
                    for ((r_i=${#remaining_files[@]}; r_i>1; r_i--)); do
                        r_j=$((RANDOM % r_i + 1))
                        r_tmp_val="${remaining_files[$r_i]}"
                        remaining_files[$r_i]="${remaining_files[$r_j]}"
                        remaining_files[$r_j]="$r_tmp_val"
                    done
                fi
                files+=("${remaining_files[@]}")
            fi
            start_idx=0
            ;;
        7)
            local -a _tmp=("${(@f)$(_jukebox_source_files original)}")
            local i j tmp_val
            for ((i=${#_tmp[@]}; i>1; i--)); do
                j=$((RANDOM % i + 1))
                tmp_val="${_tmp[$i]}"
                _tmp[$i]="${_tmp[$j]}"
                _tmp[$j]="$tmp_val"
            done
            files=("${_tmp[@]}")
            ;;
        8)
            local all_files=("${(@f)$(_jukebox_source_files name_asc)}")
            if [[ ${#all_files[@]} -eq 0 ]]; then
                echo "No music found in the $_jukebox_source library"
                _jukebox_stop_startup_jobs
                return 1
            fi
            
            _jukebox_setup_fzf_sort
            
            local fzf_header="TAB=toggle  Ctrl-A=all  Ctrl-D=none  ENTER=play"
            if [[ -s "$cachefile" ]]; then
                fzf_header="$fzf_header
─── Sort ↑  Alt: T=Title  A=Artist  B=Album  D=Date  L=Length ──
─── Sort ↓  Shift+Alt: T  A  B  D  L ──────────────────────────"
            fi
            
            local input_list
            input_list=$(_jukebox_get_input_list "${all_files[@]}")

            local selected
            selected=$(echo "$input_list" | \
                fzf -i --multi \
                    --delimiter=$'\t' --with-nth=2 \
                    --prompt="Queue: " \
                    --header="$fzf_header" \
                    --marker="✔ " \
                    --preview "$_jukebox_fzf_preview" \
                    --preview-window=right:50% \
                    --bind 'ctrl-a:select-all,ctrl-d:deselect-all' \
                    "${_fzf_binds[@]}")
                    
            command rm -rf "$_fzf_sort_dir"
            if [[ -z "$selected" ]]; then
                _jukebox_stop_startup_jobs
                return
            fi
            files=("${(@f)${$(echo "$selected" | cut -f1)}}")
            echo ""
            echo "📋 Queue (${#files[@]} songs):"
            local n=1
            for f in "${files[@]}"; do
                local _fname="${f##*/}"; _fname="${_fname%.flac}"
                echo "  $n) $_fname"
                n=$((n + 1))
            done
            start_idx=0
            ;;

        q|Q)
            _jukebox_stop_startup_jobs
            return
            ;;
        *)
            echo "Invalid choice"
            _jukebox_stop_startup_jobs
            return 1
            ;;
    esac

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No music found in the $_jukebox_source library"
        _jukebox_stop_startup_jobs
        return 1
    fi



    : > "$queuefile"  # create empty tracker for manually queued songs

    printf '%s\n' "${files[@]}" > "$playlist"

    # cleanup handler (idempotent — safe to call multiple times)
    _jukebox_cleanup() {
        trap - INT TERM HUP QUIT PIPE EXIT 2>/dev/null
        [[ -n "$_jukebox_cleaned" ]] && return
        _jukebox_cleaned=1
        (( ${+functions[_jukebox_log]} )) && _jukebox_log "cleanup: starting"
        # Final session snapshot BEFORE mpv dies, flagged as a clean exit.
        (( ${+functions[_jukebox_save_state]} )) && _jukebox_save_state clean
        # Clear Kitty graphics protocol images before leaving altscreen
        printf '\e_Ga=d;\e\\'
        printf '\e[?1049l\e[?25h'
        [[ -n "$saved_stty" ]] && stty "$saved_stty" 2>/dev/null
        if [[ -n "$_jukebox_mpv_pid" ]] && kill -0 "$_jukebox_mpv_pid" 2>/dev/null; then
            _jukebox_set '{"command":["quit"]}' 2>/dev/null
            sleep 0.1
            kill "$_jukebox_mpv_pid" 2>/dev/null
            sleep 0.1
            kill -9 "$_jukebox_mpv_pid" 2>/dev/null
            wait "$_jukebox_mpv_pid" 2>/dev/null
        fi
        # Stop any library background jobs still active.
        _jukebox_stop_startup_jobs
        # Remove session-specific temp files (persistent cache is kept!)
        command rm -f "$playlist" "$mpvsock" "$coverfile" "$coverfile_next" "$_jukebox_prevtmp" "$queuefile"
        [[ -n "$mpv_auth_config" ]] && command rm -f "$mpv_auth_config"
        command rm -f "/tmp/jukebox-sort-state-$$"
        command rm -rf "$_fzf_sort_dir"
        # Remove log files that accumulate across sessions
        command rm -f /tmp/jukebox-py.log /tmp/jukebox-debug.log 2>/dev/null
        # Unset exported env vars so they don't leak into the next session
        unset _JUKEBOX_PYTHON _JUKEBOX_PREVTMP _JUKEBOX_CACHE \
              _JUKEBOX_SHOW_FORMATNAMES _JUKEBOX_SOCK _JUKEBOX_QUEUEFILE 2>/dev/null
        unfunction _jukebox_render _jukebox_render_next_panel _jukebox_ipc \
                   _jukebox_set _jukebox_batch_get _jukebox_extract_art _jukebox_cache_art \
                   _jukebox_cache_next_art _jukebox_calc_layout \
                   _jukebox_center _jukebox_padline _jukebox_fast_get \
                   _jukebox_fetch_next_meta _jukebox_clear_next_meta \
                   _jukebox_add_next _jukebox_queue_picker _jukebox_get_input_list _jukebox_source_files \
                   _jukebox_load_lyrics _jukebox_update_lyric_index _jukebox_render_lyrics \
                   _jukebox_log _jukebox_setup_fzf_sort \
                   _jukebox_stop_startup_jobs \
                   _jukebox_save_state _jukebox_load_state _jukebox_snapshot_playlist \
                   _jukebox_resume_label _jukebox_apply_resume 2>/dev/null
    }
    trap _jukebox_cleanup INT TERM HUP QUIT PIPE EXIT

    # start mpv in background with IPC socket, fully headless
    _jukebox_log "mpv: starting with playlist=$playlist sock=$mpvsock start_idx=$start_idx"
    # Buffering: music lives on a slow HDD, so default mpv (reads ~1s ahead)
    # keeps seeking back to the file mid-track and fights cover extraction for
    # the disk head -> audible lag/stutter. Pull each track fully into RAM up
    # front and preload the next playlist entry while the current one plays, so
    # the HDD is touched once per track instead of continuously.
    local -a _mpv_auth_args=()
    if [[ "$_jukebox_source" == "jellyfin" ]]; then
        mpv_auth_config=$(mktemp /tmp/jukebox-mpv-auth-XXXXXX.conf)
        chmod 600 "$mpv_auth_config"
        if ! "$_JUKEBOX_PYTHON" "$_JUKEBOX_JELLYFIN_CLIENT" mpv-config "$mpv_auth_config"; then
            return 1
        fi
        _mpv_auth_args=(--include="$mpv_auth_config")
    fi
    # When resuming, start paused so the seek to the saved position lands
    # before a single sample of the track's beginning is heard.
    local -a _mpv_resume_args=()
    (( _jukebox_resuming )) && _mpv_resume_args=(--pause=yes)
    env PIPEWIRE_LATENCY="50/1000" mpv --no-video --no-terminal \
        "${_mpv_auth_args[@]}" "${_mpv_resume_args[@]}" \
        --ytdl=no \
        --audio-format=s32 \
        --audio-samplerate=0 \
        --keep-open=no \
        --cache=yes \
        --cache-secs=3600 \
        --demuxer-max-bytes=512MiB \
        --demuxer-max-back-bytes=128MiB \
        --demuxer-readahead-secs=3600 \
        --prefetch-playlist=yes \
        --playlist="$playlist" \
        --playlist-start="$start_idx" \
        --input-ipc-server="$mpvsock" \
        --script-opts=mpris-identity=Jukebox 2>/dev/null &
    _jukebox_mpv_pid=$!
    _jukebox_log "mpv: PID=$_jukebox_mpv_pid"

    # wait for socket
    local waited=0
    while [[ ! -S "$mpvsock" ]] && (( waited < 30 )); do
        sleep 0.1
        waited=$((waited + 1))
    done
    _jukebox_log "mpv: socket wait done (waited=${waited}, socket_exists=$(test -S "$mpvsock" && echo yes || echo no))"
    if [[ ! -S "$mpvsock" ]]; then
        echo "Error: mpv failed to start"
        _jukebox_log "mpv: FAILED — socket never appeared"
        return 1
    fi
    # mpv has consumed the private auth options; keeping the token-bearing file
    # around for the whole session would only widen its exposure window.
    [[ -n "$mpv_auth_config" ]] && command rm -f "$mpv_auth_config"

    # --- IPC helper using python for reliable Unix socket communication ---




    # --- batch property getter: single Python process, single socket connection ---
    # Usage: _jukebox_batch_get prop1 prop2 ...
    # Output: tab-separated values for each property


    # --- extract cover art ---


    # --- layout engine: computes all dimensions from terminal size ---
    # Sets: _layout_mode (normal|compact|minimal)
    #       _layout_header_rows, _layout_art_start_row
    #       _layout_art_w, _layout_art_h
    #       _layout_next_mode (side|below|hidden)
    #       _layout_next_art_w, _layout_next_art_h
    #       _layout_next_x, _layout_next_y (for side mode)
    #       _layout_content_bottom (last row available before progress bar)


    # --- cache chafa output for current cover using layout dimensions ---


    # --- cache chafa output for "Up Next" cover using layout dimensions ---


    # center helper


    # pad line to full width (clears leftover chars)


    # query an individual property fast using python batch fetcher wrapper


    # --- fetch metadata for the next track (called from main loop, NOT render) ---




    # --- render "Up Next" panel at given position (helper for _jukebox_render) ---
    # Args: $1=start_col, $2=start_row, $3=max_row (must not render past this), $4=max_col_width


    # --- render screen (pure display — all data pre-fetched by main loop) ---



    # --- add to queue (Spotify style / play next) ---


    # --- queue picker & editor ---


    # enter altscreen + initial clear
    printf '\e[?1049h\e[2J\e[?25l'

    # shared state for render (set by main loop, read by _jukebox_render)
    local _render_path="" _render_title="" _render_artist="" _render_album=""
    local _render_pl_pos=0 _render_pl_count=0
    local _render_time_pos=0 _render_duration=0 _render_paused=""
    local _render_speed=1.0 _render_pitch=1.0 _render_apc="true"
    local _source_title="" _source_artist="" _source_album=""
    local _current_meta="" _cm_date="" _cm_dur="" _cm_track="" _cm_disc=""
    local _lyrics_mode=0 _lyrics_loaded_path="" _lyrics_active_index=0 _lyrics_previous_index=0
    (( _jukebox_resuming )) && _lyrics_mode=$_resume_lyrics
    local -a _lyrics_starts=() _lyrics_lines=()
    local _jukebox_last_next_file=""
    local _jukebox_next_retries=0
    local _nav_offset=0

    # initial data fetch (retry until mpv is ready)
    sleep 0.5
    local _retries=0
    while [[ -z "$_render_path" ]] && (( _retries < 20 )); do
        _render_path=$(_jukebox_batch_get "path")
        [[ -z "$_render_path" ]] && sleep 0.2
        _retries=$((_retries + 1))
    done
    if [[ -n "$_render_path" ]]; then
        if [[ "$_render_path" == http://* || "$_render_path" == https://* ]]; then
            _current_meta=$("$_JUKEBOX_PYTHON" "$_JUKEBOX_JELLYFIN_CLIENT" cache-row --cache "$cachefile" "$_render_path" 2>/dev/null)
            IFS=$'\x1f' read -r _source_title _source_artist _source_album _cm_date _cm_dur _cm_track _cm_disc <<< "$_current_meta"
            [[ -z "$_render_title" ]] && _render_title="$_source_title"
            [[ -z "$_render_artist" ]] && _render_artist="$_source_artist"
            [[ -z "$_render_album" ]] && _render_album="$_source_album"
        fi
        _jukebox_extract_art "$_render_path"
        _jukebox_cache_art
        (( _jukebox_resuming )) && _jukebox_apply_resume
    else
        _jukebox_calc_layout    # ensure layout vars exist even without a track
        # mpv was started paused for the resume seek — never leave it stuck
        # there just because the initial property fetch came back empty.
        (( _jukebox_resuming )) && _jukebox_set '{"command":["set_property","pause",false]}'
    fi
    _jukebox_render

    # Seed the crash-safe session snapshot before the first poll tick, so a
    # kill in the next second still resumes at the right track.
    _render_pl_pos=$start_idx
    (( _jukebox_resuming )) && _render_time_pos=$_resume_time
    command cp -f "$playlist" "$_jukebox_state_playlist" 2>/dev/null
    _jukebox_save_state

    # track state for change detection
    local last_path="$_render_path"
    local last_cols=$(tput cols) last_rows=$(tput lines)
    local last_paused=""
    local force_redraw=1

    # raw terminal mode for keypress reading
    stty -echo -icanon min 0 time 0 2>/dev/null

    # main display loop
    local _tick=0 key="" seq="" _drain="" new_cols new_rows _est_next _poll_batch pos dur pos_i dur_i pos_m pos_s dur_m dur_s time_str icon label bar_w bar filled empty
    local _p_path _p_paused _p_count _p_pos _p_time _p_dur _p_title _p_artist _p_album _p_next_file _p_next_id _p_speed _p_pitch _p_apc
    local _rt_mode="tempo"
    (( _jukebox_resuming )) && [[ -n "$_resume_rtmode" ]] && _rt_mode="$_resume_rtmode"

    while kill -0 "$_jukebox_mpv_pid" 2>/dev/null; do
        # 1. Handle Input (non-blocking, fast drain)
        key=""
        if read -rs -t 0.01 -k 1 key 2>/dev/null; then
            case "$key" in
                ' ')  _jukebox_set '{"command":["cycle","pause"]}' ;;
                ',')  _jukebox_set '{"command":["playlist-prev"]}' ;;
                '<')  _jukebox_set '{"command":["playlist-prev"]}' ;;
                '.')  _jukebox_set '{"command":["playlist-next"]}' ;;
                '>')  _jukebox_set '{"command":["playlist-next"]}' ;;
                'p'|'P')
                    if [[ "$_rt_mode" == "tempo" ]]; then
                        _rt_mode="nightcore"
                        _jukebox_set '{"command":["set_property","audio-pitch-correction",false]}'
                    elif [[ "$_rt_mode" == "nightcore" ]]; then
                        _rt_mode="pitch"
                        _jukebox_set '{"command":["set_property","audio-pitch-correction",true]}'
                    else
                        _rt_mode="tempo"
                        _jukebox_set '{"command":["set_property","audio-pitch-correction",true]}'
                    fi
                    force_redraw=1
                    ;;
                '[')
                    if [[ "$_rt_mode" == "pitch" ]]; then
                        _jukebox_set '{"command":["add","pitch",-0.05]}'
                    else
                        _jukebox_set '{"command":["add","speed",-0.05]}'
                    fi
                    force_redraw=1
                    ;;
                ']')
                    if [[ "$_rt_mode" == "pitch" ]]; then
                        _jukebox_set '{"command":["add","pitch",0.05]}'
                    else
                        _jukebox_set '{"command":["add","speed",0.05]}'
                    fi
                    force_redraw=1
                    ;;
                'r'|'R'|$'\x7f')
                    _jukebox_set '{"command":["set_property","speed",1.0]}'
                    _jukebox_set '{"command":["set_property","pitch",1.0]}'
                    _rt_mode="tempo"
                    _jukebox_set '{"command":["set_property","audio-pitch-correction",true]}'
                    force_redraw=1
                    ;;
                'j')
                    if (( _lyrics_mode && ${#_lyrics_lines[@]} > 0 && ${_lyrics_starts[1]:--1} < 0 )); then
                        (( _lyrics_active_index < ${#_lyrics_lines[@]} )) && _lyrics_active_index=$((_lyrics_active_index + 1))
                        force_redraw=1
                    elif (( _render_pl_pos + 1 + _nav_offset < _render_pl_count - 1 )); then
                        _nav_offset=$((_nav_offset + 1)); _jukebox_last_next_file=""; force_redraw=1
                    fi
                    ;;
                'k')
                    if (( _lyrics_mode && ${#_lyrics_lines[@]} > 0 && ${_lyrics_starts[1]:--1} < 0 )); then
                        (( _lyrics_active_index > 1 )) && _lyrics_active_index=$((_lyrics_active_index - 1))
                        force_redraw=1
                    elif (( _nav_offset > 0 )); then
                        _nav_offset=$((_nav_offset - 1)); _jukebox_last_next_file=""; force_redraw=1
                    fi
                    ;;
                $'\n'|$'\r')
                    if (( _nav_offset == 0 )); then
                        _jukebox_set '{"command":["set_property","pause",false]}'
                    else
                        local cmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["set_property", "playlist-pos", int(sys.argv[1])]}))' "$((_render_pl_pos + 1 + _nav_offset))")
                        _jukebox_set "$cmd"
                        _nav_offset=0
                        _jukebox_last_next_file=""
                        force_redraw=1
                    fi
                    ;;
                'a'|'A')
                    _jukebox_add_next
                    _jukebox_last_next_file=""
                    _jukebox_next_retries=0
                    _jukebox_snapshot_playlist   # queue changed — persist it
                    force_redraw=1
                    ;;
                'L'|'l')
                    _jukebox_queue_picker
                    _jukebox_last_next_file=""
                    _jukebox_next_retries=0
                    _jukebox_snapshot_playlist   # queue may have been edited
                    force_redraw=1
                    ;;
                'Y'|'y')
                    if (( _lyrics_mode )); then
                        _lyrics_mode=0
                    else
                        _lyrics_mode=1
                        [[ "$_lyrics_loaded_path" != "$_render_path" ]] && _jukebox_load_lyrics "$_render_path"
                    fi
                    force_redraw=1
                    ;;
                'i'|'I')
                    # Show detailed FLAC file info overlay
                    if [[ -n "$_render_path" ]]; then
                        printf '\e[?1049l\e[?25h'
                        [[ -n "$saved_stty" ]] && stty "$saved_stty" 2>/dev/null
                        echo ""
                        echo "╔════════════════════════════════════════════════════════════╗"
                        echo "║  ℹ️  Music Source Info                                    ║"
                        echo "╚════════════════════════════════════════════════════════════╝"
                        echo ""
                        if [[ "$_render_path" == http://* || "$_render_path" == https://* ]]; then
                            echo "  🌐 Source:   Jellyfin direct stream"
                            echo "  🎵 Title:    ${_render_title:-Unknown}"
                            echo "  🎤 Artist:   ${_render_artist:-Unknown}"
                            echo "  💿 Album:    ${_render_album:-Unknown}"
                            [[ -n "$_cm_date" && "$_cm_date" != "0" ]] && echo "  📅 Year:     $_cm_date"
                            if [[ -n "$_cm_dur" ]]; then
                                echo "  ⏱️  Duration: $(printf "%d:%02d" $((${_cm_dur%.*} / 60)) $((${_cm_dur%.*} % 60)))"
                            fi
                            echo ""
                            echo "  The access token is sent as a private HTTP header."
                            echo ""
                            echo "  ── Press any key to return ──"
                            read -rs -k 1
                            printf '\e[?1049h\e[?25l'
                            stty -echo -icanon min 0 time 0 2>/dev/null
                            force_redraw=1
                            continue
                        fi
                        # File path
                        local _info_basename="${_render_path##*/}"
                        local _info_dir="${_render_path%/*}"
                        echo "  📄 File:    $_info_basename"
                        echo "  📁 Path:    $_info_dir"
                        echo ""
                        # Stream info via ffprobe (sample rate, bit depth, channels, codec)
                        local _info_stream
                        _info_stream=$(ffprobe -v quiet -select_streams a:0 \
                            -show_entries stream=sample_rate,bits_per_sample,channels,codec_name,codec_long_name \
                            -of csv=p=0 -- "$_render_path" 2>/dev/null)
                        if [[ -n "$_info_stream" ]]; then
                            IFS=',' read -r _i_codec _i_codec_long _i_sr _i_bits _i_ch <<< "$_info_stream"
                            echo "  🎵 Codec:       ${_i_codec_long:-$_i_codec}"
                            if [[ -n "$_i_sr" && "$_i_sr" != "N/A" ]]; then
                                local _i_sr_khz
                                if (( _i_sr % 1000 == 0 )); then
                                    _i_sr_khz="$((_i_sr / 1000)) kHz"
                                else
                                    _i_sr_khz="$(awk "BEGIN{printf \"%.1f\", $_i_sr/1000}") kHz"
                                fi
                                echo "  📊 Sample Rate: $_i_sr Hz ($_i_sr_khz)"
                            fi
                            if [[ -n "$_i_bits" && "$_i_bits" != "0" && "$_i_bits" != "N/A" ]]; then
                                echo "  🔢 Bit Depth:   ${_i_bits}-bit"
                            fi
                            if [[ -n "$_i_ch" && "$_i_ch" != "N/A" ]]; then
                                local _i_ch_label
                                case "$_i_ch" in
                                    1) _i_ch_label="Mono" ;;
                                    2) _i_ch_label="Stereo" ;;
                                    *) _i_ch_label="${_i_ch} channels" ;;
                                esac
                                echo "  🔊 Channels:    $_i_ch ($_i_ch_label)"
                            fi
                        fi
                        echo ""
                        # Format-level info (duration, bitrate, size)
                        local _info_fmt
                        _info_fmt=$(ffprobe -v quiet \
                            -show_entries format=duration,bit_rate,size \
                            -of csv=p=0 -- "$_render_path" 2>/dev/null)
                        if [[ -n "$_info_fmt" ]]; then
                            IFS=',' read -r _i_dur _i_bitrate _i_fsize <<< "$_info_fmt"
                            if [[ -n "$_i_dur" && "$_i_dur" != "N/A" ]]; then
                                local _i_dur_i=${_i_dur%.*}
                                echo "  ⏱️  Duration:   $(printf "%d:%02d" $((_i_dur_i / 60)) $((_i_dur_i % 60)))"
                            fi
                            if [[ -n "$_i_bitrate" && "$_i_bitrate" != "N/A" ]]; then
                                local _i_br_kbps=$((_i_bitrate / 1000))
                                echo "  📈 Bitrate:     ${_i_br_kbps} kbps ($(awk "BEGIN{printf \"%.1f\", $_i_bitrate/1000000}") Mbps)"
                            fi
                        fi
                        # File size from stat (more reliable)
                        local _i_stat_size
                        _i_stat_size=$(stat -c %s "$_render_path" 2>/dev/null)
                        if [[ -n "$_i_stat_size" && "$_i_stat_size" != "0" ]]; then
                            local _i_size_str
                            if (( _i_stat_size >= 1073741824 )); then
                                _i_size_str="$(awk "BEGIN{printf \"%.2f GB\", $_i_stat_size/1073741824}")"
                            elif (( _i_stat_size >= 1048576 )); then
                                _i_size_str="$(awk "BEGIN{printf \"%.1f MB\", $_i_stat_size/1048576}")"
                            else
                                _i_size_str="$(awk "BEGIN{printf \"%.0f KB\", $_i_stat_size/1024}")"
                            fi
                            echo "  💾 File Size:   $_i_size_str ($_i_stat_size bytes)"
                        fi
                        echo ""
                        # Tags summary
                        echo "  ── Tags ──────────────────────────────────────"
                        [[ -n "$_render_title" ]]  && echo "  Title:   $_render_title"
                        [[ -n "$_render_artist" ]] && echo "  Artist:  $_render_artist"
                        [[ -n "$_render_album" ]]  && echo "  Album:   $_render_album"
                        local _i_date _i_genre _i_tn
                        _i_date=$(ffprobe -v quiet -show_entries format_tags=date -of default=nw=1:nk=1 -- "$_render_path" 2>/dev/null)
                        _i_genre=$(ffprobe -v quiet -show_entries format_tags=genre -of default=nw=1:nk=1 -- "$_render_path" 2>/dev/null)
                        _i_tn=$(ffprobe -v quiet -show_entries format_tags=track -of default=nw=1:nk=1 -- "$_render_path" 2>/dev/null)
                        [[ -n "$_i_date" ]]  && echo "  Date:    $_i_date"
                        [[ -n "$_i_genre" ]] && echo "  Genre:   $_i_genre"
                        [[ -n "$_i_tn" ]]    && echo "  Track:   $_i_tn"
                        echo ""
                        echo "  ── Press any key to return ──"
                        read -rs -k 1
                        printf '\e[?1049h\e[?25l'
                        stty -echo -icanon min 0 time 0 2>/dev/null
                    fi
                    force_redraw=1
                    ;;
                'q'|'Q')
                    local prompt_row=$((_layout_rows / 2))
                    local prompt_col=$(( (_layout_cols - 38) / 2 ))
                    (( prompt_col < 1 )) && prompt_col=1
                    printf '\e[%d;%dH\e[1;41;37m Are you sure you want to quit? (y/N) \e[0m' "$prompt_row" "$prompt_col"
                    local ans=""
                    while true; do
                        read -rs -t 0.1 -k 1 ans 2>/dev/null
                        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
                            break 2
                        elif [[ -n "$ans" ]]; then
                            force_redraw=1
                            break
                        fi
                    done
                    ;;
                $'\e')
                    seq=""
                    read -rs -t 0.05 -k 2 seq 2>/dev/null
                    case "$seq" in
                        '[D') _jukebox_set '{"command":["seek",-5]}' ;;
                        '[C') _jukebox_set '{"command":["seek",5]}' ;;
                        '[A') _jukebox_set '{"command":["seek",30]}' ;;
                        '[B') _jukebox_set '{"command":["seek",-30]}' ;;
                    esac
                    # drain buffered input
                    _drain=""
                    while read -rs -t 0 -k 1 _drain 2>/dev/null; do :; done
                    ;;
            esac
        fi

        _tick=$((_tick + 1))
        if (( _tick % 5 == 0 || force_redraw )); then

        # 2. Check for environment changes (resize)
        new_cols=$(tput cols)
        new_rows=$(tput lines)
        if [[ "$new_cols" != "$last_cols" || "$new_rows" != "$last_rows" ]]; then
            last_cols=$new_cols; last_rows=$new_rows
            _jukebox_cache_art          # re-calculates layout + re-caches current art
            _jukebox_cache_next_art     # re-cache "Up Next" art at new dimensions
            force_redraw=1
        fi

        # 3. Fetch ALL data in a single IPC call (one python3 process per tick)
        _est_next=$((_render_pl_pos + 1 + _nav_offset))
        
        _poll_batch=$(_jukebox_batch_get path pause playlist-count playlist-pos \
            time-pos duration metadata/by-key/title metadata/by-key/artist \
            metadata/by-key/album "playlist/$_est_next/filename" "playlist/$_est_next/id" \
            speed pitch audio-pitch-correction)
            
        IFS=$'\x1f' read -r _p_path _p_paused _p_count _p_pos _p_time _p_dur \
            _p_title _p_artist _p_album _p_next_file _p_next_id \
            _p_speed _p_pitch _p_apc <<< "$_poll_batch"

        # Update shared render state
        _render_path="$_p_path"
        _render_paused="$_p_paused"
        _render_pl_count="${_p_count:-0}"
        _render_pl_pos="${_p_pos:-0}"
        _render_time_pos="${_p_time:-0}"
        _render_duration="${_p_dur:-0}"
        _render_title="$_p_title"
        _render_artist="$_p_artist"
        _render_album="$_p_album"
        [[ -z "$_render_title" ]] && _render_title="$_source_title"
        [[ -z "$_render_artist" ]] && _render_artist="$_source_artist"
        [[ -z "$_render_album" ]] && _render_album="$_source_album"
        _render_speed="$_p_speed"
        _render_pitch="$_p_pitch"
        _render_apc="$_p_apc"

        # 4. Handle track change
        if [[ -n "$_render_path" && "$_render_path" != "$last_path" ]]; then
            last_path="$_render_path"
            _source_title=""; _source_artist=""; _source_album=""
            if [[ "$_render_path" == http://* || "$_render_path" == https://* ]]; then
                _current_meta=$("$_JUKEBOX_PYTHON" "$_JUKEBOX_JELLYFIN_CLIENT" cache-row --cache "$cachefile" "$_render_path" 2>/dev/null)
                IFS=$'\x1f' read -r _source_title _source_artist _source_album _cm_date _cm_dur _cm_track _cm_disc <<< "$_current_meta"
                [[ -z "$_render_title" ]] && _render_title="$_source_title"
                [[ -z "$_render_artist" ]] && _render_artist="$_source_artist"
                [[ -z "$_render_album" ]] && _render_album="$_source_album"
            fi
            _nav_offset=0
            _jukebox_extract_art "$_render_path"
            _jukebox_cache_art
            _jukebox_last_next_file=""
            _jukebox_next_retries=0
            _jukebox_clear_next_meta
            _lyrics_loaded_path=""
            if (( _lyrics_mode )); then
                _jukebox_load_lyrics "$_render_path"
            else
                _lyrics_starts=(); _lyrics_lines=(); _lyrics_active_index=0
            fi
            _jukebox_save_state
            force_redraw=1
        fi

        if [[ "$_render_paused" != "$last_paused" ]]; then
            last_paused="$_render_paused"
        fi

        # 4b. Persist playback position (~every 2s) — the snapshot a
        # force-stop, reboot or OOM-kill leaves behind for the next launch.
        if (( _tick % 20 == 0 )); then
            _jukebox_save_state
        fi

        # 5. Handle next-track data (Coming Up Next — fetched OUTSIDE render)
        if [[ -n "$_p_next_file" && "$_p_next_file" != "$_jukebox_last_next_file" ]]; then
            _jukebox_last_next_file="$_p_next_file"
            _jukebox_log "next-track: fetching metadata for $_p_next_file (id=$_p_next_id)"
            _jukebox_fetch_next_meta "$_p_next_file" "$_p_next_id"
            force_redraw=1
        elif [[ -z "$_p_next_file" && -z "$_jukebox_last_next_file" ]]; then
            # Retry Coming Up Next (limited to prevent infinite redraw loop)
            if (( _jukebox_next_retries < 5 )); then
                if (( _render_pl_pos + 1 < _render_pl_count )); then
                    _jukebox_log "retry: Coming Up Next (attempt $_jukebox_next_retries, count=$_render_pl_count pos=$_render_pl_pos)"
                    force_redraw=1
                    _jukebox_next_retries=$((_jukebox_next_retries + 1))
                fi
            fi
        fi

        # 6. Synchronized lyrics redraw only when the active line changes.
        if (( _lyrics_mode && ${#_lyrics_lines[@]} > 0 )); then
            _lyrics_previous_index=$_lyrics_active_index
            _jukebox_update_lyric_index
            (( _lyrics_active_index != _lyrics_previous_index )) && force_redraw=1
        fi

        # 7. Render or partial update
        if (( force_redraw )); then
            _jukebox_render
            force_redraw=0
        else
            # Partial: update only progress bar (no IPC — data already fetched above)
            pos="${_render_time_pos}"
            dur="${_render_duration}"
            if [[ -n "$pos" && -n "$dur" && "$dur" != "0" ]]; then
                pos_i=${pos%.*} 
                dur_i=${dur%.*}
                pos_i=${pos_i:-0}
                dur_i=${dur_i:-0}
                pos_m=$((pos_i / 60)) 
                pos_s=$((pos_i % 60))
                dur_m=$((dur_i / 60)) 
                dur_s=$((dur_i % 60))
                time_str=$(printf "%02d:%02d / %02d:%02d" $pos_m $pos_s $dur_m $dur_s)

                icon="▶"
                [[ "$_render_paused" == "true" ]] && icon="⏸"

                label="$icon $time_str"
                bar_w=$((last_cols - ${#label} - 4))
                bar=""
                if (( bar_w > 10 && dur_i > 0 )); then
                    filled=$((pos_i * bar_w / dur_i))
                    (( filled > bar_w )) && filled=$bar_w
                    empty=$((bar_w - filled))
                    bar=" [$(printf '━%.0s' {1..$filled} 2>/dev/null)$(printf '─%.0s' {1..$empty} 2>/dev/null)]"
                fi

                # Draw ONLY the bottom line
                printf '\e[?7l\e7\e[%d;1H' "$last_rows"
                _jukebox_padline "$(_jukebox_center "${label}${bar}" $last_cols)" $last_cols
                printf '\e8\e[?7h'
            fi
        fi

        fi  # end of _tick % 5 == 0 || force_redraw

        # 8. Sleep for next tick
        sleep 0.05
    done
    _jukebox_cleanup
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║  🌙 Nightcore — FLAC Speed/Pitch Remixer                       ║
# ║  A zsh function that creates nightcore mixes from FLAC files.   ║
# ║                                                                 ║
# ║  Dependencies: sox, ffmpeg, fzf                                 ║
# ║                                                                 ║
# ║  Usage:                                                         ║
# ║    nightcore                  — interactive file picker          ║
# ║    nightcore <file.flac>      — nightcore a specific file        ║
# ║    nightcore --speed 1.3      — set speed multiplier             ║
# ║    nightcore --gain -2        — set gain adjustment (dB)         ║
# ║    nightcore --preview        — audition 15s snippet first       ║
# ║    nightcore --output <path>  — custom output path               ║
# ╚══════════════════════════════════════════════════════════════════╝
nightcore() {
    local _nc_speed=""
    local _nc_gain=""
    local _nc_input=""
    local _nc_output=""
    local _nc_preview=0
    local _nc_suffix="Nightcore Mix"
    local _nc_musicdir=""
    local _nc_script_dir="${_JUKEBOX_SCRIPT_DIR:-${0:A:h}}"

    # ── parse arguments ──────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --speed|-s)
                _nc_speed="$2"; shift 2 ;;
            --gain|-g)
                _nc_gain="$2"; shift 2 ;;
            --output|-o)
                _nc_output="$2"; shift 2 ;;
            --suffix)
                _nc_suffix="$2"; shift 2 ;;
            --preview|-p)
                _nc_preview=1; shift ;;
            --help|-h)
                cat <<'HELPEOF'
🌙 nightcore — Create nightcore mixes from FLAC files

Usage:
  nightcore [options] [file.flac]

Options:
  -s, --speed <float>     Speed multiplier (default: 1.25)
  -g, --gain  <float>     Gain adjustment in dB (default: -1)
  -o, --output <path>     Custom output file path
      --suffix <text>     Custom suffix (default: "Nightcore Mix")
  -p, --preview           Audition a 15s snippet before processing
  -h, --help              Show this help

Examples:
  nightcore                           # interactive picker
  nightcore track.flac                # quick nightcore with defaults
  nightcore -s 1.3 -g -2 track.flac  # custom speed & gain
  nightcore --preview track.flac      # preview before saving

Without arguments, opens an fzf picker to browse your music library.
HELPEOF
                return 0
                ;;
            -*)
                echo "❌ Unknown option: $1 (try nightcore --help)"
                return 1
                ;;
            *)
                _nc_input="$1"; shift ;;
        esac
    done

    # ── dependency check ─────────────────────────────────────────
    local _nc_missing=()
    command -v sox   &>/dev/null || _nc_missing+=(sox)
    command -v ffmpeg &>/dev/null || _nc_missing+=(ffmpeg)
    command -v ffprobe &>/dev/null || _nc_missing+=(ffprobe)
    if [[ ${#_nc_missing[@]} -gt 0 ]]; then
        echo "❌ Missing dependencies: ${_nc_missing[*]}"
        echo "   Install with: sudo pacman -S ${_nc_missing[*]}"
        return 1
    fi

    # Big intermediate FLACs (sox/ffmpeg work files) go to disk-backed
    # storage, not /tmp tmpfs — a hi-res source can balloon to 3× during
    # the sox→tag→cover passes. Honors $TMPDIR if set; falls back to /tmp.
    local _nc_tmpdir="${TMPDIR:-/var/tmp}"
    [[ -d "$_nc_tmpdir" && -w "$_nc_tmpdir" ]] || _nc_tmpdir=/tmp

    # ── file picker (if no input file given) ─────────────────────
    if [[ -z "$_nc_input" ]]; then
        _jukebox_configure_music_dir || return 1
        _nc_musicdir="$JUKEBOX_MUSIC_DIR"
        command -v fzf &>/dev/null || { echo "❌ fzf is required for the interactive picker"; return 1; }

        local _nc_cachefile="${JUKEBOX_DATA_DIR:-$HOME/.jukebox-app}/metadata.tsv"
        local _nc_preview_cmd="'${_nc_script_dir}/_fzf_preview.py' {1}"

        local _nc_input_list=""
        if [[ -s "$_nc_cachefile" ]]; then
            _nc_input_list=$(sort -t$'\t' -k2 -f "$_nc_cachefile" | awk -F'\t' '{ printf "%s\t%s - %s\n", $1, $2, $3 }')
        else
            # Fallback: scan directory directly
            local _nc_files=("$_nc_musicdir"/**/*.flac(N.on))
            if [[ ${#_nc_files[@]} -eq 0 ]]; then
                echo "❌ No FLAC files found in $_nc_musicdir"
                return 1
            fi
            for f in "${_nc_files[@]}"; do
                _nc_input_list+="${f}"$'\t'"${f##*/}"$'\n'
            done
        fi

        if [[ -z "$_nc_input_list" ]]; then
            echo "❌ No FLAC files found in $_nc_musicdir"
            return 1
        fi

        local _nc_selected
        _nc_selected=$(echo "$_nc_input_list" | \
            fzf -i --delimiter=$'\t' --with-nth=2 \
                --prompt="🌙 Pick a track to nightcore: " \
                --header="ENTER=select  ESC=cancel" \
                --preview "$_nc_preview_cmd" \
                --preview-window=right:50%)
        [[ -z "$_nc_selected" ]] && return 0
        _nc_input=$(echo "$_nc_selected" | cut -f1)
    fi

    # ── validate input ───────────────────────────────────────────
    if [[ ! -f "$_nc_input" ]]; then
        echo "❌ File not found: $_nc_input"
        return 1
    fi

    # ── interactive settings ─────────────────────────────────────
    echo ""
    echo "╔════════════════════════════════════════════════════╗"
    echo "║  🌙 Nightcore Mix Studio                          ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo ""
    local _nc_basename="${_nc_input##*/}"
    local _nc_name="${_nc_basename%.flac}"
    _nc_name="${_nc_name%.FLAC}"
    echo "  📄 Input:  $_nc_name"
    echo ""

    # Speed
    if [[ -z "$_nc_speed" ]]; then
        local _nc_speed_input
        read "_nc_speed_input?  ⚡ Speed multiplier [1.25]: "
        _nc_speed="${_nc_speed_input:-1.25}"
    fi

    # Validate speed is a number
    if ! [[ "$_nc_speed" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "❌ Invalid speed: $_nc_speed (must be a positive number)"
        return 1
    fi

    # Gain
    if [[ -z "$_nc_gain" ]]; then
        local _nc_gain_input
        read "_nc_gain_input?  🔊 Gain adjustment dB [-1]: "
        _nc_gain="${_nc_gain_input:--1}"
    fi

    # Validate gain is a number (can be negative)
    if ! [[ "$_nc_gain" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        echo "❌ Invalid gain: $_nc_gain (must be a number)"
        return 1
    fi

    echo ""
    echo "  ─────────────────────────────────────────────"
    echo "  ⚡ Speed:  ${_nc_speed}x"
    echo "  🔊 Gain:   ${_nc_gain} dB"
    echo "  ─────────────────────────────────────────────"

    # ── generate output filename ─────────────────────────────────
    if [[ -z "$_nc_output" ]]; then
        local _nc_dir="${_nc_input:h}"
        # Strip any existing nightcore suffix to avoid double-tagging
        # Catches: (Nightcore Mix), (Nightcore Mix 2), (1.25x Nightcore Mix), etc.
        local _nc_clean_name="$_nc_name"
        _nc_clean_name="${_nc_clean_name% \(*Nightcore*\)}"

        # Embed the speed in the suffix so different speeds coexist naturally
        # e.g. "Song (1.25x Nightcore Mix).flac" vs "Song (1.30x Nightcore Mix).flac"
        _nc_suffix="${_nc_speed}x ${_nc_suffix}"

        local _nc_base_output="${_nc_dir}/${_nc_clean_name} (${_nc_suffix}).flac"

        # Counter only needed if the exact same speed was used before
        if [[ -f "$_nc_base_output" ]]; then
            local _nc_counter=2
            while [[ -f "${_nc_dir}/${_nc_clean_name} (${_nc_suffix} ${_nc_counter}).flac" ]]; do
                ((_nc_counter++))
            done
            _nc_suffix="${_nc_suffix} ${_nc_counter}"
            _nc_output="${_nc_dir}/${_nc_clean_name} (${_nc_suffix}).flac"
        else
            _nc_output="$_nc_base_output"
        fi
    fi

    echo "  📁 Output: ${_nc_output##*/}"
    echo ""

    # ── preview mode: play a 15s snippet ─────────────────────────
    if (( _nc_preview )); then
        echo "  🎧 Playing 15s preview... (Ctrl+C to stop)"
        sox "$_nc_input" -d trim 30 15 speed "$_nc_speed" gain "$_nc_gain" 2>/dev/null
        echo ""
        local _nc_proceed
        read "_nc_proceed?  Continue with full conversion? [Y/n]: "
        [[ "$_nc_proceed" == [nN]* ]] && { echo "  Cancelled."; return 0; }
    fi

    # ── process with sox ─────────────────────────────────────────
    local _nc_tmpout=$(mktemp "$_nc_tmpdir/nightcore-XXXXXX.flac")

    echo "  ⏳ Processing..."
    local _nc_start=$SECONDS

    if ! sox "$_nc_input" "$_nc_tmpout" speed "$_nc_speed" gain "$_nc_gain" 2>/dev/null; then
        echo "  ❌ sox failed!"
        command rm -f "$_nc_tmpout"
        return 1
    fi

    # ── copy metadata tags from original ─────────────────────────
    # sox doesn't preserve FLAC tags, so we use ffmpeg to mux them back
    local _nc_tmptagged=$(mktemp "$_nc_tmpdir/nightcore-tagged-XXXXXX.flac")

    # Extract cover art from the original (if present)
    local _nc_coverart=$(mktemp "$_nc_tmpdir/nightcore-cover-XXXXXX.jpg")
    ffmpeg -y -v quiet -i "$_nc_input" -an -vcodec mjpeg -frames:v 1 "$_nc_coverart" 2>/dev/null
    local _nc_has_cover=0
    [[ -s "$_nc_coverart" ]] && _nc_has_cover=1

    # Re-mux: take audio from sox output, tags + cover from original
    if (( _nc_has_cover )); then
        ffmpeg -y -v quiet \
            -i "$_nc_tmpout" \
            -i "$_nc_coverart" \
            -map 0:a -map 1:0 \
            -c:a copy \
            -c:v mjpeg \
            -disposition:v attached_pic \
            -metadata:s:v title="Album cover" \
            -metadata:s:v comment="Cover (front)" \
            "$_nc_tmptagged" 2>/dev/null
    else
        cp "$_nc_tmpout" "$_nc_tmptagged"
    fi

    # Copy over the original metadata tags using ffprobe + ffmpeg
    local _nc_tag_args=()
    local _nc_tags
    _nc_tags=$(ffprobe -v quiet -show_entries format_tags -of json "$_nc_input" 2>/dev/null)
    if [[ -n "$_nc_tags" ]]; then
        # Parse tags and build ffmpeg metadata arguments
        local _nc_parsed_tags
        _nc_parsed_tags=$(echo "$_nc_tags" | python3 -c '
import json, sys, re
try:
    suffix = sys.argv[1]
    name_fallback = sys.argv[2]
    d = json.load(sys.stdin)
    tags = d.get("format", {}).get("tags", {})
    found_title = False
    for k, v in tags.items():
        val = v
        if k.lower() == "title":
            found_title = True
            # Strip any existing nightcore suffix (handles all variants)
            clean_v = re.sub(r"\s*\([^)]*Nightcore[^)]*\)\s*$", "", v).strip()
            val = f"{clean_v} ({suffix})"
        
        # Escape for shell
        val_clean = val.replace("\\", "\\\\").replace("\"", "\\\"")
        print(f"-metadata\n{k}={val_clean}")
    
    if not found_title:
        # If no title tag existed, use the filename
        print(f"-metadata\ntitle={name_fallback} ({suffix})")
except: pass
' "$_nc_suffix" "$_nc_name" 2>/dev/null)
        if [[ -n "$_nc_parsed_tags" ]]; then
            _nc_tag_args=(${(f)_nc_parsed_tags})
        fi
    fi

    # Final pass: apply original tags to the output
    if [[ ${#_nc_tag_args[@]} -gt 0 ]]; then
        local _nc_tmpfinal=$(mktemp "$_nc_tmpdir/nightcore-final-XXXXXX.flac")
        ffmpeg -y -v quiet \
            -i "$_nc_tmptagged" \
            -c copy \
            "${_nc_tag_args[@]}" \
            "$_nc_tmpfinal" 2>/dev/null
        if [[ -s "$_nc_tmpfinal" ]]; then
            mv "$_nc_tmpfinal" "$_nc_tmptagged"
        else
            command rm -f "$_nc_tmpfinal"
        fi
    fi

    # Move to final destination
    mv "$_nc_tmptagged" "$_nc_output"

    # Cleanup temp files
    command rm -f "$_nc_tmpout" "$_nc_coverart"

    local _nc_elapsed=$(( SECONDS - _nc_start ))
    echo ""
    echo "  ✅ Done in ${_nc_elapsed}s!"
    echo ""

    # Show file sizes
    local _nc_orig_size=$(stat --printf="%s" "$_nc_input" 2>/dev/null)
    local _nc_out_size=$(stat --printf="%s" "$_nc_output" 2>/dev/null)
    if [[ -n "$_nc_orig_size" && -n "$_nc_out_size" ]]; then
        local _nc_orig_mb=$(printf "%.1f" $(( _nc_orig_size / 1048576.0 )))
        local _nc_out_mb=$(printf "%.1f" $(( _nc_out_size / 1048576.0 )))
        echo "  📊 ${_nc_orig_mb} MB → ${_nc_out_mb} MB"
    fi

    # Show duration comparison
    local _nc_orig_dur=$(ffprobe -v quiet -show_entries format=duration -of default=nw=1:nk=1 "$_nc_input" 2>/dev/null)
    local _nc_out_dur=$(ffprobe -v quiet -show_entries format=duration -of default=nw=1:nk=1 "$_nc_output" 2>/dev/null)
    if [[ -n "$_nc_orig_dur" && -n "$_nc_out_dur" ]]; then
        local _nc_orig_dur_i=${_nc_orig_dur%.*}
        local _nc_out_dur_i=${_nc_out_dur%.*}
        printf "  ⏱️  %d:%02d → %d:%02d\n" \
            $((_nc_orig_dur_i / 60)) $((_nc_orig_dur_i % 60)) \
            $((_nc_out_dur_i / 60)) $((_nc_out_dur_i % 60))
    fi

    echo ""
    echo "  🎵 ${_nc_output##*/}"
    echo ""
}
