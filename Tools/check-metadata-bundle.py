"""Check the built resource without displaying its credential values."""
import json
from pathlib import Path
import sys

app = Path(sys.argv[1])
data = json.loads((app / "LineupMetadata.json").read_text(encoding="utf-8"))
assert set(data) == {"tmdb", "tvdb"}, "Missing Library metadata configuration"
assert all(isinstance(value, str) for value in data.values()), "Invalid Library metadata configuration"
print("Library metadata resource packaged correctly")
