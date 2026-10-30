import SwiftUI

struct StatusBadge: View {
    let status: StoredCaseStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.12), in: Capsule())
    }
}

private extension StoredCaseStatus {
    var title: LocalizedStringResource {
        switch self {
        case .queued: "Wartet auf Analyse"
        case .analyzing: "Analyse läuft"
        case .complete: "Vollständig"
        case .incomplete: "Unvollständig"
        case .needsReview: "Prüfung nötig"
        case .unsupportedLayout: "Layout nicht unterstützt"
        case .failed: "Fehlgeschlagen"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .analyzing: "sparkle.magnifyingglass"
        case .complete: "checkmark.circle.fill"
        case .incomplete: "exclamationmark.circle.fill"
        case .needsReview: "person.crop.circle.badge.questionmark"
        case .unsupportedLayout: "rectangle.slash"
        case .failed: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .queued, .analyzing: .blue
        case .complete: .green
        case .incomplete, .needsReview: .orange
        case .unsupportedLayout, .failed: .red
        }
    }
}
