import SwiftUI
import WidgetKit

private struct BWMonitorEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

private struct BWMonitorProvider: TimelineProvider {
    func placeholder(in context: Context) -> BWMonitorEntry {
        BWMonitorEntry(date: .now, snapshot: WidgetSnapshot(server: .demo, metrics: .demo, traffic: .demo))
    }

    func getSnapshot(in context: Context, completion: @escaping (BWMonitorEntry) -> Void) {
        completion(BWMonitorEntry(date: .now, snapshot: WidgetSnapshotStore.load() ?? placeholder(in: context).snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BWMonitorEntry>) -> Void) {
        let entry = BWMonitorEntry(date: .now, snapshot: WidgetSnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

private struct BWMonitorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BWMonitorEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemSmall:
                    small(snapshot)
                case .systemMedium:
                    medium(snapshot)
                default:
                    large(snapshot)
                }
            } else {
                ContentUnavailableView("No snapshot", systemImage: "server.rack", description: Text("Open BWMonitor to collect data."))
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshot.serverName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Circle().fill(snapshot.isOnline ? Color.green : Color.secondary).frame(width: 8, height: 8)
            }
            metric("CPU", snapshot.cpuUsage)
            metric("RAM", snapshot.memoryUsage)
            Spacer(minLength: 0)
            Text(snapshot.trafficUsed.byteString)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text("of \(snapshot.trafficLimit.byteString)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(snapshot.serverName).font(.headline)
                    Circle().fill(snapshot.isOnline ? Color.green : Color.secondary).frame(width: 8, height: 8)
                }
                metric("CPU", snapshot.cpuUsage)
                metric("RAM", snapshot.memoryUsage)
                metric("Disk", snapshot.diskUsage)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Monthly Traffic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(snapshot.trafficUsed.byteString)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                WidgetProgressBar(value: trafficPercentage(snapshot))
                Text("\(trafficPercentage(snapshot), format: .percent.precision(.fractionLength(0))) used")
                    .font(.caption)
            }
        }
    }

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            medium(snapshot)
            Divider()
            HStack {
                Label(snapshot.downloadRate.rateString, systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Spacer()
                Label(snapshot.uploadRate.rateString, systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.mint)
            }
            .font(.headline)
            Spacer()
            Text("Updated \(snapshot.updatedAt, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(_ label: LocalizedStringKey, _ value: Double) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
        .font(.callout)
    }

    private func trafficPercentage(_ snapshot: WidgetSnapshot) -> Double {
        guard snapshot.trafficLimit > 0 else { return 0 }
        return min(Double(snapshot.trafficUsed) / Double(snapshot.trafficLimit), 1)
    }
}

private struct WidgetProgressBar: View {
    let value: Double

    private var normalizedValue: Double {
        min(max(value, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.18))
                Capsule()
                    .fill(.primary.opacity(0.9))
                    .frame(width: proxy.size.width * normalizedValue)
            }
        }
        .frame(height: 7)
        .accessibilityElement()
        .accessibilityLabel("Monthly traffic used")
        .accessibilityValue(Text(normalizedValue, format: .percent.precision(.fractionLength(0))))
    }
}

private struct BWMonitorWidget: Widget {
    let kind = "BWMonitorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BWMonitorProvider()) { entry in
            BWMonitorWidgetView(entry: entry)
        }
        .configurationDisplayName("BWMonitor")
        .description("VPS health and monthly traffic at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct BWMonitorWidgetBundle: WidgetBundle {
    var body: some Widget {
        BWMonitorWidget()
    }
}
