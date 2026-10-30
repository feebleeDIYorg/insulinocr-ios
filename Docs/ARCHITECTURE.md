# Architecture

## Principles

1. A screenshot creates exactly one case.
2. The capture timestamp is the case's immutable clinical reference time unless
   the user explicitly corrects it. Reopening a case never advances its result.
3. SwiftData is the local source of truth and is configured without automatic
   CloudKit. Cloud sync is an explicit, separate mirror.
4. Raw evidence and every analysis/computation run are immutable. User changes
   are correction revisions, not destructive edits.
5. Critical uncertainty is fail-closed. A result can be incomplete; it cannot
   silently become a numerical zero or a best guess.
6. Screenshot bytes and diagnostic assets are protected files referenced by
   SHA-256, not large SwiftData blobs.

## Targets and boundaries

- `InsulinOCR`: SwiftUI features, SwiftData models, repository adapters, import
  consumption, local file store, export orchestration, and opt-in CloudKit sync.
- `InsulinOCRShareExtension`: accepts exactly one image, preserves its original
  bytes, and atomically places an image and import manifest in the App Group.
  It performs no OCR.
- `InsulinOCRCore`: `Sendable` domain values, deterministic correction reducer,
  Vision analysis, activity calculations, and export representations.
- Unit, integration, and UI test targets keep numerical, persistence, and full
  user-flow tests independent.

Expensive or stateful work crosses explicit actor boundaries:

- `AnalysisEngine` for Vision and pixel analysis
- `AssetStore` for protected atomic file operations
- `CaseExporter` for archive assembly and checksums
- `CloudSyncService` for CKSyncEngine state

The user interface stays on `MainActor`; core values are immutable and
`Sendable` across those boundaries.

## Import lifecycle

1. The extension validates one `NSItemProvider` image.
2. It loads the original representation without re-encoding when possible.
3. It computes the hash and extracts capture metadata.
4. Image and manifest are written to a temporary App Group directory.
5. A directory rename atomically publishes the queue item.
6. When the main app becomes active, `ImportQueue` consumes items idempotently.
7. The app copies the bytes to protected Application Support storage, inserts a
   pending `CaseRecord`, and starts analysis outside the extension process.
8. A failure records an explicit failed run. Retry creates another run.

Duplicate original bytes are identified by SHA-256 before a second case is
created. Malformed or partial queue entries are quarantined, never interpreted.

## Persistence model

- `CaseRecord`: capture time/source/time zone, status, active immutable run IDs,
  selected correction revision, sync state, and tombstone state.
- `ScreenshotAsset`: protected relative path, UTI, byte count, dimensions,
  SHA-256, and layout profile.
- `AnalysisRun`: algorithm/Vision versions, plot geometry, OCR candidates,
  calibration, observations, confidence components, warnings, and errors.
- `CorrectionRevision`: ordered add/update/delete overlays against observation
  IDs, with author/device metadata and parent revision.
- `ComputationRun`: exact effective-data revision, reference time, model version,
  DIA, peak, carbohydrate parameters, and fail-closed results.
- `SimulationScenario`: its own insulin/carbohydrate events and basis computation
  reference. Simulated events never enter corrected therapy data.

Global settings apply to new computation runs. They never rewrite history.

## Analysis pipeline

```text
layout validation
  -> plot frame and current-data edge
  -> region-specific Vision OCR
  -> time/basal/glucose axis calibration
  -> dashed-blue removal and solid basal path
  -> glucose centers or dense path
  -> event-stem geometry then single-pill OCR
  -> quality gates
  -> immutable AnalysisRun
```

Full-image text may corroborate a pill only when its complete bounding box
belongs to exactly one complete event stem and covers that stem horizontally.
Merged multi-pill text, shared evidence and conflicting amounts remain unknown;
the confidence threshold is unchanged. All contributing observation IDs remain
in provenance.

Known landscape layouts from 1 to 48 hours are supported. Unknown layouts are
rejected as `unsupportedLayout`. A fully visible event stem with an uncertain
amount becomes `amountUnknown` and blocks the relevant IOB or COB component.

## Cloud mirror

The local SwiftData store never points at CloudKit. After opt-in, CKSyncEngine
mirrors complete cases into a private custom zone:

- screenshot and diagnostic images as `CKAsset`
- immutable versioned JSON runs as compressed assets
- a small case record containing metadata and active pointers
- deletions as tombstones

Immutable runs merge by ID. Concurrent corrections to the same observation are
retained as a conflict and set `needsReview`. A CloudKit outage never makes the
local case unavailable. Disabling sync stops mirroring but does not delete local
data.

## Security and privacy

- `NSFileProtectionComplete` protects screenshot and archive-related storage.
- No analytics, tracking, advertising, or third-party crash SDK is present.
- No real health data enters source control or GitHub artifacts/logs.
- QA archives are user-initiated and explicitly contain sensitive source data.
- App Group, CloudKit, and signing entitlements are limited to their stated use.

## Failed analysis attempts

A versioned `OCRFailedAnalysis` retains request identity, requested capture metadata,
algorithm/Vision versions, failure code/message and all OCR candidates observed
before failure. The actor captures this value before releasing its synchronous
pipeline; production callers never fetch a shared diagnostic buffer after a
separate failed await. The original throwing engine API remains compatible.

Failed attempts use the same immutable run storage and opaque CloudKit transport
as successful runs. They have no fabricated calibration or therapy observations,
clear active computation/correction pointers, and cannot enable correction or
recomputation as if they had a valid domain model. The original image stays intact;
the diagnostic overlay contains measured OCR boxes only.

CaseArchive v1 includes the opaque run, an explicit `analysis/failures/<id>.json`
record and its native raw observations in `analysis/raw-ocr/<id>.json`. Readers
identify the failed envelope by its `failure` field and versioned schema; those
raw observations include region and ranked candidates. No calibration file is
invented for an uncalibrated attempt. Older successful envelopes remain readable.
The CLI additionally writes a local `failed-analysis.json` sidecar on rejection.

## Alternate event-pill recognition

Native analysis 1.9 retries an unknown event quantity using a bounded, threefold
nearest-neighbour enlargement of a fixed binary luminance image. The original
crop and all candidates remain intact. `OCRRawTextObservation.preprocessing`
records the exact versioned preparation; its absence is compatible with older
cases. Crops exceeding the preparation memory bound skip the alternate pass.

Only complete geometrically isolated stems are retried. Alternate text touching
the integer crop boundary cannot supply a quantity; rejected observations remain
available for QA. Accepted candidates join the original evidence and use the same
quantity parser and confidence threshold. Conflicting recognized quantities stay
unknown. This does not change basal extraction, clock validation, activity models
or completeness gates. Real-image/device release acceptance remains separate.
