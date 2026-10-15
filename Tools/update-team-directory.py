#!/usr/bin/env python3
"""Refresh the bundled Settings directory from ESPN's active team lists.

Use --cached-dir for previously downloaded lineup-team-*.json source files.
College membership comes from the season's FBS/FCS groups; intersecting with
the active directory excludes historical teams and all-star placeholders.
"""
import argparse
import datetime
import json
import re
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATHS = {"nfl": "football/nfl", "nba": "basketball/nba",
         "nhl": "hockey/nhl", "mlb": "baseball/mlb", "ncaaf": "football/college-football"}


def build(season, cached_dir=None):
    sources = []

    def read(url, filename):
        sources.append(url)
        if cached_dir:
            return json.loads((cached_dir / filename).read_text(encoding="utf-8-sig"))
        with urllib.request.urlopen(url, timeout=30) as response:
            return json.load(response)

    divisions = {}
    for group, label in [(80, "FBS"), (81, "FCS")]:
        url = ("https://sports.core.api.espn.com/v2/sports/football/leagues/college-football/"
               f"seasons/{season}/types/2/groups/{group}/teams?limit=1000")
        members = read(url, f"lineup-team-members-{group}.json")
        if members["pageCount"] != 1:
            raise ValueError("College membership must include every page")
        for item in members["items"]:
            team_id = re.search(r"/teams/(\d+)", item["$ref"]).group(1)
            divisions.setdefault(team_id, label)

    teams = []
    for league, path in PATHS.items():
        payload = read(f"https://site.api.espn.com/apis/site/v2/sports/{path}/teams?limit=1000",
                       f"lineup-team-catalog-{league}.json")
        for row in payload["sports"][0]["leagues"][0]["teams"]:
            team = row["team"]
            if not team.get("isActive", True) or team.get("isAllStar", False):
                continue
            if league == "ncaaf" and team["id"] not in divisions:
                continue
            teams.append(dict(league=league, espnID=team["id"], name=team["displayName"],
                              abbreviation=team["abbreviation"], logo=team["logos"][0]["href"],
                              division=divisions.get(team["id"]) if league == "ncaaf" else None))
    keys = [(t["league"], t["abbreviation"].upper()) for t in teams]
    if len(set(keys)) != len(keys):
        raise ValueError("Ambiguous team codes would collide with existing My Teams identities")
    for league, expected in {"nfl": 32, "nba": 30, "nhl": 32, "mlb": 30}.items():
        if sum(t["league"] == league for t in teams) != expected:
            raise ValueError(f"Check the complete {league} team list before updating")
    for division in ("FBS", "FCS"):
        if sum(t["division"] == division for t in teams) < 120:
            raise ValueError(f"Incomplete {division} directory")
    teams.sort(key=lambda t: (list(PATHS).index(t["league"]), t["name"].casefold()))
    return dict(updatedAt=datetime.date.today().isoformat(), season=season, sources=sources, teams=teams)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--season", type=int, default=datetime.date.today().year)
    parser.add_argument("--cached-dir", type=Path)
    args = parser.parse_args()
    directory = build(args.season, args.cached_dir)
    target = ROOT / "Lineup/Resources/SportsTeams.json"
    target.write_text(json.dumps(directory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Saved {len(directory['teams'])} teams to {target.relative_to(ROOT)}")
