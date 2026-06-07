import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto
import Citadel
@testable import WeftAppKitSSH

/// End-to-end proof that the SSH backend forwards bytes AND verifies the
/// server host key. An in-process Citadel SSH server (built-in
/// direct-tcpip forwarding) sits in front of a tiny HTTP echo; the backend
/// pins the server's host key and a real GET is driven through its
/// loopback port. A second test shows a wrong pin is rejected.
///
/// Runs from the CLI (swift test), no Xcode.
@Suite struct SSHForwardIntegrationTests {

    @Test func forwardsHTTPThroughSSHWithPinnedHostKey() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let echoPort = try startEcho(group, body: "served-by-ssh")
        let ssh = try await startSSHServer(group)
        defer { Task { try? await ssh.server.close() } }

        let backend = SSHBackend(
            host: "127.0.0.1", port: ssh.port, user: "weft",
            privateKeyOpenSSH: Curve25519.Signing.PrivateKey().makeSSHRepresentation(),
            trustedHostKeys: [ssh.hostKeyOpenSSH],   // pin the real host key
            webuiHost: "127.0.0.1", webuiPort: echoPort
        )

        #expect(await probe(backend))

        var url = backend.url(), tries = 0
        while url.hasSuffix(":0"), tries < 50 {
            try await Task.sleep(nanoseconds: 100_000_000); url = backend.url(); tries += 1
        }
        #expect(!url.hasSuffix(":0"))

        let (data, _) = try await URLSession.shared.data(from: URL(string: url + "/")!)
        #expect(String(data: data, encoding: .utf8) == "served-by-ssh")
    }

    @Test func rejectsWrongHostKey() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let ssh = try await startSSHServer(group)
        defer { Task { try? await ssh.server.close() } }

        // Pin a *different* key than the server actually presents.
        let wrongKey = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey)

        let backend = SSHBackend(
            host: "127.0.0.1", port: ssh.port, user: "weft",
            privateKeyOpenSSH: Curve25519.Signing.PrivateKey().makeSSHRepresentation(),
            trustedHostKeys: [wrongKey],
            webuiHost: "127.0.0.1", webuiPort: 9
        )

        #expect(await probe(backend) == false)   // handshake must fail on host-key mismatch
    }

    // MARK: helpers

    /// Runs the blocking probe off the cooperative pool.
    private func probe(_ backend: SSHBackend) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { c.resume(returning: backend.probe()) }
        }
    }

    private func startEcho(_ group: EventLoopGroup, body: String) throws -> Int {
        let ch = try ServerBootstrap(group: group)
            .childChannelInitializer { c in c.pipeline.addHandler(HTTPOnceHandler(body: body)) }
            .bind(host: "127.0.0.1", port: 0).wait()
        return Int(ch.localAddress!.port!)
    }

    private func startSSHServer(_ group: EventLoopGroup) async throws -> (port: Int, hostKeyOpenSSH: String, server: SSHServer) {
        let port = try freePort(group)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let server = try await SSHServer.host(
            host: "127.0.0.1", port: port,
            hostKeys: [hostKey],
            authenticationDelegate: AcceptAllAuth()
        )
        server.enableDirectTCPIP(withDelegate: ByteBufferForwardingDelegate())
        return (port, String(openSSHPublicKey: hostKey.publicKey), server)
    }
}

/// Accepts any authentication attempt — fine for a localhost test server.
private struct AcceptAllAuth: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .all }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        responsePromise.succeed(.success)
    }
}

/// Writes a fixed HTTP/1.1 response on the first inbound bytes, then closes.
private final class HTTPOnceHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let body: String
    private var responded = false
    init(body: String) { self.body = body }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { return }
        responded = true
        let resp = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        var buf = context.channel.allocator.buffer(capacity: resp.utf8.count)
        buf.writeString(resp)
        context.writeAndFlush(wrapOutboundOut(buf)).whenComplete { _ in context.close(promise: nil) }
    }
}

/// Bind a throwaway listener to get a free TCP port, then release it.
private func freePort(_ group: EventLoopGroup) throws -> Int {
    let ch = try ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
    let p = ch.localAddress!.port!
    try ch.close().wait()
    return Int(p)
}

/// Minimal direct-tcpip forwarding: the server child channel already has a
/// DataToBufferCodec (added by Citadel's Server), so it presents ByteBuffers.
/// Connect to the target and bridge ByteBuffers both ways. (Citadel's
/// built-in DirectTCPIPForwardingDelegate double-adds the codec → traps.)
private struct ByteBufferForwardingDelegate: DirectTCPIPDelegate {
    func initializeDirectTCPIPChannel(_ channel: Channel, request: SSHChannelType.DirectTCPIP, context: SSHContext) -> EventLoopFuture<Void> {
        ClientBootstrap(group: channel.eventLoop)
            .connect(host: request.targetHost, port: request.targetPort)
            .flatMap { remote in
                let a = channel.pipeline.addHandler(CopyTo(peer: remote))
                let b = remote.pipeline.addHandler(CopyTo(peer: channel))
                return a.and(b).map { _ in () }
            }
    }
}

/// Copies inbound ByteBuffers to a peer channel; closes the peer on EOF.
private final class CopyTo: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    init(peer: Channel) { self.peer = peer }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }
}
