"""Offline QA only: compare an OCR JSON with a CamAPS text export.

Reference data is never used as input to the recognition engine. Outputs may
contain health data and must remain outside Git (for example PrivateFixtures).
"""
import argparse
import bisect
import datetime as dt
import hashlib
import json
import pathlib
import re
from zoneinfo import ZoneInfo

SECTIONS = {"Meal": "carbohydrates", "Insulin_bolus": "bolus",
            "Insulin_infusion": "basal", "Glucose_concentration": "glucose"}
UNITS = {"carbohydrates": "(g)", "bolus": "(U)", "basal": "(U/h)", "glucose": "(mmol/L)"}


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def read_reference(path, timezone):
    result = {kind: [] for kind in SECTIONS.values()}
    section = None
    units_valid = False
    for line in pathlib.Path(path).read_text(encoding="utf-8-sig").splitlines():
        if "***" in line:
            section = SECTIONS.get(line.split()[0])
            units_valid = False
            continue
        if section is None:
            continue
        if line.startswith("(dd/mm/yyyy hh:mm)"):
            units_valid = UNITS[section] in line
        match = re.match(r"^(\d{2}/\d{2}/\d{4} \d{2}:\d{2})\s+([\d.,]+)", line)
        if match:
            if not units_valid:
                raise ValueError(f"Missing or unsupported reference units for {section}")
            local = dt.datetime.strptime(match[1], "%d/%m/%Y %H:%M").replace(tzinfo=ZoneInfo(timezone))
            result[section].append((local.timestamp(), float(match[2].replace(",", "."))))
    return {key: sorted(values) for key, values in result.items()}


def pair_by_time(observed, expected, tolerance=150, compatible=lambda a, b: True):
    """One-to-one matching: duplicated OCR points cannot inflate recall."""
    a = sorted(enumerate(observed), key=lambda item: item[1][0])
    b = sorted(enumerate(expected), key=lambda item: item[1][0])
    previous = [(0, 0.0)] * (len(b) + 1)
    actions = [bytearray(len(b) + 1) for _ in range(len(a) + 1)]
    for i, (_, row_a) in enumerate(a, 1):
        current = [(0, 0.0)] * (len(b) + 1)
        for j, (_, row_b) in enumerate(b, 1):
            best, action = previous[j], 1
            if current[j - 1] > best:
                best, action = current[j - 1], 2
            distance = abs(row_a[0] - row_b[0])
            if distance <= tolerance and compatible(row_a, row_b):
                candidate = (previous[j - 1][0] + 1, previous[j - 1][1] - distance)
                if candidate > best:
                    best, action = candidate, 3
            current[j], actions[i][j] = best, action
        previous = current
    pairs, i, j = [], len(a), len(b)
    while i and j:
        action = actions[i][j]
        if action == 3:
            pairs.append((a[i - 1][0], b[j - 1][0], abs(a[i - 1][1][0] - b[j - 1][1][0])))
            i, j = i - 1, j - 1
        elif action == 1:
            i -= 1
        else:
            j -= 1
    return list(reversed(pairs))


def point_metrics(observed, expected):
    pairs = pair_by_time(observed, expected)
    known = [(i, j, distance) for i, j, distance in pairs if observed[i][1] is not None]
    errors = [abs(observed[i][1] - expected[j][1]) for i, j, _ in known]
    return {"observedCount": len(observed), "referenceCount": len(expected),
            "matchedCount": len(pairs), "numericMatchedCount": len(known),
            "precision": len(known) / len(observed) if observed else None,
            "recall": len(known) / len(expected) if expected else None,
            "mae": sum(errors) / len(errors) if errors else None,
            "maximumTimeErrorMinutes": max((p[2] / 60 for p in pairs), default=None)}


def pair_events(observed, expected, tolerance=150):
    """Maximum matching/minimum time error without ordering simultaneous kinds."""
    size = len(observed) + len(expected) + 2
    source, sink = size - 2, size - 1
    graph = [[] for _ in range(size)]

    def edge(a, b, cost):
        graph[a].append([b, 1, cost, len(graph[b])])
        graph[b].append([a, 0, -cost, len(graph[a]) - 1])

    links = []
    for i, a in enumerate(observed):
        edge(source, i, 0)
        for j, b in enumerate(expected):
            distance = abs(a[0] - b[0])
            if distance <= tolerance and (a[2] == "unknown" or a[2] == b[2]):
                links.append((i, j, len(graph[i]), distance))
                edge(i, len(observed) + j, distance)
    for j in range(len(expected)):
        edge(len(observed) + j, sink, 0)
    while True:
        distance = [float("inf")] * size
        previous = [None] * size
        distance[source] = 0
        for _ in range(size - 1):
            changed = False
            for node, edges in enumerate(graph):
                for index, (target, capacity, cost, _) in enumerate(edges):
                    if capacity and distance[node] + cost < distance[target]:
                        distance[target] = distance[node] + cost
                        previous[target] = (node, index)
                        changed = True
            if not changed:
                break
        if previous[sink] is None:
            break
        node = sink
        while node != source:
            parent, index = previous[node]
            connection = graph[parent][index]
            connection[1] -= 1
            graph[node][connection[3]][1] += 1
            node = parent
    return [(i, j, delta) for i, j, index, delta in links if graph[i][index][1] == 0]


def basal_metrics(steps, reference, start, end):
    # Explicit assumption: exported rates apply forward until the next row.
    times = [row[0] for row in reference]
    boundaries = sorted({start, end} | {t for t in times if start < t < end}
                        | {t for a, b, _ in steps for t in (a, b) if start < t < end})
    covered = error = 0.0
    for a, b in zip(boundaries, boundaries[1:]):
        middle = (a + b) / 2
        index = bisect.bisect_right(times, middle) - 1
        detected = [value for lo, hi, value in steps if lo <= middle < hi and value is not None]
        if index >= 0 and len(detected) == 1:
            covered += b - a
            error += abs(detected[0] - reference[index][1]) * (b - a)
    return {"comparedSeconds": covered,
            "comparisonCoverage": covered / (end - start) if end > start else None,
            "timeWeightedMAEUnitsPerHour": error / covered if covered else None,
            "referenceSemantics": "piecewiseConstantForward; verify export interval semantics before release gating"}


def compare(analysis, reference):
    if "layout" not in analysis:
        return {"status": "rejected", "error": analysis.get("error")}
    if (analysis.get("quality", {}).get("timeAxisClockIsValid") is False
            or ("timeAxisReferenceDate" in analysis and analysis["timeAxisReferenceDate"] is None)):
        return {"status": "rejected", "error": "untrustedTimeAxis",
                "algorithmVersion": analysis.get("algorithmVersion")}
    end = timestamp(analysis["capturedAt"])
    start = end - analysis["layout"]["estimatedVisibleHours"] * 3600
    visible = {key: [row for row in rows if start <= row[0] <= end]
               for key, rows in reference.items()}
    glucose = [(timestamp(row["date"]), row.get("mmolPerLiter")) for row in analysis["glucoseSamples"]]
    events = [(timestamp(row["date"]), row["amount"].get("known", {}).get("_0"), row["kind"])
              for row in analysis["therapyEvents"] if row["isCompleteStem"]]
    expected_events = sorted((time, amount, kind) for kind in ("bolus", "carbohydrates")
                             for time, amount in visible[kind])
    pairs = pair_events(events, expected_events)
    matched_observed = {i for i, _, _ in pairs}
    known = [(i, j) for i, j, _ in pairs if events[i][1] is not None]
    event_metrics = {"detectedStemCount": len(events), "referenceEventCount": len(expected_events),
                     "matchedStemCount": len(pairs),
                     "stemRecall": len(pairs) / len(expected_events) if expected_events else None,
                     "unknownAmountCount": sum(row[1] is None for row in events),
                     "unmatchedKnownAmountCount": sum(i not in matched_observed and row[1] is not None for i, row in enumerate(events)),
                     "referenceEventsNearCaptureCount": sum(end - row[0] <= 150 for row in expected_events),
                     "maximumTimeErrorMinutes": max((delta / 60 for _, _, delta in pairs), default=None),
                     "wrongKnownAmountOrKindCount": sum(events[i][2] != expected_events[j][2]
                         or abs(events[i][1] - expected_events[j][1]) > 0.01 for i, j in known),
                     "unmatchedDetectedStemCount": len(events) - len(pairs)}
    steps = [(timestamp(row["startDate"]), timestamp(row["endDate"]), row.get("rateUnitsPerHour"))
             for row in analysis["basalSteps"]]
    return {"status": analysis["status"], "algorithmVersion": analysis["algorithmVersion"],
            "glucose": point_metrics(glucose, visible["glucose"]), "events": event_metrics,
            "basal": basal_metrics(steps, reference["basal"], start, end)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("analysis", type=pathlib.Path)
    parser.add_argument("reference", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--timezone", default="Europe/Zurich")
    args = parser.parse_args()
    report = compare(json.loads(args.analysis.read_text()), read_reference(args.reference, args.timezone))
    report.update({"qaSchemaVersion": 1, "referenceTimezone": args.timezone,
                   "matchingToleranceSeconds": 150,
                   "analysisSHA256": hashlib.sha256(args.analysis.read_bytes()).hexdigest(),
                   "referenceSHA256": hashlib.sha256(args.reference.read_bytes()).hexdigest()})
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
