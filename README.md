# weft-app-ios

iOS client for the [Weft](https://github.com/openweft) dashboard — Swift +
`WKWebView` hosting [`weft-webui`](https://github.com/openweft/weft-webui).

It mirrors [`weft-app-core`](https://github.com/openweft/weft-app-core)'s
failover logic natively. The portable code is SwiftPM, so it builds and
unit-tests **from the CLI without Xcode**:

```
Sources/WeftAppKit/      Supervisor.swift · Backend.swift · Config.swift · WebInject.swift   (no deps)
Sources/WeftAppKitSSH/   SSHBackend.swift   (SSH local-forward via Citadel/SwiftNIO)
Tests/                   SupervisorTests · ConfigTests · SSHBackendTests   (swift-testing)
App/                     AppDelegate.swift · ViewController.swift · Info.plist
Tunnel/                  PacketTunnelProvider.swift   (WireGuard NEPacketTunnelProvider)
```

[`Supervisor.swift`](Sources/WeftAppKit/Supervisor.swift) is a port of the
Go supervisor (fail over fast, fail back slow with hysteresis), checked
against the same cases as the desktop and Android clients.

## Failover model

Mobile uses the **multi-origin** model (a WebView can't host a loopback
TCP gateway): every DC origin is injected as `window.__WEFT_ENDPOINTS__`
(same contract as the desktop apps, see
[`WebInject.swift`](Sources/WeftAppKit/WebInject.swift)), so the SPA's API
client rotates across DCs itself. The native supervisor picks the first DC
to load, raises the SPA's "connection switched" banner via
`__weftFailoverNotice`, and reloads onto the active DC if the current page
becomes unreachable.

## Build & test

The portable core (**WeftAppKit** — the failover supervisor, transports,
config, the JS contract) builds **from the CLI with no Xcode**:

```sh
swift build --target WeftAppKit      # core only — CLT is enough
swift build                          # WeftAppKit + WeftAppKitSSH (Citadel/SwiftNIO) — CLT is enough
```

Tests use **swift-testing**. With **only Xcode Command Line Tools**, the
test runtime cannot locate `Testing.framework` (the SwiftPM helper hardcodes
the full-Xcode layout under `usr/lib/swift-*/macosx/`), so `swift test`
fails at dlopen time even though the test bundle compiles. To run them
locally either:

  - install full Xcode (`xcode-select -p` pointing at it), then
    `swift test` works straight from the CLI; or
  - install a stand-alone Swift toolchain (e.g. `swiftly install latest`
    or [swift.org/install](https://swift.org/install)) and run with
    `xcrun --toolchain swift-latest swift test`.

CI (`.github/workflows/ci.yml`) runs `swift test` on `macos-latest`, which
ships full Xcode, so the 10 tests across WeftAppKit + WeftAppKitSSH run
green there: the supervisor, config parsing, the SSH backend, plus an
**end-to-end SSH forwarding test** (`SSHForwardIntegrationTests`) that
stands up an in-process Citadel SSH server in front of an HTTP echo and
drives a real request through the backend's loopback port.

The **app** (`App/`) and **tunnel extension** (`Tunnel/`) target the iOS
SDK, which ships only with full Xcode:

```sh
xcodegen generate                   # WeftApp.xcodeproj from project.yml (xcodegen via pkgx/brew)
xcodebuild -scheme WeftApp -sdk iphonesimulator   # needs full Xcode
```

`project.yml` defines two targets: **WeftApp** (the WKWebView shell, links
WeftAppKit + Citadel) and **WeftTunnel** (a `NEPacketTunnelProvider`
extension for the WireGuard transport).

> Only the iOS app/extension build needs Xcode (for the iOS SDK +
> simulator). All shared logic is developed and tested in the CLI.

## Transports

- **Direct** — [`Backend.swift`](Sources/WeftAppKit/Backend.swift) `DirectBackend`, on the mesh.
- **SSH local-forward** — [`Sources/WeftAppKitSSH/SSHBackend.swift`](Sources/WeftAppKitSSH/SSHBackend.swift) (Citadel/SwiftNIO): ed25519 auth, **server host-key pinning** (`trustedHostKeys`, from the config's `host_keys` or parsed from `known_hosts_path`), `createDirectTCPIPChannel`, and a NIO ↔ `NWConnection` byte-pump exposing a loopback port. Built for `"kind":"ssh"` endpoints in `ViewController.makeEndpoint`. **End-to-end tested from the CLI** — a real request forwarded through an in-process SSH server, plus a negative test proving a wrong host key is rejected. No public web listener.
- **WireGuard** — [`Tunnel/PacketTunnelProvider.swift`](Tunnel/PacketTunnelProvider.swift) Network-Extension skeleton (WireGuardKit), with entitlements + app group in `project.yml`.

### TODO
- Wire WireGuardKit into the tunnel extension + the app-side config handoff.
- DNS SRV discovery.
- Auth window (OIDC / OpenPubkey / dev keypair) — present on the desktop
  apps (`weft-app-osx/auth_*.go`, ~2.7k LOC), absent on iOS today. Token
  storage would land on Keychain Services using the same
  `service="weft-app", account=<issuer>` (tokens) and
  `service="weft-app-keypair", account=<issuer>` (ed25519 keys)
  convention the desktop apps use.
- Cluster · DC indicator and failover banner UI — the supervisor already
  emits the `__weftFailoverNotice(from, to)` JS call, but no native
  surface (toast / status item) yet.
