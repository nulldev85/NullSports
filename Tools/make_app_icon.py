#!/usr/bin/env python3
"""Legacy entry point for packaging the approved Lineup play-icon artwork."""
from pathlib import Path
import runpy

if __name__ == "__main__":
    runpy.run_path(
        str(Path(__file__).resolve().parent.parent / "BuildAssets/generate-icons.py"),
        run_name="__main__",
    )
