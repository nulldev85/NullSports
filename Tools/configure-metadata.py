"""Generate the app credential resource from Actions secrets. Never log values.

App-wide API credentials are included in the installed bundle and are therefore
extractable by a determined client. These must be metadata-only project keys;
do not supply account passwords, signing secrets, or tokens with write access.
"""
import json
import os
from pathlib import Path

destination = Path(__file__).resolve().parents[1] / "Lineup/Resources/LineupMetadata.json"
values = {
    "tmdb": os.environ.get("LINEUP_TMDB_TOKEN", "").strip(),
    "tvdb": os.environ.get("LINEUP_TVDB_API_KEY", "").strip(),
}
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(values), encoding="utf-8")
for name, value in values.items():
    print(f"{name.upper()} metadata: {'configured' if value else 'provider fallback (no credential)'}")
