# Acceptance status

This file is the single place that records **which release gate is met, with
which evidence, as of when**. Gate definitions live in [RELEASE.md](RELEASE.md)
(Preflight and Device acceptance); this file tracks their state only.

This repository contains source code and explicitly synthetic fixtures only.
Personal screenshots, reference exports, annotations, case archives and private
QA results stay outside version control. **No real-image accuracy claim is made.**
Evidence for private gates is referenced by date, app build and algorithm
version only, never by attaching health data.

## Status legend

| Status | Meaning |
|---|---|
| ✅ Passed | Gate met; evidence is linked and reproducible. |
| 🟡 Synthetic only | Passes on synthetic data or Simulator; does not satisfy the real-data/device part of the gate. |
| ⬜ Open | Not started or no evidence recorded. |
| ⏸ Deferred | Explicitly postponed for the current internal evaluation; still required for full acceptance. |
| ⛔ Blocked | Cannot be evaluated until a named prerequisite is resolved. |

## Snapshot

- **Commit:** `6565f48` (main, PR #21)
- **Analysis algorithm:** `native-1.15.0` (branch; `main` is `native-1.13.0`)
- **Computation model policy:** `openaps-exponential+loopkit-cob/1.3.0` (branch; `main` is `1.2.3`)
- **Last reviewed:** 2026-11-12
- **Overall:** experimental internal QA only. Full release acceptance is **not**
  reached; `release_gates_confirmed` must not be set.

## Gates

### Build, CI and delivery

| # | Gate | Status | Evidence | Updated |
|---|---|---|---|---|
| B1 | Pinned toolchain (Xcode 27.1 `27A9275`, XcodeGen 2.42.0, Ruby 3.4.12, Bundler 4.0.20, Fastlane 2.241.1) | ✅ Passed | `ci.yml` jobs verify every version before running repository code | 2026-11-04 |
| B2 | CI passes without signing secrets (package, app, integration, UI) | ✅ Passed | `ci` run #55 on `8263bd2` | 2026-11-04 |
| B3 | Delivery lanes and credential policy tests | ✅ Passed | `delivery-config` job, `Scripts/test_*.rb` | 2026-11-04 |
| B4 | Read-only Match signing and internal TestFlight upload path | ✅ Passed | `4. Build and TestFlight` run #11 (`qa_upload`) on `8263bd2`; the preceding `qa_distribute` recovery run #10 failed | 2026-11-04 |
| B5 | Main-only deployment, required review and protected branch checks | ⬜ Open | Repository settings are outside Git; confirm and record here | — |

### Extraction (OCR) accuracy

| # | Gate | Status | Evidence | Updated |
|---|---|---|---|---|
| E1 | Unknown layouts rejected (`unsupportedLayout`) | 🟡 Synthetic only | `NativeAnalysisFailureTests` (Simulator) | 2026-11-04 |
| E2 | Time/basal/glucose axis calibration and clock provenance | 🟡 Synthetic only | `AnalysisPipelineTests`, `ClockAlignedTimelineTests`; [REFERENCE_QA.md](REFERENCE_QA.md) | 2026-11-04 |
| E3 | Capture marker stops observed therapy | 🟡 Synthetic only | `CaptureMarkerTests`; [CAPTURE_BOUNDARY.md](CAPTURE_BOUNDARY.md) | 2026-11-04 |
| E4 | Event recognition (bolus/carbohydrate stems and amounts) on real screenshots | ⬜ Open | No hold-out result recorded. A development check against a reference export exists as a private QA record (2026-11-10, TestFlight build with `native-1.12.0`, `compare_reference.py`); its screenshots were also used for tuning, so it is not acceptance evidence. Synthetic only: `EventEvidenceTests`, `PillImagePreparationTests`, and the end-to-end `SyntheticEventAnalysisTests` (one bolus, one carbohydrate pill; CI result not yet recorded) | — |
| E5 | Glucose accuracy on real screenshots | ⬜ Open | No hold-out result recorded; private development check as in E4, not acceptance evidence | — |
| E6 | Basal accuracy on real screenshots | ⛔ Blocked | Needs C1 (reference semantics) | — |
| E7 | Numerical accuracy thresholds defined before evaluation | ⬜ Open | Thresholds are referenced in docs but not yet written down | — |
| E8 | Extraction parameters frozen, then private hold-out evaluated once | ⬜ Open | Depends on E4–E7 | — |

### Therapy model and safety behaviour

| # | Gate | Status | Evidence | Updated |
|---|---|---|---|---|
| T1 | Insulin IOB against original OpenAPS oracle (1,620 vectors, 1e-9 IE) | ✅ Passed | `TherapyReferenceMatrixTests`; [THERAPY_VALIDATION.md](THERAPY_VALIDATION.md) | 2026-11-04 |
| T2 | COB boundary values and basal discretization bounds | ✅ Passed | `TherapyReferenceMatrixTests`, `TherapyModelsTests` | 2026-11-04 |
| T3 | Fail-closed behaviour per category (unknown amounts, basal gaps/overlaps, invalid clock). Since policy 1.3.0 a screenshot shorter than the action window no longer withholds results | 🟡 Synthetic only | Changed on the branch on 2026-11-12; CI result for `TherapyModelsTests`, `BasalCorrectionReviewTests`, `ActiveWindowQualityTests`, `DomainReducerTests` not yet recorded; [ACTIVITY_QUALITY.md](ACTIVITY_QUALITY.md) | — |
| T4 | Frozen reference time and forecast input | ✅ Passed | `FrozenForecastTests`, UI cold-reopen checks | 2026-11-04 |
| T5 | Clinical validation | ⬜ Out of scope | The app is not a medical device; numerical tests are not clinical evidence | — |

### End-to-end, device and performance

| # | Gate | Status | Evidence | Updated |
|---|---|---|---|---|
| D1 | Share → analyze → correct → simulate → export → cold reopen | 🟡 Synthetic only | `ScreenshotFlowUITests` + `verify_ui_archive.py` in CI; [UI_QA.md](UI_QA.md) | 2026-11-04 |
| D2 | CaseArchive v1 roundtrip and independent verification | ✅ Passed | `verify_ui_archive.py`, `CaseLifecycleIntegrationTests`; [CASE_ARCHIVE_V1.md](CASE_ARCHIVE_V1.md) | 2026-11-04 |
| D3 | Physical-device OCR latency P95 ≤ 10 s | ⬜ Open | Harness exists ([DEVICE_BENCHMARK.md](DEVICE_BENCHMARK.md)); no result recorded | — |
| D4 | Whole flow on a physical target iPhone from a TestFlight build | ⬜ Open | Record Case ID, build and algorithm version here | — |

### Synchronization

| # | Gate | Status | Evidence | Updated |
|---|---|---|---|---|
| S1 | CloudKit sync logic (merge, tombstones, conflict → `needsReview`) | 🟡 Synthetic only | `CloudSyncTests` | 2026-11-04 |
| S2 | Two-device CloudKit roundtrip and correction conflict | ⏸ Deferred | Explicitly deferred for the current internal TestFlight evaluation; unverified. Sync is off by default | — |
| S3 | CloudKit schema deployed to production | ⬜ Open | — | — |

### Privacy, entitlements and distribution metadata

| # | Gate | Status | Evidence | Updated |
|---|---|---|---|---|
| P1 | Privacy manifests and required-reason API declarations | 🟡 Synthetic only | [PRIVACY_API_REVIEW.md](PRIVACY_API_REVIEW.md); final signed-archive check still required | 2026-11-04 |
| P2 | App Privacy answers in App Store Connect match the code | ⬜ Open | — | — |
| P3 | Distribution profiles contain app, extension, App Group, CloudKit, push and data-protection entitlements | ⬜ Open | Verify on the signed archive | — |
| P4 | No personal fixture, archive, credential or diagnostic log in Git history or workflow artifacts | ⬜ Open | Policy enforced by design; record an explicit history/artifact audit | — |
| P5 | TestFlight copy states experimental, not a medical device, not a dosing recommendation | ✅ Passed | QA upload notes are generated automatically ([RELEASE.md](RELEASE.md), Upload) | 2026-11-04 |

### Open source questions

| # | Item | Status | Next step |
|---|---|---|---|
| C1 | Temporal semantics of basal values in the CamAPS text export | ⬜ Open | Obtain documented semantics or two independent screenshot-interval annotations ([CAMAPS_SOURCE_SEMANTICS.md](CAMAPS_SOURCE_SEMANTICS.md)). Choosing the lowest-error interpretation is not validation. |

## Updating this file

- Change a row only together with its evidence: a CI run, a test name, a
  document, or a private QA record identified by date, build and algorithm
  version.
- Set **Updated** to the date the evidence was produced and refresh the snapshot.
- A synthetic or Simulator result never upgrades a real-data/device gate to ✅.
- Deferring a gate requires an explicit note; a deferral never waives another gate.
- Set `release_gates_confirmed` for an `upload` run only when every applicable
  row is ✅ (or explicitly out of scope).
