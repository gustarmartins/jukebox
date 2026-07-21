    # ── Session persistence ────────────────────────────────────────────
    # State is rewritten atomically every couple of seconds while playing,
    # so a force-stop, OOM-kill, terminal crash or power loss still leaves a
    # resumable snapshot behind — nothing here depends on the exit trap.
    #
    # Both files live in $JUKEBOX_DATA_DIR (~/.jukebox-app), never in /tmp and
    # never in ~/.cache, so neither the startup orphan sweep nor a cache
    # cleaner can take them:
    #   session[-jellyfin].state  — key=value snapshot of playback position
    #   session[-jellyfin].m3u    — the playlist as mpv currently holds it

    # Dump mpv's live playlist (including queue edits) to the session m3u.
    _jukebox_snapshot_playlist() {
        [[ -n "$_jukebox_state_playlist" ]] || return
        local tmp="${_jukebox_state_playlist}.tmp.$$"
        "$_JUKEBOX_PYTHON" -c '
import socket, json, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(sys.argv[1])
    s.sendall(json.dumps({"command": ["get_property", "playlist"], "request_id": 901}).encode() + b"\n")
    buf = b""
    while True:
        c = s.recv(65536)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try: obj = json.loads(line)
            except: continue
            if obj.get("request_id") == 901:
                for e in (obj.get("data") or []):
                    fn = e.get("filename", "")
                    if fn: print(fn)
                s.close()
                sys.exit(0)
except Exception: pass
' "$mpvsock" > "$tmp" 2>/dev/null
        if [[ -s "$tmp" ]]; then
            command mv -f "$tmp" "$_jukebox_state_playlist" 2>/dev/null
        else
            command rm -f "$tmp" 2>/dev/null
        fi
    }

    # Write the playback snapshot. $1 = "clean" when called from cleanup.
    _jukebox_save_state() {
        [[ -n "$_jukebox_state_file" && -n "$_render_path" ]] || return
        local ended="${1:-running}"
        local tmp="${_jukebox_state_file}.tmp.$$"
        if {
            print -r -- "version=1"
            print -r -- "source=$_jukebox_source"
            print -r -- "ended=$ended"
            print -r -- "pos=${_render_pl_pos:-0}"
            print -r -- "count=${_render_pl_count:-0}"
            print -r -- "time=${_render_time_pos:-0}"
            print -r -- "duration=${_render_duration:-0}"
            print -r -- "speed=${_render_speed:-1.0}"
            print -r -- "pitch=${_render_pitch:-1.0}"
            print -r -- "apc=${_render_apc:-true}"
            print -r -- "rtmode=${_rt_mode:-tempo}"
            print -r -- "lyrics=${_lyrics_mode:-0}"
            print -r -- "path=$_render_path"
            print -r -- "title=$_render_title"
            print -r -- "artist=$_render_artist"
            print -r -- "album=$_render_album"
        } > "$tmp" 2>/dev/null; then
            command mv -f "$tmp" "$_jukebox_state_file" 2>/dev/null
        else
            command rm -f "$tmp" 2>/dev/null
        fi
    }

    # Populate the _resume_* variables. Returns 1 when there is nothing
    # usable to resume (no state, wrong source, empty playlist).
    _jukebox_load_state() {
        _resume_source=""; _resume_ended=""; _resume_pos=0; _resume_count=0
        _resume_time=0; _resume_duration=0; _resume_speed="1.0"; _resume_pitch="1.0"
        _resume_apc="true"; _resume_rtmode="tempo"; _resume_lyrics=0
        _resume_path=""; _resume_title=""; _resume_artist=""; _resume_album=""

        [[ -s "$_jukebox_state_file" && -s "$_jukebox_state_playlist" ]] || return 1

        local line key val
        while IFS= read -r line; do
            [[ "$line" == *=* ]] || continue
            key="${line%%=*}"
            val="${line#*=}"
            case "$key" in
                source)   _resume_source="$val" ;;
                ended)    _resume_ended="$val" ;;
                pos)      _resume_pos="$val" ;;
                count)    _resume_count="$val" ;;
                time)     _resume_time="$val" ;;
                duration) _resume_duration="$val" ;;
                speed)    _resume_speed="$val" ;;
                pitch)    _resume_pitch="$val" ;;
                apc)      _resume_apc="$val" ;;
                rtmode)   _resume_rtmode="$val" ;;
                lyrics)   _resume_lyrics="$val" ;;
                path)     _resume_path="$val" ;;
                title)    _resume_title="$val" ;;
                artist)   _resume_artist="$val" ;;
                album)    _resume_album="$val" ;;
            esac
        done < "$_jukebox_state_file"

        [[ "$_resume_source" == "$_jukebox_source" ]] || return 1
        [[ -n "$_resume_path" ]] || return 1
        # Sanitize anything used in arithmetic — a truncated write (power loss
        # mid-save is exactly what this feature exists for) must not blow up.
        [[ "$_resume_pos" == <-> ]] || _resume_pos=0
        [[ "$_resume_count" == <-> ]] || _resume_count=0
        [[ "$_resume_lyrics" == <-> ]] || _resume_lyrics=0
        [[ "${_resume_time%.*}" == <-> ]] || _resume_time=0
        [[ "${_resume_duration%.*}" == <-> ]] || _resume_duration=0
        return 0
    }

    # One-line human summary of the saved session, for the launch menu.
    _jukebox_resume_label() {
        local name="${_resume_title:-${_resume_path:t:r}}"
        [[ -n "$_resume_artist" ]] && name="$name — $_resume_artist"
        local t=${_resume_time%.*} d=${_resume_duration%.*}
        local at
        at=$(printf '%d:%02d' $((t / 60)) $((t % 60)))
        if (( d > 0 )); then
            at="$at/$(printf '%d:%02d' $((d / 60)) $((d % 60)))"
        fi
        local where="$at"
        if (( _resume_count > 0 )); then
            where="$where · track $((_resume_pos + 1))/$_resume_count"
        fi
        [[ "$_resume_ended" == "clean" ]] || where="$where · interrupted"
        print -r -- "$name  [$where]"
    }

    # Restore playback position and audio settings once mpv has the track
    # loaded. mpv was started paused, so the seek lands before any audio.
    _jukebox_apply_resume() {
        local t=${_resume_time%.*}
        if (( t > 0 )); then
            local cmd
            cmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["seek", float(sys.argv[1]), "absolute"]}))' "$_resume_time" 2>/dev/null)
            [[ -n "$cmd" ]] && _jukebox_set "$cmd"
        fi
        if [[ -n "$_resume_speed" && "$_resume_speed" != "1.0" ]]; then
            local scmd
            scmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["set_property", "speed", float(sys.argv[1])]}))' "$_resume_speed" 2>/dev/null)
            [[ -n "$scmd" ]] && _jukebox_set "$scmd"
        fi
        if [[ -n "$_resume_pitch" && "$_resume_pitch" != "1.0" ]]; then
            local pcmd
            pcmd=$("$_JUKEBOX_PYTHON" -c 'import sys, json; print(json.dumps({"command": ["set_property", "pitch", float(sys.argv[1])]}))' "$_resume_pitch" 2>/dev/null)
            [[ -n "$pcmd" ]] && _jukebox_set "$pcmd"
        fi
        if [[ "$_resume_apc" == "false" ]]; then
            _jukebox_set '{"command":["set_property","audio-pitch-correction",false]}'
        fi
        (( _lyrics_mode )) && _jukebox_load_lyrics "$_render_path"
        # Hand control back to the user: playback starts where it left off.
        _jukebox_set '{"command":["set_property","pause",false]}'
    }
