import Foundation
import Network

/// Reaches one datacenter's weft-webui. Mirrors weft-app-core's
/// `transport.Backend`. The Supervisor only asks "are you healthy?"
/// (`probe`); the WKWebView connects to the chosen DC directly.
public protocol Backend {
    /// True if the DC is reachable and serving. Synchronous (the
    /// Supervisor calls it from its probe loop).
    func probe() -> Bool
    /// Stable, log-friendly description of where this points.
    func target() -> String
    /// Origin to hand the WebView, e.g. "http://10.80.0.11:8080".
    func url() -> String
}

/// Plain TCP probe via the Network framework — used when the device is on
/// the mesh (a per-app WireGuard tunnel via NEPacketTunnelProvider) or
/// against a local SSH forward. SSH / WireGuard transports proper are
/// TODO on mobile.
public final class DirectBackend: Backend {
    private let host: String
    private let port: Int
    private let tls: Bool
    private let timeout: TimeInterval

    public init(host: String, port: Int, tls: Bool = false, timeoutSeconds: TimeInterval = 4) {
        self.host = host
        self.port = port
        self.tls = tls
        self.timeout = timeoutSeconds
    }

    public func probe() -> Bool {
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .tcp
        )
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ok = true
                sem.signal()
            case .failed, .cancelled:
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: .global())
        _ = sem.wait(timeout: .now() + timeout)
        conn.cancel()
        return ok
    }

    public func target() -> String { "\(host):\(port)" }
    public func url() -> String { "\(tls ? "https" : "http")://\(host):\(port)" }
}
