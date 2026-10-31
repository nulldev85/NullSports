#!/usr/bin/env python3
"""Refresh soccer competitions and clubs from ESPN.

The app uses ESPN's stable team IDs across domestic and international cups.
Raw responses are cached outside the checkout for reproducible inspection.
"""
import argparse
import concurrent.futures
import datetime
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPETITIONS = [
    ("eng.1", "Premier League", "EPL"), ("esp.1", "La Liga", "La Liga"),
    ("ger.1", "Bundesliga", "Bundesliga"), ("ita.1", "Serie A", "Serie A"),
    ("fra.1", "Ligue 1", "Ligue 1"), ("usa.1", "MLS", "MLS"),
    ("usa.nwsl", "NWSL", "NWSL"), ("uefa.champions", "Champions League", "UCL"),
    ("uefa.europa", "Europa League", "UEL"), ("uefa.europa.conf", "Conference League", "UECL"),
    ("fifa.world", "FIFA World Cup", "World Cup"), ("fifa.wwc", "FIFA Women's World Cup", "Women's World Cup"),
    ("uefa.euro", "UEFA European Championship", "EURO"),
    ("conmebol.america", "Copa América", "Copa América"),
    ("concacaf.gold", "CONCACAF Gold Cup", "Gold Cup"),
    ("caf.nations", "Africa Cup of Nations", "AFCON"),
    ("afc.asian.cup", "AFC Asian Cup", "Asian Cup"),
    ("uefa.nations", "UEFA Nations League", "Nations League"),
    ("eng.league_cup", "Carabao Cup", "Carabao Cup"),
    ("eng.fa", "FA Cup", "FA Cup"),
    ("esp.copa_del_rey", "Copa del Rey", "Copa del Rey"),
    ("esp.super_cup", "Supercopa de España", "Supercopa"),
]
CUP_IDS = {"eng.league_cup", "eng.fa", "esp.copa_del_rey", "esp.super_cup"}


def refresh(cache_dir):
    cache_dir.mkdir(parents=True, exist_ok=True)
    directory_path = ROOT / "Lineup/Resources/SportsTeams.json"
    directory = json.loads(directory_path.read_text(encoding="utf-8"))
    known_logos = {team['espnID']: team['logo'] for team in directory['teams'] if team['league'] == 'soccer'}

    def read(path, name):
        url = "https://site.api.espn.com/apis/site/v2/sports/" + path
        request = urllib.request.Request(url, headers={"User-Agent": "Lineup catalog updater", "Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
        (cache_dir / (name + ".json")).write_bytes(raw)
        return json.loads(raw), url

    def competition(spec):
        slug, name, short = spec
        metadata, source = read(f"soccer/{slug}/scoreboard?limit=1", slug + "-league")
        league = metadata["leagues"][0]
        if league["slug"] != slug:
            raise ValueError(f"Unexpected league for {slug}: {league}")
        logo = next(x["href"] for x in league["logos"] if x["href"].startswith("https://"))
        teams, team_source = read(f"soccer/{slug}/teams?limit=1000", slug + "-teams")
        rows = teams["sports"][0]["leagues"][0].get("teams", [])
        return dict(id=slug, feedID=str(league["id"]), name=name, shortName=short, logo=logo), rows, [source, team_source]

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        results = list(executor.map(competition, COMPETITIONS))
    catalog = [r[0] for r in results]
    if len({x["feedID"] for x in catalog}) != len(catalog):
        raise ValueError("Competition IDs must be unique")
    clubs = {}
    for league, rows, _ in results:
        for row in rows:
            team = row["team"]
            if not team.get("isActive", True) or team.get("isAllStar", False):
                continue
            logo = next((x["href"] for x in team.get("logos", []) if x["href"].startswith("https://")), None)
            logo = logo or known_logos.get(str(team['id']), '')
            if not logo and league['id'] not in CUP_IDS:
                raise ValueError(f"Missing official crest for {team['displayName']}")
            # ESPN supplies no crest for some lower-division cup entrants.
            # Retain those clubs with the app's existing initials fallback.
            item = clubs.setdefault(str(team["id"]), dict(league="soccer", espnID=str(team["id"]),
                name=team["displayName"], abbreviation=team.get("abbreviation", ""), logo=logo,
                division=None, competitions=[]))
            item["competitions"].append(league["id"])
    if len(clubs) < 150:
        raise ValueError("Incomplete soccer club/national-team directory")
    sources = [u for r in results for u in r[2]]
    payload = dict(updatedAt=datetime.date.today().isoformat(), sources=sources, competitions=catalog)
    (ROOT / "Lineup/Resources/SportsCompetitions.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    directory["teams"] = [t for t in directory["teams"] if t["league"] != "soccer"] + sorted(clubs.values(), key=lambda t: t["name"].casefold())
    directory["sources"] = list(dict.fromkeys(directory["sources"] + sources[1::2]))
    directory["updatedAt"] = payload["updatedAt"]
    directory_path.write_text(json.dumps(directory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Saved {len(catalog)} soccer competitions and {len(clubs)} distinct teams")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, required=True)
    refresh(parser.parse_args().cache_dir)
