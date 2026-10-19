"""Verify project authentication and real title logos without logging the key."""
import json
import os
from pathlib import PurePosixPath
import struct
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def fetch(opener, url, limit, accept):
    request = urllib.request.Request(url, headers={"Accept": accept})
    with opener.open(request, timeout=15) as response:
        data = response.read(limit + 1)
        assert len(data) <= limit, "Oversized service response"
        return data


def image_url(value):
    if not isinstance(value, str):
        return False
    parts = urllib.parse.urlsplit(value)
    return (parts.scheme == "https" and parts.hostname == "assets.fanart.tv"
            and parts.port is None and parts.username is None and parts.password is None
            and not parts.query and not parts.fragment and parts.path.startswith("/fanart/")
            and ".." not in parts.path and PurePosixPath(parts.path).suffix.lower() in (".png", ".jpg", ".jpeg", ".webp"))


def main():
    key = os.environ["LINEUP_FANART_API_KEY"].strip()
    assert key, "Project key missing"
    opener = urllib.request.build_opener(NoRedirect())
    for route, external_id, field, logo_fields in (
        ("movies", "603", "tmdb_id", ("hdmovielogo", "movielogo")),
        ("movies", "tt0133093", "imdb_id", ("hdmovielogo", "movielogo")),
        ("tv", "121361", "thetvdb_id", ("hdtvlogo", "clearlogo")),
    ):
        query = urllib.parse.urlencode({"api_key": key})
        url = f"https://webservice.fanart.tv/v3.2/{route}/{external_id}?{query}"
        value = json.loads(fetch(opener, url, 2_000_000, "application/json"))
        assert str(value.get(field)) == external_id, "Reply identity mismatch"
        candidates = []
        for quality, logo_field in enumerate(logo_fields):
            for row in value.get(logo_field, []):
                language = row.get("lang", "").lower()
                if language not in ("en", "", "00") or not image_url(row.get("url")):
                    continue
                candidates.append((0 if language == "en" else 2, quality, -int(row.get("likes", 0)), row["url"]))
        assert candidates, "No matching title logo"
        asset_url = sorted(candidates)[0][3]
        # This separate asset request has no project key or API authorization.
        data = fetch(opener, asset_url, 2_000_000, "image/*")
        assert data.startswith(b"\x89PNG\r\n\x1a\n"), "Expected transparent PNG logo"
        assert data[12:16] == b"IHDR" and len(data) > 32, "Invalid PNG header"
        width, height = struct.unpack(">II", data[16:24])
        assert 0 < width <= 8000 and 0 < height <= 4000 and width * height <= 10_000_000, "Invalid logo size"
        label = "TVDB show" if route == "tv" else "IMDb movie" if external_id.startswith("tt") else "TMDB movie"
        print(f"Fanart.tv: {label} identity, English/neutral logo and public PNG verified ({width}x{height})")
    if "--install-github-secret" in sys.argv:
        subprocess.run(["gh", "secret", "set", "LINEUP_FANART_API_KEY", "--repo", "nulldev85/NullSports"],
                       input=key, text=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("Fanart.tv project key saved as a repository Actions secret")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        print(f"Fanart.tv verification failed: HTTP {error.code}", file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        # Exceptions from network clients can contain the credentialed URL.
        print(f"Fanart.tv verification failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
