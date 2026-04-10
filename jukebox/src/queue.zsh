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
(( count == 0 )) && exit 0

# Find current position
cur_pos=$(echo "$pl_json" | "$_JUKEBOX_PYTHON" -c 'import sys, json; d=json.loads(sys.stdin.read() or "{}").get("data", []); print(next((i for i, x in enumerate(d) if x.get("current")), 0))' 2>/dev/null)

# Parse all entries (include id)
entries=$(echo "$pl_json" | "$_JUKEBOX_PYTHON" -c 'import sys, json; d=json.loads(sys.stdin.read() or "{}").get("data", []); print("\n".join(f"{str(x.get(\"current\", False)).lower()}\t{i}\t{x.get(\"filename\",\"\")}\t{x.get(\"id\",\"\")}" for i, x in enumerate(d)))' 2>/dev/null)

# Resolve display name from cache or fall back to filename
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

# --- Now Playing ---
while IFS=$'\t' read -r is_current idx fp item_id; do
    if [[ "$is_current" == "true" ]]; then
        name=$(resolve_name "$fp")
        echo "▶ $((idx + 1))) $name"
    fi
done <<< "$entries"

# --- Queue section (manually added songs) ---
queue_output=""
queue_count=0
while IFS=$'\t' read -r is_current idx fp item_id; do
    if [[ "$is_current" != "true" ]] && (( idx > cur_pos )); then
        if [[ -n "$item_id" && -f "$_JUKEBOX_QUEUEFILE" ]] && grep -qxF "$item_id" "$_JUKEBOX_QUEUEFILE" 2>/dev/null; then
            name=$(resolve_name "$fp")
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
            name=$(resolve_name "$fp")
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
    item_id=$("$_JUKEBOX_PYTHON" -c '
import socket, json, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sys.argv[1])
    idx = int(sys.argv[2])
    
    # 1. Get ID robustly
    s.sendall(json.dumps({"command": ["get_property", f"playlist/{idx}/id"], "request_id": 1}).encode() + b"\n")
    item_id = ""
    buf = b""
    got_id = False
    while not got_id:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            obj = json.loads(line)
            if obj.get("request_id") == 1:
                item_id = obj.get("data", "")
                got_id = True
                break
                
    # 2. Remove from playlist and exit
    s.sendall(json.dumps({"command": ["playlist-remove", idx]}).encode() + b"\n")
    print(item_id)
except Exception: pass
' "$_JUKEBOX_SOCK" "$idx" 2>/dev/null)

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

        command rm -rf "$script_dir"

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
