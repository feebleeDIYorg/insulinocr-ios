# Release and TestFlight runbook

TestFlight delivery is intentionally manual. Full acceptance remains blocked
until every applicable item below is satisfied. An explicitly selected early
experimental internal QA build is allowed as described under Upload; it does
not satisfy or remove the remaining acceptance criteria. The deferred
two-device check for the current internal evaluation is described below.

## One-time Apple and GitHub setup

1. Publish only a reviewed, sanitized source snapshot. Keep signing storage
   private and reuse an authorized existing store where possible.
2. Register app/extension identifiers, an App Group and a CloudKit container
   in your Apple account. Supply account-specific values outside Git.
3. Configure the App Store Connect app and an internal TestFlight group.
4. Reuse a suitable existing App Store Connect key and approved repository
   authentication. Confirm permissions and encrypted-store compatibility.
5. Bootstrap signing only through explicitly approved setup operations. Build CI
   must use read-only Match. The separate profile setup action may prepare only
   the two app profiles using the existing certificate; see [four-stage delivery](FOUR_STAGE_DELIVERY.md).
6. Configure main-only deployment, required review and protected branch checks
   before any delivery workflow is run.

## Credentials supplied outside Git

Prefer one complete existing Apple credential family:

- FASTLANE_KEY_ID, FASTLANE_ISSUER_ID, FASTLANE_KEY (raw PEM content), or
- ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT_BASE64 (base64 content).

The two families are never mixed. Configure TEAMID/APPLE_TEAM_ID privately.
MATCH_PASSWORD must match the chosen encrypted signing store; do not assume
an unrelated existing password works. Supply the private Match URL through INSULINOCR_BUILD_CONFIG; see
[the configuration contract](BUILD_CONFIGURATION.md). Reuse an existing authorized GH_PAT for HTTPS Match access when
available. No new signing GitHub App is created.

Configure main-only deployment and review protections before delivery. Do not
print secret values or upload private signing artifacts. Match remains read-only
in build CI. Only an authorized workstation bootstrap or the separately approved
profile setup action may update the two app profiles; certificate creation and
revocation are excluded from the four-stage workflow.

## Preflight

- [`xcode-27`](https://github.com/actions/runner-images/issues/14404) is the
  GitHub-hosted Apple-silicon runner label, not a self-hosted runner
  requirement. The workflow still verifies the exact Xcode version and build
  before executing repository code.
- Xcode is exactly 27.1 (`27A9275`) and XcodeGen is 2.42.0.
- Ruby is 3.4.12, Bundler is 4.0.20, Fastlane is 2.241.1, and
  `bundle check` succeeds against the committed `Gemfile.lock`.
- CI passes with no signing secrets.
- Release gates for layout rejection, axes, basal, glucose, events, mathematical
  goldens, fail-closed behavior, performance, archive roundtrip, and end-to-end
  import all pass.
- CloudKit two-device roundtrip and correction-conflict behavior remain required
  for completed synchronization acceptance. The two-device roundtrip is explicitly
  deferred for the current internal TestFlight evaluation; it has not passed.
  Synchronization remains off by default. This deferral changes no other gate.
- CloudKit schema is deployed to production.
- App, extension, App Group, CloudKit, push, and data-protection entitlements are
  present in the distribution profiles.
- Privacy manifest and App Privacy answers match the code; no tracking is added.
- No personal fixture, archive, credential, key, profile, or diagnostic log is
  present in Git history or workflow artifacts.
- TestFlight copy states that output is experimental, is not a medical device,
  and is not a dosing recommendation.

## Upload

Follow the [four-stage setup](FOUR_STAGE_DELIVERY.md) to validate secrets and
prepare missing app profiles separately. Then run `testflight` in its default `preflight` mode and approve the protected
Environment to verify existing signing credentials without uploading.

For early device testing and feedback before full OCR/device/performance
acceptance, explicitly select `qa_upload`, enter generic release notes and approve
the Environment again. The notes automatically identify the build as experimental,
the outstanding acceptance and its restriction to QA rather than therapy decisions.
This does not confirm `release_gates_confirmed` or complete the product acceptance.
No clinical calculation or incomplete-data safeguard changes in this mode.

If the binary is already valid in App Store Connect but post-upload distribution
failed, use `qa_distribute` with its `existing_build_number`. This is a separately
approved protected run for metadata and the internal group, without another
archive or binary upload. Both internal paths explicitly disable external review
and create German test notes even when the first build has no localizations.

After all release gates pass, select `upload`, confirm `release_gates_confirmed`,
enter concise release notes and approve the Environment again. Both upload modes:

1. verifies the exact Xcode build;
2. verifies successful package, app, integration and UI CI on the exact main commit;
3. reads Match with `readonly: true`;
4. selects the next build number from App Store Connect;
5. archives and uploads to `InsulinOCR Internal`.

The marketing version is changed deliberately in source. Build numbers are
monotonic App Store Connect values and are independent of archive schema,
analysis algorithm, and activity-model versions.

## Device acceptance

Before promoting a build, complete one physical target-iPhone run of the whole
flow: share screenshot, analyze, review/correct, simulate, export, close, reopen,
and verify the frozen reference time. Record the Case ID, app build, and algorithm
version with TestFlight feedback; do not attach source health data to GitHub.
