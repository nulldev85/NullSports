"""Validate Lineup's app credentials without printing keys, tokens, or URLs."""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request


def fetch(url, token=None, payload=None):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = None
    if payload:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload).encode()
    with urllib.request.urlopen(urllib.request.Request(url, body, headers), timeout=20) as reply:
        return json.load(reply)


def main():
    tmdb = os.environ["LINEUP_TMDB_TOKEN"].strip()
    tvdb = os.environ["LINEUP_TVDB_API_KEY"].strip()
    movie = fetch("https://api.themoviedb.org/3/movie/603?append_to_response=external_ids", tmdb)
    assert movie["id"] == 603 and movie["title"] == "The Matrix"
    episode = fetch("https://api.themoviedb.org/3/tv/2316/season/1/episode/1", tmdb)
    assert episode["season_number"] == 1 and episode["episode_number"] == 1
    print("TMDB: movie metadata and numbered episode lookup verified")
    token = fetch("https://api4.thetvdb.com/v4/login", payload={"apikey": tvdb})["data"]["token"]
    series = fetch("https://api4.thetvdb.com/v4/series/73244/extended", token)["data"]
    assert series["id"] == 73244 and series["name"] == "The Office (US)"
    episodes = fetch("https://api4.thetvdb.com/v4/series/73244/episodes/official?page=0&season=1&episodeNumber=1", token)["data"]["episodes"]
    assert any(e["seasonNumber"] == 1 and e["number"] == 1 and e["seriesId"] == 73244 for e in episodes)
    film = fetch("https://api4.thetvdb.com/v4/movies/244/extended", token)["data"]
    release = film.get("first_release")
    assert release is None or isinstance(release, dict)
    print("TVDB: login, series/movie metadata, and official episode numbering verified")
    if "--install-github-secrets" in sys.argv:
        for name, value in [("LINEUP_TMDB_TOKEN", tmdb), ("LINEUP_TVDB_API_KEY", tvdb)]:
            subprocess.run(["gh", "secret", "set", name, "--repo", "nulldev85/NullSports"],
                           input=value, text=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("Both credentials saved as GitHub Actions secrets")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        print(f"Metadata validation failed: HTTP {error.code}", file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print(f"Metadata validation failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
