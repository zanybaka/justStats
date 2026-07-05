import Foundation

/// Shared byte-count formatting for UI strings (TECHSPEC §1: formatting helpers
/// live in Kit).
///
/// `.file` count style is decimal (1 GB = 10^9 bytes), matching Finder and how
/// `statfs` sizes are reported — the same convention `ThresholdConfiguration`'s
/// GB defaults use. The locale is pinned to `en_US` so output matches the app's
/// English UI strings and stays deterministic in tests.
enum ByteFormat {
    private static let locale = Locale(identifier: "en_US")

    /// "500 GB", "245.11 GB", "1.5 TB". Negative counts (defensive — a
    /// filesystem should never report one) clamp to zero.
    static func text(fromBytes bytes: Int64) -> String {
        max(bytes, 0).formatted(.byteCount(style: .file).locale(locale))
    }
}
