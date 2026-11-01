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


def is_running(processes, executable, pid):
    for line in processes.splitlines():
        fields = line.split(maxsplit=2)
        if (len(fields) == 3 and fields[0] == str(pid)
                and fields[1][0] not in "ZXT"
                and Path(fields[2]).resolve() == Path(executable).resolve()):
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


def process_record(pid):
    # Simulator apps are host processes. launchctl's service table can omit an
    # app managed by RunningBoard, so absence there does not prove termination.
    try:
        return subprocess.check_output(["ps", "-ww", "-p", str(pid), "-o", "pid=", "-o", "stat=", "-o", "comm="],
                                       text=True, stderr=subprocess.STDOUT, timeout=15)
    except subprocess.CalledProcessError as error:
        if error.returncode != 1:
            raise
        return error.output or ""


def capture_abort_backtrace(device, bundle, output):
    """Diagnostic replay only; it can never turn a failed launch into a pass."""
    path = output / "abort-backtrace.txt"
    try:
        launch = simctl("launch", "--terminate-running-process", "--wait-for-debugger",
                        "--stdout=" + str(output / "debugger-stdout.log"),
                        "--stderr=" + str(output / "debugger-stderr.log"), device, bundle)
        match = re.search(r":\s*(\d+)\s*$", launch)
        if not match:
            raise RuntimeError("No debugger replay PID: " + launch)
        with path.open("w", encoding="utf-8") as handle:
            subprocess.run(["xcrun", "lldb", "--batch", "-p", match[1],
                            "-o", "breakpoint set -n __cxa_pure_virtual",
                            "-o", "process handle -s true -n true -p true SIGABRT",
                            "-o", "continue", "-o", "thread backtrace all",
                            "-o", "process detach"], text=True, stdout=handle,
                           stderr=subprocess.STDOUT, timeout=35)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        with path.open("a", encoding="utf-8") as handle:
            handle.write("\nDebugger replay did not finish: " + str(error) + "\n")


def capture_screens(device, output, label):
    screenshot = output / (label + ".png")
    try:
        simctl("io", device, "screenshot", str(screenshot))
        return [screenshot]
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = str(error) + "\n" + str(error.output or "")
        (output / (label + "-screenshot-error.txt")).write_text(detail, encoding="utf-8")
        # Multi-display iPhones require an explicit display. simctl reports
        # the available IDs; capture each so the visible Sports panel can be
        # verified without assuming a particular fold state or display ID.
        displays = list(dict.fromkeys(re.findall(r"--display=(\d+)\b", str(error.output or ""))))
    screenshots = []
    for display in displays:
        screenshot = output / (label + "-display-" + display + ".png")
        try:
            simctl("io", device, "screenshot", "--display=" + display, str(screenshot))
            screenshots.append(screenshot)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            screenshot.with_suffix(".error.txt").write_text(str(error) + "\n" + str(error.output or ""), encoding="utf-8")
    return screenshots


def check_launch(device, bundle, executable, screen_checker, output, label):
    launch = simctl("launch", "--terminate-running-process",
                    "--stdout=" + str(output / (label + "-stdout.log")),
                    "--stderr=" + str(output / (label + "-stderr.log")), device, bundle)
    match = re.search(r":\s*(\d+)\s*$", launch)
    if not match:
        raise RuntimeError("simctl did not report an application PID: " + launch)
    pid = int(match[1])
    time.sleep(8)
    processes = process_record(pid)
    (output / (label + "-processes.txt")).write_text(processes, encoding="utf-8")
    # Preserve the screen even on a failed check: Home and a visible app are
    # useful evidence when diagnosing termination versus a bad process probe.
    screenshots = capture_screens(device, output, label)
    if not is_running(processes, executable, pid):
        raise RuntimeError(f"{label}: app PID {pid} exited after launch")
    if not screenshots:
        raise RuntimeError(f"{label}: could not capture the Sports screen")
    visible = False
    for screenshot in screenshots:
        screen = subprocess.run([str(screen_checker), str(screenshot)], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        screenshot.with_name(screenshot.stem + "-screen.txt").write_text(screen.stdout, encoding="utf-8")
        if screen.returncode == 0:
            visible = True
            break
    if not visible:
        raise RuntimeError(f"{label}: the Sports screen was not visible after launch")
    if not is_running(process_record(pid), executable, pid):
        raise RuntimeError(f"{label}: app PID {pid} exited during screen verification")
    simctl("terminate", device, bundle)
    print(f"{label}: Release app PID {pid} remained alive after launch.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--screen-checker", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("An Apple simulator host is required")
    with (args.app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
        bundle = info["CFBundleIdentifier"]
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    # The caller installs into a fresh simulator and has not launched the app.
    container = simctl("get_app_container", args.device, bundle, "data").strip()
    installed = simctl("get_app_container", args.device, bundle, "app").strip()
    executable = Path(installed) / info["CFBundleExecutable"]
    seed_sports(container, bundle, time.time())
    started = time.time()
    try:
        check_launch(args.device, bundle, executable, args.screen_checker, args.output, "cached-cricket")
        check_launch(args.device, bundle, executable, args.screen_checker, args.output, "relaunch")
    except (RuntimeError, subprocess.SubprocessError):
        capture_abort_backtrace(args.device, bundle, args.output)
        raise
    finally:
        try:
            log = simctl("spawn", args.device, "log", "show", "--last", "2m", "--predicate", 'process == "Lineup"', timeout=15)
            (args.output / "app.log").write_text(log, encoding="utf-8")
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
        report_directories = [Path.home() / "Library/Logs/DiagnosticReports",
            Path.home() / "Library/Logs/DiagnosticReports/Retired",
            Path.home() / "Library/Developer/CoreSimulator/Devices" / args.device / "data/Library/Logs/CrashReporter"]
        for directory in report_directories:
            for pattern in ["Lineup*.ips", "Lineup*.crash"]:
                for report in directory.glob(pattern):
                    try:
                        if report.stat().st_mtime >= started:
                            shutil.copyfile(report, args.output / report.name)
                    except FileNotFoundError:
                        pass  # CrashReporter can move a report into Retired.


if __name__ == "__main__":
    main()
