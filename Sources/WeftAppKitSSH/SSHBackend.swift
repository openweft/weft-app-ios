import Foundation
import Network
import NIOCore
import NIOSSH
import Crypto
import Citadel
import WeftAppKit

/// SSH local-forward transport, via Citadel (pure-Swift, SwiftNIO).
/// Mirrors weft-app-core's transport.SSHForward and the Android
/// SshForwardBackend: it connects to a per-DC SSH endpoint and forwards a
/// loopback port to the webui's internal address, so the WebView loads
/// http://127.0.0.1:<port> and the platform exposes no public web service.
///
/// `probe()` is the synchronous health check the Supervisor calls; it
/// bridges Citadel's async connect with a semaphore. The loopback listener
/// + forward are brought up on the first successful probe.
///
/// Lives in WeftAppKitSSH (not the dependency-free WeftAppKit core) since
/// it pulls Citadel/SwiftNIO. Builds from the CLI (no Xcode).
public final class SSHBackend: Backend {
    private let host: String
    private let port: Int
    private let user: String
    private let privateKeyOpenSSH: String   // OpenSSH ed25519 private key
    private let trustedHostKeys: [String]   // OpenSSH public-key lines ("ssh-ed25519 AAAA…")
    private let webuiHost: String
    private let webuiPort: Int

    private let lock = NSLock()
    private var client: SSHClient?
    private var localPort: Int = 0
    private var listener: NWListener?

    /// `privateKeyOpenSSH` is an OpenSSH-format ed25519 private key (the
    /// `-----BEGIN OPENSSH PRIVATE KEY-----` block, e.g. `id_ed25519`).
    /// `trustedHostKeys` are the server's expected OpenSSH public keys; when
    /// empty the server host key is **not** verified (dev only — prefer
    /// pinning to defeat MITM).
    public init(host: String, port: Int, user: String, privateKeyOpenSSH: String,
                trustedHostKeys: [String] = [], webuiHost: String, webuiPort: Int) {
        self.host = host
        self.port = port
        self.user = user
        self.privateKeyOpenSSH = privateKeyOpenSSH
        self.trustedHostKeys = trustedHostKeys
        self.webuiHost = webuiHost
        self.webuiPort = webuiPort
    }

    /// Builds the host-key validator: pin to `trustedHostKeys` when present,
    /// otherwise accept anything (dev fallback).
    private func hostKeyValidator() throws -> SSHHostKeyValidator {
        guard !trustedHostKeys.isEmpty else { return .acceptAnything() }
        let keys = try trustedHostKeys.map { try NIOSSHPublicKey(openSSHPublicKey: $0) }
        return .trustedKeys(Set(keys))
    }

    // MARK: Backend

    public func probe() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        Task {
            ok = await ensureUp()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 8)
        return ok
    }

    public func target() -> String { "ssh://\(host):\(port)/\(webuiHost):\(webuiPort)" }

    public func url() -> String {
        lock.lock(); let p = localPort; lock.unlock()
        return p == 0 ? "http://127.0.0.1:0" : "http://127.0.0.1:\(p)"
    }

    // MARK: Connection + forward

    private func cachedClient() -> SSHClient? { lock.lock(); defer { lock.unlock() }; return client }
    private func cacheClient(_ c: SSHClient) { lock.lock(); client = c; lock.unlock() }

    private func ensureUp() async -> Bool {
        if cachedClient() != nil { return true }
        do {
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: privateKeyOpenSSH)
            let c = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: .ed25519(username: user, privateKey: key),
                hostKeyValidator: try hostKeyValidator(),
                reconnect: .never
            )
            cacheClient(c)
            try startListener(client: c)
            return true
        } catch {
            return false
        }
    }

    /// Bind a loopback listener; each inbound connection gets its own SSH
    /// direct-tcpip channel to the webui, bridged byte-for-byte.
    private func startListener(client: SSHClient) throws {
        lock.lock(); defer { lock.unlock() }
        if listener != nil { return }
        let l = try NWListener(using: .tcp) // loopback, ephemeral port
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: .global())
            Task { await self.openForward(conn, client: client) }
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = l.port {
                self?.lock.lock(); self?.localPort = Int(p.rawValue); self?.lock.unlock()
            }
        }
        l.start(queue: .global())
        listener = l
    }

    /// Open a direct-tcpip channel and pump bytes both ways between it and
    /// the loopback NWConnection.
    private func openForward(_ conn: NWConnection, client: SSHClient) async {
        do {
            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let channel = try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(
                    targetHost: webuiHost,
                    targetPort: webuiPort,
                    originatorAddress: origin
                )
            ) { channel in
                channel.pipeline.addHandler(SSHToNWHandler(connection: conn))
            }
            pumpNWToChannel(conn, channel)
        } catch {
            conn.cancel()
        }
    }

    /// NWConnection → SSH channel: read loopback bytes, write them into the
    /// SSH channel (which carries them to the webui).
    private func pumpNWToChannel(_ conn: NWConnection, _ channel: Channel) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                var buf = channel.allocator.buffer(capacity: data.count)
                buf.writeBytes(data)
                channel.writeAndFlush(buf, promise: nil)
            }
            if isComplete || error != nil {
                channel.close(promise: nil)
                conn.cancel()
                return
            }
            self.pumpNWToChannel(conn, channel)
        }
    }
}

/// SSH channel → NWConnection: inbound SSH-channel bytes (the webui's
/// responses) are written back to the loopback connection.
private final class SSHToNWHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let connection: NWConnection

    init(connection: NWConnection) { self.connection = connection }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        let bytes = Data(buf.readableBytesView)
        connection.send(content: bytes, completion: .contentProcessed { _ in })
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection.cancel()
        context.fireChannelInactive()
    }
}
