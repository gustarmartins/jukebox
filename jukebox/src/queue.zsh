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
        local tmp_files=("${(@f)$(_jukebox_source_files name_asc)}")
        local input_list
        input_list=$(_jukebox_get_input_list "${tmp_files[@]}")

        local selected
        selected=$(echo "$input_list" | \
            fzf -i --multi \
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

    _jukebox_shuffle_upcoming() {
        export _JUKEBOX_SOCK="$mpvsock"
        "$_JUKEBOX_PYTHON" -c '
import socket, json, sys, os, random
sock_path = os.environ.get("_JUKEBOX_SOCK") or sys.argv[1]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(sock_path)
    s.sendall(b"{\"command\":[\"get_property\",\"playlist\"], \"request_id\": 888}\n")
    buf = b""
    pl_data = None
    while True:
        c = s.recv(65536)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try: obj = json.loads(line)
            except: continue
            if obj.get("request_id") == 888:
                pl_data = obj.get("data", [])
                break
        if pl_data is not None:
            break

    if not pl_data or len(pl_data) <= 1:
        s.close()
        sys.exit(0)

    cur_pos = 0
    for i, e in enumerate(pl_data):
        if e.get("current"):
            cur_pos = i
            break

    n = len(pl_data)
    upcoming_count = n - (cur_pos + 1)
    if upcoming_count <= 1:
        s.close()
        sys.exit(0)

    current_order = [e.get("id") for e in pl_data]
    upcoming_ids = list(current_order[cur_pos + 1:])
    random.shuffle(upcoming_ids)
    target_order = current_order[:cur_pos + 1] + upcoming_ids

    state = list(current_order)
    moves = []
    for target_pos in range(cur_pos + 1, n):
        target_id = target_order[target_pos]
        curr_pos_of_id = state.index(target_id)
        if curr_pos_of_id != target_pos:
            moves.append({"command": ["playlist-move", curr_pos_of_id, target_pos]})
            item = state.pop(curr_pos_of_id)
            state.insert(target_pos, item)

    if moves:
        payload = "".join(json.dumps(m) + "\n" for m in moves).encode()
        s.sendall(payload)

    s.close()
except Exception:
    pass
' "$mpvsock" 2>/dev/null

        _jukebox_last_next_file=""
        _jukebox_next_retries=0
        _jukebox_clear_next_meta
        _jukebox_snapshot_playlist
        force_redraw=1
    }

    _jukebox_redo_queue() {
        # Temporarily leave altscreen and restore terminal
        printf '\e[?1049l\e[?25h'
        [[ -n "$saved_stty" ]] && stty "$saved_stty" 2>/dev/null

        echo ""
        echo "🎵 Redo Queue / Select Mode:"
        echo "  1) Browse & pick (plays from selection onward, Alt-s to shuffle rest)"
        echo "  2) Build queue (TAB to pick multiple, ENTER to play)"
        echo "  3) Shuffle entire library"
        echo "  4) Play all (A-Z)"
        echo "  5) Play all (by Date - newest first)"
        echo "  6) Play all (Original order)"
        echo "  q) Cancel (keep current playback)"
        echo ""

        local rchoice
        read "rchoice?Choose [1-6, q]: "

        local new_files=()
        case "$rchoice" in
            1)
                local all_files=("${(@f)$(_jukebox_source_files name_asc)}")
                if [[ ${#all_files[@]} -eq 0 ]]; then
                    echo "No music found in the $_jukebox_source library"
                    sleep 1
                    printf '\e[?1049h\e[2J\e[?25l'
                    stty -echo -icanon min 0 time 0 2>/dev/null
                    force_redraw=1
                    return
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

                local visual_paths
                visual_paths=$(echo "$input_list" | cut -f1)
                all_files=("${(@f)visual_paths}")

                echo "default" > "/tmp/jukebox-sort-state-$$"
                local output
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
                    printf '\e[?1049h\e[2J\e[?25l'
                    stty -echo -icanon min 0 time 0 2>/dev/null
                    force_redraw=1
                    return
                fi

                local key_pressed=$(echo "$output" | head -n 1)
                local selected=$(echo "$output" | sed '1d')
                if [[ -z "$selected" ]]; then
                    command rm -rf "$_fzf_sort_dir"
                    printf '\e[?1049h\e[2J\e[?25l'
                    stty -echo -icanon min 0 time 0 2>/dev/null
                    force_redraw=1
                    return
                fi

                local current_sort
                current_sort=$(cat "/tmp/jukebox-sort-state-$$" 2>/dev/null)
                if [[ -n "$current_sort" && "$current_sort" != "default" && -s "$cachefile" ]]; then
                    local sorted_paths
                    sorted_paths=$("$_fzf_sort_dir/$current_sort.sh" | cut -f1)
                    all_files=("${(@f)sorted_paths}")
                fi
                command rm -rf "$_fzf_sort_dir"

                local picked_arr=("${(@f)${$(echo "$selected" | cut -f1)}}")
                local last_picked="${picked_arr[-1]}"
                local last_idx=-1
                for i in {1..${#all_files[@]}}; do
                    [[ "${all_files[$i]}" == "$last_picked" ]] && { last_idx=$i; break; }
                done

                new_files=("${picked_arr[@]}")
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
                    new_files+=("${remaining_files[@]}")
                fi
                ;;
            2)
                local all_files=("${(@f)$(_jukebox_source_files name_asc)}")
                if [[ ${#all_files[@]} -eq 0 ]]; then
                    echo "No music found in the $_jukebox_source library"
                    sleep 1
                    printf '\e[?1049h\e[2J\e[?25l'
                    stty -echo -icanon min 0 time 0 2>/dev/null
                    force_redraw=1
                    return
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
                    printf '\e[?1049h\e[2J\e[?25l'
                    stty -echo -icanon min 0 time 0 2>/dev/null
                    force_redraw=1
                    return
                fi
                new_files=("${(@f)${$(echo "$selected" | cut -f1)}}")
                ;;
            3)
                local -a _tmp=("${(@f)$(_jukebox_source_files original)}")
                local i j tmp_val
                for ((i=${#_tmp[@]}; i>1; i--)); do
                    j=$((RANDOM % i + 1))
                    tmp_val="${_tmp[$i]}"
                    _tmp[$i]="${_tmp[$j]}"
                    _tmp[$j]="$tmp_val"
                done
                new_files=("${_tmp[@]}")
                ;;
            4) new_files=("${(@f)$(_jukebox_source_files name_asc)}") ;;
            5) new_files=("${(@f)$(_jukebox_source_files date_desc)}") ;;
            6) new_files=("${(@f)$(_jukebox_source_files original)}") ;;
            *)
                # Cancel or invalid option: return cleanly to current playback
                printf '\e[?1049h\e[2J\e[?25l'
                stty -echo -icanon min 0 time 0 2>/dev/null
                force_redraw=1
                return
                ;;
        esac

        if [[ ${#new_files[@]} -gt 0 ]]; then
            printf '%s\n' "${new_files[@]}" > "$playlist"
            : > "$queuefile"

            local cmd
            cmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["loadlist", sys.argv[1], "replace"]}))' "$playlist" 2>/dev/null)
            _jukebox_set "$cmd"

            _nav_offset=0
            _jukebox_last_next_file=""
            _jukebox_next_retries=0
            _jukebox_clear_next_meta
            _lyrics_loaded_path=""
            _lyrics_starts=(); _lyrics_lines=(); _lyrics_active_index=0
            last_path=""
            _render_path=""

            sleep 0.2
            _render_path=$(_jukebox_batch_get "path")
            if [[ -n "$_render_path" ]]; then
                _jukebox_extract_art "$_render_path"
                _jukebox_cache_art
            fi
            _jukebox_snapshot_playlist
            _jukebox_save_state
        fi

        # Restore altscreen and raw terminal mode
        printf '\e[?1049h\e[2J\e[?25l'
        stty -echo -icanon min 0 time 0 2>/dev/null
        force_redraw=1
    }

    _jukebox_queue_picker() {
        export _JUKEBOX_SOCK="$mpvsock"
        export _JUKEBOX_QUEUEFILE="$queuefile"

        local script_dir=$(mktemp -d /tmp/jukebox-scripts-XXXXXX)
        local fetch_script="$script_dir/fetch.sh"
        local del_script="$script_dir/del.sh"
        local move_script="$script_dir/move.sh"
        local shuffle_script="$script_dir/shuffle.sh"
        local clear_script="$script_dir/clear.sh"

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
    elif name.endswith(".mp3"):
        name = name[:-4]
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

        # --- shuffle script: shuffles all upcoming songs in-place ---
        cat << 'SHUFFLEEOF' > "$shuffle_script"
#!/usr/bin/env bash
"$_JUKEBOX_PYTHON" -c '
import socket, json, sys, random
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(sys.argv[1])
    s.sendall(b"{\"command\":[\"get_property\",\"playlist\"], \"request_id\": 888}\n")
    buf = b""
    pl_data = None
    while True:
        c = s.recv(65536)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try: obj = json.loads(line)
            except: continue
            if obj.get("request_id") == 888:
                pl_data = obj.get("data", [])
                break
        if pl_data is not None: break

    if not pl_data or len(pl_data) <= 1:
        s.close()
        sys.exit(0)

    cur_pos = 0
    for i, e in enumerate(pl_data):
        if e.get("current"):
            cur_pos = i
            break

    n = len(pl_data)
    if n - (cur_pos + 1) <= 1:
        s.close()
        sys.exit(0)

    current_order = [e.get("id") for e in pl_data]
    upcoming_ids = list(current_order[cur_pos + 1:])
    random.shuffle(upcoming_ids)
    target_order = current_order[:cur_pos + 1] + upcoming_ids

    state = list(current_order)
    moves = []
    for target_pos in range(cur_pos + 1, n):
        target_id = target_order[target_pos]
        curr_pos_of_id = state.index(target_id)
        if curr_pos_of_id != target_pos:
            moves.append({"command": ["playlist-move", curr_pos_of_id, target_pos]})
            item = state.pop(curr_pos_of_id)
            state.insert(target_pos, item)

    if moves:
        payload = "".join(json.dumps(m) + "\n" for m in moves).encode()
        s.sendall(payload)

    s.close()
except Exception: pass
' "$_JUKEBOX_SOCK" 2>/dev/null
SHUFFLEEOF

        # --- clear script: clears all upcoming tracks ---
        cat << 'CLEAREOF' > "$clear_script"
#!/usr/bin/env bash
"$_JUKEBOX_PYTHON" -c '
import socket, json, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(sys.argv[1])
    s.sendall(b"{\"command\":[\"get_property\",\"playlist\"], \"request_id\": 777}\n")
    buf = b""
    pl_data = None
    while True:
        c = s.recv(65536)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try: obj = json.loads(line)
            except: continue
            if obj.get("request_id") == 777:
                pl_data = obj.get("data", [])
                break
        if pl_data is not None: break

    if not pl_data:
        s.close()
        sys.exit(0)

    cur_pos = 0
    for i, e in enumerate(pl_data):
        if e.get("current"):
            cur_pos = i
            break

    n = len(pl_data)
    removes = []
    for idx in range(n - 1, cur_pos, -1):
        removes.append({"command": ["playlist-remove", idx]})

    if removes:
        payload = "".join(json.dumps(r) + "\n" for r in removes).encode()
        s.sendall(payload)

    s.close()
except Exception: pass
' "$_JUKEBOX_SOCK" 2>/dev/null

if [[ -f "$_JUKEBOX_QUEUEFILE" ]]; then
    : > "$_JUKEBOX_QUEUEFILE"
fi
CLEAREOF

        chmod +x "$fetch_script" "$del_script" "$move_script" "$shuffle_script" "$clear_script"

        # leave altscreen for fzf
        printf '\e[?1049l\e[?25h'
        [[ -n "$saved_stty" ]] && stty "$saved_stty" 2>/dev/null

        local output
        output=$("$fetch_script" | fzf -i \
            --delimiter=$'\t' --with-nth=2.. \
            --header-lines=2 \
            --prompt='Queue: ' \
            --header=$'ENTER = Jump  │  DEL = Remove  │  Alt+↑/↓ = Move  │  Alt+S = Shuffle  │  Alt+C = Clear  │  Alt+A = Add  │  Alt+R = Redo  │  ESC = Back' \
            --expect=alt-a,alt-r \
            --bind "delete:execute-silent($del_script {1})+reload($fetch_script)" \
            --bind "alt-up:execute-silent($move_script {1} up)+reload($fetch_script)" \
            --bind "alt-down:execute-silent($move_script {1} down)+reload($fetch_script)" \
            --bind "alt-s:execute-silent($shuffle_script)+reload($fetch_script)" \
            --bind "alt-c:execute-silent($clear_script)+reload($fetch_script)" \
            --no-sort)

        # re-enter altscreen
        printf '\e[?1049h\e[?25l'
        stty -echo -icanon min 0 time 0 2>/dev/null

        command rm -rf "$script_dir"

        [[ -z "$output" ]] && {
            _jukebox_last_next_file=""
            _jukebox_next_retries=0
            _jukebox_snapshot_playlist
            force_redraw=1
            return
        }

        local key_pressed=$(echo "$output" | head -n 1)
        local result=$(echo "$output" | sed '1d')

        if [[ "$key_pressed" == "alt-a" ]]; then
            _jukebox_add_next
            _jukebox_last_next_file=""
            _jukebox_next_retries=0
            _jukebox_snapshot_playlist
            force_redraw=1
            return
        elif [[ "$key_pressed" == "alt-r" ]]; then
            _jukebox_redo_queue
            return
        fi

        # Jump to selected song using stable ID
        if [[ -n "$result" ]]; then
            local selected_id=${result%%$'\t'*}
            [[ -z "$selected_id" || "$selected_id" == "-" ]] && {
                _jukebox_last_next_file=""
                _jukebox_next_retries=0
                _jukebox_snapshot_playlist
                force_redraw=1
                return
            }

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

        _jukebox_last_next_file=""
        _jukebox_next_retries=0
        _jukebox_snapshot_playlist
        force_redraw=1
    }
