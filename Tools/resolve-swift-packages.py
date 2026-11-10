#!/usr/bin/env python3
"""Retry transient binary downloads before building, never a build or test."""
import re
import subprocess
import sys
import time


RESOLUTION_ERROR = "xcodebuild: error: Could not resolve package dependencies:"
TRANSIENT_DOWNLOAD = re.compile(
    r"failed downloading 'https://[^'\r\n]+' which is required by binary target '[^'\r\n]+': "
    r"badResponseStatusCode\((?:500|502|503|504)\)"
)


def only_transient_download_errors(output):
    _, marker, errors = output.rpartition(RESOLUTION_ERROR)
    if not marker:
        return False
    downloads = 0
    for line in errors.splitlines():
        # Xcode can repeat the final diagnostic with fatalError appended.
        line = line.strip().removesuffix("fatalError").strip()
        if not line:
            continue
        if not TRANSIENT_DOWNLOAD.fullmatch(line):
            return False
        downloads += 1
    return downloads > 0


def run_logged(command):
    output = []
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, encoding="utf-8", errors="replace") as process:
        for line in process.stdout:
            print(line, end="", flush=True)
            output.append(line)
        return subprocess.CompletedProcess(command, process.wait(), "".join(output))


def resolve_packages(arguments, run=run_logged, sleep=time.sleep):
    command = ["xcodebuild", "-resolvePackageDependencies", *arguments]
    for attempt in range(1, 4):
        print(f"Resolving Swift packages (attempt {attempt}/3)", flush=True)
        result = run(command)
        if result.returncode == 0:
            return 0
        if attempt == 3 or not only_transient_download_errors(result.stdout):
            return result.returncode
        delay = attempt * 10
        print(f"::warning::Binary download returned a temporary server error; "
              f"retrying package resolution in {delay}s", flush=True)
        sleep(delay)
    raise AssertionError("Package resolution exhausted without returning a result")


if __name__ == "__main__":
    if len(sys.argv) == 1:
        sys.exit("Usage: resolve-swift-packages.py <xcodebuild project/scheme arguments>")
    sys.exit(resolve_packages(sys.argv[1:]))
