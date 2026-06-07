import Testing
@testable import WeftAppKitSSH

/// Offline checks for the SSH backend's non-network logic (no SSH server
/// involved): it conforms to the WeftAppKit Backend contract, reports a
/// stable target, and a not-yet-forwarded url. Runs from the CLI.
@Suite struct SSHBackendTests {

    private func make() -> SSHBackend {
        SSHBackend(host: "bastion-a", port: 22, user: "weft",
                   privateKeyOpenSSH: "", webuiHost: "127.0.0.1", webuiPort: 8443)
    }

    @Test func targetIsStable() {
        #expect(make().target() == "ssh://bastion-a:22/127.0.0.1:8443")
    }

    @Test func urlIsLoopbackPlaceholderBeforeForward() {
        // Before a successful probe brings the forward up, url() returns the
        // :0 placeholder (the Supervisor won't route to it until healthy).
        #expect(make().url() == "http://127.0.0.1:0")
    }
}
