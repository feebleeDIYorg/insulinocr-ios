import Foundation

/// Both targets read the values expanded from the same Xcode build settings.
enum BuildConfiguration {
    static var appGroupIdentifier: String { required("InsulinOCRAppGroup") }
    static var cloudKitContainerIdentifier: String { required("InsulinOCRCloudKitContainer") }

    private static func required(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(") else {
            preconditionFailure("Missing deployment configuration: \(key)")
        }
        return value
    }
}
