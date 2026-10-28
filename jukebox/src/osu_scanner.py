import os
import sys
import re

def parse_osu_file(osu_path):
    audio = title = artist = ""
    last_time = 0
    try:
        with open(osu_path, "r", encoding="utf-8-sig", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line.startswith("AudioFilename:"):
                    audio = line.split(":", 1)[1].strip()
                elif line.startswith("Title:"):
                    title = line.split(":", 1)[1].strip()
                elif line.startswith("Artist:"):
                    artist = line.split(":", 1)[1].strip()
                elif "," in line:
                    parts = line.split(",")
                    if len(parts) >= 3 and parts[2].lstrip("-").isdigit():
                        last_time = max(last_time, int(parts[2]))
        
        if not title: title = os.path.basename(os.path.dirname(osu_path))
        if not artist: artist = "osu! Artist"
        duration = str(int(last_time / 1000.0))
        return audio, title, artist, duration
    except Exception:
        return None, None, None, None

def scan_osu_library(osu_dir, filter_regex, cache_path):
    if not os.path.isdir(osu_dir):
        return

    # Load existing cache to avoid duplicates
    cached = set()
    if os.path.exists(cache_path):
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                for line in f:
                    parts = line.split('\t', 1)
                    if len(parts) > 0:
                        cached.add(parts[0])
        except Exception:
            pass

    try:
        filter_pattern = re.compile(filter_regex, re.IGNORECASE) if filter_regex else None
    except Exception:
        filter_pattern = None

    new_entries = []
    
    try:
        for d in os.listdir(osu_dir):
            if filter_pattern and not filter_pattern.search(d):
                continue
                
            folder_path = os.path.join(osu_dir, d)
            if not os.path.isdir(folder_path):
                continue
                
            # Find the first .osu file to parse metadata
            for f in os.listdir(folder_path):
                if f.endswith(".osu"):
                    osu_path = os.path.join(folder_path, f)
                    audio, title, artist, duration = parse_osu_file(osu_path)
                    
                    if audio:
                        audio_path = os.path.join(folder_path, audio)
                        # Make sure it's an audio file and actually exists
                        if audio_path.lower().endswith(('.mp3', '.ogg', '.flac')) and os.path.exists(audio_path) and audio_path not in cached:
                            # Append to new entries.
                            # format: filepath\ttitle\tartist\talbum\tdate\tdur\ttrack\tdisc
                            album = "osu! Songs"
                            date = "0"
                            track = "0"
                            disc = "1"
                            # Strip any tab characters from metadata to prevent cache corruption
                            title = title.replace('\t', ' ')
                            artist = artist.replace('\t', ' ')
                            entry = f"{audio_path}\t{title}\t{artist}\t{album}\t{date}\t{duration}\t{track}\t{disc}\n"
                            new_entries.append(entry)
                            cached.add(audio_path)
                    break  # only need to parse one .osu file per folder
    except Exception as e:
        print(f"osu! scanner error: {e}", file=sys.stderr)

    if new_entries:
        print(f"osu! scanner: added {len(new_entries)} matching tracks.", file=sys.stderr)
        try:
            with open(cache_path, "a", encoding="utf-8") as f:
                f.writelines(new_entries)
        except Exception:
            pass

if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(1)
    
    osu_dir = sys.argv[1]
    filter_regex = sys.argv[2]
    cache_path = sys.argv[3]
    scan_osu_library(osu_dir, filter_regex, cache_path)
