#!/usr/bin/env python3
"""TEMPORARY design harness: installs itself into the CI checkout only.

Appends the harness view to MediaViews.swift (so it can reach the stream
list's private views), shows it instead of the app when launched with
-StreamHarness <scenario>, and adds UI test targets that photograph it on
Apple TV and iPhone. Nothing here is ever committed into Lineup/ or
project.yml; the CI checkout is discarded after the run.
"""

import pathlib
import shutil

root = pathlib.Path(".")
harness = root / ".github" / "stream-harness"

views = root / "Lineup" / "Views" / "MediaViews.swift"
views.write_text(views.read_text() + "\n" + (harness / "StreamHarness.swift").read_text())


def patch(path, needle, replacement):
    text = path.read_text()
    assert needle in text, f"{path}: anchor not found: {needle!r}"
    path.write_text(text.replace(needle, replacement, 1))


patch(root / "Lineup" / "LineupApp.swift", "            RootView()\n",
      "            StreamHarnessGate { RootView() }\n")

for folder, test in (("StreamHarnessUITests", "StreamHarnessUITests.swift"),
                     ("StreamHarnessiOSUITests", "StreamHarnessiOSUITests.swift")):
    destination = root / folder
    destination.mkdir(exist_ok=True)
    shutil.copy(harness / test, destination / test)

project = root / "project.yml"
text = project.read_text()
if not text.endswith("\n"):
    text += "\n"
project.write_text(text + (harness / "project-append.yml").read_text())
print("Stream harness installed into this checkout.")
