#!/usr/bin/env python3
"""TEMPORARY design harness: installs itself into the CI checkout only.

Copies the mock seeder into the app's sources, calls it first thing at launch,
lets the unsigned simulator build read the mock password, and adds a UI test
target and scheme to the generated project. Nothing here is ever committed
into Lineup/ or project.yml; the CI checkout is discarded after the run.
"""

import pathlib
import shutil

root = pathlib.Path(".")
harness = root / ".github" / "live-harness"

destination = root / "Lineup" / "LiveHarness"
destination.mkdir(parents=True, exist_ok=True)
shutil.copy(harness / "LiveHarnessSeeder.swift", destination / "LiveHarnessSeeder.swift")


def patch(path, needle, replacement):
    text = path.read_text()
    assert needle in text, f"{path}: anchor not found: {needle!r}"
    path.write_text(text.replace(needle, replacement, 1))


register = "        LineupFonts.register()\n"
patch(root / "Lineup" / "LineupApp.swift", register, "        LiveHarnessSeeder.seed()\n" + register)

password = "    static func password(profileID: UUID) -> String? {\n"
patch(root / "Lineup" / "Services" / "KeychainStore.swift", password,
      password + "        if let harness = LiveHarnessSeeder.password(for: profileID) { return harness }\n")

tests = root / "LiveHarnessUITests"
tests.mkdir(exist_ok=True)
shutil.copy(harness / "LiveHarnessUITests.swift", tests / "LiveHarnessUITests.swift")

project = root / "project.yml"
text = project.read_text()
if not text.endswith("\n"):
    text += "\n"
project.write_text(text + (harness / "project-append.yml").read_text())
print("Harness installed into this checkout.")
