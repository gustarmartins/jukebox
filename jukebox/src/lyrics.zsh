    # Lyrics are loaded once per track.  The normal 20 Hz input loop never
    # performs network or ffprobe work; synchronized views redraw only when the
    # active lyric line changes.
    _jukebox_load_lyrics() {
        local reference="$1"
        local start text
        _lyrics_starts=()
        _lyrics_lines=()
        _lyrics_loaded_path="$reference"
        _lyrics_active_index=0
        while IFS=$'\x1f' read -r start text; do
            [[ -z "$text" ]] && continue
            _lyrics_starts+=("${start:--1}")
            _lyrics_lines+=("$text")
        done < <("$_JUKEBOX_PYTHON" "$_JUKEBOX_JELLYFIN_CLIENT" lyrics "$reference" 2>/dev/null)
        _jukebox_update_lyric_index
    }

    _jukebox_update_lyric_index() {
        local pos=${_render_time_pos:-0}
        local pos_whole=${pos%.*}
        [[ -z "$pos_whole" ]] && pos_whole=0
        local pos_ms=$(( pos_whole * 1000 ))
        local found=0 i start
        if (( ${#_lyrics_lines[@]} == 0 )); then
            _lyrics_active_index=0
            return
        fi
        if (( ${_lyrics_starts[1]:--1} < 0 )); then
            (( _lyrics_active_index < 1 )) && _lyrics_active_index=1
            return
        fi
        for (( i=1; i<=${#_lyrics_starts[@]}; i++ )); do
            start=${_lyrics_starts[$i]:--1}
            (( start <= pos_ms )) && found=$i || break
        done
        (( found == 0 )) && found=1
        _lyrics_active_index=$found
    }

    _jukebox_render_lyrics() {
        local cols=$1 start_row=$2 end_row=$3
        local available=$(( end_row - start_row + 1 ))
        (( available < 3 )) && return
        local center=${_lyrics_active_index:-1}
        local half=$(( (available - 2) / 2 ))
        local first=$(( center - half ))
        (( first < 1 )) && first=1
        local last=$(( first + available - 2 ))
        (( last > ${#_lyrics_lines[@]} )) && last=${#_lyrics_lines[@]}
        first=$(( last - available + 2 ))
        (( first < 1 )) && first=1

        printf '\e[%d;1H' "$start_row"
        _jukebox_padline "$(_jukebox_center "🎤 Lyrics" $cols)" $cols
        local row=$(( start_row + 1 )) i line prefix
        if (( ${#_lyrics_lines[@]} == 0 )); then
            printf '\e[%d;1H\e[2m' "$row"
            _jukebox_padline "$(_jukebox_center "No lyrics found" $cols)" $cols
            printf '\e[0m'
            return
        fi
        for (( i=first; i<=last && row<=end_row; i++ )); do
            line="${_lyrics_lines[$i]}"
            (( ${#line} > cols - 6 )) && line="${line[1,$((cols - 9))]}..."
            printf '\e[%d;1H' "$row"
            if (( i == center && ${_lyrics_starts[1]:--1} >= 0 )); then
                prefix="▶ $line"
                printf '\e[1;36m'
                _jukebox_padline "$(_jukebox_center "$prefix" $cols)" $cols
                printf '\e[0m'
            else
                printf '\e[2m'
                _jukebox_padline "$(_jukebox_center "$line" $cols)" $cols
                printf '\e[0m'
            fi
            row=$((row + 1))
        done
    }
