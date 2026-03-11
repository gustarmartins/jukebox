#!/usr/bin/env zsh
# ╔══════════════════════════════════════════════════════════════════╗
# ║  🎵 Jukebox — Terminal FLAC Player                             ║
# ║  A zsh function that plays FLAC files with album art,          ║
# ║  queue building, fzf browsing, and interactive controls.       ║
# ║                                                                ║
# ║  Dependencies: mpv, fzf, chafa, ffmpeg, socat, jq              ║
# ║                                                                ║
# ║  Setup: Add this line to your ~/.zshrc:                        ║
# ║    source ~/Jukebox/jukebox/jukebox.zsh                        ║
# ║                                                                ║
# ║  Configuration (optional, add before the source line):         ║
# ║    export JUKEBOX_MUSIC_DIR="$HOME/Music"                      ║
# ║                                                                ║
# ║  Usage: run `jukebox` in your terminal.                        ║
# ╚══════════════════════════════════════════════════════════════════╝

: ${JUKEBOX_MUSIC_DIR:="$HOME/Music"}

# --- fzf preview script (metadata + album art) ---
_jukebox_fzf_preview='
    tmpcover="$_JUKEBOX_PREVTMP"
    title=$(ffprobe -v quiet -show_entries format_tags=title -of default=nw=1:nk=1 -- "{1}" 2>/dev/null)
    artist=$(ffprobe -v quiet -show_entries format_tags=artist -of default=nw=1:nk=1 -- "{1}" 2>/dev/null)
    album=$(ffprobe -v quiet -show_entries format_tags=album -of default=nw=1:nk=1 -- "{1}" 2>/dev/null)
    duration=$(ffprobe -v quiet -show_entries format=duration -of default=nw=1:nk=1 -- "{1}" 2>/dev/null)
    if [[ -n "$duration" ]]; then
        dur_int=${duration%.*}
        mins=$((dur_int / 60))
        secs=$((dur_int % 60))
        dur_fmt=$(printf "%d:%02d" "$mins" "$secs")
    fi
    fname="{1}"; fname=${fname##*/}; fname=${fname%.flac}
    echo "🎵 ${title:-$fname}"
    [[ -n "$artist" ]] && echo "🎤 $artist"
    [[ -n "$album" ]]  && echo "💿 $album"
    [[ -n "$dur_fmt" ]] && echo "⏱  $dur_fmt"
    echo ""
    if ffmpeg -y -v quiet -i "{1}" -an -vcodec mjpeg -frames:v 1 "$tmpcover" 2>/dev/null && [[ -s "$tmpcover" ]]; then
        chafa --size 40x20 "$tmpcover" 2>/dev/null
    fi
'

# --- main function ---
jukebox() {
    local _jukebox_debug=0
    local _jukebox_debuglog="/tmp/jukebox-debug.log"
    local _jukebox_show_formatnames=1

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

    local playlist=$(mktemp /tmp/jukebox-XXXXXX.m3u)
    local mpvsock=$(mktemp -u "${XDG_RUNTIME_DIR:-/tmp}/jukebox-mpv-XXXXXX.sock")
    local coverfile=$(mktemp /tmp/jukebox-cover-XXXXXX.jpg)
    local coverfile_next=$(mktemp /tmp/jukebox-cover-next-XXXXXX.jpg)
    local _jukebox_prevtmp="/tmp/jukebox-fzf-preview-$$.jpg"
    local queuefile="/tmp/jukebox-queue-$$.txt"
    local cachefile="/tmp/jukebox-meta-$$.tsv"
    export _JUKEBOX_PREVTMP="$_jukebox_prevtmp"
    export _JUKEBOX_CACHE="$cachefile"
    export _JUKEBOX_SHOW_FORMATNAMES="$_jukebox_show_formatnames"
    local _jukebox_cleaned=""
    local _jukebox_art_text=""
    local saved_stty=$(stty -g 2>/dev/null)

    # --- build metadata cache in background for sorting ---
    "$_JUKEBOX_PYTHON" -c "
import subprocess, json, os, sys
musicdir = sys.argv[1]
out = open(sys.argv[2], 'w')
for root, dirs, files in os.walk(musicdir):
    for f in sorted(files):
        if not f.lower().endswith('.flac'): continue
        fp = os.path.join(root, f)
        try:
            r = subprocess.run(['ffprobe','-v','quiet','-print_format','json','-show_format',fp],
                               capture_output=True, text=True, timeout=10)
            d = json.loads(r.stdout)
            tags = d.get('format',{}).get('tags',{})
            get = lambda k: tags.get(k, tags.get(k.upper(), ''))
            title = get('title') or f.replace('.flac','')
            artist = get('artist') or 'Unknown'
            album = get('album') or 'Unknown'
            date = get('date') or '0'
            dur = d.get('format',{}).get('duration','0')
            out.write(f'{fp}\t{title}\t{artist}\t{album}\t{date}\t{dur}\n')
        except: pass
out.close()
" "${JUKEBOX_MUSIC_DIR:-$HOME/Music}" "$cachefile" &
    local _cache_pid=$!

    _jukebox_setup_fzf_sort() {
        if [[ -n "$_cache_pid" ]] && kill -0 "$_cache_pid" 2>/dev/null; then
            echo "⏳ Building music library metadata cache..."
            wait "$_cache_pid" 2>/dev/null
        fi

        _fzf_sort_dir=$(mktemp -d /tmp/jukebox-sort-XXXXXX)
        _gen_sort() {
            cat > "$_fzf_sort_dir/$2.sh" << SORTEOF
#!/usr/bin/env bash
if (( \$_JUKEBOX_SHOW_FORMATNAMES )); then
    $1 "\$_JUKEBOX_CACHE" | awk -F'\\t' '{ printf "%s\\t%s - %s\\n", \$1, \$2, \$3 }'
else
    $1 "\$_JUKEBOX_CACHE" | awk -F'\\t' '{ printf "%s\\t%s\\n", \$1, \$1 }'
fi
SORTEOF
        }

        _gen_sort "sort -t$'\t' -k2 -f" "by_title"
        _gen_sort "sort -t$'\t' -k2 -fr" "by_title_rev"
        _gen_sort "sort -t$'\t' -k3,3 -f -k2,2 -f" "by_artist"
        _gen_sort "sort -t$'\t' -k3,3 -fr -k2,2 -f" "by_artist_rev"
        _gen_sort "sort -t$'\t' -k4,4 -f -k2,2 -f" "by_album"
        _gen_sort "sort -t$'\t' -k4,4 -fr -k2,2 -f" "by_album_rev"
        _gen_sort "sort -t$'\t' -k5 -rn" "by_date"
        _gen_sort "sort -t$'\t' -k5 -n" "by_date_rev"
        _gen_sort "sort -t$'\t' -k6 -n" "by_length"
        _gen_sort "sort -t$'\t' -k6 -nr" "by_length_rev"
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

    local choice files=() start_idx=0
    local musicdir="${JUKEBOX_MUSIC_DIR:-$HOME/Music}"

    echo "🎵 Jukebox - Select playback mode:"
    echo "  1) Play all (original order)"
    echo "  2) Sort by filename (A-Z)"
    echo "  3) Sort by filename (Z-A)"
    echo "  4) Sort by date (oldest first)"
    echo "  5) Sort by date (newest first)"
    echo "  6) Browse & pick (plays from selection onward)"
    echo "  7) Shuffle"
    echo "  8) Build queue (TAB to pick, ENTER to play)"
    echo "  q) Quit"
    echo ""
    read "choice?Choose [1-8, q]: "

    case "$choice" in
        1) files=("$musicdir"/**/*.flac(N.)) ;;
        2) files=("$musicdir"/**/*.flac(N.on)) ;;
        3) files=("$musicdir"/**/*.flac(N.On)) ;;
        4) files=("$musicdir"/**/*.flac(N.Om)) ;;
        5) files=("$musicdir"/**/*.flac(N.om)) ;;
        6)
            local all_files=("$musicdir"/**/*.flac(N.on))
            if [[ ${#all_files[@]} -eq 0 ]]; then
                echo "No FLAC files found in $musicdir"
                return 1
            fi
            
            _jukebox_setup_fzf_sort
            
            local fzf_header="TAB=toggle  ENTER=play/queue  ESC=cancel"
            if [[ -s "$cachefile" ]]; then
                fzf_header="$fzf_header
─── Sort: Alt-T/A/B/D/L (asc) | Shift+Alt-T/A/B/D/L (desc) ───"
            fi

            local input_list
            input_list=$(_jukebox_get_input_list "${all_files[@]}")

            local selected
            selected=$(echo "$input_list" | \
                fzf --multi \
                    --delimiter=$'\t' --with-nth=2 \
                    --prompt="Pick start song(s): " \
                    --header="$fzf_header" \
                    --marker="✔ " \
                    --preview "$_jukebox_fzf_preview" \
                    --preview-window=right:50% \
                    "${_fzf_binds[@]}")
                    
            rm -rf "$_fzf_sort_dir"
            [[ -z "$selected" ]] && return
            
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
                for ((i=last_idx+1; i<=${#all_files[@]}; i++)); do
                    local f="${all_files[$i]}"
                    if [[ -z "${seen[$f]}" ]]; then
                        files+=("$f")
                    fi
                done
            fi
            start_idx=0
            ;;
        7)
            local -a _tmp=("$musicdir"/**/*.flac(N.))
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
            local all_files=("$musicdir"/**/*.flac(N.on))
            if [[ ${#all_files[@]} -eq 0 ]]; then
                echo "No FLAC files found in $musicdir"
                return 1
            fi
            
            _jukebox_setup_fzf_sort
            
            local fzf_header="TAB=toggle  Ctrl-A=all  Ctrl-D=none  ENTER=play"
            if [[ -s "$cachefile" ]]; then
                fzf_header="$fzf_header
─── Sort: Alt-T/A/B/D/L (asc) | Shift+Alt-T/A/B/D/L (desc) ───"
            fi
            
            local input_list
            input_list=$(_jukebox_get_input_list "${all_files[@]}")

            local selected
            selected=$(echo "$input_list" | \
                fzf --multi \
                    --delimiter=$'\t' --with-nth=2 \
                    --prompt="Queue: " \
                    --header="$fzf_header" \
                    --marker="✔ " \
                    --preview "$_jukebox_fzf_preview" \
                    --preview-window=right:50% \
                    --bind 'ctrl-a:select-all,ctrl-d:deselect-all' \
                    "${_fzf_binds[@]}")
                    
            rm -rf "$_fzf_sort_dir"
            [[ -z "$selected" ]] && return
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
        q|Q) return ;;
        *) echo "Invalid choice"; return 1 ;;
    esac

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No FLAC files found in $musicdir"
        return 1
    fi



    : > "$queuefile"  # create empty tracker for manually queued songs

    printf '%s\n' "${files[@]}" > "$playlist"

    # cleanup handler (idempotent — safe to call multiple times)
    _jukebox_cleanup() {
        [[ -n "$_jukebox_cleaned" ]] && return
        _jukebox_cleaned=1
        _jukebox_log "cleanup: starting"
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
        rm -f "$playlist" "$mpvsock" "$coverfile" "$coverfile_next" "$_jukebox_prevtmp" "$queuefile" "$cachefile"
        rm -rf "$_fzf_sort_dir"
        unfunction _jukebox_render _jukebox_render_next_panel _jukebox_ipc \
                   _jukebox_set _jukebox_batch_get _jukebox_extract_art _jukebox_cache_art \
                   _jukebox_cache_next_art _jukebox_calc_layout \
                   _jukebox_center _jukebox_padline _jukebox_fast_get \
                   _jukebox_fetch_next_meta _jukebox_clear_next_meta \
                   _jukebox_add_next _jukebox_queue_picker _jukebox_log _jukebox_cleanup _jukebox_setup_fzf_sort 2>/dev/null
    }
    setopt localoptions localtraps
    trap _jukebox_cleanup INT TERM EXIT

    # start mpv in background with IPC socket, fully headless
    _jukebox_log "mpv: starting with playlist=$playlist sock=$mpvsock start_idx=$start_idx"
    mpv --no-video --no-terminal \
        --audio-format=s32 \
        --audio-samplerate=0 \
        --playlist="$playlist" \
        --playlist-start="$start_idx" \
        --input-ipc-server="$mpvsock" &
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

    # --- IPC helper using python for reliable Unix socket communication ---
    _jukebox_ipc() {
        "$_JUKEBOX_PYTHON" -c '
import socket, json, sys, random
try:
    sock_path = sys.argv[2]
    rid = random.randint(1, 999999)
    cmd = json.loads(sys.argv[1])
    cmd["request_id"] = rid
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sock_path)
    s.sendall((json.dumps(cmd) + "\n").encode())
    buf = b""
    while True:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            obj = json.loads(line)
            if obj.get("request_id") == rid:
                s.close()
                print(json.dumps(obj))
                sys.exit(0)
    s.close()
except Exception: pass
' "$1" "$mpvsock" 2>/dev/null
    }

    _jukebox_set() {
        _jukebox_ipc "$1" > /dev/null
    }

    # --- batch property getter: single Python process, single socket connection ---
    # Usage: _jukebox_batch_get prop1 prop2 ...
    # Output: tab-separated values for each property
    _jukebox_batch_get() {
        _jukebox_log "_jukebox_batch_get called with args: $*"
        "$_JUKEBOX_PYTHON" -c '
import socket, json, sys
try:
    sock_path = sys.argv[1]
    props = sys.argv[2:]
    if not props:
        sys.exit(0)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sock_path)
    # Send all requests with unique request_ids
    for i, prop in enumerate(props):
        cmd = {"command": ["get_property", prop], "request_id": i + 1}
        s.sendall((json.dumps(cmd) + "\n").encode())
    # Collect all responses
    results = {}
    buf = b""
    needed = set(range(1, len(props) + 1))
    while needed:
        c = s.recv(4096)
        if not c:
            break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                obj = json.loads(line)
                rid = obj.get("request_id")
                if rid in needed:
                    val = obj.get("data")
                    if val is None:
                        results[rid] = ""
                    elif isinstance(val, bool):
                        results[rid] = "true" if val else "false"
                    else:
                        results[rid] = str(val)
                    needed.discard(rid)
            except:
                pass
    s.close()
    # Output Unit Separator (\x1f) delimited values in request order
    out = []
    for i in range(len(props)):
        out.append(results.get(i + 1, ""))
    print("\x1f".join(out))
except Exception as e:
    # Output empty separators so the caller gets the right number of fields
    print("\x1f".join(["" for _ in sys.argv[2:]]))
    print(f"Exception: {e}", file=sys.stderr)
' "$mpvsock" "$@" 2>>/tmp/jukebox-py.log
    }

    # --- extract cover art ---
    _jukebox_extract_art() {
        local filepath="$1"
        ffmpeg -y -v quiet -i "$filepath" -an -vcodec mjpeg -frames:v 1 "$coverfile" 2>/dev/null
    }

    # --- cache chafa output for current cover ---
    # --- layout engine: computes all dimensions from terminal size ---
    # Sets: _layout_mode (normal|compact|minimal)
    #       _layout_header_rows, _layout_art_start_row
    #       _layout_art_w, _layout_art_h
    #       _layout_next_mode (side|below|hidden)
    #       _layout_next_art_w, _layout_next_art_h
    #       _layout_next_x, _layout_next_y (for side mode)
    #       _layout_content_bottom (last row available before progress bar)
    _jukebox_calc_layout() {
        local cols=$(tput cols) rows=$(tput lines)
        _layout_cols=$cols
        _layout_rows=$rows

        # --- Header mode based on available rows ---
        if (( rows <= 10 )); then
            _layout_mode="minimal"    # bare essentials only
            _layout_header_rows=1     # song info only
        elif (( rows <= 20 )); then
            _layout_mode="compact"    # condensed controls
            _layout_header_rows=3     # controls + info + track
        else
            _layout_mode="normal"     # full header
            _layout_header_rows=5     # controls1 + controls2 + info + album + track
        fi

        # Progress bar always takes 1 row at the bottom
        _layout_content_bottom=$(( rows - 1 ))

        # Art starts 1 row after header (gap row)
        _layout_art_start_row=$(( _layout_header_rows + 2 ))

        # Available space for content between header and progress bar
        local avail_rows=$(( _layout_content_bottom - _layout_art_start_row ))
        (( avail_rows < 0 )) && avail_rows=0

        # --- Determine layout strategy FIRST, then size art to fit ---
        # Strategy: if terminal is wide enough, do side-by-side and give art ~60% of width.
        # Otherwise, art gets full width and "Up Next" goes below or is hidden.

        local min_panel_w=30   # minimum width for Up Next panel

        if (( cols >= 66 && avail_rows >= 8 )); then
            # --- SIDE-BY-SIDE layout ---
            _layout_next_mode="side"

            # Art gets ~60% of width, panel gets the rest
            _layout_art_w=$(( (cols - 6) * 60 / 100 ))
            (( _layout_art_w < 20 )) && _layout_art_w=20
            # Ensure panel has at least min_panel_w
            local panel_w=$(( cols - _layout_art_w - 6 ))
            if (( panel_w < min_panel_w )); then
                _layout_art_w=$(( cols - min_panel_w - 6 ))
                (( _layout_art_w < 20 )) && _layout_art_w=20
                panel_w=$(( cols - _layout_art_w - 6 ))
            fi

            # Art height from width (2:1 ratio), capped to available rows
            _layout_art_h=$(( _layout_art_w / 2 ))
            (( _layout_art_h > avail_rows )) && _layout_art_h=$avail_rows
            (( _layout_art_h < 4 )) && _layout_art_h=4

            _layout_next_x=$(( _layout_art_w + 6 ))
            _layout_next_y=$_layout_art_start_row

            # Next art: 20x10 fixed target, scaled down if needed
            _layout_next_art_w=20
            (( _layout_next_art_w > panel_w - 2 )) && _layout_next_art_w=$((panel_w - 2))
            (( _layout_next_art_w < 8 )) && _layout_next_art_w=8
            _layout_next_art_h=$(( _layout_next_art_w / 2 ))
            local max_next_art_h=$(( avail_rows - 8 ))
            (( max_next_art_h < 3 )) && max_next_art_h=3
            (( _layout_next_art_h > max_next_art_h )) && _layout_next_art_h=$max_next_art_h
            (( _layout_next_art_h < 3 )) && _layout_next_art_h=3

        else
            # --- NO SIDE PANEL: art gets full width ---
            _layout_art_w=$(( cols - 2 ))
            (( _layout_art_w < 4 )) && _layout_art_w=4
            _layout_art_h=$(( _layout_art_w / 2 ))
            (( _layout_art_h > avail_rows )) && _layout_art_h=$avail_rows
            (( _layout_art_h < 4 )) && _layout_art_h=4

            local below_space=$(( _layout_content_bottom - _layout_art_start_row - _layout_art_h ))
            if (( below_space >= 5 && cols >= 30 )); then
                # Stacked: show "Up Next" below the main art
                _layout_next_mode="below"
                _layout_next_x=3
                _layout_next_y=$(( _layout_art_start_row + _layout_art_h + 1 ))

                _layout_next_art_w=$(( cols / 4 ))
                (( _layout_next_art_w > 20 )) && _layout_next_art_w=20
                (( _layout_next_art_w < 8 )) && _layout_next_art_w=8
                _layout_next_art_h=$(( _layout_next_art_w / 2 ))
                local max_below_art_h=$(( below_space - 3 ))
                (( max_below_art_h < 2 )) && max_below_art_h=2
                (( _layout_next_art_h > max_below_art_h )) && _layout_next_art_h=$max_below_art_h
                (( _layout_next_art_h < 2 )) && _layout_next_art_h=2
            else
                _layout_next_mode="hidden"
                _layout_next_art_w=0
                _layout_next_art_h=0
            fi
        fi
    }

    # --- cache chafa output for current cover using layout dimensions ---
    _jukebox_cache_art() {
        _jukebox_calc_layout
        if [[ -s "$coverfile" ]]; then
            _jukebox_art_text=$(chafa --size "${_layout_art_w}x${_layout_art_h}" "$coverfile" 2>/dev/null)
        else
            _jukebox_art_text=""
        fi
        _jukebox_art_w=$_layout_art_w
    }

    # --- cache chafa output for "Up Next" cover using layout dimensions ---
    _jukebox_cache_next_art() {
        if [[ "$_layout_next_mode" == "hidden" ]] || (( _layout_next_art_w < 4 || _layout_next_art_h < 2 )); then
            _jukebox_next_art_text=""
            return
        fi
        if [[ -s "$coverfile_next" ]]; then
            _jukebox_next_art_text=$(chafa --size "${_layout_next_art_w}x${_layout_next_art_h}" "$coverfile_next" 2>/dev/null)
        else
            _jukebox_next_art_text=""
        fi
    }

    # center helper
    _jukebox_center() {
        local text="$1" w="$2"
        local len=${#text}
        if (( len >= w )); then
            printf '%s' "${text[1,$w]}"
        else
            local pad=$(( (w - len) / 2 ))
            printf '%*s%s' $pad '' "$text"
        fi
    }

    # pad line to full width (clears leftover chars)
    _jukebox_padline() {
        local text="$1" w="$2"
        local len=${#text}
        if (( len >= w )); then
            printf '%s' "${text[1,$w]}"
        else
            printf '%s%*s' "$text" $((w - len)) ''
        fi
    }

    # query an individual property fast using python batch fetcher wrapper
    _jukebox_fast_get() {
        _jukebox_batch_get "$1"
    }

    # --- fetch metadata for the next track (called from main loop, NOT render) ---
    _jukebox_fetch_next_meta() {
        local next_file="$1"
        local next_item_id="$2"

        rm -f "$coverfile_next" 2>/dev/null
        ffmpeg -y -v quiet -i "$next_file" -an -vcodec mjpeg -frames:v 1 "$coverfile_next" 2>/dev/null
        _jukebox_cache_next_art

        _jukebox_next_title=$(ffprobe -v quiet -show_entries format_tags=title -of default=nw=1:nk=1 -- "$next_file" 2>/dev/null)
        [[ -z "$_jukebox_next_title" ]] && _jukebox_next_title="${next_file##*/}" && _jukebox_next_title="${_jukebox_next_title%.flac}"
        _jukebox_next_artist=$(ffprobe -v quiet -show_entries format_tags=artist -of default=nw=1:nk=1 -- "$next_file" 2>/dev/null)
        _jukebox_next_album=$(ffprobe -v quiet -show_entries format_tags=album -of default=nw=1:nk=1 -- "$next_file" 2>/dev/null)

        local _ndur=$(ffprobe -v quiet -show_entries format=duration -of default=nw=1:nk=1 -- "$next_file" 2>/dev/null)
        if [[ -n "$_ndur" ]]; then
            local _ndur_i=${_ndur%.*}
            _jukebox_next_dur=$(printf "%02d:%02d" $((_ndur_i / 60)) $((_ndur_i % 60)))
        else
            _jukebox_next_dur=""
        fi

        # Audio quality metadata (sample rate, bit depth, channels)
        local _nstream=$(ffprobe -v quiet -select_streams a:0 \
            -show_entries stream=sample_rate,bits_per_sample,channels \
            -of csv=p=0 -- "$next_file" 2>/dev/null)
        if [[ -n "$_nstream" ]]; then
            local _nsample_rate=${_nstream%%,*}
            local _nrest=${_nstream#*,}
            local _nbits=${_nrest%%,*}
            local _nchannels=${_nrest#*,}
            _nchannels=${_nchannels%$'\n'}

            _jukebox_next_quality="FLAC"
            if [[ -n "$_nsample_rate" && "$_nsample_rate" != "N/A" ]]; then
                if (( _nsample_rate % 1000 == 0 )); then
                    _jukebox_next_quality="$_jukebox_next_quality · $((_nsample_rate / 1000)) kHz"
                else
                    _jukebox_next_quality="$_jukebox_next_quality · $(awk "BEGIN{printf \"%.1f\", $_nsample_rate/1000}") kHz"
                fi
            fi
            if [[ -n "$_nbits" && "$_nbits" != "0" && "$_nbits" != "N/A" ]]; then
                _jukebox_next_quality="$_jukebox_next_quality / ${_nbits}-bit"
            fi
            if [[ -n "$_nchannels" && "$_nchannels" != "N/A" ]]; then
                case "$_nchannels" in
                    1) _jukebox_next_quality="$_jukebox_next_quality · Mono" ;;
                    2) _jukebox_next_quality="$_jukebox_next_quality · Stereo" ;;
                    *) _jukebox_next_quality="$_jukebox_next_quality · ${_nchannels}ch" ;;
                esac
            fi
        else
            _jukebox_next_quality=""
        fi

        # File size
        local _nsize=$(stat -c %s "$next_file" 2>/dev/null)
        if [[ -n "$_nsize" && "$_nsize" != "0" ]]; then
            if (( _nsize >= 1073741824 )); then
                _jukebox_next_size=$(awk "BEGIN{printf \"%.1f GB\", $_nsize/1073741824}")
            elif (( _nsize >= 1048576 )); then
                _jukebox_next_size=$(awk "BEGIN{printf \"%.1f MB\", $_nsize/1048576}")
            else
                _jukebox_next_size=$(awk "BEGIN{printf \"%.0f KB\", $_nsize/1024}")
            fi
        else
            _jukebox_next_size=""
        fi

        # Genre and date tags
        _jukebox_next_genre=$(ffprobe -v quiet -show_entries format_tags=genre -of default=nw=1:nk=1 -- "$next_file" 2>/dev/null)
        _jukebox_next_date=$(ffprobe -v quiet -show_entries format_tags=date -of default=nw=1:nk=1 -- "$next_file" 2>/dev/null)

        # Source detection (queued by user vs library auto-play)
        if [[ -n "$next_item_id" && -f "$queuefile" ]] && grep -qxF "$next_item_id" "$queuefile" 2>/dev/null; then
            _jukebox_next_source="queued"
        else
            _jukebox_next_source="library"
        fi
    }

    _jukebox_clear_next_meta() {
        _jukebox_next_art_text=""
        _jukebox_next_title=""
        _jukebox_next_artist=""
        _jukebox_next_album=""
        _jukebox_next_dur=""
        _jukebox_next_quality=""
        _jukebox_next_size=""
        _jukebox_next_genre=""
        _jukebox_next_date=""
        _jukebox_next_source=""
    }

    # --- render "Up Next" panel at given position (helper for _jukebox_render) ---
    # Args: $1=start_col, $2=start_row, $3=max_row (must not render past this), $4=max_col_width
    _jukebox_render_next_panel() {
        local nx=$1 ny=$2 max_y=$3 max_w=$4
        local q_y=$ny

        # Title label
        local _title_label="📚 Up Next"
        [[ "$_jukebox_next_source" == "queued" ]] && _title_label="📋 Queued Next"
        (( _nav_offset > 0 )) && _title_label="$_title_label (+$_nav_offset)"
        (( q_y > max_y )) && return
        printf '\e[%d;%dH\e[1m%s\e[0m' "$q_y" "$nx" "$_title_label"
        q_y=$((q_y + 2))

        if [[ -n "$_jukebox_last_next_file" ]]; then
            # Art — with Kitty graphics protocol, chafa may output only 1 text
            # line but the image visually spans _layout_next_art_h rows.
            # We must advance q_y by the VISUAL height, not the text line count.
            if [[ -n "$_jukebox_next_art_text" ]]; then
                local start_q_y=$q_y
                local art_lines=("${(@f)_jukebox_next_art_text}")
                for l in "${art_lines[@]}"; do
                    (( q_y > max_y )) && break
                    printf '\e[%d;%dH%s' "$q_y" "$nx" "$l"
                    q_y=$((q_y + 1))
                done
                # Ensure cursor advances past the visual image height
                local visual_end=$(( start_q_y + _layout_next_art_h ))
                (( q_y < visual_end )) && q_y=$visual_end
            fi

            q_y=$((q_y + 1))
            local max_len=$((max_w - 2))
            (( max_len < 10 )) && max_len=10

            # Metadata lines — each guarded by vertical bounds
            local _meta_lines=()
            _meta_lines+=("Title: ${_jukebox_next_title:-Unknown}")
            _meta_lines+=("Artist: ${_jukebox_next_artist:-Unknown}")
            local _t_album="Album: ${_jukebox_next_album:-None}"
            [[ -n "$_jukebox_next_date" ]] && _t_album="$_t_album (${_jukebox_next_date})"
            _meta_lines+=("$_t_album")
            [[ -n "$_jukebox_next_dur" ]] && _meta_lines+=("Length: $_jukebox_next_dur")
            [[ -n "$_jukebox_next_quality" ]] && _meta_lines+=("Quality: $_jukebox_next_quality")
            [[ -n "$_jukebox_next_size" ]] && _meta_lines+=("Size: $_jukebox_next_size")
            [[ -n "$_jukebox_next_genre" ]] && _meta_lines+=("Genre: $_jukebox_next_genre")

            for ml in "${_meta_lines[@]}"; do
                (( q_y > max_y )) && break
                (( ${#ml} > max_len )) && ml="${ml[1,$((max_len - 3))]}..."
                printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$nx" "$ml"
                q_y=$((q_y + 1))
            done
        else
            # Loading or end-of-playlist message
            (( q_y <= max_y )) && {
                local next_idx=$((_render_pl_pos + 1 + _nav_offset))
                if (( next_idx < _render_pl_count )); then
                    printf '\e[%d;%dH\e[2m⏳ Loading...\e[0m' "$q_y" "$nx"
                else
                    printf '\e[%d;%dH\e[2mEnd of playlist\e[0m' "$q_y" "$nx"
                fi
            }
        fi
    }

    # --- render screen (pure display — all data pre-fetched by main loop) ---
    _jukebox_render() {
        local cols=$_layout_cols rows=$_layout_rows

        [[ -z "$_render_path" ]] && return

        local title="${_render_title}"
        [[ -z "$title" ]] && title="${_render_path##*/}" && title="${title%.flac}"
        local artist="$_render_artist"
        local album="$_render_album"
        local pl_pos=${_render_pl_pos:-0}
        local pl_count=${_render_pl_count:-0}
        local pos=${_render_time_pos:-0}
        local dur=${_render_duration:-0}
        local paused="$_render_paused"

        local pos_i=${pos%.*} dur_i=${dur%.*}
        pos_i=${pos_i:-0}; dur_i=${dur_i:-0}
        local pos_m=$((pos_i / 60)) pos_s=$((pos_i % 60))
        local dur_m=$((dur_i / 60)) dur_s=$((dur_i % 60))
        local time_str=$(printf "%02d:%02d / %02d:%02d" $pos_m $pos_s $dur_m $dur_s)

        local icon="▶"
        [[ "$paused" == "true" ]] && icon="⏸"

        local label="$icon $time_str"
        local bar_w=$((cols - ${#label} - 4))
        local bar=""
        if (( bar_w > 10 && dur_i > 0 )); then
            local filled=$((pos_i * bar_w / dur_i))
            (( filled > bar_w )) && filled=$bar_w
            local empty=$((bar_w - filled))
            bar=" [$(printf '━%.0s' {1..$filled} 2>/dev/null)$(printf '─%.0s' {1..$empty} 2>/dev/null)]"
        fi

        local info="♫  $title"
        [[ -n "$artist" ]] && info="$info  —  $artist"
        local track_info="[$((pl_pos + 1)) / $pl_count]"

        # begin synchronized output (Kitty double-buffers until end marker)
        printf '\e[?2026h'

        # delete all kitty images from previous frame
        printf '\e_Ga=d;\e\\'

        # Disable auto-wrap, clear screen, hide cursor
        printf '\e[?7l\e[2J\e[?25l'

        # --- Adaptive Header ---
        local cur_row=1
        if [[ "$_layout_mode" == "normal" ]]; then
            # Full header: 2 control lines + info + album + track
            local controls1="SPACE=pause  ←→=seek  ↑↓=seek 30s  ,./<>=prev/next  []=speed"
            local controls2="A=add next  L=queue  j/k=nav next  ENTER=play nav  q=quit"
            printf '\e[1;1H\e[2m'
            _jukebox_padline "$(_jukebox_center "$controls1" $cols)" $cols
            printf '\e[2;1H'
            _jukebox_padline "$(_jukebox_center "$controls2" $cols)" $cols
            printf '\e[0m'
            printf '\e[3;1H'
            _jukebox_padline "$(_jukebox_center "$info" $cols)" $cols
            printf '\e[4;1H'
            if [[ -n "$album" ]]; then
                _jukebox_padline "$(_jukebox_center "💿 $album" $cols)" $cols
            fi
            printf '\e[5;1H'
            _jukebox_padline "$(_jukebox_center "$track_info" $cols)" $cols
            cur_row=6

        elif [[ "$_layout_mode" == "compact" ]]; then
            # Compact: 1 control line + info with track
            local controls_compact="A=add next  L=queue  j/k=nav  ENTER=play  q=quit"
            printf '\e[1;1H\e[2m'
            _jukebox_padline "$(_jukebox_center "$controls_compact" $cols)" $cols
            printf '\e[0m'
            printf '\e[2;1H'
            _jukebox_padline "$(_jukebox_center "$info  $track_info" $cols)" $cols
            if [[ -n "$album" ]]; then
                printf '\e[3;1H'
                _jukebox_padline "$(_jukebox_center "💿 $album" $cols)" $cols
            fi
            cur_row=4

        else  # minimal
            # Minimal: song title + track only, single line
            local mini_info="$info  $track_info"
            printf '\e[1;1H'
            _jukebox_padline "$(_jukebox_center "$mini_info" $cols)" $cols
            cur_row=2
        fi

        # --- Album art (positioned by layout engine) ---
        if [[ -n "$_jukebox_art_text" ]]; then
            printf '\e[%d;1H%s' "$_layout_art_start_row" "$_jukebox_art_text"
        fi

        # --- "Up Next" panel (layout-driven placement with bounds) ---
        if [[ -n "$pl_pos" && "$_layout_next_mode" != "hidden" ]]; then
            local panel_max_y=$(( rows - 1 ))   # never overwrite progress bar
            local panel_max_w=$(( cols - _layout_next_x - 1 ))
            _jukebox_render_next_panel "$_layout_next_x" "$_layout_next_y" "$panel_max_y" "$panel_max_w"
        fi

        # progress at bottom
        printf '\e[%d;1H' "$rows"
        _jukebox_padline "$(_jukebox_center "${label}${bar}" $cols)" $cols

        # restore auto-wrap, end sync
        printf '\e[?7h\e[?2026l'
    }


    # --- add to queue (Spotify style / play next) ---
    _jukebox_add_next() {
        # leave altscreen for fzf
        printf '\e[?1049l\e[?25h'
        [[ -n "$saved_stty" ]] && stty "$saved_stty" 2>/dev/null

        _jukebox_setup_fzf_sort

        local fzf_header="TAB=toggle  ENTER=add to queue  ESC=cancel"

        if [[ -s "$cachefile" ]]; then
            fzf_header="$fzf_header
─── Sort: Alt-T/A/B/D/L (asc) | Shift+Alt-T/A/B/D/L (desc) ───"
        fi

        # default list: setup using shared helper
        local tmp_files=("$musicdir"/**/*.flac(N.on))
        local input_list
        input_list=$(_jukebox_get_input_list "${tmp_files[@]}")

        local selected
        selected=$(echo "$input_list" | \
            fzf --multi \
                --delimiter=$'\t' --with-nth=2 \
                --prompt="Add Next: " \
                --header="$fzf_header" \
                --marker="✔ " \
                --preview "$_jukebox_fzf_preview" \
                --preview-window=right:50% \
                "${_fzf_binds[@]}")

        # re-enter altscreen
        printf '\e[?1049h\e[?25l'
        stty -echo -icanon min 0 time 0 2>/dev/null

        rm -rf "$_fzf_sort_dir"

        [[ -z "$selected" ]] && return

        local files_to_add=("${(@f)${$(echo "$selected" | cut -f1)}}")
        (( ${#files_to_add[@]} == 0 )) && return

        local pl_pos=$(_jukebox_fast_get "playlist-pos")
        [[ -z "$pl_pos" ]] && pl_pos=0
        local target_pos=$((pl_pos + 1))

        local pl_len=$(_jukebox_fast_get "playlist-count")
        [[ -z "$pl_len" ]] && pl_len=0

        # Append each file, then move it to the target position
        for f in "${files_to_add[@]}"; do
            # Add to end of queue
            local cmd
            cmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["loadfile", sys.argv[1], "append"]}))' "$f")
            _jukebox_set "$cmd"
            
            local expected_len=$((pl_len + 1))
            local wait_t=0
            while (( wait_t < 20 )); do
                sleep 0.05
                local cur_len=$(_jukebox_fast_get "playlist-count")
                if [[ -n "$cur_len" ]] && (( cur_len >= expected_len )); then
                    pl_len=$cur_len
                    break
                fi
                wait_t=$((wait_t + 1))
            done
            
            local last_idx=$((pl_len - 1))
            
            # Extract actual mpv playlist entry id
            local item_id=$(_jukebox_fast_get "playlist/$last_idx/id")
            if [[ -n "$item_id" ]]; then
                echo "$item_id" >> "$queuefile"
            fi

            if (( last_idx > target_pos )); then
                    cmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["playlist-move", int(sys.argv[1]), int(sys.argv[2])]}))' "$last_idx" "$target_pos")
                _jukebox_set "$cmd"
            fi
            target_pos=$((target_pos + 1))
        done
    }

    # --- queue picker & editor ---
    _jukebox_queue_picker() {
        export _JUKEBOX_SOCK="$mpvsock"
        export _JUKEBOX_QUEUEFILE="$queuefile"

        # We need a small helper script we can call from fzf, because
        # exporting complex zsh functions to fzf's bash shell is messy.
        local script_dir=$(mktemp -d /tmp/jukebox-scripts-XXXXXX)
        local fetch_script="$script_dir/fetch.sh"
        local del_script="$script_dir/del.sh"

        # fetch script: shows NOW PLAYING, then QUEUE section, then LIBRARY section
        cat << 'FETCHEOF' > "$fetch_script"
#!/usr/bin/env bash
pl_json=$(echo '{"command":["get_property","playlist"]}' | socat -t 0.5 - UNIX-CONNECT:"$_JUKEBOX_SOCK" 2>/dev/null)
count=$(echo "$pl_json" | "$_JUKEBOX_PYTHON" -c 'import sys, json; d=json.load(sys.stdin).get("data", []); print(len(d))' 2>/dev/null)
(( count == 0 )) && exit 0

# Find current position
cur_pos=$(echo "$pl_json" | "$_JUKEBOX_PYTHON" -c 'import sys, json; d=json.load(sys.stdin).get("data", []); print(next((i for i, x in enumerate(d) if x.get("current")), 0))' 2>/dev/null)

# Parse all entries (include id)
entries=$(echo "$pl_json" | "$_JUKEBOX_PYTHON" -c 'import sys, json; d=json.load(sys.stdin).get("data", []); print("\n".join(f"{str(x.get(\"current\", False)).lower()}\t{i}\t{x.get(\"filename\",\"\")}\t{x.get(\"id\",\"\")}" for i, x in enumerate(d)))' 2>/dev/null)

# --- Now Playing ---
while IFS=$'\t' read -r is_current idx fp item_id; do
    if [[ "$is_current" == "true" ]]; then
        name="${fp##*/}"; name="${name%.flac}"
        echo "▶ $((idx + 1))) $name"
    fi
done <<< "$entries"

# --- Queue section (manually added songs) ---
queue_output=""
queue_count=0
while IFS=$'\t' read -r is_current idx fp item_id; do
    if [[ "$is_current" != "true" ]] && (( idx > cur_pos )); then
        if [[ -n "$item_id" && -f "$_JUKEBOX_QUEUEFILE" ]] && grep -qxF "$item_id" "$_JUKEBOX_QUEUEFILE" 2>/dev/null; then
            name="${fp##*/}"; name="${name%.flac}"
            queue_output+="♫ $((idx + 1))) $name"$'\n'
            queue_count=$((queue_count + 1))
        fi
    fi
done <<< "$entries"

if (( queue_count > 0 )); then
    echo "━━━━━━━━━━━━ Queue ($queue_count) ━━━━━━━━━━━━"
    printf '%s' "$queue_output"
fi

# --- Library section (original playlist) ---
library_output=""
library_count=0
while IFS=$'\t' read -r is_current idx fp item_id; do
    if [[ "$is_current" != "true" ]] && (( idx > cur_pos )); then
        if [[ -z "$item_id" ]] || ! [[ -f "$_JUKEBOX_QUEUEFILE" ]] || ! grep -qxF "$item_id" "$_JUKEBOX_QUEUEFILE" 2>/dev/null; then
            name="${fp##*/}"; name="${name%.flac}"
            library_output+="  $((idx + 1))) $name"$'\n'
            library_count=$((library_count + 1))
        fi
    fi
done <<< "$entries"

if (( library_count > 0 )); then
    echo "━━━━━━━━ Up Next from Library ($library_count) ━━━━━━━━"
    printf '%s' "$library_output"
fi
FETCHEOF

        # delete script: removes from mpv playlist AND from queue tracker
        cat << 'DELEOF' > "$del_script"
#!/usr/bin/env bash
# Skip separator lines
echo "$1" | grep -qE '^[━]' && exit 0
num=$(echo "$1" | grep -o -E '[0-9]+' | head -n 1)
if [[ -n "$num" ]]; then
    idx=$((num - 1))
    item_id=$("$_JUKEBOX_PYTHON" -c 'import socket, json, sys; s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1]); s.sendall((json.dumps({"command": ["get_property", sys.argv[2]]})+"\n").encode()); d=s.recv(4096).split(b"\n")[0]; print(json.loads(d).get("data", ""))' "$_JUKEBOX_SOCK" "playlist/$idx/id" 2>/dev/null)
    echo "{\"command\":[\"playlist-remove\",$idx]}" | socat -t 0.5 - UNIX-CONNECT:"$_JUKEBOX_SOCK" > /dev/null 2>&1
    if [[ -n "$item_id" && -f "$_JUKEBOX_QUEUEFILE" ]]; then
        tmp=$(mktemp)
        found=0
        while IFS= read -r line; do
            if [[ "$found" -eq 0 && "$line" == "$item_id" ]]; then
                found=1
            else
                echo "$line"
            fi
        done < "$_JUKEBOX_QUEUEFILE" > "$tmp"
        mv "$tmp" "$_JUKEBOX_QUEUEFILE"
    fi
fi
DELEOF
        chmod +x "$fetch_script" "$del_script"

        # leave altscreen for fzf
        printf '\e[?1049l\e[?25h'
        [[ -n "$saved_stty" ]] && stty "$saved_stty" 2>/dev/null

        local result
        result=$("$fetch_script" | fzf \
            --prompt='Queue: ' \
            --header=$'ENTER = Jump to song  |  DEL = Remove  |  ESC = Cancel' \
            --bind "delete:execute-silent($del_script {})+reload($fetch_script)" \
            --no-sort)

        # re-enter altscreen
        printf '\e[?1049h\e[?25l'
        stty -echo -icanon min 0 time 0 2>/dev/null

        rm -rf "$script_dir"

        # jump to selected song (ignore separator lines)
        if [[ -n "$result" ]] && ! echo "$result" | grep -qE '^[━]'; then
            local num
            num=$(echo "$result" | grep -oE '[0-9]+' | head -1)
            if [[ -n "$num" ]]; then
                local cmd
                cmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["set_property", "playlist-pos", int(sys.argv[1])]}))' "$((num - 1))")
                _jukebox_set "$cmd"
                sleep 0.3
                local newpath=$(_jukebox_fast_get "path")
                if [[ -n "$newpath" ]]; then
                    _jukebox_extract_art "$newpath"
                    _jukebox_cache_art
                fi
            fi
        fi
        force_redraw=1
    }

    # enter altscreen + initial clear
    printf '\e[?1049h\e[2J\e[?25l'

    # shared state for render (set by main loop, read by _jukebox_render)
    local _render_path="" _render_title="" _render_artist="" _render_album=""
    local _render_pl_pos=0 _render_pl_count=0
    local _render_time_pos=0 _render_duration=0 _render_paused=""
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
        _jukebox_extract_art "$_render_path"
        _jukebox_cache_art
    else
        _jukebox_calc_layout    # ensure layout vars exist even without a track
    fi
    _jukebox_render

    # track state for change detection
    local last_path="$_render_path"
    local last_cols=$(tput cols) last_rows=$(tput lines)
    local last_paused=""
    local force_redraw=1

    # raw terminal mode for keypress reading
    stty -echo -icanon min 0 time 0 2>/dev/null

    # main display loop
    local _tick=0 key="" seq="" _drain="" new_cols new_rows _est_next _poll_batch pos dur pos_i dur_i pos_m pos_s dur_m dur_s time_str icon label bar_w bar filled empty
    local _p_path _p_paused _p_count _p_pos _p_time _p_dur _p_title _p_artist _p_album _p_next_file _p_next_id

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
                '[')  _jukebox_set '{"command":["add","speed",-0.25]}' ;;
                ']')  _jukebox_set '{"command":["add","speed",0.25]}' ;;
                $'\x7f') _jukebox_set '{"command":["set_property","speed",1.0]}' ;;
                'j')
                    if (( _render_pl_pos + 1 + _nav_offset < _render_pl_count - 1 )); then
                        _nav_offset=$((_nav_offset + 1)); _jukebox_last_next_file=""; force_redraw=1
                    fi
                    ;;
                'k')
                    if (( _nav_offset > 0 )); then
                        _nav_offset=$((_nav_offset - 1)); _jukebox_last_next_file=""; force_redraw=1
                    fi
                    ;;
                $'\n'|$'\r')
                    local cmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["set_property", "playlist-pos", int(sys.argv[1])]}))' "$((_render_pl_pos + 1 + _nav_offset))")
                    _jukebox_set "$cmd"
                    _nav_offset=0
                    _jukebox_last_next_file=""
                    force_redraw=1
                    ;;
                'a'|'A')
                    _jukebox_add_next
                    _jukebox_last_next_file=""
                    _jukebox_next_retries=0
                    force_redraw=1
                    ;;
                'L'|'l')
                    _jukebox_queue_picker
                    _jukebox_last_next_file=""
                    _jukebox_next_retries=0
                    force_redraw=1
                    ;;
                'q'|'Q')
                    break
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
            metadata/by-key/album "playlist/$_est_next/filename" "playlist/$_est_next/id")
            
        IFS=$'\x1f' read -r _p_path _p_paused _p_count _p_pos _p_time _p_dur \
            _p_title _p_artist _p_album _p_next_file _p_next_id <<< "$_poll_batch"

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

        # 4. Handle track change
        if [[ -n "$_render_path" && "$_render_path" != "$last_path" ]]; then
            last_path="$_render_path"
            _nav_offset=0
            _jukebox_extract_art "$_render_path"
            _jukebox_cache_art
            _jukebox_last_next_file=""
            _jukebox_next_retries=0
            _jukebox_clear_next_meta
            force_redraw=1
        fi

        if [[ "$_render_paused" != "$last_paused" ]]; then
            last_paused="$_render_paused"
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

        # 6. Render or partial update
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

        # 7. Sleep for next tick
        sleep 0.05
    done
    _jukebox_cleanup
}
