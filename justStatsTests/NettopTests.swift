import XCTest
@testable import justStats

/// NET-004: parser fixtures, ranking, rates and failure path.
final class NettopParserTests: XCTestCase {
    /// Output as printed with the app's column exclusions (leading blank cell).
    private let compact = """
    ,bytes_in,bytes_out,
    apsd.608,47510,322388,
    com.apple.WebKit.Networking.1234,2000000,500,
    airportd.662,0,0,

    """

    /// Output as printed when `time` is not excluded.
    private let withTime = """
    time,,interface,state,bytes_in,bytes_out,rx_dupe,
    23:46:49.403525,apsd.608,,,47510,322388,79,
    23:46:49.403531,Google Chrome H.4321,,,10,20,0,
    """

    func testCompactFormat() throws {
        let rows = try XCTUnwrap(NettopParser.parse(compact))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ProcessTraffic(key: "apsd.608", name: "apsd", pid: 608, bytesIn: 47510, bytesOut: 322388))
        XCTAssertEqual(rows[1].name, "com.apple.WebKit.Networking")
        XCTAssertEqual(rows[1].pid, 1234)
        XCTAssertEqual(rows[2].bytesIn, 0)
    }

    func testTimeColumnFormatAndNamesWithSpaces() throws {
        let rows = try XCTUnwrap(NettopParser.parse(withTime))
        XCTAssertEqual(rows.map(\.name), ["apsd", "Google Chrome H"])
        XCTAssertEqual(rows[1].pid, 4321)
        XCTAssertEqual(rows[1].bytesOut, 20)
    }

    func testQuotedNameWithCommaAndEscapedQuote() throws {
        let text = ",bytes_in,bytes_out,\n\"Weird, \"\"App\"\".77\",5,6,\n"
        let rows = try XCTUnwrap(NettopParser.parse(text))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Weird, \"App\"")
        XCTAssertEqual(rows[0].pid, 77)
        XCTAssertEqual(rows[0].bytesIn, 5)
    }

    func testMalformedRowsAreSkippedNotFatal() throws {
        let text = ",bytes_in,bytes_out,\nnopid,1,2,\nok.5,3,4,\nshort.6,7\nbad.7,x,y,\n"
        let rows = try XCTUnwrap(NettopParser.parse(text))
        XCTAssertEqual(rows.map(\.key), ["ok.5"])
    }

    func testOnlyTheFirstSampleBlockIsUsed() throws {
        let text = ",bytes_in,bytes_out,\na.1,1,1,\n,bytes_in,bytes_out,\na.1,9,9,\n"
        let rows = try XCTUnwrap(NettopParser.parse(text))
        XCTAssertEqual(rows.map(\.bytesIn), [1])
    }

    func testEmptyOrHeaderlessOutputIsNil() {
        XCTAssertNil(NettopParser.parse(""))
        XCTAssertNil(NettopParser.parse("nettop: Operation not permitted\n"))
    }

    func testHeaderOnlyIsAnEmptyListNotNil() {
        XCTAssertEqual(NettopParser.parse(",bytes_in,bytes_out,\n"), [])
    }
}

final class ProcessRankingTests: XCTestCase {
    private func rate(_ name: String, _ down: Double, _ up: Double) -> ProcessRate {
        ProcessRate(key: name, displayName: name, down: down, up: up)
    }

    func testSortsByMaxOfDownAndUpDroppingIdle() {
        let ranked = ProcessRanking.top([
            rate("idle", 0, 0), rate("downer", 500, 1), rate("upper", 10, 900), rate("mid", 600, 600),
        ])
        XCTAssertEqual(ranked.map(\.displayName), ["upper", "mid", "downer"])
    }

    func testTruncatesToLimitAndTiesAreStable() {
        let rates = (0..<8).map { rate("p\($0)", 100, 0) }
        let ranked = ProcessRanking.top(rates, limit: 5)
        XCTAssertEqual(ranked.map(\.displayName), ["p0", "p1", "p2", "p3", "p4"])
        XCTAssertEqual(ProcessRanking.top(rates, limit: 0), [])
    }
}

@MainActor
final class ProcessTrafficModelTests: XCTestCase {
    private func output(_ rows: [(String, Int, Int)]) -> String {
        ",bytes_in,bytes_out,\n" + rows.map { "\($0.0),\($0.1),\($0.2)," }.joined(separator: "\n") + "\n"
    }

    private var clock: TimeInterval = 0

    private func model(_ runner: NettopRunning, names: [Int32: String] = [:]) -> ProcessTrafficModel {
        ProcessTrafficModel(runner: runner, resolveName: { names[$0] }, uptime: { [unowned self] in self.clock },
                            sleep: { _ in })
    }

    func testFirstPassMeasuresSecondPassRanksRatesAndResolvesFriendlyNames() async {
        let runner = ScriptedNettopRunner([
            .success(output([("Safari.10", 1_000, 0), ("quiet.11", 5, 5), ("sync.12", 0, 100)])),
            .success(output([("Safari.10", 9_000, 0), ("quiet.11", 5, 5), ("sync.12", 0, 4_100)])),
        ])
        let model = model(runner, names: [10: "Safari Browser"])
        await model.pass()
        XCTAssertEqual(model.state, .measuring)
        clock += 4
        await model.pass()
        XCTAssertEqual(model.state, .ready([
            ProcessRate(key: "Safari.10", displayName: "Safari Browser", down: 2_000, up: 0),
            ProcessRate(key: "sync.12", displayName: "sync", down: 0, up: 1_000),
        ]))
    }

    func testProcessThatRestartsDoesNotProduceNegativeOrHugeRate() async {
        let runner = ScriptedNettopRunner([
            .success(output([("app.10", 5_000_000, 0)])),
            .success(output([("app.10", 100, 0)])),
        ])
        let model = model(runner)
        await model.pass()
        clock += 4
        await model.pass()
        XCTAssertEqual(model.state, .ready([]))
    }

    func testFailureShowsNoticeAndNextIntervalRecovers() async {
        let runner = ScriptedNettopRunner([
            .failure(NettopError.timedOut),
            .success("garbage"),
            .success(output([("a.1", 1, 1)])),
            .success(output([("a.1", 4_001, 1)])),
        ])
        let model = model(runner)
        await model.pass()
        XCTAssertEqual(model.state, .unavailable)
        await model.pass()
        XCTAssertEqual(model.state, .unavailable, "unparsable output is the same muted notice")
        await model.pass()
        XCTAssertEqual(model.state, .measuring)
        clock += 4
        await model.pass()
        guard case .ready(let rates) = model.state else { return XCTFail("expected ready") }
        XCTAssertEqual(rates.first?.down ?? 0, 1_000, accuracy: 0.001)
    }

    func testStateMappingIncludingTheMutedNotice() {
        XCTAssertEqual(ProcessesContent(state: .idle).body, .hidden)
        XCTAssertEqual(ProcessesContent(state: .measuring).body, .measuring)
        XCTAssertEqual(ProcessesContent(state: .unavailable).body, .notice(ProcessesContent.notice))
        XCTAssertEqual(ProcessesContent(state: .ready([])).body, .empty)
        let rows = ProcessesContent(state: .ready([ProcessRate(key: "a.1", displayName: "A", down: 1_500, up: 20)])).body
        XCTAssertEqual(rows, .rows([.init(id: "a.1", name: "A", downText: "1.5 KB/s", upText: "20 B/s")]))
    }

    func testStartIsIdempotentAndStopResetsToIdle() async {
        let runner = BlockingNettopRunner()
        let model = ProcessTrafficModel(runner: runner)
        model.start()
        model.start()
        await waitUntil { runner.startedCount >= 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(runner.startedCount, 1)
        model.stop()
        await waitUntil { runner.cancelledCount == 1 }
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.isRunning)
    }

    func testRealRunnerArgumentsMatchTheDocumentedInvocation() {
        XCTAssertEqual(NettopProcessRunner.executable, "/usr/bin/nettop")
        XCTAssertEqual(Array(NettopProcessRunner.arguments.prefix(5)), ["-P", "-L", "1", "-n", "-k"])
        XCTAssertEqual(NettopProcessRunner.timeoutSeconds, 5)
        XCTAssertEqual(ProcessTrafficModel.interval, 4)
    }
}
