# Simulator screenshot QA

`ScreenshotFlowUITests` exercises the operating-system share sheet and the real
Share Extension, App Group queue, Vision analysis, persistence, calculations,
correction editor, simulation form and archive exporter. No OCR result or
repository is mocked. Its input is a public, generated 2622×1206 image with
144 glucose markers at 6 mmol/L, a constant 0.8 U/h basal trace and no events.
EXIF fixes capture at 2 January 2026, noon in the importing device's time zone.
No patient screenshot, CamAPS asset or account credential is embedded.

## Reproduce

Use an available iPhone Simulator reserved for this project's QA. Then run:

```sh
bundle exec fastlane ios test
```

`SIMULATOR_DEVICE` defaults to `iPhone 17 Pro`; `SIMULATOR_OS` can select an
installed runtime. `SIMULATOR_UDID` takes precedence when selecting an owned QA
Simulator; Fastlane forwards it to the preparation script. CI explicitly selects
iPhone 17 on iOS 27.0. The preparation
script builds and installs a separate Simulator-only `InsulinOCRShareTestHost`.
The shipping app does not depend on or embed that host, and signing automation
does not register its bundle identifier with Apple.

The full suite uses one Simulator destination with parallel testing disabled,
so XCTest retains the host installation. App and extension use local ad-hoc
signatures (`CODE_SIGN_IDENTITY=-`), preserving Simulator App Group access
without Apple signing certificates or CI secrets. Unsigned builds compile but
cannot exercise the real shared import directory.
The native 1.7.0 full lane also passes on an English-system iPhone 17 with iOS
27.0. The test selects the system cell's actual activity image; system save
labels may remain English even when both test apps request German localization.

The fixture is copied as a folder reference. Xcode's individual PNG resource
processing otherwise changes the bytes, even when PNG compression is disabled.
Preparation compares the built input against the committed fixture before
installation. `Scripts/generate_ui_fixture.py` can regenerate the source on
macOS with Pillow and the system Arial font; CI consumes the committed PNG.

## Checks

The test imports the image, explicitly reanalyzes it with the current extractor
while retaining prior immutable history, then requires complete analysis.
It changes a basal amount and
saves a uniquely named simulation with 1 U bolus and 15 g carbohydrate at the
frozen reference. It checks the scenario deltas and unchanged baseline values.
It then removes the basal amount: all four activity cards must become
unavailable, both decay charts disappear and simulation is disabled. A further
immutable revision restores the amount. The test exports through the actual
share sheet, then performs three cold relaunches. Each reopening must retain
the corrected value and frozen date and render every therapy/decay chart. The
saved scenario is reopened afterwards. An XCTest screenshot is retained.

On iOS 27.0, an interpolated glucose column label reproduced a native Charts
`HashableText` dictionary crash on persisted reopening. Using the constant
`Glukose` column label fixes that path; the unit remains on the y-axis and in
the accessibility descriptor. A separate local stress probe passed 20 cold
launches with all four charts rendered. Date-axis-only and numeric-axis
formatting changes did not solve the crash and are not part of the fix.
The checked-in regression is self-contained in the real import flow; it does
not depend on a pre-existing case as the diagnostic probe did.

Identical image imports intentionally deduplicate. On a repeat run the test
alternates its correction between 0.8 and 0.9 U/h and creates a fresh scenario
name. Histories remain intact. If a local run is interrupted during the
incomplete-data check, restore that synthetic case in the correction UI or use
a fresh QA Simulator before retrying. Existing user cases are not erased by
the test's onboarding reset.

`Scripts/verify_ui_archive.py --udid <simulator-uuid>` independently reads the
latest UI-created ZIP without extracting it. It verifies every indexed file,
SHA-256 list and ZIP CRC; exact original image bytes; diagnostic exports;
144 recognized glucose observations; absolute clock provenance; continuous,
non-overlapping observed basal coverage across DIA; raw versus corrected data; complete and
incomplete computation history; frozen references; saved scenario provenance
and 1e-9 simulation deltas; and effective basal CSV consistency. CI and the
Fastlane test lane both run this check after XCTest.
Independent known-zero component diagnostics may remain in a partial internal
calculation; the incomplete presentation contains no numeric activity values.

This synthetic flow does not establish real-image OCR accuracy, physical-phone
latency, two-device CloudKit synchronization, or a TestFlight device run. It
also does not simulate a remote invalidation while the simulation sheet is
already open.
