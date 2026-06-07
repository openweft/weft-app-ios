import Foundation

/// One datacenter's connection config. Mirrors weft-app-core's
/// shell.EndpointConfig (same JSON keys), so a cluster can ship one
/// config schema for every client.
public struct EndpointConfig: Codable {
    public let name: String
    public let kind: String          // "direct" | "ssh" | "wireguard"
    public let addr: String?         // direct/wireguard: webui "host:port"
    public let tls: Bool?

    // SSH transport fields (built by the app target's SSHBackend, since
    // WeftAppKit itself stays dependency-free).
    public let sshAddr: String?
    public let user: String?
    public let keyPath: String?
    public let knownHostsPath: String?
    public let webuiAddr: String?
    /// Pinned server host keys as OpenSSH public-key lines
    /// ("ssh-ed25519 AAAA…"). If absent, the app falls back to parsing
    /// `known_hosts_path`.
    public let hostKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case name, kind, addr, tls
        case sshAddr = "ssh_addr"
        case user
        case keyPath = "key_path"
        case knownHostsPath = "known_hosts_path"
        case webuiAddr = "webui_addr"
        case hostKeys = "host_keys"
    }
}

/// App connection config, decoded from JSON. Endpoints are in priority
/// order (first = most preferred).
public struct AppConfig: Codable {
    public let endpoints: [EndpointConfig]

    /// Decode from JSON data (e.g. a bundled or fetched app.json).
    public static func decode(_ data: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: data)
    }

    /// Build runtime Endpoints. Only the Direct transport is wired on
    /// mobile today; SSH / WireGuard entries throw (see Backend.swift TODO).
    public func buildEndpoints() throws -> [Endpoint] {
        try endpoints.map { ec in
            switch ec.kind {
            case "direct":
                guard let addr = ec.addr, let (host, port) = splitHostPort(addr) else {
                    throw ConfigError.invalid("direct endpoint \(ec.name) needs addr host:port")
                }
                return Endpoint(name: ec.name, backend: DirectBackend(host: host, port: port, tls: ec.tls ?? false))
            case "ssh", "wireguard":
                throw ConfigError.unsupported("transport \(ec.kind) not yet wired on iOS (endpoint \(ec.name))")
            default:
                throw ConfigError.invalid("unknown transport kind \(ec.kind)")
            }
        }
    }
}

public enum ConfigError: Error, Equatable {
    case invalid(String)
    case unsupported(String)
}

public func splitHostPort(_ s: String) -> (String, Int)? {
    guard let i = s.lastIndex(of: ":") else { return nil }
    let host = String(s[s.startIndex..<i])
    guard let port = Int(s[s.index(after: i)...]), !host.isEmpty else { return nil }
    return (host, port)
}
