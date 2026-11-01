#!/usr/bin/env python3
"""Open the CI-created device in the selected Xcode's simulator frontend."""
import argparse
import os
from pathlib import Path
import subprocess


def frontend_command(developer, device):
    developer = Path(developer).resolve()
    # Xcode 27 moved bundled apps up from Contents/Developer/Applications
    # and replaced Simulator with Device Hub. Its device selection uses a URL.
    hub = developer.parent / "Applications/DeviceHub.app"
    if hub.is_dir():
        return ["open", "-a", str(hub), "devices://device/open?id=" + device]
    simulator = developer / "Applications/Simulator.app"
    if simulator.is_dir():
        return ["open", "-a", str(simulator), "--args", "-CurrentDeviceUDID", device]
    raise RuntimeError(f"Selected Xcode has neither Device Hub nor Simulator: {hub}; {simulator}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    args = parser.parse_args()
    developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(
        ["xcode-select", "--print-path"], text=True, timeout=15).strip()
    command = frontend_command(developer, args.device)
    print("Opening selected Xcode frontend: " + command[2], flush=True)
    subprocess.run(command, check=True, timeout=30)


if __name__ == "__main__":
    main()
