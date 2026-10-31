"""Check the shipped team directory and logo coverage without Xcode/network."""
import json
import hashlib
import unittest
from collections import Counter
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
CUPS = {"eng.league_cup": "3920", "eng.fa": "3918", "esp.copa_del_rey": "3951", "esp.super_cup": "8102"}


class TeamDirectoryChecks(unittest.TestCase):
    def setUp(self):
        self.directory = json.loads((ROOT / "Lineup/Resources/SportsTeams.json").read_text(encoding="utf-8"))
        self.teams = self.directory["teams"]

    def test_complete_team_leagues_and_unique_schedule_keys(self):
        counts = Counter(team["league"] for team in self.teams)
        for league, expected in {"nfl": 32, "nba": 30, "nhl": 32, "mlb": 30}.items():
            self.assertEqual(counts[league], expected)
        self.assertEqual(set(counts), {"nfl", "nba", "nhl", "mlb", "ncaaf", "soccer"})
        self.assertGreater(counts['soccer'], 300)
        college = [team for team in self.teams if team["league"] == "ncaaf"]
        self.assertGreater(len(college), 250)
        self.assertEqual(set(team["division"] for team in college), {"FBS", "FCS"})
        keys = [(team["league"].upper(), 'ESPN:' + team['espnID'] if team['league'] == 'soccer' else team["abbreviation"].upper()) for team in self.teams]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertTrue(all(team["name"] and team["espnID"] for team in self.teams))

    def test_real_team_and_league_logos_on_both_platforms(self):
        for team in self.teams:
            if not team['logo']:
                self.assertEqual(team['league'], 'soccer')
                self.assertTrue(set(team['competitions']).issubset(CUPS),
                                'Only cup-only clubs without an upstream crest may use the initials fallback')
            else:
                self.assertEqual(urlparse(team['logo']).scheme, 'https')
                self.assertEqual(urlparse(team['logo']).hostname, 'a.espncdn.com')
        for platform in ("Lineup", "iPhone"):
            for league in {team["league"] for team in self.teams}:
                if league == 'soccer':
                    catalog = json.loads((ROOT / 'Lineup/Resources/SportsCompetitions.json').read_text(encoding='utf-8'))
                    self.assertEqual(len(catalog['competitions']), 22)
                    self.assertTrue(all(urlparse(c['logo']).hostname == 'a.espncdn.com' for c in catalog['competitions']))
                    continue
                asset = ROOT / platform / "Assets.xcassets" / f"League-{league}.imageset"
                description = json.loads((asset / "Contents.json").read_text(encoding="utf-8"))
                files = [image["filename"] for image in description["images"] if "filename" in image]
                self.assertTrue(files)
                self.assertTrue(all((asset / file).is_file() for file in files))

    def test_existing_schedule_codes_match_the_directory(self):
        teams = {(team["league"], team["abbreviation"]): team["name"] for team in self.teams}
        for league, abbreviation, name in [("nfl", "BUF", "Buffalo Bills"), ("nba", "BOS", "Boston Celtics"),
                ("nhl", "MTL", "Montreal Canadiens"), ("nhl", "WSH", "Washington Capitals"),
                ("mlb", "ATH", "Athletics"), ("ncaaf", "KENN", "Kennesaw State Owls"),
                ("ncaaf", "MOST", "Missouri State Bears")]:
            self.assertEqual(teams[(league, abbreviation)], name)

    def test_soccer_competitions_share_ids_and_racing_marks_are_original(self):
        catalog = json.loads((ROOT / 'Lineup/Resources/SportsCompetitions.json').read_text(encoding='utf-8'))['competitions']
        self.assertEqual(len({c['id'] for c in catalog}), 22)
        self.assertEqual(len({c['feedID'] for c in catalog}), 22)
        self.assertEqual({c['id']: c['feedID'] for c in catalog if c['id'] in CUPS}, CUPS)
        known = {c['id'] for c in catalog}
        for team in self.teams:
            if team['league'] == 'soccer':
                self.assertTrue(team['competitions'])
                self.assertTrue(set(team['competitions']).issubset(known))
        for competition in CUPS:
            self.assertTrue(any(competition in t.get('competitions', []) for t in self.teams))
        marks = json.loads((ROOT / 'Lineup/Resources/SportsArtworkSources.json').read_text())
        self.assertEqual(set(marks), {'f1', 'nascar'})
        self.assertEqual(urlparse(marks['nascar']['source']).hostname, 'rf.nascar.com')
        for platform in ('Lineup', 'iPhone'):
            for league, mark in marks.items():
                data = (ROOT / platform / 'Assets.xcassets' / f'League-{league}.imageset' / 'logo.png').read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), mark['sha256'])


if __name__ == "__main__":
    unittest.main()
