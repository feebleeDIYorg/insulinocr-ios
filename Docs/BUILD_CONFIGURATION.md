# Private deployment configuration

The checked-in configuration builds only with example identifiers. Both app
and extension read the same expanded build settings through their Info.plists.
Simulator CI uses no signing credentials and clears generated signing overrides.

## Protected TestFlight configuration

Create exactly one Environment secret, `INSULINOCR_BUILD_CONFIG`, in the reviewed
`testflight` Environment. Its JSON object has exactly these five fields:

```json
{
  "app_identifier": "com.yourcompany.insulinocr",
  "share_identifier": "com.yourcompany.insulinocr.share",
  "app_group": "group.com.yourcompany.insulinocr",
  "cloudkit_container": "iCloud.com.yourcompany.insulinocr",
  "match_git_url": "https://github.com/your-organization/private-signing.git"
}
```

Use the already registered identifiers and existing private signing repository.
Do not put tokens in the URL. Team identity comes from the existing `TEAMID`
secret; it is deliberately absent from this JSON. Example identifiers and the
simulator team are rejected for signing.

Reuse the authorized organization secrets `FASTLANE_KEY_ID`, `FASTLANE_ISSUER_ID`,
`FASTLANE_KEY` (raw PEM), `TEAMID`, `GH_PAT` and `MATCH_PASSWORD`. Their repository
visibility and the token's read access must be checked before activation. The
workflow does not create keys, applications, certificates or profiles. Its
Match operation is read-only; an incompatible password stops delivery.

Environment approval protects this configuration secret. It does not restrict
organization secrets independently referenced by other workflows. Limit write
access to trusted maintainers, inspect inherited permissions and protect main.
Fork pull requests receive no signing credentials. Do not use pull_request_target.
Workflow inputs and release notes are not confidential storage; use generic
release descriptions and keep patient-specific TestFlight feedback private.

The manual workflow defaults to `preflight`: it verifies access and decrypts
existing Match profiles read-only without uploading a build. Select `upload`
explicitly only after all release gates pass.

Only the final approved signing step receives credentials. Private identifier
values and derived authentication are masked before use. Detailed signing
output is stored in a temporary directory and removed rather than published.
No signed packages, signing logs or profiles are uploaded as Actions artifacts.
Public errors contain only allowlisted stage/code tokens, such as
`stage=match code=match_decryption_failed`. Underlying messages, repository URLs,
identifiers and credentials never become diagnostic fields. An unclassified
Match failure remains `match_failed` and requires private investigation; do not
paste private logs into public issues. Do not enable shell tracing or add environment-dump steps.

## Authorized local delivery

Store the same JSON in an ignored `*.build-config.json` file with mode 0600 and
set `INSULINOCR_BUILD_CONFIG_FILE` to its path. Supply the existing Apple and
Match credentials privately. `bundle exec fastlane ios beta` first tests with
public simulator identifiers, then creates an ignored mode-0600
`Config/Local.generated.xcconfig` for device signing. Never commit that file.
The local signing setup lane is opt-in and must not be used to repair a CI
credential failure automatically.

For Xcode device development, generate the private override without contacting
Apple or changing signing assets, then open the generated project:

```sh
bundle exec ruby -r ./fastlane/lib/insulinocr_build_configuration -e 'InsulinOCRBuildConfiguration.prepare(Dir.pwd, signing: true)'
xcodegen generate --spec project.yml
open InsulinOCR.xcodeproj
```

The public workflow deliberately contains no concrete owner deployment values.
Changing identifiers requires existing matching Apple capabilities and profiles;
it does not register them automatically. CloudKit and physical-device acceptance
remain separate release requirements.
