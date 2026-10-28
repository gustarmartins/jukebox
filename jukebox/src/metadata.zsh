    _jukebox_extract_art() {
        local filepath="$1"
        command rm -f "$coverfile" 2>/dev/null
        if [[ "$filepath" == http://* || "$filepath" == https://* ]]; then
            "$_JUKEBOX_PYTHON" "$_JUKEBOX_JELLYFIN_CLIENT" art "$filepath" "$coverfile" >/dev/null 2>&1
        else
            ffmpeg -y -v quiet -i "$filepath" -an -vcodec mjpeg -frames:v 1 "$coverfile" 2>/dev/null
            if [[ ! -s "$coverfile" ]]; then
                local _folder="${filepath:h}"
                local _folder_art=("$_folder"/*.(#i)(jpg|jpeg|png)(N))
                if [[ ${#_folder_art[@]} -gt 0 && -s "${_folder_art[1]}" ]]; then
                    cp "${_folder_art[1]}" "$coverfile" 2>/dev/null
                fi
            fi
        fi
        if [[ ! -s "$coverfile" ]]; then
            cp "$_JUKEBOX_SCRIPT_DIR/assets/NO-COVER.png" "$coverfile" 2>/dev/null
        fi
    }

    _jukebox_cache_art() {
        _jukebox_calc_layout
        if [[ -s "$coverfile" ]]; then
            _jukebox_art_text=$(chafa --size "${_layout_art_w}x${_layout_art_h}" "$coverfile" 2>/dev/null)
        else
            _jukebox_art_text=""
        fi
    }

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

    _jukebox_fetch_next_meta() {
        local next_file="$1"
        local next_item_id="$2"

        command rm -f "$coverfile_next" 2>/dev/null
        if [[ "$next_file" == http://* || "$next_file" == https://* ]]; then
            "$_JUKEBOX_PYTHON" "$_JUKEBOX_JELLYFIN_CLIENT" art "$next_file" "$coverfile_next" >/dev/null 2>&1
            if [[ ! -s "$coverfile_next" ]]; then
                cp "$_JUKEBOX_SCRIPT_DIR/assets/NO-COVER.png" "$coverfile_next" 2>/dev/null
            fi
            _jukebox_cache_next_art

            local _remote_meta
            local _r_title _r_artist _r_album _r_date _r_dur _r_track _r_disc
            _remote_meta=$("$_JUKEBOX_PYTHON" "$_JUKEBOX_JELLYFIN_CLIENT" cache-row --cache "$cachefile" "$next_file" 2>/dev/null)
            IFS=$'\x1f' read -r _r_title _r_artist _r_album _r_date _r_dur _r_track _r_disc <<< "$_remote_meta"
            _jukebox_next_title="$_r_title"
            _jukebox_next_artist="$_r_artist"
            _jukebox_next_album="$_r_album"
            _jukebox_next_date="$_r_date"
            _jukebox_next_genre=""
            _jukebox_next_quality="Jellyfin · Direct stream"
            _jukebox_next_size=""
            if [[ -n "$_r_dur" ]]; then
                local _rdur_i=${_r_dur%.*}
                _jukebox_next_dur=$(printf "%02d:%02d" $((_rdur_i / 60)) $((_rdur_i % 60)))
            else
                _jukebox_next_dur=""
            fi
            if [[ -n "$next_item_id" && -f "$queuefile" ]] && grep -qxF "$next_item_id" "$queuefile" 2>/dev/null; then
                _jukebox_next_source="queued"
            else
                _jukebox_next_source="library"
            fi
            return
        fi
        ffmpeg -y -v quiet -i "$next_file" -an -vcodec mjpeg -frames:v 1 "$coverfile_next" 2>/dev/null
        if [[ ! -s "$coverfile_next" ]]; then
            local _next_folder="${next_file:h}"
            local _next_folder_art=("$_next_folder"/*.(#i)(jpg|jpeg|png)(N))
            if [[ ${#_next_folder_art[@]} -gt 0 && -s "${_next_folder_art[1]}" ]]; then
                cp "${_next_folder_art[1]}" "$coverfile_next" 2>/dev/null
            fi
        fi
        if [[ ! -s "$coverfile_next" ]]; then
            cp "$_JUKEBOX_SCRIPT_DIR/assets/NO-COVER.png" "$coverfile_next" 2>/dev/null
        fi
        _jukebox_cache_next_art

        local _next_details
        _next_details=$("$_JUKEBOX_PYTHON" "$_JUKEBOX_SCRIPT_DIR/src/library.py" details "$next_file" "$cachefile")
        IFS=$'\x1f' read -r _jukebox_next_title _jukebox_next_artist _jukebox_next_album \
            _jukebox_next_dur _jukebox_next_quality _jukebox_next_size \
            _jukebox_next_genre _jukebox_next_date <<< "$_next_details"

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
