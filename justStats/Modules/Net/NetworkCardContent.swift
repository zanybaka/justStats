import Foundation

/// Pure state → presentation mapping for the collapsed network card (NET-002), in the
/// pattern of `VolumeRowView.Content`: everything the card draws is decided here so it
/// is unit-testable without a SwiftUI host.
struct NetworkCardContent: Equatable {
    enum Chart: Equatable {
        /// No real samples yet: the view draws an explicit empty track, never a zero line.
        case empty
        /// Real samples, oldest first.
        case series(down: [Double], up: [Double])
    }

    /// Shown instead of a number while no rate has been measured yet.
    static let placeholder = "—"

    let downText: String
    let upText: String
    let chart: Chart
    let totalsLabel: String
    let totalsDownText: String
    let totalsUpText: String
    let accessibilitySummary: String

    init(latest: NetRate?, samples: [NetRate], totals: NetTotals, totalsWereReset: Bool) {
        downText = latest.map { RateFormat.text(bytesPerSecond: $0.down) } ?? Self.placeholder
        upText = latest.map { RateFormat.text(bytesPerSecond: $0.up) } ?? Self.placeholder
        chart = samples.isEmpty
            ? .empty
            : .series(down: samples.map(\.down), up: samples.map(\.up))
        totalsLabel = totalsWereReset ? "Since reset" : "Since boot"
        totalsDownText = Self.totalText(totals.down)
        totalsUpText = Self.totalText(totals.up)

        let rates = latest == nil
            ? "measuring"
            : "download \(downText), upload \(upText)"
        accessibilitySummary =
            "Network: \(rates). \(totalsLabel): \(totalsDownText) downloaded, \(totalsUpText) uploaded."
    }

    /// `ByteFormat` spells zero as "Zero kB"; a fresh or reset total reads "0 B".
    private static func totalText(_ bytes: UInt64) -> String {
        bytes == 0 ? "0 B" : ByteFormat.text(fromBytes: Int64(clamping: bytes))
    }

    /// Spoken label of the reset button.
    static let resetAccessibilityLabel = "Reset network totals"
}

/// What a disclosure row draws (NET-002): the Interfaces and Top processes rows share it.
struct NetworkDisclosureContent: Equatable {
    static let interfacesTitle = "Interfaces"
    static let processesTitle = "Top processes"

    let title: String
    let symbolName: String
    let accessibilityLabel: String
    let accessibilityValue: String

    init(title: String, isExpanded: Bool) {
        self.title = title
        symbolName = isExpanded ? "chevron.down" : "chevron.right"
        accessibilityLabel = title
        accessibilityValue = isExpanded ? "expanded" : "collapsed"
    }
}
