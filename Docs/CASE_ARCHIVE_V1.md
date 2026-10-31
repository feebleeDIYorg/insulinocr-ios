# CaseArchive v1

`CaseArchive v1` is the portable, English-language QA representation of one
InsulinOCR case. The archive is a ZIP file. Paths are UTF-8, relative, use `/`,
and never contain case titles or other user-provided path fragments.

## Normative rules

- `schemaVersion` is exactly `1`.
- JSON uses UTF-8, RFC 3339 timestamps with an explicit offset, and decimal JSON
  numbers. Non-finite numbers are forbidden.
- CSV uses UTF-8, comma separators, LF line endings, RFC 4180 quoting, English
  headers, and `.` as decimal separator.
- All timestamps also have a UTC form. The original time zone identifier and
  capture-time source remain available in the manifest.
- Raw, corrected/effective, and simulated values are separate files and include
  a `provenance` field. They are never blended into one unlabeled table.
- Missing critical amounts are represented by `null` plus a machine-readable
  reason such as `amountUnknown`; they are never encoded as `0`.
- `checksums.sha256` covers `manifest.json` and every payload file, but not
  itself. Hash lines use lowercase hex, two spaces, then the relative path,
  sorted by path. `manifest.files` covers payload files only, avoiding a
  recursive manifest hash.

## Layout

```text
manifest.json
checksums.sha256
case.json
screenshot.json
assets/original.<ext>
assets/diagnostic-overlay.png                    (when produced)
analysis/runs/<analysis-run-id>.json
analysis/raw-ocr/<analysis-run-id>.json
analysis/calibration/<analysis-run-id>.json
analysis/confidence/<analysis-run-id>.json
corrections/<revision-id>.json
effective/<computation-run-id>.json              (when decodable)
computations/<computation-run-id>.json
simulations/<scenario-id>.json
csv/raw-basal.csv
csv/raw-glucose.csv
csv/raw-bolus.csv
csv/raw-carbohydrates.csv
csv/raw-ambiguities.csv
csv/effective-basal.csv
csv/effective-glucose.csv
csv/effective-bolus.csv
csv/effective-carbohydrates.csv
csv/simulation-events.csv
```

Optional files are listed explicitly in `manifest.files`; absence is never
inferred from an unlisted checksum.

## Manifest

The required top-level shape is:

```json
{
  "schemaName": "CaseArchive",
  "schemaVersion": 1,
  "createdAt": "2026-10-27T12:00:00Z",
  "app": {
    "bundleIdentifier": "org.example.insulinocr",
    "version": "0.1.0",
    "build": "1",
    "gitRevision": "<40-hex-or-null>"
  },
  "case": {
    "id": "<uuid>",
    "title": "Case 27.10.2026, 12:00",
    "captureTime": "2026-10-27T12:00:00+01:00",
    "captureTimeZoneIdentifier": "Europe/Zurich",
    "captureTimeSource": "imageMetadata",
    "status": "needsReview",
    "activeAnalysisRunID": "<uuid-or-null>",
    "activeCorrectionRevisionID": "<uuid-or-null>",
    "activeComputationRunID": "<uuid-or-null>"
  },
  "versions": {
    "analysisAlgorithm": "1.0.0",
    "activityModel": "1.0.0",
    "visionRevision": 3
  },
  "units": {
    "glucose": "mmol/L",
    "insulin": "U",
    "basalRate": "U/h",
    "carbohydrates": "g"
  },
  "active": {
    "analysisRunID": "<uuid-or-null>",
    "correctionRevisionID": "<uuid-or-null>",
    "computationRunID": "<uuid-or-null>"
  },
  "screenshot": {
    "id": "<uuid>",
    "originalFilename": "IMG_0001.PNG",
    "uniformTypeIdentifier": "public.png",
    "pixelWidth": 2622,
    "pixelHeight": 1206,
    "byteCount": 1234,
    "sha256": "<64-lowercase-hex>"
  },
  "files": [
    {
      "path": "assets/original.png",
      "mediaType": "image/png",
      "byteCount": 1234,
      "sha256": "<64-lowercase-hex>"
    }
  ]
}
```

Unknown fields must be ignored by readers. A reader must reject an unsupported
`schemaVersion`, a path traversal component, a checksum mismatch, duplicate
paths, or duplicate JSON IDs.

## Observation provenance

Each observation contains a stable ID, kind, normalized source bounding box,
absolute or interval time, unit, nullable value, alternatives, confidence
components, and provenance. Provenance values are:

- `visionOCR`
- `pixelGeometry`
- `axisCalibration`
- `userCorrection`
- `simulation`

A corrected observation additionally references the raw observation and the
revision that changed it. A deletion remains present in revision history and is
excluded only from effective data.

## Compatibility

Writers may add optional fields and files without changing v1. Removing or
renaming a required field, changing units without explicit unit metadata, or
changing a field's meaning requires a new schema version. Golden archives test
both current writing and backward reading.


## Native clock provenance

When an analysis envelope contains a native `extractorResult`, native 1.7 adds
optional `timeAxisReferenceDate` and `quality.timeAxisClockIsValid` fields. The
former anchors the graph edge independently of `capturedAt`; the latter is
explicitly true for trusted absolute clock mapping and false for a clock
conflict. Absent fields preserve the legacy capture-relative interpretation.

An invalid clock retains relative geometry/OCR for QA, with an `invalidTimeAxis`
domain blocker and no public activity values. Raw CSV dates must be interpreted
with the enclosing analysis quality; a known quantity does not establish a
trusted timestamp. Reanalysis keeps older runs and their corrections intact,
while active corrections/computations are reset until new versions are stored.

Timestamps remain ISO 8601 strings in UTC. New app/extension writers preserve
up to nine fractional digits in JSON and CSV, so confirmed interval boundaries
survive storage and reopening. Readers continue to accept older whole-second
payloads. Immutable historical payload bytes are not rewritten.
