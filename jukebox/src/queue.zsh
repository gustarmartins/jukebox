    _jukebox_add_next() {
        # leave altscreen for fzf
        printf '\e[?1049l\e[?25h'
        [[ -n "$saved_stty" ]] && stty "$saved_stty" 2>/dev/null

        _jukebox_setup_fzf_sort

        local fzf_header="TAB=toggle  ENTER=add to queue  ESC=cancel"

        if [[ -s "$cachefile" ]]; then
            fzf_header="$fzf_header
─── Sort ↑  Alt: T=Title  A=Artist  B=Album  D=Date  L=Length ──
─── Sort ↓  Shift+Alt: T  A  B  D  L ──────────────────────────"
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

        command rm -rf "$_fzf_sort_dir"

        [[ -z "$selected" ]] && return

        local files_to_add=("${(@f)${$(echo "$selected" | cut -f1)}}")
        (( ${#files_to_add[@]} == 0 )) && return

        local pl_pos=$(_jukebox_fast_get "playlist-pos")
        [[ -z "$pl_pos" ]] && pl_pos=0
        local target_pos=$((pl_pos + 1))

        for f in "${files_to_add[@]}"; do
            # Build and send loadfile command, capturing response
            local cmd
            cmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["loadfile", sys.argv[1], "append"]}))' "$f" 2>/dev/null)
            [[ -z "$cmd" ]] && continue

            local response
            response=$(_jukebox_ipc "$cmd")

            # Extract playlist_entry_id from response (mpv 0.36+)
            local entry_id=""
            if [[ -n "$response" ]]; then
                entry_id=$(echo "$response" | "$_JUKEBOX_PYTHON" -c '
import sys, json
try:
    r = json.loads(sys.stdin.read() or "{}")
    d = r.get("data")
    if isinstance(d, dict):
        v = d.get("playlist_entry_id")
        if v is not None: print(v)
except: pass
' 2>/dev/null)
            fi

            # Get current playlist count (file was just appended to end)
            local cur_len=$(_jukebox_fast_get "playlist-count")
            [[ -z "$cur_len" || "$cur_len" == "0" ]] && continue
            local last_idx=$((cur_len - 1))

            # Fallback: get ID by index if response didn't include it
            if [[ -z "$entry_id" ]]; then
                entry_id=$(_jukebox_fast_get "playlist/$last_idx/id")
            fi

            # Track in queuefile for visual ♫ marker
            if [[ -n "$entry_id" ]]; then
                echo "$entry_id" >> "$queuefile"
            fi

            # Move from end to right after current song
            if (( last_idx > target_pos )); then
                cmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["playlist-move", int(sys.argv[1]), int(sys.argv[2])]}))' "$last_idx" "$target_pos" 2>/dev/null)
                [[ -n "$cmd" ]] && _jukebox_set "$cmd"
            fi
            target_pos=$((target_pos + 1))
        done
    }

    _jukebox_queue_picker() {
        export _JUKEBOX_SOCK="$mpvsock"
        export _JUKEBOX_QUEUEFILE="$queuefile"

        local script_dir=$(mktemp -d /tmp/jukebox-scripts-XXXXXX)
        local fetch_script="$script_dir/fetch.sh"
        local del_script="$script_dir/del.sh"
        local move_script="$script_dir/move.sh"

        # --- fetch script: outputs ID<tab>label lines ---
        # First 2 lines become fzf headers (Now Playing + separator)
        cat << 'FETCHEOF' > "$fetch_script"
#!/usr/bin/env bash
pl_json=$("$_JUKEBOX_PYTHON" -c '
import socket, json, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sys.argv[1])
    s.sendall(b"{\"command\":[\"get_property\",\"playlist\"], \"request_id\": 777}\n")
    buf = b""
    while True:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            obj = json.loads(line)
            if obj.get("request_id") == 777:
                print(json.dumps(obj))
                sys.exit(0)
except Exception: pass
' "$_JUKEBOX_SOCK" 2>/dev/null)

count=$(echo "$pl_json" | "$_JUKEBOX_PYTHON" -c 'import sys, json; d=json.loads(sys.stdin.read() or "{}").get("data", []); print(len(d))' 2>/dev/null)
if (( count == 0 )); then
    printf '%s\t%s\n' "-" "⏹ No songs in playlist"
    printf '%s\t%s\n' "-" "━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
fi

entries=$(echo "$pl_json" | "$_JUKEBOX_PYTHON" -c 'import sys, json; d=json.loads(sys.stdin.read() or "{}").get("data", []); print("\n".join(f"{str(x.get(\"current\", False)).lower()}\t{i}\t{x.get(\"filename\",\"\")}\t{x.get(\"id\",\"\")}" for i, x in enumerate(d)))' 2>/dev/null)

cur_pos=$(echo "$pl_json" | "$_JUKEBOX_PYTHON" -c 'import sys, json; d=json.loads(sys.stdin.read() or "{}").get("data", []); print(next((i for i, x in enumerate(d) if x.get("current")), 0))' 2>/dev/null)

resolve_name() {
    local fp="$1"
    if (( _JUKEBOX_SHOW_FORMATNAMES )) && [[ -s "$_JUKEBOX_CACHE" ]]; then
        local cached
        cached=$(grep -F "$fp" "$_JUKEBOX_CACHE" | head -n 1)
        if [[ -n "$cached" ]]; then
            local title artist
            title=$(echo "$cached" | cut -f2)
            artist=$(echo "$cached" | cut -f3)
            echo "${title} - ${artist}"
            return
        fi
    fi
    local name="${fp##*/}"; name="${name%.flac}"
    echo "$name"
}

# Header line 1: Now Playing
now_shown=0
while IFS=$'\t' read -r is_current idx fp item_id; do
    if [[ "$is_current" == "true" ]]; then
        name=$(resolve_name "$fp")
        printf '%s\t▶ %s) %s\n' "${item_id:--}" "$((idx + 1))" "$name"
        now_shown=1
    fi
done <<< "$entries"
(( now_shown )) || printf '%s\t%s\n' "-" "⏹ No song playing"

# Header line 2: separator with count
up_count=0
while IFS=$'\t' read -r is_current idx fp item_id; do
    [[ "$is_current" != "true" ]] && (( idx > cur_pos )) && up_count=$((up_count + 1))
done <<< "$entries"
printf '%s\t━━━━━━━━━━━━ Up Next (%s) ━━━━━━━━━━━━\n' "-" "$up_count"

# List items: ALL songs after current position
while IFS=$'\t' read -r is_current idx fp item_id; do
    if [[ "$is_current" != "true" ]] && (( idx > cur_pos )); then
        name=$(resolve_name "$fp")
        if [[ -n "$item_id" && -f "$_JUKEBOX_QUEUEFILE" ]] && grep -qxF "$item_id" "$_JUKEBOX_QUEUEFILE" 2>/dev/null; then
            printf '%s\t♫ %s) %s\n' "$item_id" "$((idx + 1))" "$name"
        else
            printf '%s\t   %s) %s\n' "$item_id" "$((idx + 1))" "$name"
        fi
    fi
done <<< "$entries"
FETCHEOF

        # --- delete script: resolves fresh index by stable ID, then removes ---
        cat << 'DELEOF' > "$del_script"
#!/usr/bin/env bash
item_id="$1"
[[ -z "$item_id" || "$item_id" == "-" ]] && exit 0

"$_JUKEBOX_PYTHON" -c '
import socket, json, sys
try:
    target_id = int(sys.argv[2])
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sys.argv[1])
    s.sendall(json.dumps({"command": ["get_property", "playlist"], "request_id": 1}).encode() + b"\n")
    buf = b""
    while True:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            obj = json.loads(line)
            if obj.get("request_id") == 1:
                for i, e in enumerate(obj.get("data", [])):
                    if e.get("id") == target_id:
                        s.sendall(json.dumps({"command": ["playlist-remove", i]}).encode() + b"\n")
                        break
                sys.exit(0)
except Exception: pass
' "$_JUKEBOX_SOCK" "$item_id" 2>/dev/null

# Remove from queuefile tracker
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
DELEOF

        # --- move script: resolves fresh index by stable ID, moves up/down ---
        cat << 'MOVEEOF' > "$move_script"
#!/usr/bin/env bash
item_id="$1"
dir="$2"
[[ -z "$item_id" || "$item_id" == "-" ]] && exit 0

"$_JUKEBOX_PYTHON" -c '
import socket, json, sys
try:
    target_id = int(sys.argv[2])
    direction = sys.argv[3]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sys.argv[1])
    s.sendall(json.dumps({"command": ["get_property", "playlist"], "request_id": 1}).encode() + b"\n")
    buf = b""
    while True:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            obj = json.loads(line)
            if obj.get("request_id") == 1:
                data = obj.get("data", [])
                cur_idx = None
                cur_pos = None
                for i, e in enumerate(data):
                    if e.get("id") == target_id:
                        cur_idx = i
                    if e.get("current"):
                        cur_pos = i
                if cur_idx is None or cur_pos is None:
                    sys.exit(0)
                if direction == "up":
                    target = cur_idx - 1
                    if target <= cur_pos:
                        sys.exit(0)
                else:
                    target = cur_idx + 1
                    if target >= len(data):
                        sys.exit(0)
                s.sendall(json.dumps({"command": ["playlist-move", cur_idx, target]}).encode() + b"\n")
                sys.exit(0)
except Exception: pass
' "$_JUKEBOX_SOCK" "$item_id" "$dir" 2>/dev/null
MOVEEOF

        chmod +x "$fetch_script" "$del_script" "$move_script"

        # leave altscreen for fzf
        printf '\e[?1049l\e[?25h'
        [[ -n "$saved_stty" ]] && stty "$saved_stty" 2>/dev/null

        local result
        result=$("$fetch_script" | fzf \
            --delimiter=$'\t' --with-nth=2.. \
            --header-lines=2 \
            --prompt='Queue: ' \
            --header=$'ENTER = Jump  │  DEL = Remove  │  Alt+↑/↓ = Move  │  ESC = Cancel' \
            --bind "delete:execute-silent($del_script {1})+reload($fetch_script)" \
            --bind "alt-up:execute-silent($move_script {1} up)+reload($fetch_script)" \
            --bind "alt-down:execute-silent($move_script {1} down)+reload($fetch_script)" \
            --no-sort)

        # re-enter altscreen
        printf '\e[?1049h\e[?25l'
        stty -echo -icanon min 0 time 0 2>/dev/null

        command rm -rf "$script_dir"

        # Jump to selected song using stable ID
        if [[ -n "$result" ]]; then
            local selected_id=${result%%$'\t'*}
            [[ -z "$selected_id" || "$selected_id" == "-" ]] && { force_redraw=1; return; }

            # Resolve fresh playlist index from stable ID
            local jump_idx
            jump_idx=$("$_JUKEBOX_PYTHON" -c '
import socket, json, sys
try:
    target_id = int(sys.argv[2])
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sys.argv[1])
    s.sendall(json.dumps({"command": ["get_property", "playlist"], "request_id": 1}).encode() + b"\n")
    buf = b""
    while True:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            obj = json.loads(line)
            if obj.get("request_id") == 1:
                for i, e in enumerate(obj.get("data", [])):
                    if e.get("id") == target_id:
                        print(i)
                        sys.exit(0)
except Exception: pass
' "$mpvsock" "$selected_id" 2>/dev/null)

            if [[ -n "$jump_idx" ]]; then
                local cmd
                cmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["set_property", "playlist-pos", int(sys.argv[1])]}))' "$jump_idx" 2>/dev/null)
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
