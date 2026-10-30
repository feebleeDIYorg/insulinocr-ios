#!/usr/bin/env python3
"""Independently validate the QA archive produced by ScreenshotFlowUITests.

Reads only the latest Simulator export and requires the public synthetic image.
Does not extract files or copy Simulator data into the repository.
"""
import argparse
import csv
from datetime import datetime, timedelta
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import zipfile
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "CaseArchive-v1/"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def available(snapshot, key):
    return snapshot[key]["available"]["_0"]


def verify(path):
    fixture = (ROOT / "InsulinOCRUITests/Fixtures/SyntheticTherapy12Hours.png").read_bytes()
    fixture_hash = hashlib.sha256(fixture).hexdigest()
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, "ZIP CRC failed")
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate archive entry")
        require(all(name.startswith(PREFIX) and ".." not in PurePosixPath(name).parts
                    for name in names), "Unsafe archive path")

        def read(name):
            return archive.read(PREFIX + name)

        def document(name):
            return json.loads(read(name))

        manifest = document("manifest.json")
        require((manifest["schemaName"], manifest["schemaVersion"]) == ("CaseArchive", 1), "Wrong schema")
        require(manifest["screenshot"]["sha256"] == fixture_hash, "Export is not the public synthetic fixture")
        require(read("assets/original.png") == fixture, "Original image bytes changed during sharing")
        require((manifest["screenshot"]["pixelWidth"], manifest["screenshot"]["pixelHeight"])
                == (2622, 1206), "Wrong image dimensions")

        indexed = {entry["path"]: entry for entry in manifest["files"]}
        require(len(indexed) == len(manifest["files"]), "Duplicate manifest path")
        for name, entry in indexed.items():
            payload = read(name)
            require(len(payload) == entry["byteCount"], "Byte count mismatch: " + name)
            require(hashlib.sha256(payload).hexdigest() == entry["sha256"], "Hash mismatch: " + name)
        checksums = dict(line.split("  ", 1)[::-1]
                         for line in read("checksums.sha256").decode().splitlines())
        require(set(checksums) == set(indexed) | {"manifest.json"}, "Incomplete checksum index")
        for name, digest in checksums.items():
            require(hashlib.sha256(read(name)).hexdigest() == digest, "Checksum failed: " + name)
        require({name for name in names if not name.endswith("/")} ==
                {PREFIX + name for name in checksums} | {PREFIX + "checksums.sha256"}, "Unindexed ZIP file")

        metadata = document("case.json")
        require(metadata == manifest["case"], "Case metadata differs from manifest")
        require(metadata["status"] == "complete", "Restored case is incomplete")
        require(metadata["captureTimeSource"] == "imageMetadata", "Image timestamp was not used")
        capture = datetime.fromisoformat(metadata["captureTime"].replace("Z", "+00:00"))
        local_capture = capture.astimezone(ZoneInfo(metadata["captureTimeZoneIdentifier"]))
        require((local_capture.year, local_capture.month, local_capture.day,
                 local_capture.hour, local_capture.minute) == (2026, 1, 2, 12, 0), "Frozen capture time changed")
        active = manifest["active"]
        analysis_envelope = document("analysis/runs/" + active["analysisRunID"] + ".json")
        analysis = analysis_envelope["run"]
        extraction = analysis_envelope["extractorResult"]
        require(extraction["quality"].get("timeAxisClockIsValid") is True,
                "Current analysis has no trustworthy absolute clock")
        require(analysis["calibration"]["timeEnd"] == extraction.get("timeAxisReferenceDate"),
                "Domain calibration lost the independent clock reference")
        observations = analysis["observations"]
        glucose = [row for row in observations if row["kind"] == "glucose"]
        basal = [row for row in observations if row["kind"] == "basalRate"]
        require(len(glucose) == 144 and len(basal) == 1, "Synthetic trace recognition changed")
        require(all(abs(row["amount"] - 6) <= 0.15 for row in glucose), "Synthetic glucose exceeds tolerance")
        require(abs(basal[0]["amount"] - 0.8) <= 0.05, "Synthetic basal exceeds tolerance")
        for section in ("calibration", "confidence", "raw-ocr"):
            require("analysis/" + section + "/" + active["analysisRunID"] + ".json" in indexed,
                    "Missing analysis diagnostics")
        require("assets/diagnostic-overlay.png" in indexed, "Missing overlay")

        computations = {row["run"]["id"]: row for name in indexed if name.startswith("computations/")
                        for row in [document(name)]}
        corrections = [document(name) for name in indexed if name.startswith("corrections/")]
        require(len(computations) >= 4 and len(corrections) >= 3, "Correction history is incomplete")
        require(all(row["run"]["caseID"] == metadata["id"] for row in computations.values())
                and all(row["caseID"] == metadata["id"] for row in corrections), "History crosses case boundaries")
        require(active["correctionRevisionID"] in {row["id"] for row in corrections}, "Active correction missing")
        uncorrected = [row for row in computations.values() if not row["run"].get("correctionRevisionID")]
        require(any(abs(row["effectiveData"]["basalSegments"][0]["unitsPerHour"] - basal[0]["amount"]) <= 1e-12
                    for row in uncorrected), "Original analysis differs from its original computation")
        require(all(row["run"]["referenceDate"] == metadata["captureTime"]
                    for row in computations.values()), "A computation moved the frozen reference")
        incomplete = [row for row in computations.values() if not row["presentation"]["isComplete"]]
        require(bool(incomplete), "Critical incomplete computation was not retained")
        for row in incomplete:
            require(all(value is None for value in row["presentation"]["metrics"].values()),
                    "Incomplete presentation contains a number")
            # This test removes basal. Independent known-zero bolus/COB remain
            # internal diagnostics; the public presentation above withholds all four.
            require(all("available" not in row["run"]["result"]["current"][key]
                        for key in ("basalIOB", "totalIOB")),
                    "Unknown basal produced numeric basal/total IOB")

        current = computations[active["computationRunID"]]
        effective = current["effectiveData"]
        require(current["presentation"]["isComplete"], "Active presentation is incomplete")
        require(effective["basalSegments"][0]["unitsPerHour"] in (0.8, 0.9), "Correction was lost")
        require(not effective["boluses"] and not effective["carbohydrates"], "Simulation changed effective data")
        require(not effective["unresolvedIssues"], "Restored data has unresolved issues")
        observed_start = capture - timedelta(minutes=current["run"]["settings"]["diaMinutes"])
        cursor = observed_start
        for segment in sorted(effective["basalSegments"], key=lambda row: row["startDate"]):
            begin = max(observed_start, datetime.fromisoformat(segment["startDate"].replace("Z", "+00:00")))
            end = min(capture, datetime.fromisoformat(segment["endDate"].replace("Z", "+00:00")))
            if end <= begin:
                continue
            require(begin == cursor, "Observed basal history has a gap or overlap")
            cursor = end
        require(cursor == capture, "Observed basal history does not reach capture")

        scenarios = [document(name) for name in indexed if name.startswith("simulations/")]
        require(all(row["caseID"] == metadata["id"] for row in scenarios), "Scenario crosses case boundaries")
        scenarios = [row for row in scenarios if row["name"].startswith("Synthetic QA ")]
        require(bool(scenarios), "Saved UI scenario missing")
        scenario = max(scenarios, key=lambda row: row["createdAt"])
        baseline, simulated = scenario["baseline"], scenario["scenario"]
        require(baseline == computations[scenario["baseComputationRunID"]]["run"]["result"]["current"],
                "Scenario lost its original computation")
        for key, delta in (("basalIOB", 0), ("bolusIOB", 1), ("totalIOB", 1), ("cob", 15)):
            require(abs(available(simulated, key) - available(baseline, key) - delta) <= 1e-9,
                    "Wrong simulation delta: " + key)
        for suffix in ("basal", "bolus", "carbohydrates", "glucose"):
            for kind in ("raw", "effective"):
                require("csv/" + kind + "-" + suffix + ".csv" in indexed, "Missing therapy CSV")
        csv_basal = list(csv.DictReader(io.StringIO(read("csv/effective-basal.csv").decode())))
        require(len(csv_basal) == 1 and float(csv_basal[0]["units_per_hour"])
                == effective["basalSegments"][0]["unitsPerHour"], "CSV disagrees with effective data")
        require({"csv/raw-ambiguities.csv", "csv/simulation-events.csv"} <= set(indexed),
                "Missing ambiguity or simulation CSV")
        return {"verified_files": len(checksums),
                "analysis_runs": sum(name.startswith("analysis/runs/") for name in indexed),
                "computation_runs": len(computations), "corrections": len(corrections),
                "critical_incomplete_runs": len(incomplete), "simulations": len(scenarios),
                "original_bytes_preserved": True, "frozen_capture_time_preserved": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    args = parser.parse_args()
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.udid,
                    "org.example.insulinocr", "data"], text=True).strip())
    exports = list((container / "Library/Caches/InsulinOCRExports").glob("*.zip"))
    require(bool(exports), "UI did not create a QA archive")
    latest = max(exports, key=lambda path: path.stat().st_mtime)
    print(json.dumps(verify(latest), sort_keys=True))


if __name__ == "__main__":
    main()
