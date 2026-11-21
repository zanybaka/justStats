import Foundation

/// Down/up rate in bytes per second.
struct NetRate: Equatable {
    var down: Double
    var up: Double

    static let zero = NetRate(down: 0, up: 0)
}

/// One interface's rate within a tick, plus the state NET-003's rows need.
struct InterfaceRate: Equatable {
    let name: String
    let kind: NetInterfaceKind
    let isUp: Bool
    let rate: NetRate
    /// Cumulative bytes since boot (rx + tx), used to tell a live tunnel from an idle one.
    let totalBytes: UInt64
}

/// What one ingested counter read produces.
struct NetReading: Equatable {
    /// Aggregate rate over the physical interfaces; `nil` on the baseline read (no
    /// previous counters, so nothing honest to report yet).
    let physicalRate: NetRate?
    let interfaces: [InterfaceRate]
    /// Since-boot totals of the physical interfaces, minus the reset offset.
    let totals: NetTotals
}

struct NetTotals: Equatable {
    var down: UInt64
    var up: UInt64

    static let zero = NetTotals(down: 0, up: 0)
}

/// The pure core of the throughput sampler (NET-001): turns successive counter reads
/// into clamped, plausibility-checked rates and since-boot totals. No clock, no I/O —
/// the elapsed interval is passed in, the counters come from a fake in tests.
struct NetThroughputEngine {
    /// A one-shot jump larger than `baudrate / 8 × elapsed × 1.5` is treated as a counter
    /// glitch (interface re-created, driver reset) and zeroed rather than plotted.
    static let plausibilityHeadroom = 1.5
    /// Cutoff bytes/second when the driver reports no link rate (40 Gbit/s).
    static let fallbackMaxBytesPerSecond: Double = 5_000_000_000

    private var previous: [String: InterfaceCounters] = [:]
    private var offset: NetTotals = .zero
    private var lastPhysicalSum: NetTotals = .zero

    /// Feeds one read. `elapsed` is the time since the previous read; ignored (and may be
    /// 0) on the baseline read.
    mutating func ingest(_ counters: [InterfaceCounters], elapsed: TimeInterval) -> NetReading {
        var rows: [InterfaceRate] = []
        var aggregate = NetRate.zero
        var sum = NetTotals.zero
        let canComputeRate = elapsed > 0 && !previous.isEmpty

        for current in counters {
            let kind = NetInterfaceKind.kind(forName: current.name)
            var rate = NetRate.zero
            if canComputeRate, let before = previous[current.name] {
                rate = NetRate(
                    down: Self.rate(from: before.rxBytes, to: current.rxBytes, baudrate: current.baudrate, elapsed: elapsed),
                    up: Self.rate(from: before.txBytes, to: current.txBytes, baudrate: current.baudrate, elapsed: elapsed)
                )
            }
            if kind == .physical {
                aggregate.down += rate.down
                aggregate.up += rate.up
                sum.down &+= current.rxBytes
                sum.up &+= current.txBytes
            }
            rows.append(InterfaceRate(
                name: current.name, kind: kind, isUp: current.isUp, rate: rate,
                totalBytes: current.rxBytes &+ current.txBytes
            ))
        }

        // An interface that disappeared (USB adapter unplugged) lowers the physical sum;
        // never let the shown total go negative — rebase the offset instead.
        if sum.down < offset.down { offset.down = sum.down }
        if sum.up < offset.up { offset.up = sum.up }
        lastPhysicalSum = sum

        previous = Dictionary(counters.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        return NetReading(
            physicalRate: canComputeRate ? aggregate : nil,
            interfaces: rows,
            totals: NetTotals(down: sum.down - offset.down, up: sum.up - offset.up)
        )
    }

    /// Reset stores an offset at the current counters; the monotonic counters are untouched.
    mutating func resetTotals() {
        offset = lastPhysicalSum
    }

    /// Drops the previous counters so the next ingest is a baseline again (totals and the
    /// reset offset are kept).
    mutating func forgetPrevious() {
        previous = [:]
    }

    /// Totals as of the last ingest (after any reset).
    var totals: NetTotals {
        NetTotals(down: lastPhysicalSum.down - offset.down, up: lastPhysicalSum.up - offset.up)
    }

    /// Bytes/second between two counter values: negative deltas (wrap or counter reset)
    /// and implausible jumps both read as 0.
    static func rate(from old: UInt64, to new: UInt64, baudrate: UInt64, elapsed: TimeInterval) -> Double {
        guard new >= old, elapsed > 0 else { return 0 }
        let delta = Double(new - old)
        let ceilingPerSecond = baudrate > 0 ? Double(baudrate) / 8 : fallbackMaxBytesPerSecond
        if delta > ceilingPerSecond * elapsed * plausibilityHeadroom { return 0 }
        return delta / elapsed
    }
}
