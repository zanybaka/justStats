import XCTest
@testable import justStats

/// NET-003: state mapping + lazy lifecycle of the expanded details.
final class NetworkDetailsContentTests: XCTestCase {
    private let wifi = WiFiStatus(interfaceName: "en0", ssid: "HomeNet", channel: 36, rssi: -52)
    private func metadata(_ wifi: WiFiStatus?) -> NetworkMetadata {
        NetworkMetadata(wifi: wifi, localIP: "192.168.1.5", dnsServers: ["1.1.1.1", "8.8.8.8", "9.9.9.9", "4.4.4.4"])
    }
    private func iface(_ name: String, up: Bool = true, bytes: UInt64 = 100, rate: NetRate = .zero) -> InterfaceRate {
        InterfaceRate(name: name, kind: NetInterfaceKind.kind(forName: name), isUp: up, rate: rate, totalBytes: bytes)
    }

    func testPermissionNotDeterminedShowsInterfaceNameWithoutSSIDPlusGrantPath() throws {
        let content = NetworkDetailsContent(
            phase: .loaded(metadata: metadata(wifi), latency: .unreachable),
            permission: .notDetermined, interfaces: []
        )
        let row = try XCTUnwrap(content.wifi)
        XCTAssertEqual(row.title, "en0")
        XCTAssertFalse(row.detail.contains("HomeNet"))
        XCTAssertTrue(row.showsGrantAction)
        XCTAssertEqual(row.grantActionTitle, NetworkDetailsContent.grantTitleNotDetermined)
    }

    func testPermissionDeniedPointsToSettings() throws {
        let content = NetworkDetailsContent(
            phase: .loaded(metadata: metadata(wifi), latency: .unreachable), permission: .denied, interfaces: []
        )
        let row = try XCTUnwrap(content.wifi)
        XCTAssertTrue(row.showsGrantAction)
        XCTAssertEqual(row.grantActionTitle, NetworkDetailsContent.grantTitleDenied)
    }

    func testAuthorizedShowsSSIDChannelAndRSSI() throws {
        let content = NetworkDetailsContent(
            phase: .loaded(metadata: metadata(wifi), latency: .reachable(milliseconds: 23.4)),
            permission: .authorized, interfaces: []
        )
        let row = try XCTUnwrap(content.wifi)
        XCTAssertEqual(row.title, "HomeNet")
        XCTAssertEqual(row.detail, "en0 · Wi-Fi · ch 36 · -52 dBm")
        XCTAssertFalse(row.showsGrantAction)
    }

    func testNoWiFiInterfaceMeansNoWiFiRow() {
        let content = NetworkDetailsContent(phase: .loaded(metadata: metadata(nil), latency: .unreachable),
                                            permission: .authorized, interfaces: [])
        XCTAssertNil(content.wifi)
    }

    func testDownInterfacesCollapseIntoOneMutedRow() {
        let interfaces = ["en1", "en2", "en3", "en4", "en5", "bridge0"].map { iface($0, up: false) } + [iface("en0")]
        let content = NetworkDetailsContent(phase: .idle, permission: .authorized, interfaces: interfaces)
        XCTAssertEqual(content.inactiveLine, "Inactive: bridge0, en1, en2, en3 +2 more")
        let none = NetworkDetailsContent(phase: .idle, permission: .authorized, interfaces: [iface("en0")])
        XCTAssertNil(none.inactiveLine)
    }

    func testBusyTunnelsGetOwnRatesAndIdleOnesCollapseIntoOneMutedLine() {
        let interfaces = [
            iface("utun3", bytes: 5_000, rate: NetRate(down: 1_500, up: 200)),
            iface("utun1", bytes: 900), iface("utun2", bytes: 900),
            iface("utun0", bytes: 0),
            iface("utun9", up: false, bytes: 10),
            iface("en0", rate: NetRate(down: 9, up: 9)),
        ]
        let content = NetworkDetailsContent(phase: .idle, permission: .authorized, interfaces: interfaces)
        XCTAssertEqual(content.tunnels, [.init(name: "utun3", downText: "1.5 KB/s", upText: "200 B/s")])
        XCTAssertEqual(content.idleTunnelsLine, "Idle tunnels: utun1, utun2")
    }

    func testNoTunnelRowsWhenAllTunnelsAreIdleOrUnused() {
        let content = NetworkDetailsContent(
            phase: .idle, permission: .authorized, interfaces: [iface("utun0", bytes: 0), iface("en0")]
        )
        XCTAssertTrue(content.tunnels.isEmpty)
        XCTAssertNil(content.idleTunnelsLine)
    }

    func testWiFiRowShowsItsOwnLiveRate() throws {
        let content = NetworkDetailsContent(
            phase: .loaded(metadata: metadata(wifi), latency: .unreachable), permission: .authorized,
            interfaces: [iface("en0", rate: NetRate(down: 16_000, up: 9_200))]
        )
        XCTAssertEqual(try XCTUnwrap(content.wifi).rateText, "↓ 16 KB/s  ↑ 9.2 KB/s")
    }

    func testWiredLinksThatCarriedTrafficGetRowsButTheWiFiInterfaceDoesNot() {
        let interfaces = [
            iface("en0", rate: NetRate(down: 5, up: 5)),
            iface("en5", bytes: 4_000, rate: NetRate(down: 2_000, up: 0)),
            iface("en6", bytes: 0),
            iface("en7", up: false, bytes: 50),
        ]
        let content = NetworkDetailsContent(
            phase: .loaded(metadata: metadata(wifi), latency: .unreachable), permission: .authorized, interfaces: interfaces
        )
        XCTAssertEqual(content.wired, [.init(name: "en5", downText: "2.0 KB/s", upText: "0 B/s")])
    }

    func testConnectionRowsFollowThePhase() {
        let idle = NetworkDetailsContent(phase: .idle, permission: .authorized, interfaces: [])
        XCTAssertEqual(idle.connection.map(\.label), ["Internet"])

        let loading = NetworkDetailsContent(phase: .loading(metadata: metadata(nil)), permission: .authorized, interfaces: [])
        XCTAssertEqual(loading.connection.first?.value, "Checking…")
        XCTAssertEqual(loading.connection.map(\.label), ["Internet", "Local IP", "DNS"])

        let online = NetworkDetailsContent(phase: .loaded(metadata: metadata(nil), latency: .reachable(milliseconds: 23.4)),
                                           permission: .authorized, interfaces: [])
        XCTAssertEqual(online.connection[0].value, "Online · 23 ms")
        XCTAssertEqual(online.connection[1].value, "192.168.1.5")
        XCTAssertEqual(online.connection[2].value, "1.1.1.1, 8.8.8.8, 9.9.9.9")

        let offline = NetworkDetailsContent(phase: .loaded(metadata: metadata(nil), latency: .unreachable),
                                            permission: .authorized, interfaces: [])
        XCTAssertEqual(offline.connection[0].value, "Offline")
    }

    func testThereIsNoPublicIPRow() {
        let content = NetworkDetailsContent(phase: .loaded(metadata: metadata(nil), latency: .unreachable),
                                            permission: .authorized, interfaces: [])
        XCTAssertFalse(content.connection.contains { $0.label.lowercased().contains("public") })
    }
}

@MainActor
final class NetworkDetailsModelTests: XCTestCase {
    func testNothingReadUntilBegin() {
        let metadata = SpyMetadataProvider()
        let prober = SpyProber()
        let location = FakeLocation(.notDetermined)
        let model = NetworkDetailsModel(metadata: metadata, prober: prober, location: location)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(metadata.readCount, 0)
        XCTAssertEqual(prober.pingCount, 0)
        XCTAssertEqual(location.requestCount, 0, "Location is never requested before the first expand")
    }

    func testBeginRequestsLocationLazilyAndReadsOnceAndPingsOnce() async {
        let metadata = SpyMetadataProvider()
        let prober = SpyProber()
        let location = FakeLocation(.notDetermined)
        let model = NetworkDetailsModel(metadata: metadata, prober: prober, location: location)
        await model.begin().value
        XCTAssertEqual(location.requestCount, 1)
        XCTAssertEqual(metadata.readCount, 1)
        XCTAssertEqual(prober.pingCount, 1)
        guard case .loaded(_, let latency) = model.phase else { return XCTFail("expected loaded, got \(model.phase)") }
        XCTAssertEqual(latency, .reachable(milliseconds: 23.4))
    }

    func testAuthorizedLocationIsNotRequestedAgain() async {
        let location = FakeLocation(.authorized)
        let model = NetworkDetailsModel(metadata: SpyMetadataProvider(), prober: SpyProber(), location: location)
        await model.begin().value
        XCTAssertEqual(location.requestCount, 0)
    }

    func testCancelDropsPendingWorkAndSkipsThePing() async {
        let metadata = SpyMetadataProvider()
        let gate = DispatchSemaphore(value: 0)
        metadata.gate = gate
        let prober = SpyProber()
        let model = NetworkDetailsModel(metadata: metadata, prober: prober, location: FakeLocation(.authorized))
        let task = model.begin()
        await waitUntil { metadata.readCount == 1 }
        model.cancel()
        gate.signal()
        await task.value
        XCTAssertEqual(model.phase, .idle, "a result arriving after cancel is never published")
        XCTAssertEqual(prober.pingCount, 0, "the ICMP echo is not sent for a cancelled expand")
    }

    func testBeginAfterBeginSupersedesTheFirstRun() async {
        let metadata = SpyMetadataProvider()
        let prober = SpyProber()
        let model = NetworkDetailsModel(metadata: metadata, prober: prober, location: FakeLocation(.authorized))
        let first = model.begin()
        await model.begin().value
        await first.value
        guard case .loaded = model.phase else { return XCTFail("expected loaded") }
    }
}

/// The module's surface makes no network request other than the single ICMP echo.
final class NetworkModuleSurfaceTests: XCTestCase {
    func testNetModuleSourcesUseNoNetworkAPIsBeyondTheICMPSocket() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("justStats/Modules/Net")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 5)
        let forbidden = ["URLSession", "URLRequest", "NWConnection", "NWPathMonitor", "CFHTTP", "CFReadStream",
                         "NSURLConnection", "getaddrinfo", "gethostbyname", "SCNetworkReachability", "ipify"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(file.lastPathComponent) must not use \(token)")
            }
            // `socket(`/`sendto(` belong only to the ICMP probe.
            if file.lastPathComponent != "NetworkMetadata.swift" {
                XCTAssertFalse(text.contains("sendto("), "\(file.lastPathComponent) must not send packets")
            }
        }
    }

    func testICMPEchoRequestHasValidChecksumAndLayout() {
        let packet = ICMPLatencyProbe.echoRequest(identifier: 0x1234, sequence: 0x00AB)
        XCTAssertEqual(packet[0], 8)
        XCTAssertEqual(packet[1], 0)
        XCTAssertEqual(Array(packet[4...7]), [0x12, 0x34, 0x00, 0xAB])
        XCTAssertEqual(ICMPLatencyProbe.checksum(packet), 0, "a correct checksum folds the whole packet to zero")
    }

    func testReplyMatchingSkipsIPHeaderAndChecksSequence() {
        let ipHeader = [UInt8](repeating: 0, count: 20).enumerated().map { $0.offset == 0 ? UInt8(0x45) : 0 }
        let reply: [UInt8] = [0, 0, 0, 0, 0x12, 0x34, 0x00, 0xAB, 0, 0, 0, 0]
        XCTAssertTrue(ICMPLatencyProbe.isMatchingReply(ipHeader + reply, sequence: 0x00AB))
        XCTAssertFalse(ICMPLatencyProbe.isMatchingReply(ipHeader + reply, sequence: 0x00AC))
        var request = reply
        request[0] = 8
        XCTAssertFalse(ICMPLatencyProbe.isMatchingReply(ipHeader + request, sequence: 0x00AB), "only echo replies match")
    }
}
