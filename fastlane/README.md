fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios test

```sh
[bundle exec] fastlane ios test
```

Generate the project and execute core, integration, and UI tests on Simulator

### ios setup_signing

```sh
[bundle exec] fastlane ios setup_signing
```

Create or renew development and App Store profiles in the encrypted Match repository

### ios signing_preflight

```sh
[bundle exec] fastlane ios signing_preflight
```

Verify existing signing access and encrypted profiles without uploading

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload an internal TestFlight build

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
