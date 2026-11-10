#!/usr/bin/env python3
"""Package the approved Lineup three-bar raster masters without redrawing them.

Committed asset catalogs are used directly by CI. Regeneration is an explicit
Windows maintenance task using System.Drawing, with no image API calls.
"""
from pathlib import Path
import os
import shutil
import subprocess


def main():
    root = Path(__file__).resolve().parent.parent
    shell = shutil.which("pwsh") or shutil.which("powershell")
    if os.name != "nt" or not shell:
        raise SystemExit(
            "Icon assets are already committed. To repackage approved masters, "
            "run BuildAssets/package-lineup-icon.ps1 on Windows with PowerShell. "
            "Use the committed approved masters."
        )
    subprocess.run(
        [shell, "-NoProfile", "-File", str(root / "BuildAssets/package-lineup-icon.ps1")],
        check=True,
    )


if __name__ == "__main__":
    main()
