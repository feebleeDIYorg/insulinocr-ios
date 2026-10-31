# Required-reason API review

The app declares these direct API uses:

| Use | Declaration | Scope |
|---|---|---|
| `AppSettings` reads/writes `UserDefaults.standard` | UserDefaults / `CA92.1` | This app's own settings |
| `CaseLibraryView.handleFileImport` reads `creationDateKey` | FileTimestamp / `3B52.1` | The user-selected document, inside its security-scoped access; fallback capture time when image metadata is absent |

The Share Extension reads dates embedded in image metadata through ImageIO. It does not read the selected file's filesystem timestamp or share app settings through UserDefaults.

ZIPFoundation stays pinned to 0.9.20. Its resource bundle contains its own FileTimestamp wrapper declaration (`0A2A.1`); the app's direct document-picker access needs its own declaration. Verify both manifests and the extension manifest in the final product.

The physical performance harness uses system uptime only in a test target, outside the shipping app source/dependency graph. This does not add a production system-boot-time declaration.

Sources: Apple's [required-reason API categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) and [per-bundle declaration requirement](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

This review covers declarations and bundle inclusion. It does not approve the App Store Connect privacy questionnaire or substitute for final signed-archive validation. No tracking or analytics integration is added.
