    _jukebox_extract_art() {
        local filepath="$1"
        command rm -f "$coverfile" 2>/dev/null
        ffmpeg -y -v quiet -i "$filepath" -an -vcodec mjpeg -frames:v 1 "$coverfile" 2>/dev/null
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
        ffmpeg -y -v quiet -i "$next_file" -an -vcodec mjpeg -frames:v 1 "$coverfile_next" 2>/dev/null
        if [[ ! -s "$coverfile_next" ]]; then
            cp "$_JUKEBOX_SCRIPT_DIR/assets/NO-COVER.png" "$coverfile_next" 2>/dev/null
        fi
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
