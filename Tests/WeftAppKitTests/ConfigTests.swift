import Testing
@testable import WeftAppKit

@Suite struct ConfigTests {

    @Test func decodeAndBuildDirectEndpoints() throws {
        let json = """
        { "endpoints": [
            { "name": "DC-A", "kind": "direct", "addr": "10.80.0.11:8080" },
            { "name": "DC-B", "kind": "direct", "addr": "10.80.1.11:8080", "tls": true }
        ] }
        """.data(using: .utf8)!

        let cfg = try AppConfig.decode(json)
        let eps = try cfg.buildEndpoints()
        #expect(eps.count == 2)
        #expect(eps[0].name == "DC-A")
        #expect(eps[0].backend.url() == "http://10.80.0.11:8080")
        #expect(eps[1].backend.url() == "https://10.80.1.11:8080")
    }

    @Test func sshIsUnsupportedInKit() throws {
        // WeftAppKit itself stays dependency-free; the app target builds SSH
        // via Citadel. So kit-level buildEndpoints rejects ssh.
        let json = """
        { "endpoints": [ { "name": "DC-A", "kind": "ssh", "ssh_addr": "h:22" } ] }
        """.data(using: .utf8)!
        let cfg = try AppConfig.decode(json)
        #expect(throws: ConfigError.self) { try cfg.buildEndpoints() }
    }

    @Test func invalidDirectAddrThrows() throws {
        let json = """
        { "endpoints": [ { "name": "DC-A", "kind": "direct", "addr": "no-port" } ] }
        """.data(using: .utf8)!
        let cfg = try AppConfig.decode(json)
        #expect(throws: ConfigError.self) { try cfg.buildEndpoints() }
    }
}
