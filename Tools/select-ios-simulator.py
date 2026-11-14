#!/usr/bin/env python3
"""Select an available iPhone configuration, never a simulator's saved state."""
import argparse
import json
import sys


def select_configuration(catalog, model="standard"):
    runtimes = {
        runtime["identifier"]: runtime
        for runtime in catalog.get("runtimes", [])
        if runtime.get("isAvailable")
        and ".iOS-" in runtime.get("identifier", "")
    }
    types = {entry["name"]: entry["identifier"] for entry in catalog.get("devicetypes", [])}
    # A Duo-only runtime can be newer than the standard iPhone runtime.
    # Choose a compatible pair for the layout under test.
    # Device UUIDs/data are deliberately not carried into the test session.
    ordered = sorted(runtimes, key=lambda key: tuple(
        int(part) for part in runtimes[key]["version"].split(".")), reverse=True)
    for runtime in ordered:
        for device in catalog.get("devices", {}).get(runtime, []):
            if not device.get("isAvailable"):
                continue
            device_type = device.get("deviceTypeIdentifier") or types.get(device.get("name"))
            if not device_type:
                continue
            type_name = device_type.rsplit(".", 1)[-1]
            if type_name.startswith("iPhone") and ("Duo" in type_name) == (model == "duo"):
                return device_type, runtime
    raise ValueError(f"No available {model} iPhone model and iOS runtime for the simulator tests")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=["standard", "duo"], default="standard")
    args = parser.parse_args()
    try:
        print("\t".join(select_configuration(json.load(sys.stdin), args.model)))
    except (ValueError, KeyError, TypeError) as error:
        sys.exit(str(error))
