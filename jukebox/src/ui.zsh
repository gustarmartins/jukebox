    _jukebox_calc_layout() {
        local cols=$(tput cols) rows=$(tput lines)
        _layout_cols=$cols
        _layout_rows=$rows

        # --- Header mode based on available rows ---
        if (( rows <= 10 )); then
            _layout_mode="minimal"    # bare essentials only
            _layout_header_rows=1     # song info only
        elif (( rows <= 20 )); then
            _layout_mode="compact"    # condensed controls
            _layout_header_rows=3     # controls + info + track
        else
            _layout_mode="normal"     # full header
            _layout_header_rows=5     # controls1 + controls2 + info + album + track
        fi

        # Progress bar always takes 1 row at the bottom
        _layout_content_bottom=$(( rows - 1 ))

        # Art starts 1 row after header (gap row)
        _layout_art_start_row=$(( _layout_header_rows + 2 ))

        # Available space for content between header and progress bar
        local avail_rows=$(( _layout_content_bottom - _layout_art_start_row ))
        (( avail_rows < 0 )) && avail_rows=0

        # --- Determine layout strategy FIRST, then size art to fit ---
        # Strategy: if terminal is wide enough, do side-by-side and give art ~60% of width.
        # Otherwise, art gets full width and "Up Next" goes below or is hidden.

        local min_panel_w=30   # minimum width for Up Next panel

        if (( cols >= 66 && avail_rows >= 8 )); then
            # --- SIDE-BY-SIDE layout ---
            _layout_next_mode="side"

            # Art gets ~60% of width, panel gets the rest
            _layout_art_w=$(( (cols - 6) * 60 / 100 ))
            (( _layout_art_w < 20 )) && _layout_art_w=20
            # Ensure panel has at least min_panel_w
            local panel_w=$(( cols - _layout_art_w - 6 ))
            if (( panel_w < min_panel_w )); then
                _layout_art_w=$(( cols - min_panel_w - 6 ))
                (( _layout_art_w < 20 )) && _layout_art_w=20
                panel_w=$(( cols - _layout_art_w - 6 ))
            fi

            # Art height from width (2:1 ratio), capped to available rows
            _layout_art_h=$(( _layout_art_w / 2 ))
            (( _layout_art_h > avail_rows )) && _layout_art_h=$avail_rows
            (( _layout_art_h < 4 )) && _layout_art_h=4

            _layout_next_x=$(( _layout_art_w + 6 ))
            _layout_next_y=$_layout_art_start_row

            # Next art: 20x10 fixed target, scaled down if needed
            _layout_next_art_w=20
            (( _layout_next_art_w > panel_w - 2 )) && _layout_next_art_w=$((panel_w - 2))
            (( _layout_next_art_w < 8 )) && _layout_next_art_w=8
            _layout_next_art_h=$(( _layout_next_art_w / 2 ))
            local max_next_art_h=$(( avail_rows - 8 ))
            (( max_next_art_h < 3 )) && max_next_art_h=3
            (( _layout_next_art_h > max_next_art_h )) && _layout_next_art_h=$max_next_art_h
            (( _layout_next_art_h < 3 )) && _layout_next_art_h=3

        else
            # --- NO SIDE PANEL: art gets full width ---
            _layout_art_w=$(( cols - 2 ))
            (( _layout_art_w < 4 )) && _layout_art_w=4
            _layout_art_h=$(( _layout_art_w / 2 ))
            (( _layout_art_h > avail_rows )) && _layout_art_h=$avail_rows
            (( _layout_art_h < 4 )) && _layout_art_h=4

            local below_space=$(( _layout_content_bottom - _layout_art_start_row - _layout_art_h ))
            if (( below_space >= 5 && cols >= 30 )); then
                # Stacked: show "Up Next" below the main art
                _layout_next_mode="below"
                _layout_next_x=3
                _layout_next_y=$(( _layout_art_start_row + _layout_art_h + 1 ))

                _layout_next_art_w=$(( cols / 4 ))
                (( _layout_next_art_w > 20 )) && _layout_next_art_w=20
                (( _layout_next_art_w < 8 )) && _layout_next_art_w=8
                _layout_next_art_h=$(( _layout_next_art_w / 2 ))
                local max_below_art_h=$(( below_space - 3 ))
                (( max_below_art_h < 2 )) && max_below_art_h=2
                (( _layout_next_art_h > max_below_art_h )) && _layout_next_art_h=$max_below_art_h
                (( _layout_next_art_h < 2 )) && _layout_next_art_h=2
            else
                _layout_next_mode="hidden"
                _layout_next_art_w=0
                _layout_next_art_h=0
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
        local _title_label="📚 Up Next"
        [[ "$_jukebox_next_source" == "queued" ]] && _title_label="📋 Queued Next"
        (( _nav_offset > 0 )) && _title_label="$_title_label (+$_nav_offset)"
        (( q_y > max_y )) && return
        printf '\e[%d;%dH\e[1m%s\e[0m' "$q_y" "$nx" "$_title_label"
        q_y=$((q_y + 2))

        if [[ -n "$_jukebox_last_next_file" ]]; then
            # Art — with Kitty graphics protocol, chafa may output only 1 text
            # line but the image visually spans _layout_next_art_h rows.
            # We must advance q_y by the VISUAL height, not the text line count.
            if [[ -n "$_jukebox_next_art_text" ]]; then
                local start_q_y=$q_y
                local art_lines=("${(@f)_jukebox_next_art_text}")
                for l in "${art_lines[@]}"; do
                    (( q_y > max_y )) && break
                    printf '\e[%d;%dH%s' "$q_y" "$nx" "$l"
                    q_y=$((q_y + 1))
                done
                # Ensure cursor advances past the visual image height
                local visual_end=$(( start_q_y + _layout_next_art_h ))
                (( q_y < visual_end )) && q_y=$visual_end
            fi

            q_y=$((q_y + 1))
            local max_len=$((max_w - 2))
            (( max_len < 10 )) && max_len=10

            # Metadata lines — each guarded by vertical bounds
            local _meta_lines=()
            _meta_lines+=("Title: ${_jukebox_next_title:-Unknown}")
            _meta_lines+=("Artist: ${_jukebox_next_artist:-Unknown}")
            local _t_album="Album: ${_jukebox_next_album:-None}"
            [[ -n "$_jukebox_next_date" ]] && _t_album="$_t_album (${_jukebox_next_date})"
            _meta_lines+=("$_t_album")
            [[ -n "$_jukebox_next_dur" ]] && _meta_lines+=("Length: $_jukebox_next_dur")
            [[ -n "$_jukebox_next_quality" ]] && _meta_lines+=("Quality: $_jukebox_next_quality")
            [[ -n "$_jukebox_next_size" ]] && _meta_lines+=("Size: $_jukebox_next_size")
            [[ -n "$_jukebox_next_genre" ]] && _meta_lines+=("Genre: $_jukebox_next_genre")

            for ml in "${_meta_lines[@]}"; do
                (( q_y > max_y )) && break
                (( ${#ml} > max_len )) && ml="${ml[1,$((max_len - 3))]}..."
                printf '\e[%d;%dH\e[2m%s\e[0m' "$q_y" "$nx" "$ml"
                q_y=$((q_y + 1))
            done
        else
            # Loading or end-of-playlist message
            (( q_y <= max_y )) && {
                local next_idx=$((_render_pl_pos + 1 + _nav_offset))
                if (( next_idx < _render_pl_count )); then
                    printf '\e[%d;%dH\e[2m⏳ Loading...\e[0m' "$q_y" "$nx"
                else
                    printf '\e[%d;%dH\e[2mEnd of playlist\e[0m' "$q_y" "$nx"
                fi
            }
        fi
    }

    _jukebox_render() {
        local cols=$_layout_cols rows=$_layout_rows

        [[ -z "$_render_path" ]] && return

        local title="${_render_title}"
        [[ -z "$title" ]] && title="${_render_path##*/}" && title="${title%.flac}"
        local artist="$_render_artist"
        local album="$_render_album"
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
        if (( bar_w > 10 && dur_i > 0 )); then
            local filled=$((pos_i * bar_w / dur_i))
            (( filled > bar_w )) && filled=$bar_w
            local empty=$((bar_w - filled))
            bar=" [$(printf '━%.0s' {1..$filled} 2>/dev/null)$(printf '─%.0s' {1..$empty} 2>/dev/null)]"
        fi

        local speed="${_render_speed:-1.000000}"
        local pitch="${_render_pitch:-1.000000}"
        local apc="${_render_apc:-true}"
        
        local speed_fmt pitch_fmt
        { LC_NUMERIC=C printf -v speed_fmt "%.2f" "$speed" } 2>/dev/null || speed_fmt="1.00"
        { LC_NUMERIC=C printf -v pitch_fmt "%.2f" "$pitch" } 2>/dev/null || pitch_fmt="1.00"
        [[ "$speed_fmt" == "0.00" ]] && speed_fmt="1.00"
        [[ "$pitch_fmt" == "0.00" ]] && pitch_fmt="1.00"
        
        local fx_str=""
        if [[ "$apc" == "false" ]]; then
            if [[ "$speed_fmt" != "1.00" ]]; then
                fx_str="(🌙 Nightcore ${speed_fmt}x)"
            fi
        else
            local parts=()
            [[ "$speed_fmt" != "1.00" ]] && parts+=("⚡ ${speed_fmt}x")
            [[ "$pitch_fmt" != "1.00" ]] && parts+=("🎵 ${pitch_fmt}x")
            if (( ${#parts[@]} > 0 )); then
                fx_str="(${(j. .)parts})"
            fi
        fi

        local info="♫  $title"
        [[ -n "$artist" ]] && info="$info  —  $artist"
        [[ -n "$fx_str" ]] && info="$info  $fx_str"
        local track_info="[$((pl_pos + 1)) / $pl_count]"

        # begin synchronized output (Kitty double-buffers until end marker)
        printf '\e[?2026h'

        # delete all kitty images from previous frame
        printf '\e_Ga=d;\e\\'

        # Disable auto-wrap, clear screen, hide cursor
        printf '\e[?7l\e[2J\e[?25l'

        # --- Adaptive Header ---
        local cur_row=1
        if [[ "$_layout_mode" == "normal" ]]; then
            # Full header: 2 control lines + info + album + track
            local controls1="SPACE=pause  ←→=seek  ↑↓=seek 30s  ,./<>=prev/next  [/]=adj  P=mode:${_rt_mode}"
            local controls2="A=add next  L=queue  j/k=nav next  i=info  ENTER=play nav  q=quit"
            printf '\e[1;1H\e[2m'
            _jukebox_padline "$(_jukebox_center "$controls1" $cols)" $cols
            printf '\e[2;1H'
            _jukebox_padline "$(_jukebox_center "$controls2" $cols)" $cols
            printf '\e[0m'
            printf '\e[3;1H'
            _jukebox_padline "$(_jukebox_center "$info" $cols)" $cols
            printf '\e[4;1H'
            if [[ -n "$album" ]]; then
                _jukebox_padline "$(_jukebox_center "💿 $album" $cols)" $cols
            fi
            printf '\e[5;1H'
            _jukebox_padline "$(_jukebox_center "$track_info" $cols)" $cols
            cur_row=6

        elif [[ "$_layout_mode" == "compact" ]]; then
            # Compact: 1 control line + info with track
            local controls_compact="A=add  L=que  j/k=nav  i=info  ENTER=play  P=mode:${_rt_mode}  q=quit"
            printf '\e[1;1H\e[2m'
            _jukebox_padline "$(_jukebox_center "$controls_compact" $cols)" $cols
            printf '\e[0m'
            printf '\e[2;1H'
            _jukebox_padline "$(_jukebox_center "$info  $track_info" $cols)" $cols
            if [[ -n "$album" ]]; then
                printf '\e[3;1H'
                _jukebox_padline "$(_jukebox_center "💿 $album" $cols)" $cols
            fi
            cur_row=4

        else  # minimal
            # Minimal: song title + track only, single line
            local mini_info="$info  $track_info"
            printf '\e[1;1H'
            _jukebox_padline "$(_jukebox_center "$mini_info" $cols)" $cols
            cur_row=2
        fi

        # --- Album art (positioned by layout engine) ---
        if [[ -n "$_jukebox_art_text" ]]; then
            printf '\e[%d;1H%s' "$_layout_art_start_row" "$_jukebox_art_text"
        fi

        # --- "Up Next" panel (layout-driven placement with bounds) ---
        if [[ -n "$pl_pos" && "$_layout_next_mode" != "hidden" ]]; then
            local panel_max_y=$(( rows - 1 ))   # never overwrite progress bar
            local panel_max_w=$(( cols - _layout_next_x - 1 ))
            _jukebox_render_next_panel "$_layout_next_x" "$_layout_next_y" "$panel_max_y" "$panel_max_w"
        fi

        # progress at bottom
        printf '\e[%d;1H' "$rows"
        _jukebox_padline "$(_jukebox_center "${label}${bar}" $cols)" $cols

        # restore auto-wrap, end sync
        printf '\e[?7h\e[?2026l'
    }
