import SwiftUI

@main
struct InsulinOCRApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView(appModel: appModel, settings: appModel.settings)
                .task {
                    await appModel.processPendingImports()
                    await appModel.applyCloudPreference()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await appModel.processPendingImports() }
                }
        }
    }
}
