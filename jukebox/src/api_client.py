#!/usr/bin/env python3
"""Dependency-free online API integrations for Jukebox.

Mirrors the API integrations from Rhythm-the-Mekki-remix:
  - Last.fm (track.getSimilar + artist.getSimilar) for smart recommendations
  - Better Lyrics -> LRCLIB -> Lyrically/Paxsenix (Apple Music) for lyrics
  - Deezer -> iTunes Search for verified cover art fallback

All network calls have strict timeouts, rate-limit protection, and persistent
disk caches under $JUKEBOX_DATA_DIR so Jukebox stays fast and lightweight.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import random
import re
import shutil
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


APP_USER_AGENT = "Jukebox/1.0 (https://github.com/gustarmartins/jukebox)"
UNIT_SEPARATOR = "\x1f"

LASTFM_BASE_URL = "https://ws.audioscrobbler.com/2.0/"
BETTER_LYRICS_BASE_URL = "https://api.betterlyrics.org/getLyrics"
LRCLIB_SEARCH_URL = "https://lrclib.net/api/search"
ITUNES_SEARCH_URL = "https://itunes.apple.com/search"
LYRICALLY_APPLE_URL = "https://lyrics.paxsenix.org/apple-music/lyrics"
DEEZER_BASE_URL = "https://api.deezer.com"

LASTFM_HIT_TTL = 24 * 3600
LASTFM_MISS_TTL = 15 * 60
LYRICS_HIT_TTL = 7 * 24 * 3600
LYRICS_MISS_TTL = 6 * 3600
ART_MISS_TTL = 6 * 3600

GENRE_SPLIT_RE = re.compile(r"[,;\n\r/]+")
FEAT_SPLIT_RE = re.compile(r"\s+(?:feat\.?|ft\.?|featuring|with|x|&|,)\s+", re.IGNORECASE)
FEAT_STRIP_RE = re.compile(r"\s*[\(\[]?\s*(?:feat\.?|ft\.?|featuring)\b.*$", re.IGNORECASE)
PAREN_RE = re.compile(r"\s*[\(\[].*?[\)\]]")
NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")
NIGHTCORE_RE = re.compile(
    r"nightcore|nightstep|speed\s*up|sped\s*up|spdup|chincore|bakaricore|zcore",
    re.IGNORECASE,
)
LRC_RE = re.compile(r"\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]")
WORD_TIME_RE = re.compile(r"<\d{1,3}:[0-5]\d(?:[.:]\d{1,3})?>")
UNKNOWN_ARTISTS = frozenset({"", "unknown", "<unknown>", "unknown artist", "various", "various artists"})

_LAST_LASTFM_REQUEST = 0.0


def config_path() -> Path:
    configured = os.environ.get("JUKEBOX_API_CONFIG")
    if configured:
        return Path(configured).expanduser()
    root = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return root / "jukebox" / "api.json"


def data_dir(explicit: str | None = None) -> Path:
    if explicit:
        return Path(explicit).expanduser()
    return Path(os.environ.get("JUKEBOX_DATA_DIR", Path.home() / ".jukebox-app")).expanduser()


def load_config() -> dict[str, Any]:
    data: dict[str, Any] = {}
    path = config_path()
    if path.is_file():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                data.update(loaded)
        except (OSError, json.JSONDecodeError):
            pass

    if os.environ.get("JUKEBOX_LASTFM_API_KEY"):
        data["lastfm_api_key"] = os.environ["JUKEBOX_LASTFM_API_KEY"].strip()

    global_online = os.environ.get("JUKEBOX_ONLINE_APIS", "").strip().lower()
    if global_online in {"0", "false", "no", "off"}:
        data["online_enabled"] = False
    elif global_online in {"1", "true", "yes", "on"}:
        data["online_enabled"] = True
    else:
        data.setdefault("online_enabled", True)

    for env_name, key in (
        ("JUKEBOX_ONLINE_LYRICS", "online_lyrics"),
        ("JUKEBOX_ONLINE_ART", "online_art"),
        ("JUKEBOX_LASTFM_ENABLED", "lastfm_enabled"),
    ):
        val = os.environ.get(env_name, "").strip().lower()
        if val in {"0", "false", "no", "off"}:
            data[key] = False
        elif val in {"1", "true", "yes", "on"}:
            data[key] = True
        else:
            data.setdefault(key, True)

    return data


def save_config(data: dict[str, Any]) -> None:
    path = config_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    payload = json.dumps(data, indent=2, sort_keys=True) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=".api-", dir=path.parent, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
        os.replace(tmp_name, path)
        os.chmod(path, 0o600)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def atomic_write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def clean_field(value: Any) -> str:
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(value or "")).strip()


def normalize_artist(value: str) -> str:
    norm = unicodedata.normalize("NFKC", value or "").strip().lower()
    norm = re.sub(r"\s+", " ", norm)
    return "" if norm in UNKNOWN_ARTISTS else norm


def split_artists(value: str) -> list[str]:
    if not value:
        return []
    parts = [normalize_artist(p) for p in FEAT_SPLIT_RE.split(value)]
    result: list[str] = []
    seen: set[str] = set()
    full = normalize_artist(value)
    if full:
        result.append(full)
        seen.add(full)
    for part in parts:
        if part and part not in seen:
            result.append(part)
            seen.add(part)
    return result


def canonicalize_match(value: str) -> str:
    text = unicodedata.normalize("NFKD", value or "")
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = PAREN_RE.sub(" ", text)
    text = FEAT_STRIP_RE.sub("", text)
    text = NON_ALNUM_RE.sub("", text.lower())
    return text


def strip_nightcore_title(title: str) -> str:
    cleaned = re.sub(
        r"[\[(]\s*(?:nightcore|nightstep|speed\s*up|sped\s*up|bakaricore|zcore|chincore)[^\])]*[\])]",
        "",
        title or "",
        flags=re.IGNORECASE,
    )
    cleaned = re.sub(r"\bnightcore\b", "", cleaned, flags=re.IGNORECASE)
    return re.sub(r"\s+", " ", cleaned).strip(" -")


def split_genres(raw: str) -> set[str]:
    if not raw:
        return set()
    tokens = set()
    for part in GENRE_SPLIT_RE.split(raw):
        tok = part.strip().lower()
        if tok and tok not in {"unknown", "other", "general"}:
            tokens.add(tok)
    return tokens


def extract_year(date_str: str) -> int | None:
    m = re.search(r"\b(19\d{2}|20\d{2})\b", str(date_str or ""))
    return int(m.group(1)) if m else None


def cache_key_hash(*parts: str) -> str:
    joined = "\x1f".join(p.strip().lower() for p in parts)
    return hashlib.sha1(joined.encode("utf-8")).hexdigest()


def http_get_json(url: str, *, headers: dict[str, str] | None = None, timeout: float = 5.0) -> Any:
    req_headers = {"User-Agent": APP_USER_AGENT, "Accept": "application/json"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, headers=req_headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
        return json.loads(raw.decode("utf-8", errors="replace")) if raw else None
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, json.JSONDecodeError):
        return None


def http_get_bytes(url: str, *, headers: dict[str, str] | None = None, timeout: float = 6.0) -> bytes | None:
    req_headers = {"User-Agent": APP_USER_AGENT, "Accept": "*/*"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, headers=req_headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        return None


# ---------------------------------------------------------------------------
# Last.fm Recommendations (mirrors Rhythm's LastFmRecommendations.kt + track.getSimilar)
# ---------------------------------------------------------------------------

def _lastfm_fetch(
    method: str,
    params: dict[str, str],
    api_key: str,
    cache_dir: Path,
    cache_id: str,
) -> dict[str, Any] | None:
    global _LAST_LASTFM_REQUEST
    cache_file = cache_dir / f"{cache_id}.json"
    now = time.time()
    if cache_file.is_file():
        try:
            cached = json.loads(cache_file.read_text(encoding="utf-8"))
            ts = float(cached.get("ts", 0))
            has_data = bool(cached.get("has_data"))
            ttl = LASTFM_HIT_TTL if has_data else LASTFM_MISS_TTL
            if now - ts < ttl:
                return cached.get("data")
        except (OSError, ValueError, TypeError):
            pass

    if not api_key:
        return None

    # Rate limit: minimum 2 seconds between live Last.fm requests (Rhythm policy)
    elapsed = now - _LAST_LASTFM_REQUEST
    if _LAST_LASTFM_REQUEST > 0 and elapsed < 2.0:
        time.sleep(min(2.0 - elapsed, 2.0))
    _LAST_LASTFM_REQUEST = time.time()

    query = {
        "method": method,
        "format": "json",
        "autocorrect": "1",
        "limit": "40",
        "api_key": api_key,
        **params,
    }
    url = f"{LASTFM_BASE_URL}?{urllib.parse.urlencode(query)}"
    data = http_get_json(url, timeout=2.5)
    has_data = isinstance(data, dict) and "error" not in data
    try:
        atomic_write_json(cache_file, {"ts": time.time(), "has_data": has_data, "data": data if has_data else None})
    except OSError:
        pass
    return data if has_data else None


def lastfm_similar_artists(api_key: str, artist: str, cache_dir: Path) -> dict[str, float]:
    norm = normalize_artist(artist)
    if not norm or not api_key:
        return {}
    cache_id = f"artist_{cache_key_hash(norm)}"
    payload = _lastfm_fetch("artist.getSimilar", {"artist": norm}, api_key, cache_dir, cache_id)
    if not isinstance(payload, dict):
        return {}
    artists = (payload.get("similarartists") or {}).get("artist") or []
    if isinstance(artists, dict):
        artists = [artists]
    scores: dict[str, float] = {}
    for item in artists:
        if not isinstance(item, dict):
            continue
        name = normalize_artist(str(item.get("name") or ""))
        if not name:
            continue
        try:
            score = float(item.get("match", 0.5))
        except (TypeError, ValueError):
            score = 0.5
        scores[name] = max(scores.get(name, 0.0), min(1.0, max(0.05, score)))
    return scores


def lastfm_similar_tracks(api_key: str, artist: str, title: str, cache_dir: Path) -> dict[tuple[str, str], float]:
    norm_artist = normalize_artist(artist)
    clean_title = strip_nightcore_title(title)
    if not norm_artist or not clean_title or not api_key:
        return {}
    cache_id = f"track_{cache_key_hash(norm_artist, clean_title)}"
    payload = _lastfm_fetch(
        "track.getSimilar",
        {"artist": norm_artist, "track": clean_title},
        api_key,
        cache_dir,
        cache_id,
    )
    if not isinstance(payload, dict):
        return {}
    tracks = (payload.get("similartracks") or {}).get("track") or []
    if isinstance(tracks, dict):
        tracks = [tracks]
    scores: dict[tuple[str, str], float] = {}
    for item in tracks:
        if not isinstance(item, dict):
            continue
        t_name = canonicalize_match(str(item.get("name") or ""))
        a_obj = item.get("artist")
        a_raw = a_obj.get("name") if isinstance(a_obj, dict) else str(a_obj or "")
        a_name = normalize_artist(a_raw)
        if not t_name or not a_name:
            continue
        try:
            score = float(item.get("match", 0.5))
        except (TypeError, ValueError):
            score = 0.5
        key = (a_name, t_name)
        scores[key] = max(scores.get(key, 0.0), min(1.0, max(0.05, score)))
    return scores


def read_library_cache(cache_path: Path) -> tuple[dict[str, list[str]], dict[str, str]]:
    rows: dict[str, list[str]] = {}
    try:
        for line in cache_path.read_text(encoding="utf-8").splitlines():
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 8:
                rows[parts[0]] = parts[1:8]
    except OSError:
        pass
    genres: dict[str, str] = {}
    genres_path = Path(str(cache_path) + ".genres.json")
    if genres_path.is_file():
        try:
            loaded = json.loads(genres_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                genres = {str(k): str(v) for k, v in loaded.items()}
        except (OSError, ValueError):
            pass
    return rows, genres


def _soundtrack_family(album: str) -> str:
    low = (album or "").lower()
    if "head radio" in low:
        return "gta_head_radio"
    if "lips 106" in low:
        return "gta_lips_106"
    if "grand theft auto" in low or "gta" in low:
        return "gta"
    if "sims 2" in low or "sims 3" in low or "the sims" in low:
        return "the_sims"
    if "mario kart" in low:
        return "mario_kart"
    if "cyberpunk 2077" in low:
        return "cyberpunk_2077"
    return ""


def _is_nightcore_meta(path: str, fields: list[str], genre_raw: str) -> bool:
    if NIGHTCORE_RE.search(path) or NIGHTCORE_RE.search(genre_raw):
        return True
    for f in fields[:3]:
        if NIGHTCORE_RE.search(f):
            return True
    if len(fields) >= 3 and fields[2].strip().lower() == "osu! songs":
        return True
    return False


def build_recommendations(
    seed_paths: list[str],
    candidate_paths: list[str],
    cache_path: Path,
    cfg: dict[str, Any],
    base_data_dir: Path,
    rng: random.Random | None = None,
) -> list[str]:
    """Rank candidate_paths for smart playback after seed_paths."""
    if rng is None:
        rng = random.Random()
    rows, genres_map = read_library_cache(cache_path)
    seed_set = set(seed_paths)
    candidates = [p for p in candidate_paths if p not in seed_set]
    if not candidates:
        return []

    use_lastfm = bool(cfg.get("online_enabled", True)) and bool(cfg.get("lastfm_enabled", True))
    api_key = str(cfg.get("lastfm_api_key") or "").strip() if use_lastfm else ""
    lfm_cache_dir = base_data_dir / "api-cache" / "lastfm"

    seed_artists: set[str] = set()
    seed_albums: set[str] = set()
    seed_genres: set[str] = set()
    seed_years: list[int] = []
    seed_families: set[str] = set()
    seed_nc_count = 0

    similar_artists: dict[str, float] = {}
    similar_tracks: dict[tuple[str, str], float] = {}

    # Query Last.fm for up to 2 most recent seed tracks to keep startup snappy.
    for idx, sp in enumerate(seed_paths[-2:]):
        fields = rows.get(sp, [Path(sp).stem, "", "", "0", "0", "0", "1"])
        title, artist, album, date_str = fields[0], fields[1], fields[2], fields[3]
        g_raw = genres_map.get(sp, "")
        for a in split_artists(artist):
            seed_artists.add(a)
        if album and album.lower() not in {"unknown", "nightcore mix", "osu! songs"}:
            seed_albums.add(album.lower())
        seed_genres.update(split_genres(g_raw))
        yr = extract_year(date_str)
        if yr:
            seed_years.append(yr)
        fam = _soundtrack_family(album)
        if fam:
            seed_families.add(fam)
        if _is_nightcore_meta(sp, fields, g_raw):
            seed_nc_count += 1

        if api_key:
            primary_artists = split_artists(artist)
            primary = primary_artists[-1] if len(primary_artists) > 1 else (primary_artists[0] if primary_artists else "")
            if primary:
                for k, v in lastfm_similar_tracks(api_key, primary, title, lfm_cache_dir).items():
                    similar_tracks[k] = max(similar_tracks.get(k, 0.0), v)
                if idx == 0 or len(seed_paths) == 1:
                    for k, v in lastfm_similar_artists(api_key, primary, lfm_cache_dir).items():
                        similar_artists[k] = max(similar_artists.get(k, 0.0), v)

    seed_is_nc = seed_nc_count > 0 and seed_nc_count >= len(seed_paths[-2:]) / 2
    avg_year = sum(seed_years) / len(seed_years) if seed_years else None

    scored: list[tuple[float, str, str]] = []
    for path in candidates:
        fields = rows.get(path, [Path(path).stem, "", "", "0", "0", "0", "1"])
        title, artist, album, date_str = fields[0], fields[1], fields[2], fields[3]
        g_raw = genres_map.get(path, "")
        c_artists = split_artists(artist)
        c_title_canon = canonicalize_match(strip_nightcore_title(title))
        c_genres = split_genres(g_raw)
        c_is_nc = _is_nightcore_meta(path, fields, g_raw)

        score = 0.0

        # 1. Last.fm track.getSimilar match (strongest signal)
        best_track_lfm = 0.0
        for ca in c_artists:
            m = similar_tracks.get((ca, c_title_canon), 0.0)
            if m > best_track_lfm:
                best_track_lfm = m
        if best_track_lfm > 0:
            score += 120.0 * best_track_lfm

        # 2. Last.fm artist.getSimilar match (Rhythm's core signal)
        best_artist_lfm = 0.0
        for ca in c_artists:
            m = similar_artists.get(ca, 0.0)
            if m > best_artist_lfm:
                best_artist_lfm = m
        if best_artist_lfm > 0:
            score += 75.0 * best_artist_lfm

        # 3. Multi-genre overlap (rewards specific multi-genre matches)
        if seed_genres and c_genres:
            overlap = seed_genres & c_genres
            if overlap:
                union = seed_genres | c_genres
                jaccard = len(overlap) / len(union)
                score += 20.0 + 30.0 * jaccard

        # 4. Soundtrack / game family & album match
        c_fam = _soundtrack_family(album)
        if c_fam and c_fam in seed_families:
            score += 35.0
        if album and album.lower() in seed_albums:
            score += 18.0

        # 5. Same artist (different song)
        if any(ca in seed_artists for ca in c_artists):
            score += 26.0

        # 6. Nightcore edition affinity
        if seed_is_nc and c_is_nc:
            score += 35.0
        elif not seed_is_nc and c_is_nc:
            score -= 35.0

        # 7. Era / release year proximity
        if avg_year is not None:
            c_yr = extract_year(date_str)
            if c_yr is not None:
                diff = abs(c_yr - avg_year)
                if diff <= 5:
                    score += 8.0 * (1.0 - diff / 6.0)

        # Mild jitter so repeated plays feel fresh without breaking relevance
        score += rng.uniform(0.0, 6.0)
        primary_artist = c_artists[0] if c_artists else path
        scored.append((score, primary_artist, path))

    scored.sort(key=lambda item: item[0], reverse=True)

    # Space out consecutive tracks by the same artist in the top tier (top 80)
    top_n = min(len(scored), 80)
    top_pool = list(scored[:top_n])
    tail_paths = [p for _, _, p in scored[top_n:]]
    rng.shuffle(tail_paths)

    ordered: list[str] = []
    recent_artists: list[str] = []
    while top_pool:
        pick_idx = 0
        for idx, (_sc, art, _p) in enumerate(top_pool[:12]):
            if art not in recent_artists[-2:]:
                pick_idx = idx
                break
        _sc, art, p = top_pool.pop(pick_idx)
        ordered.append(p)
        recent_artists.append(art)

    return ordered + tail_paths


# ---------------------------------------------------------------------------
# Online Lyrics (mirrors Rhythm: Better Lyrics -> LRCLIB -> Lyrically/Apple Music)
# ---------------------------------------------------------------------------

def parse_lrc(text: str) -> list[tuple[int, str]]:
    output: list[tuple[int, str]] = []
    plain: list[str] = []
    offsets = re.findall(r"\[offset:\s*([+-]?\d+)\s*\]", text or "", flags=re.IGNORECASE)
    offset_ms = int(offsets[-1]) if offsets else 0
    for raw_line in (text or "").splitlines():
        raw_line = raw_line.lstrip("\ufeff")
        matches = list(LRC_RE.finditer(raw_line))
        if matches:
            lyric = clean_field(WORD_TIME_RE.sub("", raw_line[matches[-1].end():]))
            for match in matches:
                fraction = match.group(3) or "0"
                millis = int((fraction + "00")[:3])
                start_ms = (int(match.group(1)) * 60 + int(match.group(2))) * 1000 + millis
                if lyric:
                    output.append((max(0, start_ms + offset_ms), lyric))
        elif raw_line.strip() and not re.match(r"^\[[a-zA-Z]+:", raw_line):
            plain.append(clean_field(raw_line))
    if output:
        return sorted(output)
    return [(-1, line) for line in plain]


def _parse_ttml_time(ts: str) -> int:
    ts = (ts or "").strip()
    if not ts:
        return -1
    if ts.endswith("s"):
        try:
            return int(float(ts[:-1]) * 1000)
        except ValueError:
            return -1
    parts = ts.split(":")
    try:
        if len(parts) == 3:
            return int((int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])) * 1000)
        if len(parts) == 2:
            return int((int(parts[0]) * 60 + float(parts[1])) * 1000)
        return int(float(parts[0]) * 1000)
    except ValueError:
        return -1


def parse_ttml(ttml_xml: str) -> list[tuple[int, str]]:
    if not ttml_xml or "<" not in ttml_xml:
        return []
    try:
        root = ET.fromstring(ttml_xml)
    except ET.ParseError:
        return []
    lines: list[tuple[int, str]] = []
    for elem in root.iter():
        tag = elem.tag.rsplit("}", 1)[-1].lower()
        if tag != "p":
            continue
        begin = elem.attrib.get("begin", "")
        start_ms = _parse_ttml_time(begin)
        text = clean_field("".join(elem.itertext()))
        if text:
            lines.append((start_ms, text))
    return sorted(lines) if lines and any(ms >= 0 for ms, _ in lines) else lines


def _fetch_better_lyrics(artist: str, title: str, album: str, duration_s: int) -> list[tuple[int, str]]:
    clean_title = strip_nightcore_title(title)
    clean_artist = FEAT_STRIP_RE.sub("", artist).strip() or artist
    attempts = [
        {"a": artist, "s": clean_title, "al": album, "d": str(duration_s) if duration_s > 0 else ""},
        {"a": clean_artist, "s": clean_title},
    ]
    for params in attempts:
        q = {k: v for k, v in params.items() if v}
        if not q.get("a") or not q.get("s"):
            continue
        url = f"{BETTER_LYRICS_BASE_URL}?{urllib.parse.urlencode(q)}"
        data = http_get_json(url, timeout=4.0)
        if not isinstance(data, dict):
            continue
        ttml = data.get("ttml")
        if isinstance(ttml, str) and ttml.strip():
            parsed = parse_ttml(ttml)
            if parsed:
                return parsed
    return []


def _fetch_lrclib_lyrics(artist: str, title: str) -> list[tuple[int, str]]:
    clean_title = strip_nightcore_title(title)
    clean_artist = FEAT_STRIP_RE.sub("", artist).strip() or artist
    canon_a = canonicalize_match(clean_artist)
    canon_t = canonicalize_match(clean_title)
    if not canon_t:
        return []

    queries = [
        {"track_name": clean_title, "artist_name": artist},
        {"q": f"{clean_artist} {clean_title}"},
    ]
    if clean_artist != artist:
        queries.append({"track_name": clean_title, "artist_name": clean_artist})

    best_plain: list[tuple[int, str]] = []
    for params in queries:
        url = f"{LRCLIB_SEARCH_URL}?{urllib.parse.urlencode(params)}"
        results = http_get_json(url, headers={"Lrclib-Client": APP_USER_AGENT}, timeout=5.0)
        if not isinstance(results, list):
            continue
        for item in results:
            if not isinstance(item, dict):
                continue
            r_artist = canonicalize_match(str(item.get("artistName") or ""))
            r_track = canonicalize_match(str(item.get("trackName") or ""))
            title_ok = canon_t and (canon_t in r_track or r_track in canon_t)
            artist_ok = (not canon_a) or (r_artist and (canon_a in r_artist or r_artist in canon_a))
            if not (title_ok and artist_ok):
                continue
            synced = item.get("syncedLyrics")
            if isinstance(synced, str) and synced.strip():
                parsed = parse_lrc(synced)
                if parsed:
                    return parsed
            plain = item.get("plainLyrics")
            if not best_plain and isinstance(plain, str) and plain.strip():
                best_plain = parse_lrc(plain)
    return best_plain


def _itunes_find_track(artist: str, title: str) -> dict[str, Any] | None:
    clean_title = strip_nightcore_title(title)
    clean_artist = FEAT_STRIP_RE.sub("", artist).strip() or artist
    term = f"{clean_artist} {clean_title}".strip()
    if not term:
        return None
    params = urllib.parse.urlencode({"term": term, "media": "music", "entity": "song", "limit": "5"})
    data = http_get_json(f"{ITUNES_SEARCH_URL}?{params}", timeout=5.0)
    if not isinstance(data, dict):
        return None
    canon_a = canonicalize_match(clean_artist)
    canon_t = canonicalize_match(clean_title)
    for item in data.get("results") or []:
        if not isinstance(item, dict):
            continue
        ia = canonicalize_match(str(item.get("artistName") or ""))
        it = canonicalize_match(str(item.get("trackName") or ""))
        if canon_t and it and (canon_t == it or canon_t in it or it in canon_t):
            if not canon_a or (ia and (canon_a == ia or canon_a in ia or ia in canon_a)):
                return item
    return None


def _fetch_lyrically_apple(artist: str, title: str) -> list[tuple[int, str]]:
    match = _itunes_find_track(artist, title)
    if not match or not match.get("trackId"):
        return []
    url = f"{LYRICALLY_APPLE_URL}?{urllib.parse.urlencode({'id': str(match['trackId'])})}"
    data = http_get_json(url, timeout=4.5)
    if not isinstance(data, dict):
        return []
    content = data.get("content")
    if isinstance(content, list):
        lines: list[tuple[int, str]] = []
        for entry in content:
            if not isinstance(entry, dict):
                continue
            text = clean_field(entry.get("text"))
            if not text:
                continue
            ts = entry.get("timestamp")
            try:
                start_ms = int(ts) if ts is not None else -1
            except (TypeError, ValueError):
                start_ms = -1
            lines.append((start_ms, text))
        if lines:
            return lines
    return []


def fetch_online_lyrics(
    artist: str,
    title: str,
    album: str,
    duration_s: int,
    cfg: dict[str, Any],
    base_data_dir: Path,
) -> list[tuple[int, str]]:
    if not (cfg.get("online_enabled", True) and cfg.get("online_lyrics", True)):
        return []
    if not normalize_artist(artist) or not title.strip():
        return []

    cache_dir = base_data_dir / "lyrics-cache"
    key = cache_key_hash(artist, strip_nightcore_title(title))
    cache_file = cache_dir / f"{key}.json"
    now = time.time()
    if cache_file.is_file():
        try:
            cached = json.loads(cache_file.read_text(encoding="utf-8"))
            ts = float(cached.get("ts", 0))
            lines = cached.get("lines") or []
            ttl = LYRICS_HIT_TTL if lines else LYRICS_MISS_TTL
            if now - ts < ttl:
                return [(int(ms), str(txt)) for ms, txt in lines]
        except (OSError, ValueError, TypeError):
            pass

    # Rhythm default priority: Better Lyrics -> LRCLIB (prefer synced) -> Lyrically (Apple Music)
    lines = _fetch_better_lyrics(artist, title, album, duration_s)
    lrc_fallback: list[tuple[int, str]] = []
    if not lines:
        lrc_lines = _fetch_lrclib_lyrics(artist, title)
        if lrc_lines and lrc_lines[0][0] >= 0:
            lines = lrc_lines
        else:
            lrc_fallback = lrc_lines
    if not lines:
        lines = _fetch_lyrically_apple(artist, title)
    if not lines and lrc_fallback:
        lines = lrc_fallback

    try:
        atomic_write_json(cache_file, {"ts": time.time(), "lines": lines})
    except OSError:
        pass
    return lines


# ---------------------------------------------------------------------------
# Online Cover Art (mirrors Rhythm: Deezer verified match -> iTunes fallback)
# ---------------------------------------------------------------------------

def _deezer_artwork_url(artist: str, title: str, album: str) -> str | None:
    clean_title = strip_nightcore_title(title)
    clean_artist = FEAT_STRIP_RE.sub("", artist).strip() or artist
    canon_a = canonicalize_match(clean_artist)
    canon_t = canonicalize_match(clean_title)
    if not canon_a or not canon_t:
        return None

    # 1. Track search (verified exact normalized artist + title match)
    q = urllib.parse.urlencode({"q": f"{clean_title} {clean_artist}"})
    data = http_get_json(f"{DEEZER_BASE_URL}/search?{q}", timeout=4.0)
    if isinstance(data, dict):
        for item in data.get("data") or []:
            if not isinstance(item, dict):
                continue
            ia = canonicalize_match(str((item.get("artist") or {}).get("name") or ""))
            it = canonicalize_match(str(item.get("title") or ""))
            if ia == canon_a and (it == canon_t or canon_t in it):
                alb = item.get("album") or {}
                url = alb.get("cover_xl") or alb.get("cover_big") or alb.get("cover_medium")
                if url:
                    return str(url)

    # 2. Album search fallback
    if album and album.lower() not in {"unknown", "nightcore mix", "osu! songs"}:
        q_alb = urllib.parse.urlencode({"q": f"{album} {clean_artist}"})
        alb_data = http_get_json(f"{DEEZER_BASE_URL}/search/album?{q_alb}", timeout=4.0)
        if isinstance(alb_data, dict):
            canon_alb = canonicalize_match(album)
            for item in alb_data.get("data") or []:
                if not isinstance(item, dict):
                    continue
                ia = canonicalize_match(str((item.get("artist") or {}).get("name") or ""))
                ialb = canonicalize_match(str(item.get("title") or ""))
                if ia == canon_a and (ialb == canon_alb or canon_alb in ialb):
                    url = item.get("cover_xl") or item.get("cover_big") or item.get("cover_medium")
                    if url:
                        return str(url)
    return None


def _itunes_artwork_url(artist: str, title: str) -> str | None:
    match = _itunes_find_track(artist, title)
    if not match:
        return None
    url = str(match.get("artworkUrl100") or match.get("artworkUrl60") or "")
    if not url:
        return None
    return re.sub(r"\d+x\d+bb", "600x600bb", url)


def art_cache_path(artist: str, title: str, album: str, base_data_dir: Path) -> Path:
    key = cache_key_hash(artist, strip_nightcore_title(title), album)
    return base_data_dir / "art-cache" / f"{key}.jpg"


def fetch_online_art(
    artist: str,
    title: str,
    album: str,
    output_path: Path,
    cfg: dict[str, Any],
    base_data_dir: Path,
    *,
    cache_only: bool = False,
) -> bool:
    if not normalize_artist(artist) or not title.strip():
        return False

    cached_img = art_cache_path(artist, title, album, base_data_dir)
    if cached_img.is_file() and cached_img.stat().st_size > 0:
        shutil.copyfile(cached_img, output_path)
        return True

    if cache_only or not (cfg.get("online_enabled", True) and cfg.get("online_art", True)):
        return False

    miss_file = cached_img.with_suffix(".miss.json")
    now = time.time()
    if miss_file.is_file():
        try:
            miss = json.loads(miss_file.read_text(encoding="utf-8"))
            if now - float(miss.get("ts", 0)) < ART_MISS_TTL:
                return False
        except (OSError, ValueError, TypeError):
            pass

    art_url = _deezer_artwork_url(artist, title, album) or _itunes_artwork_url(artist, title)
    if art_url:
        raw = http_get_bytes(art_url, timeout=6.0)
        if raw and len(raw) > 256:
            cached_img.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp_name = tempfile.mkstemp(prefix=".art-", dir=cached_img.parent)
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(raw)
                os.replace(tmp_name, cached_img)
            finally:
                try:
                    os.unlink(tmp_name)
                except FileNotFoundError:
                    pass
            shutil.copyfile(cached_img, output_path)
            return True

    try:
        atomic_write_json(miss_file, {"ts": time.time()})
    except OSError:
        pass
    return False


# ---------------------------------------------------------------------------
# Metadata lookup helper for local / cache paths
# ---------------------------------------------------------------------------

def resolve_track_meta(reference: str, cache_path: Path | None) -> tuple[str, str, str, int]:
    if cache_path and cache_path.is_file():
        try:
            for line in cache_path.read_text(encoding="utf-8").splitlines():
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 6 and parts[0] == reference:
                    try:
                        dur = int(float(parts[5]))
                    except ValueError:
                        dur = 0
                    return parts[1], parts[2], parts[3], dur
        except OSError:
            pass
    stem = Path(reference).stem
    if " - " in stem:
        art, _, tit = stem.partition(" - ")
        return tit.strip(), art.strip(), "", 0
    return stem, "", "", 0


# ---------------------------------------------------------------------------
# CLI Commands
# ---------------------------------------------------------------------------

def cmd_lastfm_setup(args: argparse.Namespace) -> int:
    cfg = load_config()
    key = (args.api_key or "").strip()
    if not key:
        print("Create a free Last.fm API key at: https://www.last.fm/api/account/create")
        key = getpass.getpass("Last.fm API key: ").strip()
    if not key:
        print("No API key provided; nothing changed.", file=sys.stderr)
        return 1
    cfg["lastfm_api_key"] = key
    cfg["lastfm_enabled"] = True
    save_config(cfg)
    print(f"✓ Last.fm API key saved in {config_path()} (mode 0600)")
    return 0


def cmd_lastfm_status(_args: argparse.Namespace) -> int:
    cfg = load_config()
    key = str(cfg.get("lastfm_api_key") or "")
    if key:
        masked = f"{key[:4]}…{key[-4:]}" if len(key) > 8 else "****"
        state = "enabled" if cfg.get("lastfm_enabled", True) else "disabled"
        print(f"Last.fm: configured ({masked}, {state})")
    else:
        print("Last.fm: not configured (using local genre/metadata recommendations; run 'jukebox lastfm-setup')")
    print(f"Online lyrics fallback: {'on' if cfg.get('online_lyrics', True) else 'off'}")
    print(f"Online cover art fallback: {'on' if cfg.get('online_art', True) else 'off'}")
    return 0


def cmd_lastfm_logout(_args: argparse.Namespace) -> int:
    cfg = load_config()
    cfg.pop("lastfm_api_key", None)
    save_config(cfg)
    print("✓ Removed Last.fm API key from Jukebox config")
    return 0


def cmd_recommend(args: argparse.Namespace) -> int:
    cfg = load_config()
    candidates = [line.rstrip("\n") for line in sys.stdin if line.rstrip("\n")]
    ordered = build_recommendations(
        seed_paths=args.seed,
        candidate_paths=candidates,
        cache_path=Path(args.cache),
        cfg=cfg,
        base_data_dir=data_dir(args.data_dir),
    )
    for path in ordered:
        print(path)
    return 0


def cmd_lyrics(args: argparse.Namespace) -> int:
    cfg = load_config()
    cache_path = Path(args.cache) if args.cache else None
    title, artist, album, dur = resolve_track_meta(args.reference, cache_path)
    if args.title:
        title = args.title
    if args.artist:
        artist = args.artist
    if args.album:
        album = args.album
    lines = fetch_online_lyrics(artist, title, album, dur, cfg, data_dir(args.data_dir))
    for start_ms, lyric in lines:
        print(f"{start_ms}{UNIT_SEPARATOR}{lyric}")
    return 0 if lines else 1


def cmd_art(args: argparse.Namespace) -> int:
    cfg = load_config()
    cache_path = Path(args.cache) if args.cache else None
    title, artist, album, _dur = resolve_track_meta(args.reference, cache_path)
    if args.title:
        title = args.title
    if args.artist:
        artist = args.artist
    if args.album:
        album = args.album
    ok = fetch_online_art(
        artist,
        title,
        album,
        Path(args.output),
        cfg,
        data_dir(args.data_dir),
        cache_only=args.cache_only,
    )
    return 0 if ok else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_setup = sub.add_parser("lastfm-setup")
    p_setup.add_argument("api_key", nargs="?")
    p_setup.set_defaults(func=cmd_lastfm_setup)

    sub.add_parser("lastfm-status").set_defaults(func=cmd_lastfm_status)
    sub.add_parser("lastfm-logout").set_defaults(func=cmd_lastfm_logout)

    p_rec = sub.add_parser("recommend")
    p_rec.add_argument("--cache", required=True)
    p_rec.add_argument("--data-dir", default="")
    p_rec.add_argument("--seed", action="append", required=True)
    p_rec.set_defaults(func=cmd_recommend)

    p_lyr = sub.add_parser("lyrics")
    p_lyr.add_argument("reference")
    p_lyr.add_argument("--cache", default="")
    p_lyr.add_argument("--data-dir", default="")
    p_lyr.add_argument("--title", default="")
    p_lyr.add_argument("--artist", default="")
    p_lyr.add_argument("--album", default="")
    p_lyr.set_defaults(func=cmd_lyrics)

    p_art = sub.add_parser("art")
    p_art.add_argument("reference")
    p_art.add_argument("output")
    p_art.add_argument("--cache", default="")
    p_art.add_argument("--data-dir", default="")
    p_art.add_argument("--title", default="")
    p_art.add_argument("--artist", default="")
    p_art.add_argument("--album", default="")
    p_art.add_argument("--cache-only", action="store_true")
    p_art.set_defaults(func=cmd_art)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    return int(args.func(args) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
