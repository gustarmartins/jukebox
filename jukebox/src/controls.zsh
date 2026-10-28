    _jukebox_cycle_repeat() {
        case "$_repeat_mode" in
            off)
                _repeat_mode="track"
                _jukebox_set '{"command":["set_property","loop-playlist","no"]}'
                _jukebox_set '{"command":["set_property","loop-file","inf"]}'
                ;;
            track)
                _repeat_mode="queue"
                _jukebox_set '{"command":["set_property","loop-file","no"]}'
                _jukebox_set '{"command":["set_property","loop-playlist","inf"]}'
                ;;
            *)
                _repeat_mode="off"
                _jukebox_set '{"command":["set_property","loop-file","no"]}'
                _jukebox_set '{"command":["set_property","loop-playlist","no"]}'
                ;;
        esac
        force_redraw=1
    }

    _jukebox_show_help() {
        printf '\e[?1049l\e[?25h'
        [[ -n "$saved_stty" ]] && stty "$saved_stty" 2>/dev/null
        cat <<'HELPEOF'

Jukebox controls

  Space          Pause / resume
  , / .          Previous / next track
  Left / Right   Seek 5 seconds
  Up / Down      Seek 30 seconds
  - / +          Volume down / up (5%)
  M              Mute / unmute
  T              Repeat: off → track → queue
  A              Add songs to play next
  L              Edit the live queue
  S              Shuffle upcoming tracks
  N / B          Build a new queue
  Y              Toggle lyrics
  j / k          Browse upcoming songs / scroll plain lyrics
  Enter          Play the selected upcoming song
  [ / ]          Adjust speed or pitch
  P              Effect: tempo → nightcore → pitch
  R / Backspace  Reset speed and pitch
  I              Audio metadata
  Q              Quit with confirmation

Press any key to return.
HELPEOF
        read -rs -k 1
        printf '\e[?1049h\e[?25l'
        stty -echo -icanon min 0 time 0 2>/dev/null
        force_redraw=1
    }
