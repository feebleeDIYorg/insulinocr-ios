import SwiftUI

struct MetricCard: View {
    let title: LocalizedStringResource
    let value: Double?
    let unit: String
    let tint: Color
    let unavailableReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let value {
                    Text(value, format: .number.precision(.fractionLength(2)))
                        .font(.title2.monospacedDigit().weight(.semibold))
                    Text(unit)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Nicht verfügbar")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
