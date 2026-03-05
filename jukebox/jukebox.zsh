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
    tmpcover=$(mktemp /tmp/jukebox-prev-XXXXXX.jpg)
    title=$(ffprobe -v quiet -show_entries format_tags=title -of default=nw=1:nk=1 {} 2>/dev/null)
    artist=$(ffprobe -v quiet -show_entries format_tags=artist -of default=nw=1:nk=1 {} 2>/dev/null)
    album=$(ffprobe -v quiet -show_entries format_tags=album -of default=nw=1:nk=1 {} 2>/dev/null)
    duration=$(ffprobe -v quiet -show_entries format=duration -of default=nw=1:nk=1 {} 2>/dev/null)
    if [[ -n "$duration" ]]; then
        mins=$(printf "%.0f" "$(echo "$duration / 60" | bc -l 2>/dev/null)")
        secs=$(printf "%02.0f" "$(echo "$duration - $mins * 60" | bc -l 2>/dev/null)")
        dur_fmt="${mins}:${secs}"
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
    rm -f "$tmpcover"
'

# --- main function ---
jukebox() {
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
        1) files=("${(@f)$(find "$musicdir" -name '*.flac' -type f)}") ;;
        2) files=("${(@f)$(find "$musicdir" -name '*.flac' -type f | sort)}") ;;
        3) files=("${(@f)$(find "$musicdir" -name '*.flac' -type f | sort -r)}") ;;
        4) files=("${(@f)$(find "$musicdir" -name '*.flac' -type f -printf '%T@\t%p\n' | sort -n | cut -f2-)}") ;;
        5) files=("${(@f)$(find "$musicdir" -name '*.flac' -type f -printf '%T@\t%p\n' | sort -rn | cut -f2-)}") ;;
        6)
            files=("${(@f)$(find "$musicdir" -name '*.flac' -type f | sort)}")
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
        7) files=("${(@f)$(find "$musicdir" -name '*.flac' -type f | shuf)}") ;;
        8)
            local all_files=("${(@f)$(find "$musicdir" -name '*.flac' -type f | sort)}")
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
    local mpvsock="/tmp/jukebox-mpv-$$.sock"
    local coverfile="/tmp/jukebox-cover-$$.jpg"
    local _jukebox_art_text=""

    printf '%s\n' "${files[@]}" > "$playlist"

    # cleanup handler
    _jukebox_cleanup() {
        printf '\e[?1049l\e[?25h'
        stty sane 2>/dev/null
        if [[ -n "$_jukebox_mpv_pid" ]] && kill -0 "$_jukebox_mpv_pid" 2>/dev/null; then
            kill "$_jukebox_mpv_pid" 2>/dev/null
            wait "$_jukebox_mpv_pid" 2>/dev/null
        fi
        rm -f "$playlist" "$mpvsock" "$coverfile"
    }
    trap _jukebox_cleanup EXIT INT TERM

    # start mpv in background with IPC socket, fully headless
    mpv --no-video --no-terminal \
        --playlist="$playlist" \
        --playlist-start="$start_idx" \
        --input-ipc-server="$mpvsock" &
    _jukebox_mpv_pid=$!

    # wait for socket
    local waited=0
    while [[ ! -S "$mpvsock" ]] && (( waited < 30 )); do
        sleep 0.1
        waited=$((waited + 1))
    done
    if [[ ! -S "$mpvsock" ]]; then
        echo "Error: mpv failed to start"
        return 1
    fi

    # --- IPC helper using python for reliable Unix socket communication ---
    _jukebox_ipc() {
        python3 -c "
import socket, json, sys, random
try:
    rid = random.randint(1, 999999)
    cmd = json.loads(sys.argv[1])
    cmd['request_id'] = rid
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect('$mpvsock')
    s.sendall((json.dumps(cmd) + '\n').encode())
    buf = b''
    while True:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            obj = json.loads(line)
            if obj.get('request_id') == rid:
                s.close()
                print(json.dumps(obj))
                sys.exit(0)
    s.close()
except: pass
" "$1" 2>/dev/null
    }

    _jukebox_get() {
        local resp
        resp=$(_jukebox_ipc '{"command":["get_property","'"$1"'"]}')
        echo "$resp" | jq -r '.data // empty' 2>/dev/null
    }

    _jukebox_get_num() {
        local resp
        resp=$(_jukebox_ipc '{"command":["get_property","'"$1"'"]}')
        echo "$resp" | jq -r '.data // "0"' 2>/dev/null
    }

    _jukebox_set() {
        _jukebox_ipc "$1" > /dev/null
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
    _center() {
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
    _padline() {
        local text="$1" w="$2"
        local len=${#text}
        if (( len >= w )); then
            printf '%s' "${text[1,$w]}"
        else
            printf '%s%*s' "$text" $((w - len)) ''
        fi
    }

    # --- render screen (absolute positioning for stability) ---
    _jukebox_render() {
        local cols=$(tput cols) rows=$(tput lines)

        local path=$(_jukebox_get "path")
        [[ -z "$path" ]] && return

        local title=$(_jukebox_get "metadata/by-key/title")
        [[ -z "$title" ]] && title="${path##*/}" && title="${title%.flac}"
        local artist=$(_jukebox_get "metadata/by-key/artist")
        local album=$(_jukebox_get "metadata/by-key/album")
        local pl_pos=$(_jukebox_get_num "playlist-pos")
        local pl_count=$(_jukebox_get_num "playlist-count")
        local pos=$(_jukebox_get_num "time-pos")
        local dur=$(_jukebox_get_num "duration")
        local paused=$(_jukebox_get "pause")

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
        _padline "$(_center "$controls" $cols)" $cols
        printf '\e[0m'

        # row 3: song info
        printf '\e[3;1H'
        _padline "$(_center "$info" $cols)" $cols

        # row 4: album (or blank)
        printf '\e[4;1H'
        if [[ -n "$album" ]]; then
            _padline "$(_center "💿 $album" $cols)" $cols
        fi

        # row 5: track position
        printf '\e[5;1H'
        _padline "$(_center "$track_info" $cols)" $cols

        # album art (kitty graphics — start at row 7)
        local _art_line_count=0
        if [[ -n "$_jukebox_art_text" ]]; then
            printf '\e[7;1H%s' "$_jukebox_art_text"
        fi

        # progress at bottom
        printf '\e[%d;1H' "$rows"
        _padline "$(_center "${label}${bar}" $cols)" $cols

        # restore auto-wrap, show cursor, end sync
        printf '\e[?7h\e[?25h\e[?2026l'
    }

    # --- add to queue (Spotify style / play next) ---
    _jukebox_add_next() {
        # leave altscreen for fzf
        printf '\e[?1049l\e[?25h'
        stty sane 2>/dev/null

        # fetch all flac files under musicdir (sorted)
        local all_files=("${(@f)$(find "$musicdir" -name '*.flac' -type f | sort)}")

        local selected
        selected=$(printf '%s\n' "${all_files[@]}" | \
            fzf --multi \
                --prompt="Add Next: " \
                --header="TAB=toggle  ENTER=add to queue  ESC=cancel" \
                --marker="✔ " \
                --preview "$_jukebox_fzf_preview" \
                --preview-window=right:50%)

        # re-enter altscreen
        printf '\e[?1049h'
        stty -echo -icanon min 0 time 0 2>/dev/null

        [[ -z "$selected" ]] && return

        local files_to_add=("${(@f)${selected}}")
        (( ${#files_to_add[@]} == 0 )) && return

        local pl_pos=$(_jukebox_fast_get "playlist-pos")
        [[ -z "$pl_pos" ]] && pl_pos=0
        local target_pos=$((pl_pos + 1))

        # Append each file, then move it to the target position
        for f in "${files_to_add[@]}"; do
            # Add to end of queue
            _jukebox_set '{"command":["loadfile","'"$f"'","append"]}'
            sleep 0.1 # let mpv register the file in the playlist

            # Get new length
            local pl_len=$(_jukebox_fast_get "playlist-count")
            local last_idx=$((pl_len - 1))

            # Move from end to target pos if not already there
            if (( last_idx > target_pos )); then
                _jukebox_set '{"command":["playlist-move",'$last_idx','$target_pos']}'
            fi
            target_pos=$((target_pos + 1))
        done
    }

    # --- queue picker & editor ---
    _jukebox_queue_picker() {
        # function for fzf to reload the queue dynamically
        export _JUKEBOX_SOCK="$mpvsock"
        export -f _jukebox_fast_get 2>/dev/null || true
        
        # We need a small helper script we can call from fzf, because
        # exporting complex zsh functions to fzf's bash shell is messy.
        local script_dir=$(mktemp -d /tmp/jukebox-scripts-XXXXXX)
        local fetch_script="$script_dir/fetch.sh"
        local del_script="$script_dir/del.sh"

        cat << 'EOF' > "$fetch_script"
#!/usr/bin/env bash
pl_json=$(echo '{"command":["get_property","playlist"]}' | socat -t 0.5 - UNIX-CONNECT:"$_JUKEBOX_SOCK" 2>/dev/null)
count=$(echo "$pl_json" | jq -r '.data | length // 0' 2>/dev/null)
(( count == 0 )) && exit 0
echo "$pl_json" | jq -r '.data | to_entries[] | "\(.value.current // false)\t\(.key)\t\(.value.filename)"' 2>/dev/null | {
    while IFS=$'\t' read -r is_current idx fp; do
        name="${fp##*/}"; name="${name%.flac}"
        marker="  "
        [[ "$is_current" == "true" ]] && marker="▶ "
        echo "${marker}$((idx + 1))) $name"
    done
}
EOF
        cat << 'EOF' > "$del_script"
#!/usr/bin/env bash
# $1 is the selected line (e.g. "  3) Song Name")
num=$(echo "$1" | grep -o -E '[0-9]+' | head -n 1)
if [[ -n "$num" ]]; then
    idx=$((num - 1))
    echo "{\"command\":[\"playlist-remove\",$idx]}" | socat -t 0.5 - UNIX-CONNECT:"$_JUKEBOX_SOCK" >/dev/null 2>&1
fi
EOF
        chmod +x "$fetch_script" "$del_script"

        # leave altscreen for fzf
        printf '\e[?1049l\e[?25h'
        stty sane 2>/dev/null

        # Run fzf using the fetch script as the initial input AND the reload command
        local result
        result=$("$fetch_script" | fzf \
            --prompt='Queue: ' \
            --header=$'Current: ▶ \nENTER = Jump to song\nDEL = Remove from queue\nESC = Cancel' \
            --bind "delete:execute-silent($del_script {})" \
            --bind "delete:+reload($fetch_script)" \
            --bind "backspace:execute-silent($del_script {})" \
            --bind "backspace:+reload($fetch_script)")

        # re-enter altscreen
        printf '\e[?1049h'
        stty -echo -icanon min 0 time 0 2>/dev/null

        rm -rf "$script_dir"

        if [[ -n "$result" ]]; then
            local num=${result##*▶ }
            num=${result%%)*}
            num=${num##* }
            num=${num//[^0-9]/}
            if [[ -n "$num" ]]; then
                _jukebox_set '{"command":["set_property","playlist-pos",'$((num - 1))']}'
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
        cur_path=$(_jukebox_get "path")
        [[ -z "$cur_path" ]] && sleep 0.2
        _retries=$((_retries + 1))
    done
    if [[ -n "$cur_path" ]]; then
        _jukebox_extract_art "$cur_path"
        _jukebox_cache_art
    fi
    _jukebox_render

    # fast property getter using socat (avoids python overhead for simple queries)
    _jukebox_fast_get() {
        echo "{\"command\":[\"get_property\",\"$1\"]}" | socat -t 0.5 - UNIX-CONNECT:"$mpvsock" 2>/dev/null | jq -r '.data // empty' 2>/dev/null
    }

    # track state for change detection
    local last_path="$cur_path"
    local last_cols=$(tput cols) last_rows=$(tput lines)
    local last_paused=""
    local force_redraw=1

    # raw terminal mode for keypress reading
    stty -echo -icanon min 0 time 0 2>/dev/null

    # main display loop (runs ~4 times a second for real-time bar)
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

        # 2. Check for environment changes (resize)
        local new_cols=$(tput cols) new_rows=$(tput lines)
        if [[ "$new_cols" != "$last_cols" || "$new_rows" != "$last_rows" ]]; then
            last_cols=$new_cols; last_rows=$new_rows
            _jukebox_cache_art
            force_redraw=1
        fi

        # 3. Check for Track/State Changes (Fast poll)
        local cur_path=$(_jukebox_fast_get "path")
        local cur_paused=$(_jukebox_fast_get "pause")

        if [[ -n "$cur_path" && "$cur_path" != "$last_path" ]]; then
            last_path="$cur_path"
            _jukebox_extract_art "$cur_path"
            _jukebox_cache_art
            force_redraw=1
        fi

        if [[ "$cur_paused" != "$last_paused" ]]; then
            last_paused="$cur_paused"
            # Pause state changes the icon, we can do a partial redraw for just that
            # but simplest is to just flag it - or we handle it in the fast path below
            # Let's handle it in the fast path so we don't flicker art
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
                _padline "$(_center "${label}${bar}" $last_cols)" $last_cols
                # show cursor, restore cursor, restore auto-wrap
                printf '\e[?25h\e8\e[?7h'
            fi
        fi

        # 5. Sleep for next tick
        sleep 0.25
    done
}
