import SwiftUI

struct AppRootView: View {
    @Bindable var appModel: AppModel
    @Bindable var settings: AppSettings

    var body: some View {
        if let error = appModel.bootstrapError {
            ContentUnavailableView {
                Label("Lokale Datenbank nicht verfügbar", systemImage: "externaldrive.badge.xmark")
            } description: {
                Text(error)
            }
        } else if !settings.onboardingComplete {
            OnboardingView(appModel: appModel)
        } else if let library = appModel.library {
            CaseLibraryView(appModel: appModel, library: library)
        } else {
            ProgressView("App wird vorbereitet …")
        }
    }
}

#Preview {
    AppRootView(appModel: AppModel(inMemory: true), settings: AppSettings())
}
