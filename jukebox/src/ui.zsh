    _jukebox_calc_layout() {
        local cols=$(tput cols 2>/dev/null) rows=$(tput lines 2>/dev/null)
        [[ -z "$cols" || "$cols" -le 0 ]] && cols=80
        [[ -z "$rows" || "$rows" -le 0 ]] && rows=24
        _layout_cols=$cols
        _layout_rows=$rows

        # --- Header mode based on available rows ---
        # Title, Artist, and Album MUST always show up.
        if (( rows <= 14 )); then
            _layout_mode="minimal"    # 2 rows: Title+Artist, Album+Track
            _layout_header_rows=2
        elif (( rows <= 22 )); then
            _layout_mode="compact"    # 3 rows: Controls, Title+Artist+Track, Album
            _layout_header_rows=3
        else
            _layout_mode="normal"     # 5 rows: Controls1, Controls2, Title+Artist, Album, Track
            _layout_header_rows=5
        fi

        # Progress bar takes 1 row at the bottom
        _layout_content_bottom=$(( rows - 1 ))

        # Art starts immediately after header (+1 row gap if space allows)
        _layout_art_start_row=$(( _layout_header_rows + 1 ))

        # Available space for body content between header and progress bar
        local avail_rows=$(( _layout_content_bottom - _layout_art_start_row ))
        (( avail_rows < 3 )) && avail_rows=3

        # --- Side-by-Side Layout Strategy ---
        # Fits main cover on the left and next song cover on the right down to small window sizes (~40 cols)
        if (( cols >= 40 && avail_rows >= 3 )); then
            _layout_next_mode="side"

            # Divide available width between left (main art) and right (next panel)
            local left_zone_w=$(( (cols * 52) / 100 ))
            (( left_zone_w < 18 )) && left_zone_w=18
            local right_zone_w=$(( cols - left_zone_w - 1 ))
            if (( right_zone_w < 16 )); then
                right_zone_w=16
                left_zone_w=$(( cols - right_zone_w - 1 ))
            fi

            # Main Art dimensions: target ~85% of left_zone_w
            _layout_art_w=$(( (left_zone_w * 85) / 100 ))
            (( _layout_art_w < 10 )) && _layout_art_w=10
            (( _layout_art_w % 2 != 0 )) && _layout_art_w=$(( _layout_art_w - 1 ))

            _layout_art_h=$(( _layout_art_w / 2 ))
            if (( _layout_art_h > avail_rows )); then
                _layout_art_h=$avail_rows
                _layout_art_w=$(( _layout_art_h * 2 ))
            fi
            (( _layout_art_h < 3 )) && _layout_art_h=3
            (( _layout_art_w < 6 )) && _layout_art_w=6

            # Center Main Art inside the left zone
            _layout_art_x=$(( 1 + (left_zone_w - _layout_art_w) / 2 ))
            (( _layout_art_x < 1 )) && _layout_art_x=1

            # Next Panel position & dimensions
            _layout_next_x=$(( left_zone_w + 2 ))
            _layout_next_y=$_layout_art_start_row

            # Next Cover Art: smaller cover on the right (~60% width of main cover)
            _layout_next_art_w=$(( (_layout_art_w * 60) / 100 ))
            (( _layout_next_art_w < 8 )) && _layout_next_art_w=8
            (( _layout_next_art_w % 2 != 0 )) && _layout_next_art_w=$(( _layout_next_art_w - 1 ))

            _layout_next_art_h=$(( _layout_next_art_w / 2 ))
            local max_next_art_h=$(( avail_rows - 3 ))
            (( max_next_art_h < 2 )) && max_next_art_h=2
            if (( _layout_next_art_h > max_next_art_h )); then
                _layout_next_art_h=$max_next_art_h
                _layout_next_art_w=$(( _layout_next_art_h * 2 ))
            fi
            (( _layout_next_art_h < 2 )) && _layout_next_art_h=2
            (( _layout_next_art_w < 4 )) && _layout_next_art_w=4

            # Center Next Art inside the right zone
            _layout_next_art_x=$(( _layout_next_x + (right_zone_w - _layout_next_art_w) / 2 ))
            (( _layout_next_art_x < _layout_next_x )) && _layout_next_art_x=$_layout_next_x

        else
            # Extremely narrow window: center main art, stack next if vertical space permits
            _layout_art_w=$(( cols - 2 ))
            (( _layout_art_w < 4 )) && _layout_art_w=4
            (( _layout_art_w % 2 != 0 )) && _layout_art_w=$(( _layout_art_w - 1 ))

            _layout_art_h=$(( _layout_art_w / 2 ))
            (( _layout_art_h > avail_rows )) && _layout_art_h=$avail_rows
            (( _layout_art_h < 3 )) && _layout_art_h=3

            _layout_art_x=$(( 1 + (cols - _layout_art_w) / 2 ))
            (( _layout_art_x < 1 )) && _layout_art_x=1

            local below_space=$(( avail_rows - _layout_art_h ))
            if (( below_space >= 4 )); then
                _layout_next_mode="below"
                _layout_next_x=2
                _layout_next_y=$(( _layout_art_start_row + _layout_art_h + 1 ))

                _layout_next_art_w=$(( cols / 3 ))
                (( _layout_next_art_w < 8 )) && _layout_next_art_w=8
                (( _layout_next_art_w % 2 != 0 )) && _layout_next_art_w=$(( _layout_next_art_w - 1 ))
                _layout_next_art_h=$(( _layout_next_art_w / 2 ))
                _layout_next_art_x=$(( 1 + (cols - _layout_next_art_w) / 2 ))
            else
                _layout_next_mode="hidden"
                _layout_next_art_w=0
                _layout_next_art_h=0
                _layout_next_art_x=$_layout_next_x
            fi
        fi
    }

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

    _jukebox_padline() {
        local text="$1" w="$2"
        local len=${#text}
        if (( len >= w )); then
            printf '%s' "${text[1,$w]}"
        else
            printf '%s%*s' "$text" $((w - len)) ''
        fi
    }

    _jukebox_render_next_panel() {
        local nx=$1 ny=$2 max_y=$3 max_w=$4
        local q_y=$ny

        # Title label
        local _title_label="📋 Up Next"
        [[ "$_jukebox_next_source" == "queued" ]] && _title_label="📋 Queued Next"
        (( _nav_offset > 0 )) && _title_label="$_title_label (+$_nav_offset)"
        (( q_y > max_y )) && return

        local centered_title="$(_jukebox_center "$_title_label" $max_w)"
        printf '\e[%d;%dH\e[1m%s\e[0m' "$q_y" "$nx" "$centered_title"
        q_y=$((q_y + 1))

        if [[ -n "$_jukebox_last_next_file" ]]; then
            # Render Next Cover Art centered inside the right zone
            if [[ -n "$_jukebox_next_art_text" ]]; then
                local start_q_y=$q_y
                local art_lines=("${(@f)_jukebox_next_art_text}")
                for l in "${art_lines[@]}"; do
                    (( q_y > max_y )) && break
                    printf '\e[%d;%dH%s' "$q_y" "${_layout_next_art_x:-$nx}" "$l"
                    q_y=$((q_y + 1))
                done
                local visual_end=$(( start_q_y + _layout_next_art_h ))
                (( q_y < visual_end )) && q_y=$visual_end
            fi

            q_y=$((q_y + 1))
            local max_len=$((max_w - 1))
            (( max_len < 8 )) && max_len=8

            # Metadata lines centered cleanly under next art
            local _meta_lines=()
            [[ -n "$_jukebox_next_title" ]] && _meta_lines+=("${_jukebox_next_title}")
            [[ -n "$_jukebox_next_artist" ]] && _meta_lines+=("${_jukebox_next_artist}")
            local _t_album="${_jukebox_next_album:-}"
            [[ -n "$_jukebox_next_date" ]] && _t_album="$_t_album (${_jukebox_next_date})"
            [[ -n "$_t_album" ]] && _meta_lines+=("💿 $_t_album")
            [[ -n "$_jukebox_next_dur" ]] && _meta_lines+=("⏱️ $_jukebox_next_dur")
            [[ -n "$_jukebox_next_quality" ]] && _meta_lines+=("$_jukebox_next_quality")

            for ml in "${_meta_lines[@]}"; do
                (( q_y > max_y )) && break
                (( ${#ml} > max_len )) && ml="${ml[1,$((max_len - 2))]}.."
                local centered_ml="$(_jukebox_center "$ml" $max_w)"
                printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$nx" "$centered_ml"
                q_y=$((q_y + 1))
            done
        else
            # Loading or end-of-playlist message
            (( q_y <= max_y )) && {
                local next_idx=$((_render_pl_pos + 1 + _nav_offset))
                local status_msg="⏳ Loading..."
                (( next_idx >= _render_pl_count )) && status_msg="End of playlist"
                local centered_status="$(_jukebox_center "$status_msg" $max_w)"
                printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$nx" "$centered_status"
            }
        fi
    }

    _jukebox_render() {
        _jukebox_calc_layout
        local cols=$_layout_cols rows=$_layout_rows

        [[ -z "$_render_path" ]] && return

        local title="${_render_title}"
        [[ -z "$title" ]] && title="${_render_path##*/}" && title="${title%.flac}"
        local artist="${_render_artist:-Unknown Artist}"
        local album="${_render_album:-Unknown Album}"
        local pl_pos=${_render_pl_pos:-0}
        local pl_count=${_render_pl_count:-0}
        local pos=${_render_time_pos:-0}
        local dur=${_render_duration:-0}
        local paused="$_render_paused"

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
        if (( bar_w > 8 && dur_i > 0 )); then
            local filled=$((pos_i * bar_w / dur_i))
            (( filled > bar_w )) && filled=$bar_w
            local empty=$((bar_w - filled))
            bar=" [$(printf '━%.0s' {1..$filled} 2>/dev/null)$(printf '─%.0s' {1..$empty} 2>/dev/null)]"
        fi

        local speed="${_render_speed:-1.000000}"
        local pitch="${_render_pitch:-1.000000}"
        local apc="${_render_apc:-true}"
        local rt_mode="${_rt_mode:-tempo}"
        
        local speed_fmt pitch_fmt
        { LC_NUMERIC=C printf -v speed_fmt "%.2f" "$speed" } 2>/dev/null || speed_fmt="1.00"
        { LC_NUMERIC=C printf -v pitch_fmt "%.2f" "$pitch" } 2>/dev/null || pitch_fmt="1.00"
        [[ "$speed_fmt" == "0.00" ]] && speed_fmt="1.00"
        [[ "$pitch_fmt" == "0.00" ]] && pitch_fmt="1.00"
        
        local fx_str=""
        if [[ "$apc" == "false" ]]; then
            if [[ "$speed_fmt" != "1.00" ]]; then
                fx_str="(🌙 ${speed_fmt}x)"
            fi
        else
            local parts=()
            [[ "$speed_fmt" != "1.00" ]] && parts+=("⚡ ${speed_fmt}x")
            [[ "$pitch_fmt" != "1.00" ]] && parts+=("🎵 ${pitch_fmt}x")
            if (( ${#parts[@]} > 0 )); then
                fx_str="(${(j. .)parts})"
            fi
        fi

        local track_info="[$((pl_pos + 1)) / $pl_count]"

        # Begin synchronized terminal output (Kitty / iTerm double-buffering)
        printf '\e[?2026h'

        # Delete all kitty images from previous frame
        printf '\e_Ga=d;\e\\'

        # Disable auto-wrap, clear screen, hide cursor
        printf '\e[?7l\e[2J\e[?25l'

        # --- Adaptive Header ---
        # Title, Artist, Album are ALWAYS rendered & centered regardless of layout mode.
        if [[ "$_layout_mode" == "normal" ]]; then
            # Full header (5 rows): Controls1, Controls2, Title+Artist, Album, Track
            local controls1="SPACE=pause  ←→=seek  ↑↓=seek 30s  ,./<>=prev/next  [/]=adj  P=mode:${rt_mode}"
            local controls2="A=add next  L=queue  S=shuffle  N=new queue  Y=lyrics  j/k=nav  i=info  q=quit"
            printf '\e[1;1H\e[2m'
            _jukebox_padline "$(_jukebox_center "$controls1" $cols)" $cols
            printf '\e[2;1H'
            _jukebox_padline "$(_jukebox_center "$controls2" $cols)" $cols
            printf '\e[0m'
            printf '\e[3;1H'
            _jukebox_padline "$(_jukebox_center "♫  $title  —  $artist  $fx_str" $cols)" $cols
            printf '\e[4;1H'
            _jukebox_padline "$(_jukebox_center "💿  $album" $cols)" $cols
            printf '\e[5;1H'
            _jukebox_padline "$(_jukebox_center "$track_info" $cols)" $cols

        elif [[ "$_layout_mode" == "compact" ]]; then
            # Compact header (3 rows): Controls, Title+Artist+Track, Album
            local controls_compact="A=add  L=que  S=shuf  N=new  Y=lyr  j/k=nav  i=info  P=mode:${rt_mode}  q=quit"
            printf '\e[1;1H\e[2m'
            _jukebox_padline "$(_jukebox_center "$controls_compact" $cols)" $cols
            printf '\e[0m'
            printf '\e[2;1H\e[1m'
            _jukebox_padline "$(_jukebox_center "♫  $title  —  $artist  $track_info" $cols)" $cols
            printf '\e[0m\e[3;1H'
            _jukebox_padline "$(_jukebox_center "💿  $album" $cols)" $cols

        else
            # Minimal header (2 rows): Title+Artist, Album+Track
            printf '\e[1;1H\e[1m'
            _jukebox_padline "$(_jukebox_center "♫  $title  —  $artist" $cols)" $cols
            printf '\e[0m\e[2;1H'
            _jukebox_padline "$(_jukebox_center "💿  $album  $track_info" $cols)" $cols
        fi

        if (( _lyrics_mode )); then
            _jukebox_render_lyrics "$cols" "$_layout_art_start_row" "$((rows - 1))"
        else
            # --- Main Album Art (Centered in left section) ---
            if [[ -n "$_jukebox_art_text" ]]; then
                local r=$_layout_art_start_row
                local art_lines=("${(@f)_jukebox_art_text}")
                for l in "${art_lines[@]}"; do
                    (( r > _layout_content_bottom )) && break
                    printf '\e[%d;%dH%s' "$r" "${_layout_art_x:-1}" "$l"
                    r=$((r + 1))
                done
            fi

            # --- "Up Next" panel with next song cover (Centered in right section) ---
            if [[ -n "$pl_pos" && "$_layout_next_mode" != "hidden" ]]; then
                local panel_max_y=$(( rows - 1 ))
                local right_zone_w=$(( cols - _layout_next_x ))
                _jukebox_render_next_panel "$_layout_next_x" "$_layout_next_y" "$panel_max_y" "$right_zone_w"
            fi
        fi

        # --- Progress bar (Centered at bottom row) ---
        printf '\e[%d;1H' "$rows"
        _jukebox_padline "$(_jukebox_center "${label}${bar}" $cols)" $cols

        # Restore auto-wrap, end sync
        printf '\e[?7h\e[?2026l'
    }
