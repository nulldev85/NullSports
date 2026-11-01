#!/usr/bin/env python3
"""Cold-launch the actual Release app with saved Sports data, outside XCTest."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time


def is_running(processes, bundle, pid):
    for line in processes.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) == 3 and fields[0] == str(pid) and bundle in fields[2]:
            return True
    return False


def seed_sports(container, bundle, now):
    """Only called for the workflow's newly created, disposable simulator."""
    container = Path(container)
    profile_id = "11111111-2222-3333-4444-555555555555"
    preferences = container / "Library/Preferences" / (bundle + ".plist")
    preferences.parent.mkdir(parents=True, exist_ok=True)
    profile = {"id": profile_id, "name": "Launch fixture", "serverURL": "https://launch-fixture.invalid", "username": "fixture"}
    preferences.write_bytes(plistlib.dumps({
        "NullSports.profiles": json.dumps([profile]).encode(),
        "NullSports.activeProfile": profile_id,
    }))
    # Swift Codable dates count from 2001-01-01, not the Unix epoch.
    swift_now = now - 978307200
    games = []
    for key, away, home, away_code, home_code, format_, start, state, score in [
        ("test", "India A", "New Zealand A", "IND-A", "NZ-A", "Test", swift_now - 2 * 86400, "in", "333/8 (99 ov)"),
        ("women", "Adelaide Strikers Women", "Melbourne Stars Women", "AS-W", "MS-W", "T20", swift_now - 600, "in", "140/6 (20 ov)"),
        ("upcoming", "India", "Australia", "IND", "AUS", "T20", swift_now + 3600, "pre", ""),
    ]:
        games.append({
            "id": "cricket-launch-" + key, "league": "cricket", "start": start,
            "awayTeam": away, "homeTeam": home, "awayAbbreviation": away_code, "homeAbbreviation": home_code,
            "awayLogo": "", "homeLogo": "", "awayScore": score, "homeScore": score,
            "status": "Day 3" if format_ == "Test" else "Live", "state": state, "broadcast": "",
            "cricket": {"end": swift_now + 3 * 86400, "format": format_},
        })
    schedule = container / "Library/Caches/lineup-schedule.json"
    schedule.parent.mkdir(parents=True, exist_ok=True)
    schedule.write_text(json.dumps({"savedAt": swift_now, "games": {"cricket": games}}), encoding="utf-8")


def simctl(*args, timeout=45):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True, stderr=subprocess.STDOUT, timeout=timeout)


def check_launch(device, bundle, output, label):
    launch = simctl("launch", "--terminate-running-process", device, bundle)
    match = re.search(r":\s*(\d+)\s*$", launch)
    if not match:
        raise RuntimeError("simctl did not report an application PID: " + launch)
    pid = int(match[1])
    time.sleep(8)
    processes = simctl("spawn", device, "launchctl", "list")
    (output / (label + "-processes.txt")).write_text(processes, encoding="utf-8")
    if not is_running(processes, bundle, pid):
        raise RuntimeError(f"{label}: app PID {pid} exited after launch")
    simctl("io", device, "screenshot", str(output / (label + ".png")))
    simctl("terminate", device, bundle)
    print(f"{label}: Release app PID {pid} remained alive after launch.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("An Apple simulator host is required")
    with (args.app / "Info.plist").open("rb") as handle:
        bundle = plistlib.load(handle)["CFBundleIdentifier"]
    args.output.mkdir(parents=True, exist_ok=True)
    # The caller installs into a fresh simulator and has not launched the app.
    container = simctl("get_app_container", args.device, bundle, "data").strip()
    seed_sports(container, bundle, time.time())
    try:
        check_launch(args.device, bundle, args.output, "cached-cricket")
        check_launch(args.device, bundle, args.output, "relaunch")
    finally:
        try:
            log = simctl("spawn", args.device, "log", "show", "--last", "2m", "--predicate", 'process == "Lineup"', timeout=15)
            (args.output / "app.log").write_text(log, encoding="utf-8")
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
        for report in (Path.home() / "Library/Logs/DiagnosticReports").glob("Lineup*.ips"):
            shutil.copyfile(report, args.output / report.name)


if __name__ == "__main__":
    main()
