import NetworkExtension
import os

// PacketTunnelProvider is the WireGuard transport's Network Extension.
// When the app activates the "wireguard" transport it starts this
// provider (a NETunnelProviderManager pointing here); the device then
// becomes a userspace mesh peer and the app's DirectBackend reaches each
// DC's webui on its mesh address — no public web listener.
//
// Production wiring uses WireGuardKit (github.com/WireGuard/wireguard-apple):
// build a WireGuardAdapter over `self`, hand it the config pulled from the
// shared app group, and start it. This skeleton is the integration point;
// add the WireGuardKit dependency to the WeftTunnel target in project.yml.
//
// NOTE: not compiled in this scaffold's CI (needs the Network Extension
// entitlement + a provisioning profile + WireGuardKit).
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "io.openweft.weftapp.tunnel", category: "wg")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log.info("startTunnel")
        // TODO:
        //   1. Read the WireGuard config from the shared app group
        //      (group.io.openweft.weftapp) — written by the app when the
        //      user enables the wireguard transport.
        //   2. let adapter = WireGuardAdapter(with: self) { ... }
        //      adapter.start(tunnelConfiguration: cfg) { error in completionHandler(error) }
        completionHandler(nil)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("stopTunnel: \(reason.rawValue, privacy: .public)")
        // TODO: adapter.stop { _ in completionHandler() }
        completionHandler()
    }
}
