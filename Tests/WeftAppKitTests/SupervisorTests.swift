import Testing
@testable import WeftAppKit

/// Mirrors weft-app-core's failover supervisor tests, verifying the Swift
/// port behaves identically: fail over fast, fail back slow.
///
/// Uses swift-testing (`import Testing`), which ships with the Swift
/// toolchain — so `swift test` runs from the CLI without Xcode/XCTest.
@Suite struct SupervisorTests {

    final class FakeBackend: Backend {
        var up: Bool
        init(_ up: Bool) { self.up = up }
        func probe() -> Bool { up }
        func target() -> String { "fake" }
        func url() -> String { "http://fake" }
    }

    final class Clock { var t: Int64 = 0 }

    private func makeSup(_ clock: Clock, _ backends: [FakeBackend]) -> (Supervisor, () -> [Switch]) {
        var switches: [Switch] = []
        let names = ["A", "B", "C"]
        let eps = backends.enumerated().map { Endpoint(name: names[$0.offset], backend: $0.element) }
        var opts = Options()
        opts.holdDownMs = 15_000
        opts.now = { clock.t }
        let s = Supervisor(endpoints: eps, options: opts) { switches.append($0) }
        return (s, { switches })
    }

    @Test func coldStartPicksTopHealthy() {
        let clock = Clock()
        let (s, sw) = makeSup(clock, [FakeBackend(true), FakeBackend(true)])
        s.round()
        #expect(s.activeEndpoint()?.name == "A")
        #expect(sw().last?.toName == "A")
        #expect(sw().last?.fromName == nil)
    }

    @Test func failoverIsImmediate() {
        let clock = Clock()
        let a = FakeBackend(true); let b = FakeBackend(true)
        let (s, sw) = makeSup(clock, [a, b])
        s.round() // -> A
        a.up = false; clock.t += 1_000; s.round()
        #expect(s.activeEndpoint()?.name == "B")
        #expect(sw().last?.fromName == "A")
        #expect(sw().last?.toName == "B")
    }

    @Test func failBackWaitsForHoldDown() {
        let clock = Clock()
        let a = FakeBackend(true); let b = FakeBackend(true)
        let (s, _) = makeSup(clock, [a, b])
        s.round() // -> A
        a.up = false; clock.t += 1_000; s.round() // -> B
        a.up = true;  clock.t += 1_000; s.round() // within hold-down: stay B
        #expect(s.activeEndpoint()?.name == "B")
        clock.t += 20_000; s.round()              // past hold-down: back to A
        #expect(s.activeEndpoint()?.name == "A")
    }

    @Test func allDownThenRecoverImmediately() {
        let clock = Clock()
        let a = FakeBackend(true); let b = FakeBackend(true)
        let (s, sw) = makeSup(clock, [a, b])
        s.round() // -> A
        a.up = false; b.up = false; clock.t += 1_000; s.round()
        #expect(s.activeEndpoint() == nil)
        #expect(sw().last?.allDown == true)
        b.up = true; clock.t += 1_000; s.round()
        #expect(s.activeEndpoint()?.name == "B")
    }
}
