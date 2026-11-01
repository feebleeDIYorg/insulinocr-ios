# Four-stage internal delivery

The workflow arrangement follows the working organization forks of
[Trio](https://github.com/feebleeDIYorg/Trio/tree/0b29cd53415e7f0e668677749cad8daf81c68c2f/.github/workflows)
and [LoopWorkspace](https://github.com/feebleeDIYorg/LoopWorkspace/tree/548b33245198eaae165c094c9c68fe333cb69c05/.github/workflows).
This implementation shares their sequence and selected-profile mapping, and
keeps the existing private configuration, pinned tools and protected environment.
It does not copy app-specific identifiers, clinical code or unrelated targets.

| Action | Operation | Signing-store access |
| --- | --- | --- |
| 1. Validate Secrets | Validate configured repository/token, Apple API access, one existing distribution identity and Match decryption, without requiring app profiles | Read only |
| 2. Add Identifiers | Run validation; find exact app and share identifiers, create missing identifiers and add required capabilities | Read only; Apple identifier/capability additions are possible |
| 3. Prepare App Profiles | Default `check` verifies existing app profiles. Explicit `prepare_profiles` runs validation and prepares only the app/share App Store profiles with the existing distribution certificate | Writes encrypted app profiles only in explicit setup mode |
| 4. Build and TestFlight | Require successful CI on the exact main commit. Default `preflight` verifies profiles; `qa_upload` delivers an experimental internal test build; `upload` additionally requires full acceptance | Read only |

All four actions are manual, main-only and protected by `testflight` approval.
They serialize access to the same signing store. Existing organization credentials
are exposed only to the final operation step; complete logs stay temporary and
private. No signing logs, profiles or signed packages become public artifacts.
The ephemeral runner clock is synchronized before Apple authentication, as in
the reference workflows, with a one-minute bound.

## Sequence

1. Run **1. Validate Secrets** and approve the deployment. This does not build
   or run UI tests: missing per-app profiles must not prevent checking credentials.
2. Run **2. Add Identifiers** when identifiers/capabilities need provisioning.
   Existing capability settings are preserved. App Group and CloudKit container
   associations and the production CloudKit schema still require the Apple setup
   checks in [the release runbook](RELEASE.md); adding the capability alone does
   not prove those associations or production readiness.
3. Run **3. Prepare App Profiles** in `check` mode. If profiles are missing,
   select `prepare_profiles` explicitly and review that deployment. This is an
   initialization operation, separate from read-only build CI. It can create or
   renew the two app-specific profiles and commit their encrypted files to the
   selected private store, using its existing password and certificate. It must
   not change profiles belonging to other apps.
4. Run **4. Build and TestFlight** in `preflight` mode. For an early experimental
   internal QA build, explicitly select `qa_upload`, enter generic notes and
   approve that deployment. This mode leaves unfinished acceptance criteria open
   and prepends that limitation to the TestFlight notes. It requires successful
   CI for the exact main commit, existing signing profiles, manual dispatch from
   the main workflow and the protected Environment approval. Delivery stays
   internal and Match stays read-only.

   If Apple already accepted the binary but metadata or distribution failed,
   select `qa_distribute` and provide `existing_build_number`. This finishes only
   that build of the checked-in marketing version. It uses explicit German test
   notes, disables external beta review and external notifications, and assigns
   the existing internal group. It does not sign, archive, increment the build
   number or upload a binary; Match credentials are not provided to this mode.
   Exact-main CI and the protected Environment approval still apply.

   After the documented release gates actually pass, select `upload`, confirm
   `release_gates_confirmed`, enter generic notes and approve that deployment.
   The confirmation is a human attestation, not a substitute for measured
   OCR/device/performance acceptance. It is not required by `qa_upload` and must
   not be used to claim that an early QA build has passed final acceptance.

   In `upload` mode, if `release_gates_confirmed` is false or missing, delivery stops before
   signing with `stage=release_acceptance code=release_acceptance_required`.
   Environment approval and successful CI do not set this separate confirmation.
   Do not confirm unfinished acceptance criteria; `preflight` remains available
   for a read-only check without an upload.

No distribution certificate or API key is generated or revoked by this sequence.
An expired/missing/ambiguous identity stops setup. Match's certificate-generation
path is explicitly blocked in profile setup. No certificate nuke workflow exists.
The normal build remains read-only and does not repair profiles silently.

## Build profile mapping and tests

Both generated Xcode targets and export options use the profile names returned
by Match. A profile's display name need not equal its encrypted repository filename
or a hardcoded `match AppStore ...` string. Missing or malformed mappings stop the
archive instead of selecting another profile.

Unit, integration and UI tests continue in `ci.yml`. Delivery verifies the latest
CI run for the exact main SHA, same repository, push event and main branch; queued,
failed, skipped, fork and different-SHA results cannot satisfy this gate. It does
not repeat a separate Fastlane Scan UI run or weaken the existing CI tests. A new
failed/running CI attempt cannot be hidden by an older green attempt.

Actions 1–3 perform infrastructure operations and do not ship a build. Their
independence from UI tests follows the reference sequence. Existing release gates,
including real-device and OCR acceptance, remain applicable to action 4 upload.
