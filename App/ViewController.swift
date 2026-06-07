import UIKit
import WebKit
import WeftAppKit
import WeftAppKitSSH

/// The whole app: a full-screen WKWebView hosting weft-webui, plus the
/// native failover Supervisor from WeftAppKit.
///
/// iOS uses the *multi-origin* failover model (a WebView can't host a
/// loopback TCP gateway): every DC origin is injected as
/// `window.__WEFT_ENDPOINTS__`, so the SPA's API client rotates across
/// them. The supervisor picks the first DC to load, raises the SPA's
/// "connection switched" banner via `__weftFailoverNotice`, and reloads
/// onto the active DC if the current page becomes unreachable.
///
/// TODO: load endpoints from config / DNS SRV instead of the sample
/// below; add SSH / NEPacketTunnelProvider (WireGuard) transports so the
/// platform exposes no public web listener (see Backend.swift).
final class ViewController: UIViewController, WKNavigationDelegate {

    private var web: WKWebView!
    private var supervisor: Supervisor!
    private var endpoints: [Endpoint] = []

    /// Loads endpoints from a bundled `app.json` (the same schema as the
    /// desktop apps), falling back to a sample three-DC mesh setup.
    /// TODO: also support DNS SRV discovery and a user-editable config.
    private static func loadEndpoints() -> [Endpoint] {
        if let url = Bundle.main.url(forResource: "app", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cfg = try? AppConfig.decode(data) {
            let eps = cfg.endpoints.compactMap(makeEndpoint)
            if !eps.isEmpty { return eps }
        }
        return [
            Endpoint(name: "DC-A", backend: DirectBackend(host: "10.80.0.11", port: 8080)),
            Endpoint(name: "DC-B", backend: DirectBackend(host: "10.80.1.11", port: 8080)),
            Endpoint(name: "DC-C", backend: DirectBackend(host: "10.80.2.11", port: 8080)),
        ]
    }

    /// Builds one Endpoint, handling SSH (app-target SSHBackend) and Direct
    /// (WeftAppKit DirectBackend). WireGuard goes through the tunnel
    /// extension, not here.
    private static func makeEndpoint(_ ec: EndpointConfig) -> Endpoint? {
        switch ec.kind {
        case "direct":
            guard let addr = ec.addr, let (h, p) = splitHostPort(addr) else { return nil }
            return Endpoint(name: ec.name, backend: DirectBackend(host: h, port: p, tls: ec.tls ?? false))
        case "ssh":
            guard let sa = ec.sshAddr, let (sh, sp) = splitHostPort(sa),
                  let wa = ec.webuiAddr, let (wh, wp) = splitHostPort(wa),
                  let keyPath = ec.keyPath, let pem = try? String(contentsOfFile: keyPath, encoding: .utf8)
            else { return nil }
            let trusted = ec.hostKeys ?? parseKnownHosts(ec.knownHostsPath)
            return Endpoint(name: ec.name, backend: SSHBackend(
                host: sh, port: sp, user: ec.user ?? "weft",
                privateKeyOpenSSH: pem, trustedHostKeys: trusted,
                webuiHost: wh, webuiPort: wp))
        default:
            return nil // wireguard handled by the tunnel extension
        }
    }

    /// Extracts OpenSSH public-key lines ("<type> <base64>") from a
    /// known_hosts file. Handles plain (non-hashed) entries:
    /// "host[,host2] ssh-ed25519 AAAA… comment".
    private static func parseKnownHosts(_ path: String?) -> [String] {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var keys: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            let f = l.split(separator: " ", omittingEmptySubsequences: true)
            if f.count >= 3 { keys.append("\(f[1]) \(f[2])") }
        }
        return keys
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        endpoints = Self.loadEndpoints()

        // Inject the endpoint list before any page script runs.
        let config = WKWebViewConfiguration()
        let userScript = WKUserScript(
            source: WebInject.initScript(endpoints),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)

        web = WKWebView(frame: view.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        view.addSubview(web)

        supervisor = Supervisor(endpoints: endpoints) { [weak self] sw in
            DispatchQueue.main.async {
                guard let self else { return }
                self.web.evaluateJavaScript(WebInject.failoverNotice(from: sw.fromName, to: sw.toName))
                if let to = sw.toName, let ep = self.endpoints.first(where: { $0.name == to }),
                   let url = URL(string: ep.backend.url()) {
                    self.web.load(URLRequest(url: url))
                }
            }
        }
        supervisor.run()

        // Optimistically load the preferred DC; the supervisor re-points
        // if a better/healthy choice emerges.
        if let url = URL(string: (supervisor.activeEndpoint() ?? endpoints[0]).backend.url()) {
            web.load(URLRequest(url: url))
        }
    }
}
