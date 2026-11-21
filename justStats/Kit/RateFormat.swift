import Foundation

/// Throughput formatting for the network section (NET-002; TECHSPEC §1: formatting
/// helpers live in Kit). Decimal units (1 MB = 10^6 bytes) like `ByteFormat`, with a
/// fixed US-English output so strings are deterministic in tests.
enum RateFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    /// "0 B/s", "812 B/s", "12 KB/s", "1.2 MB/s". One decimal below 10 in KB and up,
    /// none otherwise. Negative or non-finite input reads as zero.
    static func text(bytesPerSecond: Double) -> String {
        "\(magnitude(bytesPerSecond))/s"
    }

    /// "0 B", "812 B", "12 KB", "1.2 MB" — same scaling without the "/s".
    static func magnitude(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 B" }
        var scaled = value
        var unit = 0
        while scaled >= 1000, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(scaled.rounded())) B" }
        let rounded = (scaled * 10).rounded() / 10
        // 999.96 KB rounds to 1000.0: promote to the next unit instead of printing "1000 KB".
        if rounded >= 1000, unit < units.count - 1 { return "1 \(units[unit + 1])" }
        let digits = rounded < 10 ? String(format: "%.1f", rounded) : String(Int(rounded.rounded()))
        return "\(digits) \(units[unit])"
    }
}
