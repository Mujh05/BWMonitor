import SwiftUI

enum BWFormat {
    static let percentage: FloatingPointFormatStyle<Double>.Percent = .percent.precision(.fractionLength(0))
    static let compactDate: Date.FormatStyle = .dateTime.month(.abbreviated).day().hour().minute()

    static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: interval)
            ?? String(format: NSLocalizedString("%lld minutes", comment: "Duration fallback"), Int64(interval / 60))
    }
}

struct StatusLabel: View {
    let text: String
    let active: Bool

    var body: some View {
        let status = active
            ? NSLocalizedString("available", comment: "Accessibility status")
            : NSLocalizedString("unavailable", comment: "Accessibility status")
        Label(text, systemImage: active ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(active ? .green : .secondary)
            .font(.callout.weight(.medium))
            .accessibilityLabel("\(text): \(status)")
    }
}

struct GaugeMetric: View {
    let title: LocalizedStringKey
    let value: Double
    let detail: LocalizedStringKey
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(value, format: BWFormat.percentage)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }
            ProgressView(value: min(max(value, 0), 1))
                .tint(tint)
                .accessibilityLabel(title)
                .accessibilityValue(Text(value, format: BWFormat.percentage))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct EmptySelectionView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "server.rack")
        } description: {
            Text(message)
        } actions: {
            Button("Add Server", action: action)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss)
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
