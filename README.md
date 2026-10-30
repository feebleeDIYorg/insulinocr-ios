# InsulinOCR

InsulinOCR is an experimental native iOS app that extracts therapy data from a
single landscape CamAPS FX screenshot. It reconstructs glucose context, basal
delivery, boluses, and carbohydrate events, then computes the portion that is
still active at the screenshot's capture time. Cases are frozen at that time
and remain reproducible when opened later.

> **Safety:** InsulinOCR is an experimental estimate, not a medical device and
> not a dosing recommendation. Never make therapy decisions from InsulinOCR
> alone. Verify all values in the source app and follow the treatment plan
> agreed with the responsible healthcare professional.

CamAPS is a trademark of its respective owner. This project is independent and
does not include CamAPS logos, source code, or proprietary assets.

## Product scope

- iOS 18+, Swift 6, SwiftUI, SwiftData, Vision, Swift Charts, and CloudKit.
- Exactly one screenshot creates one complete, versioned case.
- Processing and local persistence are on-device. iCloud synchronization is
  disabled by default and requires an explicit opt-in.
- Critical uncertainty is fail-closed: unknown insulin or carbohydrate amounts
  produce an incomplete result, never a silent zero or guessed number.
- Bolus IOB, basal IOB, total IOB, and COB remain separate and auditable.
- Corrections are immutable overlays; recomputation creates a new run.
- Simulations are stored separately from observed and corrected therapy data.
- `CaseArchive v1` provides a checksum-protected QA export.

The user interface is German. Export schemas and developer documentation are
English and versioned.

## Repository layout

```text
InsulinOCR/                       SwiftUI app, SwiftData, services, resources
ShareExtension/                  one-image App Group queue producer
Packages/InsulinOCRCore/         domain, OCR pipeline, activity math, export
InsulinOCRTests/                 app unit tests
InsulinOCRIntegrationTests/      persistence/import/export integration tests
InsulinOCRUITests/               end-to-end UI tests
Config/                          build configurations and generated Info.plists
fastlane/                        tests, Match bootstrap, TestFlight delivery
.github/workflows/               secret-free Simulator CI and manual TestFlight workflow
Docs/                            architecture, archive schema, privacy, release
```

The `.xcodeproj` is generated and intentionally not committed.


## Local setup

Requirements:

- Xcode 27.1 (`27A9275`)
- XcodeGen 2.42.0
- Ruby 3.4.12
- Bundler 4.0.20
- Fastlane 2.241.1

Generate and open the project:

```sh
xcodegen generate --spec project.yml
open InsulinOCR.xcodeproj
```

Run the portable core tests and the full simulator suite:

```sh
swift test --package-path Packages/InsulinOCRCore
bundle install
bundle check
bundle exec fastlane ios test
```

The full suite includes a real screenshot share flow and independently checks
its exported archive. Simulator App Groups require the lane's local ad-hoc
signatures; no Apple signing secrets are needed. See [Simulator QA](Docs/UI_QA.md)
for the synthetic fixture, isolated Simulator selection and repeat-run behavior.

Development signing is automatic. Release signing uses the Match profile named
`match AppStore <bundle-id>` from the separate
private signing repository selected outside Git.

## Test data policy

Real CamAPS screenshots, OCR text, diagnostic overlays, and CaseArchive exports
contain health data and must never be committed. Keep them in the approved local
or Drive location. CI may use only synthetic or explicitly anonymized fixtures.
The ignored directories `PrivateFixtures/`, `LocalFixtures/`, and `QA/Real/`
exist for local workflows.

Reference exports are ground truth only. They must never be read as extraction
input. The private hold-out remains the untouched hold-out until parameter freeze.

For a local developer-only OCR inspection, run:

```sh
swift run --package-path Packages/InsulinOCRCore insulinocr-analyze \
  PrivateFixtures/example.png PrivateFixtures/example.analysis.json
```

Successful analysis writes the full extraction result. Rejection returns exit
code 1 and writes a structured failure report plus a `.raw-ocr.json` sidecar
containing the observations collected before calibration failed. These outputs
contain health data and must remain in ignored local fixture directories.

## Delivery

CI runs on pushes and pull requests without signing secrets. TestFlight delivery
is available only through the manual `testflight` workflow and its protected
GitHub Environment. The workflow tests first, reads signing assets from Match in
read-only mode, increments the build number from App Store Connect, and sends the
build to `InsulinOCR Internal`.

The protected Environment contains one private build-configuration secret.
Existing organization credentials are reused only by the approved signing step.
See [Private build configuration](Docs/BUILD_CONFIGURATION.md) for the exact
configuration contract, privacy restrictions, and local delivery instructions.
See [Release runbook](Docs/RELEASE.md) before creating any TestFlight build.

## Licensing

The application repository is proprietary. Third-party notices are in
[NOTICE.md](NOTICE.md). Activity algorithms are clean-room implementations based
on the original MIT-licensed OpenAPS and LoopKit references. No GPL code from
the organization’s `xdripswift` fork is copied into this repository.
