"""Check the built resource without displaying its credential values."""
import json
from pathlib import Path
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--require-online-subtitles", action="store_true")
parser.add_argument("--require-fanart", action="store_true")
parser.add_argument("--require-tmdb", action="store_true")
args = parser.parse_args()
app = args.app
data = json.loads((app / "LineupMetadata.json").read_text(encoding="utf-8"))
assert set(data) == {"tmdb", "tvdb", "opensubtitles", "fanart"}, "Missing Library service configuration"
assert all(isinstance(value, str) for value in data.values()), "Invalid Library metadata configuration"
if args.require_online_subtitles:
    assert data["opensubtitles"].strip(), "Missing built-in OpenSubtitles configuration"
if args.require_fanart:
    assert data["fanart"].strip(), "Missing Fanart.tv project configuration"
if args.require_tmdb:
    assert data["tmdb"].strip(), "Missing TMDB project configuration"
print("Library metadata resource packaged correctly")
