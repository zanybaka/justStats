import SwiftUI

/// The Network tab's content (NET-002…004): a card (rates, sparkline, since-boot totals)
/// plus two independent lazy disclosures, Interfaces and Top processes.
struct NetworkSectionView: View {
    @ObservedObject var model: NetworkSectionViewModel
    /// Opens the Location pane from the Wi-Fi row's grant action.
    var openLocationSettings: () -> Void = { SystemSettingsOpener().openLocationSettings() }

    var body: some View {
        VStack(alignment: .leading, spacing: DiskMetrics.rowSpacing + 2) {
            NetworkCardView(sampler: model.sampler, onReset: { model.resetTotals() })
            Divider()
            NetworkDisclosureRow(
                title: NetworkDisclosureContent.interfacesTitle,
                isExpanded: model.isInterfacesExpanded,
                toggle: { model.toggleInterfaces() }
            )
            if model.isInterfacesExpanded {
                NetworkInterfacesView(
                    sampler: model.sampler,
                    details: model.details,
                    onRefresh: { model.refreshDetails() },
                    openLocationSettings: openLocationSettings
                )
            }
            NetworkDisclosureRow(
                title: NetworkDisclosureContent.processesTitle,
                isExpanded: model.isProcessesExpanded,
                toggle: { model.toggleProcesses() }
            )
            if model.isProcessesExpanded {
                ProcessesSection(processes: model.processes)
            }
        }
        .padding(DiskMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DiskMetrics.cardCornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }
}

/// Observes `ProcessTrafficModel` so the block re-renders as passes land.
struct ProcessesSection: View {
    @ObservedObject var processes: ProcessTrafficModel
    var body: some View {
        ProcessesBlockView(content: ProcessesContent(state: processes.state))
    }
}

/// Rates, sparkline and totals. Spoken as one summary sentence; the chart is decorative.
struct NetworkCardView: View {
    @ObservedObject var sampler: NetSampler
    var onReset: () -> Void

    private var content: NetworkCardContent {
        NetworkCardContent(
            latest: sampler.latest,
            samples: sampler.samples.map(\.rate),
            totals: sampler.totals,
            totalsWereReset: sampler.totalsWereReset
        )
    }

    var body: some View {
        let content = content
        VStack(alignment: .leading, spacing: DiskMetrics.rowSpacing + 2) {
            VStack(alignment: .leading, spacing: DiskMetrics.rowSpacing + 2) {
                HStack(alignment: .firstTextBaseline) {
                    rate(symbol: "arrow.down", label: "Down", text: content.downText, color: NetworkPalette.down)
                    Spacer(minLength: DiskMetrics.inlineSpacing)
                    rate(symbol: "arrow.up", label: "Up", text: content.upText, color: NetworkPalette.up)
                }
                NetworkSparklineView(chart: content.chart)
                    .frame(height: NetworkPalette.sparklineHeight)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.accessibilitySummary)

            HStack(spacing: DiskMetrics.inlineSpacing) {
                Text(content.totalsLabel)
                Label(content.totalsDownText, systemImage: "arrow.down")
                Label(content.totalsUpText, systemImage: "arrow.up")
                Spacer(minLength: DiskMetrics.inlineSpacing)
                Button("Reset", action: onReset)
                    .buttonStyle(.borderless)
                    .clickableCursor()
                    .accessibilityLabel(NetworkCardContent.resetAccessibilityLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
        }
    }

    private func rate(symbol: String, label: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: symbol).imageScale(.small)
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(color)
            Text(text)
                .font(.system(size: NetworkPalette.rateFontSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

enum NetworkPalette {
    /// Down = system blue, up = system green; arrows and labels always accompany the color.
    static let down = Color.blue
    static let up = Color.green
    static let rateFontSize: CGFloat = 17
    static let sparklineHeight: CGFloat = 38
}

/// Dual-series sparkline over real samples only. An empty buffer draws an explicit empty
/// track, never a flat zero line or invented history.
struct NetworkSparklineView: View {
    let chart: NetworkCardContent.Chart

    /// Vertical scale never drops below 10 KB/s so idle noise doesn't fill the chart.
    static let minimumScale: Double = 10_000

    static func scale(down: [Double], up: [Double]) -> Double {
        max(minimumScale, (down + up).max() ?? 0)
    }

    var body: some View {
        switch chart {
        case .empty:
            RoundedRectangle(cornerRadius: DiskMetrics.barCornerRadius, style: .continuous)
                .fill(DiskPalette.track)
                .overlay(
                    Text("Collecting…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                )
                .accessibilityHidden(true)
        case .series(let down, let up):
            Canvas { context, size in
                let top = Self.scale(down: down, up: up)
                // Newest sample pinned to the right edge; history scrolls in from the left.
                let step = size.width / CGFloat(NetSampler.ringCapacity - 1)
                func path(_ values: [Double]) -> Path {
                    var path = Path()
                    for (index, value) in values.enumerated() {
                        let x = size.width - CGFloat(values.count - 1 - index) * step
                        let y = size.height - CGFloat(value / top) * (size.height - 2) - 1
                        index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    }
                    return path
                }
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: DiskMetrics.barCornerRadius)
                context.fill(track, with: .color(DiskPalette.track.opacity(0.5)))
                context.clip(to: track)
                context.stroke(path(down), with: .color(NetworkPalette.down), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                context.stroke(path(up), with: .color(NetworkPalette.up), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .accessibilityHidden(true)
        }
    }
}

struct NetworkDisclosureRow: View {
    let title: String
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        let content = NetworkDisclosureContent(title: title, isExpanded: isExpanded)
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: content.symbolName).imageScale(.small).frame(width: 10)
                Text(content.title)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(isHovering ? .primary : .secondary)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .rowHoverHighlight(isHovering, cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .clickableCursor()
        .accessibilityLabel(content.accessibilityLabel)
        .accessibilityValue(content.accessibilityValue)
    }
}

/// Interface rows and connection info (NET-003), shown while Interfaces is expanded.
struct NetworkInterfacesView: View {
    @ObservedObject var sampler: NetSampler
    @ObservedObject var details: NetworkDetailsModel
    var onRefresh: () -> Void
    var openLocationSettings: () -> Void

    private var content: NetworkDetailsContent {
        NetworkDetailsContent(phase: details.phase, permission: details.permission, interfaces: sampler.interfaces)
    }

    var body: some View {
        let content = content
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise").imageScale(.small)
                }
                .font(.caption)
                .hoverIconButtonStyle()
                .accessibilityLabel("Refresh network details")
            }
            if let wifi = content.wifi { wifiRow(wifi) }
            ForEach(content.wired, id: \.name) { rateRow($0, symbol: "cable.connector") }
            ForEach(content.tunnels, id: \.name) { rateRow($0, symbol: "lock.shield") }
            if let idle = content.idleTunnelsLine {
                Text(idle).font(.caption).foregroundStyle(.secondary)
            }
            if let inactive = content.inactiveLine {
                Text(inactive).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(content.connection, id: \.label) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label).foregroundStyle(.secondary)
                    Spacer(minLength: DiskMetrics.inlineSpacing)
                    Text(row.value).monospacedDigit().multilineTextAlignment(.trailing)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.leading, 14)
        .padding(.bottom, 4)
    }

    private func wifiRow(_ row: NetworkDetailsContent.WiFiRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: DiskMetrics.inlineSpacing) {
                Image(systemName: "wifi").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(row.title).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: DiskMetrics.inlineSpacing)
                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let rate = row.rateText {
                Text(rate).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .padding(.leading, 22)
            }
            if row.showsGrantAction {
                Button(row.grantActionTitle, action: openLocationSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .clickableCursor()
            }
        }
    }

    private func rateRow(_ row: NetworkDetailsContent.RateRow, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DiskMetrics.inlineSpacing) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(row.name).fontWeight(.medium)
            Spacer(minLength: DiskMetrics.inlineSpacing)
            Text("↓ \(row.downText)  ↑ \(row.upText)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name): download \(row.downText), upload \(row.upText)")
    }
}

/// "Top processes" block, same row rhythm as the largest-files list.
struct ProcessesBlockView: View {
    let content: ProcessesContent

    var body: some View {
        switch content.body {
        case .hidden:
            EmptyView()
        case .measuring:
            Text(ProcessesContent.measuringText).font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 14)
        case .empty:
            Text(ProcessesContent.emptyText).font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 14)
        case .rows(let rows):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: DiskMetrics.inlineSpacing) {
                        Text(row.name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: DiskMetrics.inlineSpacing)
                        Text("↓ \(row.downText)  ↑ \(row.upText)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.name): download \(row.downText), upload \(row.upText)")
                }
            }
            .padding(.leading, 14)
        case .notice(let text):
            HStack(spacing: 4) {
                Image(systemName: "info.circle").imageScale(.small)
                Text(text)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
            .accessibilityElement(children: .combine)
        }
    }
}
