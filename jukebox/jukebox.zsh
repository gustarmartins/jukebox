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
    title=$(ffprobe -v quiet -show_entries format_tags=title -of default=nw=1:nk=1 -- {} 2>/dev/null)
    artist=$(ffprobe -v quiet -show_entries format_tags=artist -of default=nw=1:nk=1 -- {} 2>/dev/null)
    album=$(ffprobe -v quiet -show_entries format_tags=album -of default=nw=1:nk=1 -- {} 2>/dev/null)
    duration=$(ffprobe -v quiet -show_entries format=duration -of default=nw=1:nk=1 -- {} 2>/dev/null)
    if [[ -n "$duration" ]]; then
        dur_int=${duration%.*}
        mins=$((dur_int / 60))
        secs=$((dur_int % 60))
        dur_fmt=$(printf "%d:%02d" "$mins" "$secs")
    fi
    fname={}; fname=${fname##*/}; fname=${fname%.flac}
    echo "🎵 ${title:-$fname}"
    [[ -n "$artist" ]] && echo "🎤 $artist"
    [[ -n "$album" ]]  && echo "💿 $album"
    [[ -n "$dur_fmt" ]] && echo "⏱  $dur_fmt"
    echo ""
    if ffmpeg -y -v quiet -i {} -an -vcodec copy -update 1 "$tmpcover" 2>/dev/null && [[ -s "$tmpcover" ]]; then
        chafa --size 40x20 "$tmpcover" 2>/dev/null
    fi
'

# --- main function ---
jukebox() {
    local _jukebox_debug=0
    local _jukebox_debuglog="/tmp/jukebox-debug.log"
    if [[ "$1" == "--debug" || "$1" == "-d" ]]; then
        _jukebox_debug=1
        : > "$_jukebox_debuglog"
        echo "🔧 Debug mode ON → tail -f $_jukebox_debuglog"
    fi

    _jukebox_log() {
        (( _jukebox_debug )) && printf '[%s] %s\n' "$SECONDS" "$*" >> "$_jukebox_debuglog"
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
            files=("$musicdir"/**/*.flac(N.on))
            if [[ ${#files[@]} -eq 0 ]]; then
                echo "No FLAC files found in $musicdir"
                return 1
            fi
            local picked=$(printf '%s\n' "${files[@]}" | \
                fzf --prompt="Pick start song: " \
                    --preview "$_jukebox_fzf_preview" \
                    --preview-window=right:50%)
            [[ -z "$picked" ]] && return
            for i in {1..${#files[@]}}; do
                [[ "${files[$i]}" == "$picked" ]] && { start_idx=$((i - 1)); break; }
            done
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
            local selected
            selected=$(printf '%s\n' "${all_files[@]}" | \
                fzf --multi \
                    --prompt="Queue: " \
                    --header="TAB=toggle  Ctrl-A=all  Ctrl-D=none  ENTER=play" \
                    --marker="✔ " \
                    --preview "$_jukebox_fzf_preview" \
                    --preview-window=right:50% \
                    --bind 'ctrl-a:select-all,ctrl-d:deselect-all')
            [[ -z "$selected" ]] && return
            files=("${(@f)${selected}}")
            echo ""
            echo "📋 Queue (${#files[@]} songs):"
            local n=1
            for f in "${files[@]}"; do
                local _fname="${f##*/}"; _fname="${_fname%.flac}"
                echo "  $n) $_fname"
                n=$((n + 1))
            done
            ;;
        q|Q) return ;;
        *) echo "Invalid choice"; return 1 ;;
    esac

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No FLAC files found in $musicdir"
        return 1
    fi

    # temp files
    local playlist=$(mktemp /tmp/jukebox-XXXXXX.m3u)
    local mpvsock=$(mktemp -u "${XDG_RUNTIME_DIR:-/tmp}/jukebox-mpv-XXXXXX.sock")
    local coverfile=$(mktemp /tmp/jukebox-cover-XXXXXX.jpg)
    local coverfile_next=$(mktemp /tmp/jukebox-cover-next-XXXXXX.jpg)
    local _jukebox_prevtmp="/tmp/jukebox-fzf-preview-$$.jpg"
    local queuefile="/tmp/jukebox-queue-$$.txt"
    local cachefile="/tmp/jukebox-meta-$$.tsv"
    export _JUKEBOX_PREVTMP="$_jukebox_prevtmp"
    local _jukebox_art_text=""
    local saved_stty=$(stty -g 2>/dev/null)

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
            kill "$_jukebox_mpv_pid" 2>/dev/null
            wait "$_jukebox_mpv_pid" 2>/dev/null
        fi
        rm -f "$playlist" "$mpvsock" "$coverfile" "$coverfile_next" "$_jukebox_prevtmp" "$queuefile" "$cachefile"
        unfunction _jukebox_render _jukebox_ipc _jukebox_get _jukebox_get_num \
                   _jukebox_set _jukebox_batch_get _jukebox_extract_art _jukebox_cache_art \
                   _jukebox_center _jukebox_padline _jukebox_fast_get \
                   _jukebox_add_next _jukebox_queue_picker _jukebox_log _jukebox_cleanup 2>/dev/null
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

    # --- build metadata cache in background for sorting ---
    python3 -c "
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
            # FLAC tags can be uppercase or lowercase
            get = lambda k: tags.get(k, tags.get(k.upper(), ''))
            title = get('title') or f.replace('.flac','')
            artist = get('artist') or 'Unknown'
            album = get('album') or 'Unknown'
            date = get('date') or '0'
            dur = d.get('format',{}).get('duration','0')
            out.write(f'{fp}\\t{title}\\t{artist}\\t{album}\\t{date}\\t{dur}\\n')
        except: pass
out.close()
" "$musicdir" "$cachefile" &
    local _cache_pid=$!

    # --- IPC helper using python for reliable Unix socket communication ---
    _jukebox_ipc() {
        python3 -c '
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

    _jukebox_get() {
        local resp cmd
        cmd=$(jq -nc --arg p "$1" '{"command":["get_property",$p]}' 2>/dev/null)
        resp=$(_jukebox_ipc "$cmd")
        echo "$resp" | jq -r '.data // empty' 2>/dev/null
    }

    _jukebox_get_num() {
        local resp cmd
        cmd=$(jq -nc --arg p "$1" '{"command":["get_property",$p]}' 2>/dev/null)
        resp=$(_jukebox_ipc "$cmd")
        echo "$resp" | jq -r '.data // "0"' 2>/dev/null
    }

    _jukebox_set() {
        _jukebox_ipc "$1" > /dev/null
    }

    # --- batch property getter: single Python process, single socket connection ---
    # Usage: _jukebox_batch_get prop1 prop2 ...
    # Output: tab-separated values for each property
    _jukebox_batch_get() {
        _jukebox_log "_jukebox_batch_get called with args: $*"
        python3 -c '
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
            print("MPV RES:", line.decode("utf-8", "replace"), file=sys.stderr)
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
        ffmpeg -y -v quiet -i "$filepath" -an -vcodec copy -update 1 "$coverfile" 2>/dev/null
    }

    # --- cache chafa output for current cover ---
    _jukebox_cache_art() {
        local cols=$(tput cols) rows=$(tput lines)
        local art_h=$((rows * 45 / 100))
        (( art_h < 6 )) && art_h=6
        local art_w=$((art_h * 2))
        (( art_w > cols - 4 )) && art_w=$((cols - 4))
        if [[ -s "$coverfile" ]]; then
            _jukebox_art_text=$(chafa --size "${art_w}x${art_h}" "$coverfile" 2>/dev/null)
        else
            _jukebox_art_text=""
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

    # fast property getter using socat (avoids python overhead for simple queries)
    _jukebox_fast_get() {
        local cmd
        cmd=$(jq -nc --arg p "$1" '{"command":["get_property",$p]}' 2>/dev/null)
        echo "$cmd" | socat -t 0.5 - UNIX-CONNECT:"$mpvsock" 2>/dev/null | jq -r '.data // empty' 2>/dev/null
    }

    # --- render screen (absolute positioning for stability) ---
    _jukebox_render() {
        local cols=$(tput cols) rows=$(tput lines)

        # Fetch all display properties in a single IPC call (replaces 9 socat calls)
        local _batch
        _batch=$(_jukebox_batch_get path metadata/by-key/title metadata/by-key/artist \
                    metadata/by-key/album playlist-pos playlist-count time-pos duration pause)
        local path title artist album pl_pos pl_count pos dur paused
        IFS=$'\x1f' read -r path title artist album pl_pos pl_count pos dur paused <<< "$_batch"

        [[ -z "$path" ]] && return

        [[ -z "$title" ]] && title="${path##*/}" && title="${title%.flac}"
        pl_pos=${pl_pos:-0}; pl_count=${pl_count:-0}
        pos=${pos:-0}; dur=${dur:-0}

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

        local controls="SPACE=pause  ←→=seek  ↑↓=seek 30s  ,./<>=prev/next  []=speed  A=add next  L=queue  q=quit"
        local info="♫  $title"
        [[ -n "$artist" ]] && info="$info  —  $artist"
        local track_info="[$((pl_pos + 1)) / $pl_count]"

        # begin synchronized output (Kitty double-buffers until end marker)
        printf '\e[?2026h'

        # delete all kitty images from previous frame
        printf '\e_Ga=d;\e\\'

        # Disable auto-wrap, clear screen, hide cursor
        printf '\e[?7l\e[2J\e[?25l'

        # row 1: controls (dim)
        printf '\e[1;1H\e[2m'
        _jukebox_padline "$(_jukebox_center "$controls" $cols)" $cols
        printf '\e[0m'

        # row 3: song info
        printf '\e[3;1H'
        _jukebox_padline "$(_jukebox_center "$info" $cols)" $cols

        # row 4: album (or blank)
        printf '\e[4;1H'
        if [[ -n "$album" ]]; then
            _jukebox_padline "$(_jukebox_center "💿 $album" $cols)" $cols
        fi

        # row 5: track position
        printf '\e[5;1H'
        _jukebox_padline "$(_jukebox_center "$track_info" $cols)" $cols

        # album art (kitty graphics — start at row 7)
        local _art_line_count=0
        if [[ -n "$_jukebox_art_text" ]]; then
            printf '\e[7;1H%s' "$_jukebox_art_text"
        fi

        # upcoming queue on the right (Coming Up Next)
        if [[ -n "$pl_pos" ]]; then
            # calculate safe X position on the right
            local art_w_est=$(( _art_line_count * 2 ))
            (( art_w_est == 0 )) && art_w_est=10
            local queue_x=$(( cols - 40 ))
            (( queue_x < art_w_est + 6 )) && queue_x=$(( art_w_est + 6 ))
            
            if (( queue_x < cols - 15 )); then
                local next_idx=$((pl_pos + 1))
                # Query specific playlist entry — small response, socat handles it fine
                local next_file=$(_jukebox_fast_get "playlist/$next_idx/filename")
                local _next_item_id=$(_jukebox_fast_get "playlist/$next_idx/id")

                _jukebox_log "next: pl_pos=$pl_pos next_idx=$next_idx next_file=$next_file item_id=$_next_item_id"
                
                if [[ -n "$next_file" && "$next_file" != "$_jukebox_last_next_file" ]]; then
                    _jukebox_last_next_file="$next_file"
                    
                    if [[ -n "$next_file" ]]; then
                        rm -f "$coverfile_next" 2>/dev/null
                        ffmpeg -y -v quiet -i "$next_file" -an -vcodec copy -update 1 "$coverfile_next" 2>/dev/null
                        if [[ -s "$coverfile_next" ]]; then
                            _jukebox_next_art_text=$(chafa --size 20x10 "$coverfile_next" 2>/dev/null)
                        else
                            _jukebox_next_art_text=""
                        fi
                        
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
                        if [[ -n "$_next_item_id" && -f "$queuefile" ]] && grep -qxF "$_next_item_id" "$queuefile" 2>/dev/null; then
                            _jukebox_next_source="queued"
                        else
                            _jukebox_next_source="library"
                        fi
                    else
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
                    fi
                fi
                
                local q_y=7
                local _src_icon=""
                [[ "$_jukebox_next_source" == "queued" ]] && _src_icon="  📋 Queued"
                [[ "$_jukebox_next_source" == "library" ]] && _src_icon="  📚 Up Next"
                printf '\e[%d;%dH\e[1m🎵 Coming Up Next%s\e[0m' "$q_y" "$queue_x" "$_src_icon"
                q_y=$((q_y + 2))
                
                if [[ -n "$next_file" ]]; then
                    if [[ -n "$_jukebox_next_art_text" ]]; then
                        local art_lines=("${(@f)_jukebox_next_art_text}")
                        for l in "${art_lines[@]}"; do
                            printf '\e[%d;%dH%s' "$q_y" "$queue_x" "$l"
                            q_y=$((q_y + 1))
                        done
                    fi
                    
                    q_y=$((q_y + 1))
                    local max_len=$(( cols - queue_x - 2 ))
                    
                    local t_title="Title: ${_jukebox_next_title:-Unknown}"
                    (( ${#t_title} > max_len )) && t_title="${t_title[1,$((max_len - 3))]}..."
                    printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$queue_x" "$t_title"; q_y=$((q_y + 1))
                    
                    local t_artist="Artist: ${_jukebox_next_artist:-Unknown}"
                    (( ${#t_artist} > max_len )) && t_artist="${t_artist[1,$((max_len - 3))]}..."
                    printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$queue_x" "$t_artist"; q_y=$((q_y + 1))
                    
                    local t_album="Album: ${_jukebox_next_album:-None}"
                    [[ -n "$_jukebox_next_date" ]] && t_album="$t_album (${_jukebox_next_date})"
                    (( ${#t_album} > max_len )) && t_album="${t_album[1,$((max_len - 3))]}..."
                    printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$queue_x" "$t_album"; q_y=$((q_y + 1))
                    
                    if [[ -n "$_jukebox_next_dur" ]]; then
                        local t_dur="Length: $_jukebox_next_dur"
                        (( ${#t_dur} > max_len )) && t_dur="${t_dur[1,$((max_len - 3))]}..."
                        printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$queue_x" "$t_dur"; q_y=$((q_y + 1))
                    fi

                    if [[ -n "$_jukebox_next_quality" ]]; then
                        local t_quality="Quality: $_jukebox_next_quality"
                        (( ${#t_quality} > max_len )) && t_quality="${t_quality[1,$((max_len - 3))]}..."
                        printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$queue_x" "$t_quality"; q_y=$((q_y + 1))
                    fi

                    if [[ -n "$_jukebox_next_size" ]]; then
                        local t_size="Size: $_jukebox_next_size"
                        (( ${#t_size} > max_len )) && t_size="${t_size[1,$((max_len - 3))]}..."
                        printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$queue_x" "$t_size"; q_y=$((q_y + 1))
                    fi

                    if [[ -n "$_jukebox_next_genre" ]]; then
                        local t_genre="Genre: $_jukebox_next_genre"
                        (( ${#t_genre} > max_len )) && t_genre="${t_genre[1,$((max_len - 3))]}..."
                        printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$queue_x" "$t_genre"; q_y=$((q_y + 1))
                    fi
                else
                    if (( next_idx < pl_count )); then
                        printf '\e[%d;%dH\e[2m⏳ Loading...\e[0m' "$q_y" "$queue_x"
                    else
                        printf '\e[%d;%dH\e[2mEnd of playlist\e[0m' "$q_y" "$queue_x"
                    fi
                fi
            fi
        fi

        # progress at bottom
        printf '\e[%d;1H' "$rows"
        _jukebox_padline "$(_jukebox_center "${label}${bar}" $cols)" $cols

        # restore auto-wrap, show cursor, end sync
        printf '\e[?7h\e[?25h\e[?2026l'
    }

    # --- add to queue (Spotify style / play next) ---
    _jukebox_add_next() {
        # leave altscreen for fzf
        printf '\e[?1049l\e[?25h'
        [[ -n "$saved_stty" ]] && stty "$saved_stty" 2>/dev/null

        # wait for metadata cache if still building
        if [[ -n "$_cache_pid" ]] && kill -0 "$_cache_pid" 2>/dev/null; then
            echo "⏳ Building music library metadata cache..."
            wait "$_cache_pid" 2>/dev/null
        fi

        local sort_dir=$(mktemp -d /tmp/jukebox-sort-XXXXXX)
        export _JUKEBOX_CACHE="$cachefile"

        # --- sort helper scripts for fzf reload ---
        cat > "$sort_dir/by_title.sh" << 'SORTEOF'
#!/usr/bin/env bash
sort -t$'\t' -k2 -f "$_JUKEBOX_CACHE" | cut -f1
SORTEOF
        cat > "$sort_dir/by_title_rev.sh" << 'SORTEOF'
#!/usr/bin/env bash
sort -t$'\t' -k2 -fr "$_JUKEBOX_CACHE" | cut -f1
SORTEOF

        cat > "$sort_dir/by_artist.sh" << 'SORTEOF'
#!/usr/bin/env bash
sort -t$'\t' -k3,3 -f -k2,2 -f "$_JUKEBOX_CACHE" | cut -f1
SORTEOF
        cat > "$sort_dir/by_artist_rev.sh" << 'SORTEOF'
#!/usr/bin/env bash
sort -t$'\t' -k3,3 -fr -k2,2 -f "$_JUKEBOX_CACHE" | cut -f1
SORTEOF

        cat > "$sort_dir/by_album.sh" << 'SORTEOF'
#!/usr/bin/env bash
sort -t$'\t' -k4,4 -f -k2,2 -f "$_JUKEBOX_CACHE" | cut -f1
SORTEOF
        cat > "$sort_dir/by_album_rev.sh" << 'SORTEOF'
#!/usr/bin/env bash
sort -t$'\t' -k4,4 -fr -k2,2 -f "$_JUKEBOX_CACHE" | cut -f1
SORTEOF

        cat > "$sort_dir/by_date.sh" << 'SORTEOF'
#!/usr/bin/env bash
sort -t$'\t' -k5 -rn "$_JUKEBOX_CACHE" | cut -f1
SORTEOF
        cat > "$sort_dir/by_date_rev.sh" << 'SORTEOF'
#!/usr/bin/env bash
sort -t$'\t' -k5 -n "$_JUKEBOX_CACHE" | cut -f1
SORTEOF

        cat > "$sort_dir/by_length.sh" << 'SORTEOF'
#!/usr/bin/env bash
sort -t$'\t' -k6 -n "$_JUKEBOX_CACHE" | cut -f1
SORTEOF
        cat > "$sort_dir/by_length_rev.sh" << 'SORTEOF'
#!/usr/bin/env bash
sort -t$'\t' -k6 -nr "$_JUKEBOX_CACHE" | cut -f1
SORTEOF

        chmod +x "$sort_dir"/*.sh

        local fzf_header="TAB=toggle  ENTER=add to queue  ESC=cancel"
        local fzf_binds=()

        if [[ -s "$cachefile" ]]; then
            fzf_header="$fzf_header
─── Sort: Alt-T/A/B/D/L (asc) | Shift+Alt-T/A/B/D/L (desc) ───"
            fzf_binds=(
                --bind "alt-t:reload($sort_dir/by_title.sh)"
                --bind "alt-T:reload($sort_dir/by_title_rev.sh)"
                --bind "alt-a:reload($sort_dir/by_artist.sh)"
                --bind "alt-A:reload($sort_dir/by_artist_rev.sh)"
                --bind "alt-b:reload($sort_dir/by_album.sh)"
                --bind "alt-B:reload($sort_dir/by_album_rev.sh)"
                --bind "alt-d:reload($sort_dir/by_date.sh)"
                --bind "alt-D:reload($sort_dir/by_date_rev.sh)"
                --bind "alt-l:reload($sort_dir/by_length.sh)"
                --bind "alt-L:reload($sort_dir/by_length_rev.sh)"
            )
        fi

        # default list: sorted by title if cache ready, else by filename
        local input_list
        if [[ -s "$cachefile" ]]; then
            input_list=$(sort -t$'\t' -k2 -f "$cachefile" | cut -f1)
        else
            local tmp_files=("$musicdir"/**/*.flac(N.on))
            input_list=$(printf '%s\n' "${tmp_files[@]}")
        fi

        local selected
        selected=$(echo "$input_list" | \
            fzf --multi \
                --prompt="Add Next: " \
                --header="$fzf_header" \
                --marker="✔ " \
                --preview "$_jukebox_fzf_preview" \
                --preview-window=right:50% \
                "${fzf_binds[@]}")

        # re-enter altscreen
        printf '\e[?1049h'
        stty -echo -icanon min 0 time 0 2>/dev/null

        rm -rf "$sort_dir"

        [[ -z "$selected" ]] && return

        local files_to_add=("${(@f)${selected}}")
        (( ${#files_to_add[@]} == 0 )) && return

        local pl_pos=$(_jukebox_fast_get "playlist-pos")
        [[ -z "$pl_pos" ]] && pl_pos=0
        local target_pos=$((pl_pos + 1))

        # Append each file, then move it to the target position
        for f in "${files_to_add[@]}"; do
            # Add to end of queue
            local cmd
            cmd=$(jq -nc --arg f "$f" '{"command":["loadfile",$f,"append"]}')
            _jukebox_set "$cmd"
            sleep 0.1 # let mpv register the file in the playlist
            local pl_len=$(_jukebox_fast_get "playlist-count")
            local last_idx=$((pl_len - 1))
            
            # Extract actual mpv playlist entry id
            local item_id=$(_jukebox_fast_get "playlist/$last_idx/id")
            if [[ -n "$item_id" ]]; then
                echo "$item_id" >> "$queuefile"
            fi

            if (( last_idx > target_pos )); then
                cmd=$(jq -nc --argjson last "$last_idx" --argjson tgt "$target_pos" '{"command":["playlist-move",$last,$tgt]}')
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
count=$(echo "$pl_json" | jq -r '.data | length // 0' 2>/dev/null)
(( count == 0 )) && exit 0

# Find current position
cur_pos=$(echo "$pl_json" | jq -r '[.data | to_entries[] | select(.value.current == true) | .key] | .[0] // 0' 2>/dev/null)

# Parse all entries (include id)
entries=$(echo "$pl_json" | jq -r '.data | to_entries[] | "\(.value.current // false)\t\(.key)\t\(.value.filename)\t\(.value.id // "")"' 2>/dev/null)

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
    item_id=$(echo "{\"command\":[\"get_property\",\"playlist/$idx/id\"]}" | socat -t 0.5 - UNIX-CONNECT:"$_JUKEBOX_SOCK" 2>/dev/null | jq -r '.data // empty' 2>/dev/null)
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
        printf '\e[?1049h'
        stty -echo -icanon min 0 time 0 2>/dev/null

        rm -rf "$script_dir"

        # jump to selected song (ignore separator lines)
        if [[ -n "$result" ]] && ! echo "$result" | grep -qE '^[━]'; then
            local num
            num=$(echo "$result" | grep -oE '[0-9]+' | head -1)
            if [[ -n "$num" ]]; then
                local cmd
                cmd=$(jq -nc --argjson pos "$((num - 1))" '{"command":["set_property","playlist-pos",$pos]}')
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
    printf '\e[?1049h\e[2J'

    # initial render (retry if mpv hasn't loaded yet)
    sleep 0.5
    local cur_path="" _retries=0
    while [[ -z "$cur_path" ]] && (( _retries < 20 )); do
        cur_path=$(_jukebox_fast_get "path")
        [[ -z "$cur_path" ]] && sleep 0.2
        _retries=$((_retries + 1))
    done
    if [[ -n "$cur_path" ]]; then
        _jukebox_extract_art "$cur_path"
        _jukebox_cache_art
    fi
    _jukebox_render

    # track state for change detection
    local last_path="$cur_path"
    local last_cols=$(tput cols) last_rows=$(tput lines)
    local last_paused=""
    local force_redraw=1

    # raw terminal mode for keypress reading
    stty -echo -icanon min 0 time 0 2>/dev/null

    # main display loop
    local _tick=0
    while kill -0 "$_jukebox_mpv_pid" 2>/dev/null; do
        # 1. Handle Input (non-blocking, fast drain)
        local key=""
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
                'a'|'A')
                    _jukebox_add_next
                    force_redraw=1
                    ;;
                'L'|'l')
                    _jukebox_queue_picker
                    force_redraw=1
                    ;;
                'q'|'Q')
                    break
                    ;;
                $'\e')
                    local seq=""
                    read -rs -t 0.05 -k 2 seq 2>/dev/null
                    case "$seq" in
                        '[D') _jukebox_set '{"command":["seek",-5]}' ;;
                        '[C') _jukebox_set '{"command":["seek",5]}' ;;
                        '[A') _jukebox_set '{"command":["seek",30]}' ;;
                        '[B') _jukebox_set '{"command":["seek",-30]}' ;;
                    esac
                    # drain buffered input
                    local _drain=""
                    while read -rs -t 0 -k 1 _drain 2>/dev/null; do :; done
                    ;;
            esac
        fi

        _tick=$((_tick + 1))
        if (( _tick % 5 == 0 || force_redraw )); then

        # 2. Check for environment changes (resize)
        local new_cols=$(tput cols) new_rows=$(tput lines)
        if [[ "$new_cols" != "$last_cols" || "$new_rows" != "$last_rows" ]]; then
            last_cols=$new_cols; last_rows=$new_rows
            _jukebox_cache_art
            force_redraw=1
        fi

        # 3. Check for Track/State Changes (batch poll — single IPC call)
        local _poll_batch
        _poll_batch=$(_jukebox_batch_get path pause playlist-count playlist-pos)
        local cur_path cur_paused _poll_pl_count _poll_pl_pos
        IFS=$'\x1f' read -r cur_path cur_paused _poll_pl_count _poll_pl_pos <<< "$_poll_batch"

        if [[ -n "$cur_path" && "$cur_path" != "$last_path" ]]; then
            last_path="$cur_path"
            _jukebox_extract_art "$cur_path"
            _jukebox_cache_art
            _jukebox_last_next_file=""  # reset so Coming Up Next re-fetches
            force_redraw=1
        fi

        if [[ "$cur_paused" != "$last_paused" ]]; then
            last_paused="$cur_paused"
        fi

        # Check if Coming Up Next needs a retry (empty on previous render)
        if [[ -z "$_jukebox_last_next_file" ]]; then
            if [[ -n "$_poll_pl_count" && -n "$_poll_pl_pos" ]] && (( _poll_pl_pos + 1 < _poll_pl_count )); then
                _jukebox_log "retry: playlist loaded (count=$_poll_pl_count pos=$_poll_pl_pos), forcing redraw"
                force_redraw=1
            fi
        fi

        # 4. Render
        if (( force_redraw )); then
            # Full redraw (Track changed, resized, returned from queue)
            _jukebox_render
            force_redraw=0
        else
            # PARTIAL REDRAW (Time/Progress Bar Only)
            local pos=$(_jukebox_fast_get "time-pos")
            local dur=$(_jukebox_fast_get "duration")

            # only update if we got valid numbers
            if [[ -n "$pos" && -n "$dur" && "$dur" != "0" ]]; then
                local pos_i=${pos%.*} dur_i=${dur%.*}
                pos_i=${pos_i:-0}; dur_i=${dur_i:-0}
                local pos_m=$((pos_i / 60)) pos_s=$((pos_i % 60))
                local dur_m=$((dur_i / 60)) dur_s=$((dur_i % 60))
                local time_str=$(printf "%02d:%02d / %02d:%02d" $pos_m $pos_s $dur_m $dur_s)

                local icon="▶"
                [[ "$cur_paused" == "true" ]] && icon="⏸"

                local label="$icon $time_str"
                local bar_w=$((last_cols - ${#label} - 4))
                local bar=""
                if (( bar_w > 10 && dur_i > 0 )); then
                    local filled=$((pos_i * bar_w / dur_i))
                    (( filled > bar_w )) && filled=$bar_w
                    local empty=$((bar_w - filled))
                    bar=" [$(printf '━%.0s' {1..$filled} 2>/dev/null)$(printf '─%.0s' {1..$empty} 2>/dev/null)]"
                fi

                # Draw ONLY the bottom line
                # disable auto-wrap, save cursor, move to bottom left, hide cursor
                printf '\e[?7l\e7\e[%d;1H\e[?25l' "$last_rows"
                _jukebox_padline "$(_jukebox_center "${label}${bar}" $last_cols)" $last_cols
                # show cursor, restore cursor, restore auto-wrap
                printf '\e[?25h\e8\e[?7h'
            fi
        fi

        fi  # end of _tick % 5 == 0 || force_redraw

        # 5. Sleep for next tick
        sleep 0.05
    done
    _jukebox_cleanup
}
