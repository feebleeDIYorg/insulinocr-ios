import SwiftUI
import UIKit

/// Simulator-only input host. The shipping application does not depend on it.
@main
struct ShareHostApp: App {
    @State private var isSharing = false
    @State private var shareResult = "Ready"

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 24) {
                Text("Synthetic screenshot QA")
                    .font(.title2)
                Text("No patient data")
                if let url = Bundle.main.url(forResource: "SyntheticTherapy12Hours", withExtension: "png", subdirectory: "Fixtures") {
                    Button("Share synthetic screenshot") {
                        shareResult = "Waiting"
                        isSharing = true
                    }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("fixture.share")
                        .sheet(isPresented: $isSharing) {
                            FixtureShareSheet(url: url) { completed, activity in
                                shareResult = completed ? "Completed: \(activity ?? "unknown")" : "Cancelled"
                                isSharing = false
                            }
                        }
                } else {
                    Text("Missing synthetic fixture")
                }
                Text(shareResult)
                    .accessibilityIdentifier("fixture.result")
            }
            .padding()
        }
    }
}

private struct FixtureShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onCompletion: @MainActor @Sendable (Bool, String?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, _ in
            let identifier = activity?.rawValue
            Task { @MainActor in onCompletion(completed, identifier) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
