"""Generate the app credential resource from Actions secrets. Never log values.

App-wide API credentials are included in the installed bundle and are therefore
extractable by a determined client. These must be scoped project/consumer keys;
do not supply account passwords, signing secrets, or tokens with write access.
The OpenSubtitles key is an app consumer key for anonymous subtitle access.
"""
import json
import os
from pathlib import Path

destination = Path(__file__).resolve().parents[1] / "Lineup/Resources/LineupMetadata.json"
values = {
    "tmdb": os.environ.get("LINEUP_TMDB_TOKEN", "").strip(),
    "tvdb": os.environ.get("LINEUP_TVDB_API_KEY", "").strip(),
    "opensubtitles": os.environ.get("LINEUP_OPENSUBTITLES_API_KEY", "").strip(),
}
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(values), encoding="utf-8")
for name, value in values.items():
    print(f"{name.upper()} metadata: {'configured' if value else 'provider fallback (no credential)'}")
