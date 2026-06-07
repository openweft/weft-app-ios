import Foundation

/// Health standing of one datacenter.
public enum Health { case unknown, up, down }

/// An active-DC change, delivered to the Supervisor's onSwitch callback.
/// `fromName` is nil on the first selection; when `allDown` is true no DC
/// is healthy and `toName` is nil.
public struct Switch {
    public let fromName: String?
    public let toName: String?
    public let allDown: Bool
}

/// One datacenter: a display name plus the Backend used to reach it.
public struct Endpoint {
    public let name: String
    public let backend: Backend
    public init(name: String, backend: Backend) {
        self.name = name
        self.backend = backend
    }
}

/// Tuning. Matches weft-app-core's failover.Options.
public struct Options {
    public var intervalMs: Int = 3_000
    public var holdDownMs: Int64 = 15_000
    public var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    public init() {}
}

/// Read-only per-endpoint status for a status sheet.
public struct EndpointStatus {
    public let name: String
    public let target: String
    public let health: Health
    public let active: Bool
}

/// Selects a healthy DC from an ordered endpoint list with hysteresis —
/// fail over fast, fail back slow — a port of weft-app-core's
/// `failover.Supervisor`, so iOS behaves identically to the desktop and
/// Android clients.
public final class Supervisor {
    private final class State {
        let ep: Endpoint
        var health: Health = .unknown
        var healthy = false
        var upSince: Int64 = 0
        init(_ ep: Endpoint) { self.ep = ep }
    }

    private let lock = NSLock()
    private let eps: [State]
    private var active = -1
    private let opts: Options
    private let onSwitch: ((Switch) -> Void)?
    private var running = false

    public init(endpoints: [Endpoint], options: Options = Options(), onSwitch: ((Switch) -> Void)? = nil) {
        self.eps = endpoints.map { State($0) }
        self.opts = options
        self.onSwitch = onSwitch
    }

    /// Currently selected endpoint, or nil when every DC is down.
    public func activeEndpoint() -> Endpoint? {
        lock.lock(); defer { lock.unlock() }
        return active < 0 ? nil : eps[active].ep
    }

    public func status() -> [EndpointStatus] {
        lock.lock(); defer { lock.unlock() }
        return eps.enumerated().map { i, s in
            EndpointStatus(name: s.ep.name, target: s.ep.backend.target(), health: s.health, active: i == active)
        }
    }

    /// Start the probe loop on a background queue. Runs one round at once.
    public func run() {
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while self.running {
                self.round()
                Thread.sleep(forTimeInterval: Double(self.opts.intervalMs) / 1000.0)
            }
        }
    }

    public func stop() { running = false }

    /// One probe round: probe all DCs, update health, re-select. Internal —
    /// exercised directly by the tests.
    func round() {
        let now = opts.now()
        let results = eps.map { $0.ep.backend.probe() }

        lock.lock()
        for (i, ok) in results.enumerated() {
            let s = eps[i]
            if ok {
                if !s.healthy { s.upSince = now }
                s.healthy = true
                s.health = .up
            } else {
                s.healthy = false
                s.health = .down
                s.upSince = 0
            }
        }
        let sw = reselectLocked(now: now)
        lock.unlock()

        if let sw { onSwitch?(sw) }
    }

    /// Returns the Switch to emit, or nil if nothing changed. Caller holds
    /// the lock.
    private func reselectLocked(now: Int64) -> Switch? {
        let prev = active
        let activeHealthy = prev >= 0 && eps[prev].healthy

        var best = -1
        for i in eps.indices {
            let s = eps[i]
            if !s.healthy { continue }
            if !activeHealthy { best = i; break }            // nothing working: take top healthy now
            if i == prev { best = i; break }                 // reached active before any better: keep it
            if i < prev && now - s.upSince >= opts.holdDownMs { best = i; break } // failed back
        }

        if best == prev { return nil }
        let fromName = prev >= 0 ? eps[prev].ep.name : nil
        active = best
        if best < 0 { return Switch(fromName: fromName, toName: nil, allDown: true) }
        return Switch(fromName: fromName, toName: eps[best].ep.name, allDown: false)
    }
}
