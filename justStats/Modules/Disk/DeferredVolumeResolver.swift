import Foundation

/// Streamed result for one deferred (external/network) volume — delivered on the
/// main queue, exactly once per volume per refresh generation (TECHSPEC §3 tier 2).
enum DeferredVolumeResolution: Equatable {
    /// Capacity resolved — ready to render as a full row (PRD FR4–FR5).
    case resolved(Volume)
    /// The capacity read failed outright, or exceeded the per-volume timeout
    /// (hung network mount). Render an "unavailable" placeholder row for this
    /// volume instead of blocking the pipeline.
    case unavailable(DeferredVolume)

    /// The mount this result belongs to — consumers key rows by URL.
    var mountURL: URL {
        switch self {
        case .resolved(let volume): return volume.mountURL
        case .unavailable(let volume): return volume.mountURL
        }
    }
}

/// Async half of the popover-tier enumeration (VOL-002, TECHSPEC §3 tier 2):
/// resolves the `DeferredVolume` stubs from
/// `VolumeEnumerator.enumerateSynchronously()` on
/// `DispatchQueue.global(qos: .utility)` and streams each volume back the moment
/// its own capacity read finishes — results are never batched behind the slowest
/// mount, and no filesystem call ever runs on the main thread.
///
/// Hung-mount isolation (TECHSPEC §7): a stuck SMB `statfs` delays only its own
/// row. Every volume gets a per-row timeout; on expiry an `.unavailable`
/// placeholder is delivered and the blocked read is left to finish (or hang
/// forever) in the background. Its mount URL stays marked in-flight, so repeated
/// refreshes reuse the stuck read instead of piling up one blocked thread per
/// refresh; if the read eventually completes, its result is handed to the newest
/// refresh generation still waiting on that volume.
///
/// In-flight slots age out (`staleReadThreshold`): a read still blocked long
/// after its row timed out is treated as abandoned, so a *different* healthy
/// volume later mounted at the same path (dead NAS unmounted, USB drive mounted
/// at `/Volumes/NAS`) gets a fresh read instead of being poisoned into permanent
/// "Unavailable". Aging caps re-dispatch to at most once per threshold window,
/// preserving the pile-up protection for a genuinely still-hung mount.
///
/// Cancellation: every `resolve` call starts a new generation and invalidates all
/// undelivered results from prior generations (VOL-005 Refresh relies on this).
final class DeferredVolumeResolver {
    /// Per-volume budget before a row is declared unavailable. "A few seconds":
    /// long enough for a healthy-but-slow network mount to answer, short enough
    /// that a dead one can't keep a row pending indefinitely.
    static let defaultTimeout: TimeInterval = 3

    /// How long an in-flight read may block before its slot is considered
    /// abandoned and a fresh `resolve` for the same URL is allowed to re-dispatch.
    /// Far above `defaultTimeout` so a healthy-but-slow read is never re-stacked;
    /// its only job is to let a genuinely different volume mounted at a reused path
    /// recover instead of being poisoned forever by the previous mount's dead read.
    static let defaultStaleReadThreshold: TimeInterval = 60

    /// The not-yet-delivered result slot for one volume in the current generation.
    private struct PendingDelivery {
        let generation: UInt64
        let volume: DeferredVolume
        let deliver: (DeferredVolumeResolution) -> Void
    }

    private let provider: VolumeInfoProviding
    private let timeout: TimeInterval
    private let staleReadThreshold: TimeInterval
    /// Monotonic clock (`ProcessInfo.systemUptime`); injected so the stale-slot
    /// aging can be exercised deterministically in tests without real waiting.
    private let uptime: () -> TimeInterval
    /// Serializes all resolver state below. Never blocks on the main queue, so the
    /// main queue may `sync` onto it for the last-moment staleness check.
    private let stateQueue = DispatchQueue(label: QueueLabels.deferredVolumeState)
    /// Refresh token: results and timeouts tagged with an older generation are
    /// dropped instead of delivered.
    private var generation: UInt64 = 0
    /// Current-generation deliveries not yet made, keyed by mount URL.
    private var pending: [URL: PendingDelivery] = [:]
    /// One still-running capacity read. `dispatchedAt` ages the slot out;
    /// `token` identifies which dispatch owns it so a late completion only clears
    /// its own slot, not a fresh re-dispatch that replaced it.
    private struct InFlightRead {
        let token: UInt64
        let dispatchedAt: TimeInterval
    }
    /// Mount URLs whose blocking capacity read is still running. Deliberately
    /// survives generation bumps — a hung read from a previous refresh keeps its
    /// slot so the same volume is never dispatched twice concurrently — but a slot
    /// older than `staleReadThreshold` is treated as abandoned so a healthy volume
    /// remounted at the same path can get a fresh read (never poisoned forever).
    private var inFlightReads: [URL: InFlightRead] = [:]
    /// Monotonic per-dispatch token source (unambiguous slot ownership even if two
    /// dispatches read the same clock value).
    private var nextReadToken: UInt64 = 0

    init(
        provider: VolumeInfoProviding = FileManagerVolumeInfoProvider(),
        timeout: TimeInterval = DeferredVolumeResolver.defaultTimeout,
        staleReadThreshold: TimeInterval = DeferredVolumeResolver.defaultStaleReadThreshold,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.provider = provider
        self.timeout = timeout
        self.staleReadThreshold = staleReadThreshold
        self.uptime = uptime
    }

    /// Starts a new refresh generation resolving `volumes`, invalidating anything
    /// still undelivered from earlier generations. `onResult` is called on the
    /// main queue exactly once per volume — `.resolved` or `.unavailable` — unless
    /// a newer `resolve`/`invalidate` supersedes this generation first.
    ///
    /// Callable from any thread; does no filesystem work itself.
    func resolve(_ volumes: [DeferredVolume], onResult: @escaping (DeferredVolumeResolution) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            let generation = self.generation
            self.pending.removeAll()
            for volume in volumes {
                let url = volume.mountURL
                guard self.pending[url] == nil else { continue } // duplicate mount in input
                self.pending[url] = PendingDelivery(generation: generation, volume: volume, deliver: onResult)
                self.scheduleTimeout(for: url, generation: generation)
                // A read for this URL may still be hanging from a previous
                // refresh — never stack a second blocked thread on a *live* one;
                // the existing read hands off to this generation when it completes.
                // But a slot older than `staleReadThreshold` is abandoned: the read
                // has hung far past any useful window, so allow one fresh dispatch
                // (a different, healthy volume may now be mounted at this path).
                if let inFlight = self.inFlightReads[url],
                   self.uptime() - inFlight.dispatchedAt < self.staleReadThreshold {
                    continue
                }
                self.nextReadToken &+= 1
                let token = self.nextReadToken
                self.inFlightReads[url] = InFlightRead(token: token, dispatchedAt: self.uptime())
                self.dispatchRead(for: url, token: token)
            }
        }
    }

    /// Drops every undelivered result of the current generation (e.g. on popover
    /// close). Hung reads keep running in the background but deliver nowhere.
    func invalidate() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.pending.removeAll()
        }
    }

    // MARK: - stateQueue internals

    /// Dispatches the (potentially hanging) filesystem reads for one volume.
    /// Captures the provider, not `self`, so a resolver can deallocate while a
    /// dead mount keeps a global-queue thread blocked. `token` tags this read so a
    /// late completion only clears the in-flight slot it actually owns.
    private func dispatchRead(for url: URL, token: UInt64) {
        let provider = self.provider
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // NFR3 invariant: the popover tier never touches the filesystem on
            // the main thread. Debug-build check; free in release.
            dispatchPrecondition(condition: .notOnQueue(.main))
            let space = provider.capacity(forVolumeAt: url)
            // Skip DiskArbitration metadata when the volume has no readable
            // capacity — the row will be a placeholder either way.
            let bsdName = space != nil ? provider.bsdName(forVolumeAt: url) : nil
            guard let self else { return }
            self.stateQueue.async {
                self.finishRead(for: url, token: token, space: space, bsdName: bsdName)
            }
        }
    }

    /// Runs on `stateQueue` when a read completes (however late). Delivers to the
    /// volume's still-pending slot, if any; results that arrive after their row
    /// timed out or after a newer generation started are dropped.
    private func finishRead(for url: URL, token: UInt64, space: VolumeSpace?, bsdName: String?) {
        // Only this read may act if it still owns the in-flight slot. An aged-out
        // slot may already have been reclaimed by a fresh re-dispatch whose own
        // read is still running — that newer read owns the slot now, so a
        // superseded old read must neither clear the slot nor consume the pending
        // delivery (else its stale `.unavailable` re-poisons a row the fresh
        // healthy read is about to resolve).
        guard inFlightReads[url]?.token == token else { return }
        inFlightReads.removeValue(forKey: url)
        guard let delivery = pending.removeValue(forKey: url) else { return }
        guard let space else {
            deliver(.unavailable(delivery.volume), via: delivery)
            return
        }
        deliver(.resolved(Volume(
            name: delivery.volume.name,
            mountURL: url,
            totalBytes: space.total,
            freeBytes: space.free,
            kind: delivery.volume.kind,
            bsdName: bsdName
        )), via: delivery)
    }

    /// Row-level timeout (TECHSPEC §3 tier 2): if the volume's slot is still
    /// pending in the same generation when the deadline passes, deliver the
    /// `.unavailable` placeholder. The blocked read itself is left alone — it
    /// stays in `inFlightReads` so later refreshes don't re-dispatch it.
    private func scheduleTimeout(for url: URL, generation: UInt64) {
        stateQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            guard let delivery = self.pending[url], delivery.generation == generation else { return }
            self.pending.removeValue(forKey: url)
            self.deliver(.unavailable(delivery.volume), via: delivery)
        }
    }

    /// Hops to the main queue and re-checks the generation at the last moment —
    /// a refresh may supersede this delivery between the `stateQueue` decision
    /// and the main-queue hop.
    private func deliver(_ resolution: DeferredVolumeResolution, via delivery: PendingDelivery) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.stateQueue.sync(execute: { self.generation == delivery.generation }) else { return }
            delivery.deliver(resolution)
        }
    }
}
