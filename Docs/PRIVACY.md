# Privacy and data handling

InsulinOCR processes screenshots that can reveal glucose values, insulin,
carbohydrate intake, timestamps, and other health-related context.

## Default behavior

- Analysis happens on the device.
- Cases and source images stay on the device.
- iCloud synchronization is off until the user explicitly enables it.
- No analytics, advertising, behavioral profiling, or tracking SDK is included.
- No data is sent to the developer by the application.

## Optional iCloud synchronization

When enabled, complete cases are mirrored through Apple's CloudKit private
database in `iCloud.org.example.insulinocr`. Images are `CKAsset` records and
runs are versioned JSON assets. Local cases remain available during outages.
Disabling synchronization stops the mirror; it does not silently delete local
cases. Cloud deletion is a separate explicit operation.

This is private CloudKit storage under the signed-in Apple account, not a claim
of application-managed end-to-end encryption.

## Export

A user can create a `CaseArchive v1` ZIP for quality review or algorithm
improvement. It deliberately includes the source image, OCR evidence, diagnosis
images, corrections, model settings, and checksums. The share destination is
chosen by the user. The archive must be treated as sensitive health data.

## Deletion

Deleting a local-only case removes its SwiftData records and protected files.
For a synchronized case, deletion also creates a tombstone for CloudKit. Local
file removal should happen only after the repository transaction succeeds;
failed cloud deletion remains visibly pending and retryable.

## Source-control boundary

Real screenshots, OCR output, QA archives, signing credentials, and provisioning
profiles must never be committed or uploaded as CI artifacts. Only synthetic or
explicitly anonymized fixtures are permitted in GitHub.
