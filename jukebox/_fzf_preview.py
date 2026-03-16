#!/usr/bin/env python3
"""fzf preview script for Jukebox — shows album art + comprehensive metadata."""
import subprocess, json, os, sys

def run(cmd, strip=True, **kw):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10, **kw)
        return r.stdout.strip() if strip else r.stdout
    except Exception:
        return ""

def fmt_duration(secs):
    try:
        s = int(float(secs))
        m, s = divmod(s, 60)
        h, m = divmod(m, 60)
        return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"
    except Exception:
        return ""

def fmt_size(nbytes):
    try:
        n = int(nbytes)
        if n >= 1_073_741_824:
            return f"{n / 1_073_741_824:.1f} GB"
        elif n >= 1_048_576:
            return f"{n / 1_048_576:.1f} MB"
        elif n >= 1024:
            return f"{n / 1024:.0f} KB"
        return f"{n} B"
    except Exception:
        return ""

def fmt_bitrate(br):
    try:
        bps = int(br)
        return f"{bps // 1000} kbps"
    except Exception:
        return ""

def fmt_samplerate(sr):
    try:
        hz = int(sr)
        if hz % 1000 == 0:
            return f"{hz // 1000} kHz"
        return f"{hz / 1000:.1f} kHz"
    except Exception:
        return ""

def main():
    if len(sys.argv) < 2:
        return
    filepath = sys.argv[1]
    if not os.path.isfile(filepath):
        print(f"File not found: {filepath}")
        return

    cols = int(os.environ.get("FZF_PREVIEW_COLUMNS", 60))
    lines = int(os.environ.get("FZF_PREVIEW_LINES", 40))
    tmpcover = os.environ.get("_JUKEBOX_PREVTMP", "/tmp/jukebox-fzf-prev.jpg")

    # --- Probe all metadata in one shot ---
    raw = run(["ffprobe", "-v", "quiet", "-print_format", "json",
               "-show_format", "-show_streams", "--", filepath])
    data = {}
    if raw:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            pass

    fmt = data.get("format") if isinstance(data.get("format"), dict) else {}
    tags = fmt.get("tags") if isinstance(fmt.get("tags"), dict) else {}

    # Case-insensitive tag getter
    def tag(k):
        val = tags.get(k, tags.get(k.upper(), tags.get(k.lower(), "")))
        return str(val) if val is not None else ""

    # Find audio stream
    audio_stream = None
    for s in data.get("streams", []):
        if s.get("codec_type") == "audio":
            audio_stream = s
            break

    # --- Basic metadata ---
    fname = os.path.splitext(os.path.basename(filepath))[0]
    title = tag("title") or fname
    artist = tag("artist") or ""
    album = tag("album") or ""
    album_artist = tag("album_artist") or tag("albumartist") or ""
    date = tag("date") or tag("year") or tag("DATE") or ""
    genre = tag("genre") or ""
    track = tag("track") or tag("tracknumber") or ""
    disc = tag("disc") or tag("discnumber") or ""
    comment = tag("comment") or ""
    isrc = tag("ISRC") or tag("isrc") or ""
    encoder = tag("encoder") or ""
    composer = tag("composer") or ""
    performer = tag("performer") or ""
    copyright_tag = tag("copyright") or ""
    label = tag("label") or tag("organization") or tag("publisher") or ""
    remixer = tag("remixer") or tag("mixartist") or ""
    arranger = tag("arranger") or ""
    lyrics = tag("lyrics") or tag("LYRICS") or tag("unsyncedlyrics") or ""

    duration = fmt.get("duration", "")
    filesize = fmt.get("size", "")
    bitrate = fmt.get("bit_rate", "")

    # Audio stream details
    codec = ""
    sample_rate = ""
    bit_depth = ""
    channels = ""
    channel_layout = ""
    if isinstance(audio_stream, dict):
        codec = audio_stream.get("codec_name", "")
        if codec:
            codec = codec.upper()
        sample_rate = audio_stream.get("sample_rate", "")
        bit_depth = audio_stream.get("bits_per_raw_sample", "") or ""
        if bit_depth == "0":
            bit_depth = ""
        channels = audio_stream.get("channels", "")
        channel_layout = audio_stream.get("channel_layout", "")

    # ReplayGain
    rg_track = tag("REPLAYGAIN_TRACK_GAIN") or tag("replaygain_track_gain") or ""
    rg_album = tag("REPLAYGAIN_ALBUM_GAIN") or tag("replaygain_album_gain") or ""
    rg_track_peak = tag("REPLAYGAIN_TRACK_PEAK") or tag("replaygain_track_peak") or ""

    # --- Determine detail level based on preview size ---
    # compact: minimal info only
    # normal: most info
    # full: everything including replaygain, comment, lyrics preview
    if lines <= 12:
        detail = "compact"
    elif lines <= 25:
        detail = "normal"
    else:
        detail = "full"

    sep = "─" * min(cols - 2, 50)

    header_lines_count = [0]

    def printline(s):
        if len(s) > cols:
            s = s[:cols - 3] + "..."
        print(s)
        header_lines_count[0] += 1

    printline(f"🎵 {title}")
    if artist:
        printline(f"🎤 {artist}")
    if album:
        album_line = f"💿 {album}"
        if date:
            album_line += f" ({date})"
        printline(album_line)

    # Track/disc + duration on one line
    info_parts = []
    if duration:
        info_parts.append(f"⏱  {fmt_duration(duration)}")
    if track:
        track_str = f"Track {track}"
        if disc:
            track_str += f" · Disc {disc}"
        info_parts.append(track_str)
    if info_parts:
        printline("  ".join(info_parts))

    # --- Album art (responsive to window size) ---
    art_w = max(cols - 2, 8)

    # Dynamically compute art height from remaining space:
    #   total lines - header lines printed - 1 (gap line before art)
    #   - lines reserved for metadata sections below the art
    if detail == "compact":
        metadata_reserve = 1
    elif detail == "normal":
        metadata_reserve = 8
    else:
        metadata_reserve = 14

    remaining = lines - header_lines_count[0] - 1 - metadata_reserve
    art_h = min(art_w // 2, remaining)
    # Enforce sensible bounds
    art_h = max(art_h, 3)

    if art_h >= 3 and art_w >= 8 and remaining >= 3:
        print()
        try:
            subprocess.run(
                ["ffmpeg", "-y", "-v", "quiet", "-i", filepath,
                 "-an", "-vcodec", "mjpeg", "-frames:v", "1", tmpcover],
                timeout=10, capture_output=True)
            if not (os.path.isfile(tmpcover) and os.path.getsize(tmpcover) > 0):
                script_dir = os.environ.get("_JUKEBOX_SCRIPT_DIR", "")
                fallback = os.path.join(script_dir, "assets", "NO-COVER.png")
                if os.path.isfile(fallback):
                    import shutil
                    shutil.copy(fallback, tmpcover)
            
            if os.path.isfile(tmpcover) and os.path.getsize(tmpcover) > 0:
                art_out = run(["chafa", "--size", f"{art_w}x{art_h}", tmpcover], strip=False)
                if art_out:
                    print(art_out, end="")
                    # If chafa output an image overlay (Kitty/Sixel) instead of block characters,
                    # it might not emit enough newlines. We must pad with newlines so fzf
                    # advances its line counter and doesn't draw text over the image.
                    newlines_in_art = art_out.count("\n")
                    # some overhead newlines from chafa might exist, but we want at least art_h total lines
                    if newlines_in_art < art_h:
                        print("\n" * (art_h - newlines_in_art), end="")
        except Exception:
            pass

    if detail == "compact":
        return

    # --- Audio quality section ---
    print()
    printline(f"┈┈┈ Audio Quality ┈┈┈")
    quality_parts = []
    if codec:
        quality_parts.append(codec)
    if sample_rate:
        quality_parts.append(fmt_samplerate(sample_rate))
    if bit_depth:
        quality_parts.append(f"{bit_depth}-bit")
    if channel_layout:
        quality_parts.append(channel_layout.capitalize())
    elif channels:
        ch_map = {"1": "Mono", "2": "Stereo"}
        quality_parts.append(ch_map.get(str(channels), f"{channels}ch"))
    if quality_parts:
        printline("  " + " · ".join(quality_parts))

    extra = []
    if bitrate:
        extra.append(f"Bitrate: {fmt_bitrate(bitrate)}")
    if filesize:
        extra.append(f"Size: {fmt_size(filesize)}")
    if extra:
        printline("  " + "  │  ".join(extra))

    if detail == "normal" and not any([album_artist and album_artist != artist,
                                        genre, composer, performer, remixer, arranger]):
        return

    # --- Details section ---
    print()
    printline(f"┈┈┈ Details ┈┈┈")
    if album_artist and album_artist != artist:
        printline(f"  Album Artist: {album_artist}")
    if genre:
        printline(f"  Genre: {genre}")
    if composer:
        printline(f"  Composer: {composer}")
    if performer:
        printline(f"  Performer: {performer}")
    if remixer:
        printline(f"  Remixer: {remixer}")
    if arranger:
        printline(f"  Arranger: {arranger}")
    if label:
        printline(f"  Label: {label}")
    if copyright_tag:
        printline(f"  ©: {copyright_tag}")
    if isrc:
        printline(f"  ISRC: {isrc}")

    if detail != "full":
        return

    # --- Extended info (full detail only) ---
    if rg_track or rg_album:
        rg_parts = []
        if rg_track:
            rg_parts.append(f"Track: {rg_track}")
        if rg_album:
            rg_parts.append(f"Album: {rg_album}")
        printline(f"  ReplayGain: {' / '.join(rg_parts)}")
    if rg_track_peak:
        printline(f"  Peak: {rg_track_peak}")
    if encoder:
        printline(f"  Encoder: {encoder}")
    if comment:
        # Truncate long comments
        if len(comment) > cols * 2:
            comment = comment[:cols * 2 - 3] + "..."
        printline(f"  Comment: {comment}")
    if lyrics:
        print()
        printline(f"┈┈┈ Lyrics (preview) ┈┈┈")
        # Show first few lines of lyrics
        lyric_lines = lyrics.split("\n")
        max_lyric = min(6, lines - 30) if lines > 30 else 0
        for ll in lyric_lines[:max_lyric]:
            printline(f"  {ll.strip()}")
        if len(lyric_lines) > max_lyric:
            printline(f"  ... ({len(lyric_lines)} lines total)")

if __name__ == "__main__":
    main()
