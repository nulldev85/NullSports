"""Check the shipped team directory and logo coverage without Xcode/network."""
import json
import unittest
from collections import Counter
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]


class TeamDirectoryChecks(unittest.TestCase):
    def setUp(self):
        self.directory = json.loads((ROOT / "Lineup/Resources/SportsTeams.json").read_text(encoding="utf-8"))
        self.teams = self.directory["teams"]

    def test_complete_team_leagues_and_unique_schedule_keys(self):
        counts = Counter(team["league"] for team in self.teams)
        for league, expected in {"nfl": 32, "nba": 30, "nhl": 32, "mlb": 30}.items():
            self.assertEqual(counts[league], expected)
        self.assertEqual(set(counts), {"nfl", "nba", "nhl", "mlb", "ncaaf"})
        college = [team for team in self.teams if team["league"] == "ncaaf"]
        self.assertGreater(len(college), 250)
        self.assertEqual(set(team["division"] for team in college), {"FBS", "FCS"})
        keys = [(team["league"].upper(), team["abbreviation"].upper()) for team in self.teams]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertTrue(all(team["name"] and team["espnID"] for team in self.teams))

    def test_real_team_and_league_logos_on_both_platforms(self):
        self.assertTrue(all(urlparse(team["logo"]).scheme == "https"
                            and urlparse(team["logo"]).hostname == "a.espncdn.com" for team in self.teams))
        for platform in ("Lineup", "iPhone"):
            for league in {team["league"] for team in self.teams}:
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


if __name__ == "__main__":
    unittest.main()
