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
    s.settimeout(3)
    s.connect(sys.argv[1])
    s.sendall(b"{\"command\":[\"get_property\",\"playlist\"], \"request_id\": 777}\n")
    buf = b""
    while True:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                obj = json.loads(line)
            except: continue
            if obj.get("request_id") == 777:
                s.close()
                print(json.dumps(obj))
                sys.exit(0)
except Exception: pass
' "$_JUKEBOX_SOCK" 2>/dev/null)

if [[ -z "$pl_json" ]]; then
    printf '%s\t%s\n' "-" "⏹ No songs in playlist"
    printf '%s\t%s\n' "-" "━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
fi

# Parse playlist into entries using a single python call
"$_JUKEBOX_PYTHON" -c '
import sys, json, os

data = json.loads(sys.stdin.read() or "{}").get("data", [])
if not data:
    print("-\t⏹ No songs in playlist")
    print("-\t━━━━━━━━━━━━━━━━━━━━━━━━")
    sys.exit(0)

cache_file = os.environ.get("_JUKEBOX_CACHE", "")
queuefile = os.environ.get("_JUKEBOX_QUEUEFILE", "")
show_fmt = os.environ.get("_JUKEBOX_SHOW_FORMATNAMES", "0")

# Load cache for pretty names
cache = {}
if show_fmt == "1" and cache_file:
    try:
        with open(cache_file) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    cache[parts[0]] = parts[1] + " - " + parts[2]
    except: pass

# Load queue IDs
queue_ids = set()
if queuefile:
    try:
        with open(queuefile) as f:
            queue_ids = {line.strip() for line in f if line.strip()}
    except: pass

def resolve_name(fp):
    if fp in cache:
        return cache[fp]
    name = fp.rsplit("/", 1)[-1]
    if name.endswith(".flac"):
        name = name[:-5]
    return name

# Find current position
cur_pos = 0
for i, e in enumerate(data):
    if e.get("current"):
        cur_pos = i
        break

# Header line 1: Now Playing
now = None
for i, e in enumerate(data):
    if e.get("current"):
        now = e
        name = resolve_name(e.get("filename", ""))
        item_id = e.get("id", "-")
        print(f"{item_id}\t▶ {i+1}) {name}")
        break
if now is None:
    print("-\t⏹ No song playing")

# Header line 2: separator with upcoming count
up_count = sum(1 for i, e in enumerate(data) if i > cur_pos and not e.get("current"))
print(f"-\t━━━━━━━━━━━━ Up Next ({up_count}) ━━━━━━━━━━━━")

# Upcoming songs
for i, e in enumerate(data):
    if i > cur_pos:
        name = resolve_name(e.get("filename", ""))
        item_id = str(e.get("id", ""))
        marker = "♫" if item_id in queue_ids else "  "
        print(f"{item_id}\t{marker} {i+1}) {name}")
' <<< "$pl_json"
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
    s.settimeout(3)
    s.connect(sys.argv[1])
    s.sendall(json.dumps({"command": ["get_property", "playlist"], "request_id": 1}).encode() + b"\n")
    buf = b""
    while True:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try: obj = json.loads(line)
            except: continue
            if obj.get("request_id") == 1:
                for i, e in enumerate(obj.get("data", [])):
                    if e.get("id") == target_id:
                        s.sendall(json.dumps({"command": ["playlist-remove", i]}).encode() + b"\n")
                        break
                s.close()
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
    s.settimeout(3)
    s.connect(sys.argv[1])
    s.sendall(json.dumps({"command": ["get_property", "playlist"], "request_id": 1}).encode() + b"\n")
    buf = b""
    while True:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try: obj = json.loads(line)
            except: continue
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
                    s.close()
                    sys.exit(0)
                if direction == "up":
                    target = cur_idx - 1
                    if target <= cur_pos:
                        s.close()
                        sys.exit(0)
                else:
                    target = cur_idx + 1
                    if target >= len(data):
                        s.close()
                        sys.exit(0)
                s.sendall(json.dumps({"command": ["playlist-move", cur_idx, target]}).encode() + b"\n")
                s.close()
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
