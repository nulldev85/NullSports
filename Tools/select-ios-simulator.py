#!/usr/bin/env python3
"""Select an available iPhone configuration, never a simulator's saved state."""
import json
import sys


def select_configuration(catalog):
    runtimes = {
        runtime["identifier"]: runtime
        for runtime in catalog.get("runtimes", [])
        if runtime.get("isAvailable")
        and ".iOS-" in runtime.get("identifier", "")
    }
    types = {entry["name"]: entry["identifier"] for entry in catalog.get("devicetypes", [])}
    # Use the newest installed iOS runtime and its existing supported model.
    # Device UUIDs/data are deliberately not carried into the test session.
    ordered = sorted(runtimes, key=lambda key: tuple(
        int(part) for part in runtimes[key]["version"].split(".")), reverse=True)
    for runtime in ordered:
        for device in catalog.get("devices", {}).get(runtime, []):
            if not device.get("isAvailable") or not device.get("name", "").startswith("iPhone"):
                continue
            device_type = device.get("deviceTypeIdentifier") or types.get(device["name"])
            if device_type:
                return device_type, runtime
    raise ValueError("No available iPhone model and iOS runtime for the simulator tests")


if __name__ == "__main__":
    try:
        print("\t".join(select_configuration(json.load(sys.stdin))))
    except (ValueError, KeyError, TypeError) as error:
        sys.exit(str(error))
