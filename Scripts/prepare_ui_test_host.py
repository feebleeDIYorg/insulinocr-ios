#!/usr/bin/env python3
"""Build/install the synthetic share host on a selected iOS Simulator.

No photos, patient fixtures, Apple credentials or physical devices are used.
The host is outside the shipping app's dependency graph.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]


def select_device(devices, name, version=None, identifier=None):
    candidates = []
    prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
    for runtime, entries in devices.items():
        if not runtime.startswith(prefix):
            continue
        # Device-specific runtimes append hardware IDs (for example iPhone19-4).
        # Their digits are not part of the OS version.
        version_parts = []
        for part in runtime[len(prefix):].split("-"):
            if not part.isdecimal():
                break
            version_parts.append(int(part))
        if not version_parts:
            continue
        runtime_version = tuple(version_parts)
        for device in entries:
            if not device.get("isAvailable", True):
                continue
            if identifier:
                if device["udid"].lower() != identifier.lower():
                    continue
            elif device["name"] != name or (version and runtime_version != version):
                continue
            candidates.append((runtime_version, device))
    if not candidates:
        raise RuntimeError("Requested iOS Simulator is not available")
    if not identifier and not version:
        booted = [row for row in candidates if row[1]["state"] == "Booted"]
        if booted:
            candidates = booted
        else:
            newest = max(row[0] for row in candidates)
            candidates = [row for row in candidates if row[0] == newest]
    if len(candidates) != 1:
        raise RuntimeError("Ambiguous iOS Simulator selection; set SIMULATOR_UDID")
    return candidates[0][1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="iPhone 17 Pro")
    parser.add_argument("--os")
    parser.add_argument("--udid")
    parser.add_argument("--derived-data", default="build/DerivedData")
    args = parser.parse_args()
    if args.udid:
        uuid.UUID(args.udid)
    version = tuple(int(part) for part in args.os.split(".")) if args.os else None
    manifest = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
    device = select_device(manifest["devices"], args.device, version, args.udid)
    identifier = device["udid"]
    if device["state"] == "Shutdown":
        subprocess.run(["xcrun", "simctl", "boot", identifier], check=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", identifier, "-b"], check=True)
    derived = (ROOT / args.derived_data).resolve()
    log = ROOT / "build/share-host-preparation.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    command = ["xcodebuild", "-project", str(ROOT / "InsulinOCR.xcodeproj"),
               "-scheme", "InsulinOCRShareTestHost", "-configuration", "Debug",
               "-destination", "platform=iOS Simulator,id=" + identifier,
               "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "build"]
    print("Preparing synthetic share host on " + device["name"], flush=True)
    with log.open("w") as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-25:]), file=sys.stderr)
        raise RuntimeError("Synthetic share host build failed")
    app = derived / "Build/Products/Debug-iphonesimulator/InsulinOCRShareTestHost.app"
    if not app.is_dir():
        raise RuntimeError("Synthetic share host product is missing")
    fixture = ROOT / "InsulinOCRUITests/Fixtures/SyntheticTherapy12Hours.png"
    if (app / "Fixtures" / fixture.name).read_bytes() != fixture.read_bytes():
        raise RuntimeError("Xcode changed the synthetic fixture; copy Fixtures as a folder reference")
    subprocess.run(["xcrun", "simctl", "install", identifier, str(app)], check=True)
    if os.environ.get("GITHUB_ENV"):
        with open(os.environ["GITHUB_ENV"], "a") as output:
            output.write("SIMULATOR_UDID=" + identifier + "\n")
    print("SIMULATOR_UDID=" + identifier, flush=True)


if __name__ == "__main__":
    main()
