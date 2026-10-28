    # One accent family: pale cyan keys, a filled teal key for enabled state,
    # bright text for actions, and slate for secondary metadata.
    _jukebox_theme_init() {
        _ui_reset=$'\e[0m'
        _ui_text=$'\e[38;2;231;237;243m'
        _ui_secondary=$'\e[38;2;173;188;203m'
        _ui_accent=$'\e[38;2;142;211;216m'
        _ui_title=$'\e[1;38;2;245;247;250m'
        _ui_key=$'\e[1;38;2;163;225;229;48;2;35;49;61m'
        _ui_key_active=$'\e[1;38;2;19;34;43;48;2;142;211;216m'
        if [[ "${JUKEBOX_COLOR:-auto}" == 0 || ( "${JUKEBOX_COLOR:-auto}" != 1 && -n "${NO_COLOR:-}" ) ]]; then
            _ui_reset=""; _ui_text=""; _ui_secondary=""; _ui_accent=""
            _ui_title=""; _ui_key=""; _ui_key_active=""
        fi
    }

    _jukebox_text_line() {
        local width=$1 style=$2 text=$3
        printf '%s' "$style"
        _jukebox_padline "$(_jukebox_center "$text" "$width")" "$width"
        printf '%s' "$_ui_reset"
    }

    _jukebox_fzf() {
        if [[ -n "$_ui_reset" ]]; then
            command fzf --color='hl:#8ed3d8,hl+:#b9f0f1,prompt:#8ed3d8,pointer:#8ed3d8,marker:#8ed3d8,header:#adbccb,border:#617787,fg+:#f5f7fa,bg+:#23313d' "$@"
        else
            command fzf "$@"
        fi
    }

    # Entries are key|label|enabled. Measure plain text before applying ANSI
    # styling so colored keys do not alter centering or terminal clipping.
    _jukebox_control_row() {
        local width=$1
        shift
        local -a entries=("$@") keys=() labels=() enabled=()
        local entry key rest label active total=0 i gap=2 padding=0 remaining
        for entry in "${entries[@]}"; do
            key="${entry%%|*}"
            rest="${entry#*|}"
            label="${rest%%|*}"
            active="${rest##*|}"
            keys+=("$key"); labels+=("$label"); enabled+=("$active")
            total=$(( total + ${#key} + ${#label} + 3 ))
        done
        if (( total + 2 * (${#keys[@]} - 1) > width )); then
            # Narrow windows keep the actual shortcuts and use ? for details.
            labels=()
            total=0
            for key in "${keys[@]}"; do
                labels+=("")
                total=$(( total + ${#key} + 2 ))
            done
        fi
        if (( ${#keys[@]} > 1 )); then
            gap=$(( (width - total) / (${#keys[@]} - 1) ))
            (( gap > 6 )) && gap=6
            (( gap < 1 )) && gap=1
        fi
        padding=$(( (width - total - gap * (${#keys[@]} - 1)) / 2 ))
        (( padding < 0 )) && padding=0
        printf '%*s' "$padding" ''
        remaining=$(( width - padding ))
        for (( i=1; i<=${#keys[@]}; i++ )); do
            key="${keys[$i]}"; label="${labels[$i]}"
            total=$(( ${#key} + 2 ))
            [[ -n "$label" ]] && total=$(( total + ${#label} + 1 ))
            (( total > remaining )) && break
            if [[ "${enabled[$i]}" == 1 ]]; then
                printf '%s[%s]%s' "$_ui_key_active" "$key" "$_ui_reset"
            else
                printf '%s[%s]%s' "$_ui_key" "$key" "$_ui_reset"
            fi
            [[ -n "$label" ]] && printf '%s %s%s' "$_ui_text" "$label" "$_ui_reset"
            remaining=$(( remaining - total ))
            if (( i < ${#keys[@]} && remaining >= gap )); then
                printf '%*s' "$gap" ''
                remaining=$(( remaining - gap ))
            fi
        done
        (( remaining > 0 )) && printf '%*s' "$remaining" ''
        printf '%s' "$_ui_reset"
    }

    _jukebox_status_line() {
        local width=$1
        local volume="${_render_volume%.*}%" playback="Playing"
        [[ -z "$_render_volume" ]] && volume="—"
        [[ "$_render_mute" == true ]] && volume="Muted"
        [[ "$_render_paused" == true ]] && playback="Paused"
        local text="$playback  ·  Track $(( ${_render_pl_pos:-0} + 1 ))/${_render_pl_count:-0}  ·  Vol $volume  ·  Repeat ${_repeat_mode:-off}"
        _jukebox_text_line "$width" "$_ui_accent" "$text"
    }

    _jukebox_progress_line() {
        local width=$1 pos=${_render_time_pos%.*} duration=${_render_duration%.*}
        [[ "$pos" == <-> ]] || pos=0
        [[ "$duration" == <-> ]] || duration=0
        local state="PLAY" label filled=0 empty bar_width padding full_bar="" rest_bar=""
        [[ "$_render_paused" == true ]] && state="PAUSE"
        label=$(printf '%s  %02d:%02d / %02d:%02d' "$state" $((pos / 60)) $((pos % 60)) $((duration / 60)) $((duration % 60)))
        bar_width=$(( width - ${#label} - 6 ))
        if (( bar_width < 8 || duration <= 0 )); then
            _jukebox_text_line "$width" "$_ui_text" "$label"
            return
        fi
        filled=$(( pos * bar_width / duration ))
        (( filled > bar_width )) && filled=$bar_width
        empty=$(( bar_width - filled ))
        printf -v full_bar '%*s' "$filled" ''
        printf -v rest_bar '%*s' "$empty" ''
        full_bar="${full_bar// /━}"; rest_bar="${rest_bar// /─}"
        padding=$(( (width - ${#label} - bar_width - 3) / 2 ))
        printf '%*s%s%s%s  %s%s%s%s%s%*s%s' "$padding" '' "$_ui_text" "$label" "$_ui_reset" \
            "$_ui_accent" "$full_bar" "$_ui_secondary" "$rest_bar" "$_ui_reset" \
            "$((width - padding - ${#label} - bar_width - 2))" '' "$_ui_reset"
    }
