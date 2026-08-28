import Foundation
import CryptoKit
import NIOCore
import NIOPosix
import NIOSSH

/// One ssh connection to a Mac, the phone's whole transport: `exec` runs
/// `vigild dir` and returns its output; `stream` runs `vigild proxy <pane>`
/// and returns one end of a socketpair whose other end this object pumps
/// to the channel, so the Attach backend speaks its frames on a plain fd
/// and never knows a network exists. Auth is an ed25519 key held by the
/// app (VigilPhone.key); the server's host key is checked by `trust`.
final class VigilSSH {
    struct Endpoint: Equatable {
        var host: String
        var port: Int
        var user: String
    }

    enum Failure: Error, LocalizedError {
        case notConnected
        case exec(String, Int32)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "not connected"
            case .exec(let cmd, let code): return "\(cmd) exited \(code)"
            }
        }
    }

    let endpoint: Endpoint
    private let key: Curve25519.Signing.PrivateKey
    private let trust: (NIOSSHPublicKey) -> Bool
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var ssh: NIOSSHHandler?
    static var trace: ((String) -> Void)?

    init(endpoint: Endpoint, key: Curve25519.Signing.PrivateKey, trust: @escaping (NIOSSHPublicKey) -> Bool) {
        self.endpoint = endpoint
        self.key = key
        self.trust = trust
    }

    var isConnected: Bool { channel?.isActive ?? false }

    func connect() async throws {
        let auth = KeyAuth(user: endpoint.user, key: key)
        let hostTrust = HostTrust(trust: trust)
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(8))
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: hostTrust)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil),
                    ErrorSink(),
                ])
            }
        let ch = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        channel = ch
        ssh = try await ch.pipeline.handler(type: NIOSSHHandler.self).get()
        Self.trace?("ssh: connected \(endpoint.user)@\(endpoint.host):\(endpoint.port)")
    }

    func close() {
        channel?.close(promise: nil)
        channel = nil
        ssh = nil
    }

    /// Run a command, return everything it wrote to stdout. Fails on a
    /// non-zero exit (stderr goes to the trace).
    func exec(_ command: String) async throws -> Data {
        guard let ssh, let channel else { throw Failure.notConnected }
        let done = channel.eventLoop.makePromise(of: (Data, Int32).self)
        let created = channel.eventLoop.makePromise(of: Channel.self)
        ssh.createChannel(created, channelType: .session) { child, _ in
            child.pipeline.addHandler(ExecCollector(done: done))
        }
        let child = try await created.futureResult.get()
        try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)).get()
        let (data, status) = try await done.futureResult.get()
        if status != 0 { throw Failure.exec(command, status) }
        return data
    }

    /// Run a command whose stdin/stdout is a byte stream (`vigild proxy`),
    /// and hand back an fd carrying it. The caller owns the fd; closing it
    /// ends the command.
    func stream(_ command: String) async throws -> Int32 {
        guard let ssh, let channel else { throw Failure.notConnected }
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let pump = FdPump(fd: fds[1], label: command)
        let created = channel.eventLoop.makePromise(of: Channel.self)
        ssh.createChannel(created, channelType: .session) { child, _ in
            child.pipeline.addHandler(pump)
        }
        do {
            let child = try await created.futureResult.get()
            try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)).get()
        } catch {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
            throw error
        }
        Self.trace?("ssh: stream '\(command)' on fd \(fds[0])")
        return fds[0]
    }
}

// MARK: - Auth delegates

private final class KeyAuth: NIOSSHClientUserAuthenticationDelegate {
    let user: String
    let key: Curve25519.Signing.PrivateKey
    var offered = false
    init(user: String, key: Curve25519.Signing.PrivateKey) {
        self.user = user
        self.key = key
    }
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: user, serviceName: "",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))))
    }
}

private final class HostTrust: NIOSSHClientServerAuthenticationDelegate {
    let trust: (NIOSSHPublicKey) -> Bool
    init(trust: @escaping (NIOSSHPublicKey) -> Bool) { self.trust = trust }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if trust(hostKey) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(NSError(domain: "vigil.ssh", code: 1,
                                                   userInfo: [NSLocalizedDescriptionKey: "host key rejected"]))
        }
    }
}

private final class ErrorSink: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        VigilSSH.trace?("ssh: error \(error)")
        context.close(promise: nil)
    }
}

// MARK: - Child channel handlers

/// Collects stdout until the channel closes; stderr goes to the trace.
private final class ExecCollector: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private var out = Data()
    private var status: Int32 = 0
    private let done: EventLoopPromise<(Data, Int32)>
    init(done: EventLoopPromise<(Data, Int32)>) { self.done = done }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = d.data else { return }
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        switch d.type {
        case .channel: out.append(contentsOf: bytes)
        case .stdErr: VigilSSH.trace?("ssh: stderr \(String(decoding: bytes, as: UTF8.self))")
        default: break
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus { status = Int32(exit.exitStatus) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        done.succeed((out, status))
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        done.fail(error)
        context.close(promise: nil)
    }
}

/// The bridge: channel bytes → fd, fd bytes → channel. Our side of the
/// socketpair is `fd`; the other end belongs to the Attach backend.
private final class FdPump: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    private let fd: Int32
    private let label: String
    private var reader: DispatchSourceRead?
    private let queue = DispatchQueue(label: "vigil.ssh.pump")
    private var closed = false

    init(fd: Int32, label: String) {
        self.fd = fd
        self.label = label
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 16384)
            let n = read(self.fd, &buf, buf.count)
            if n <= 0 {
                // The surface closed its end: the command is over.
                self.reader?.cancel()
                channel.eventLoop.execute { channel.close(promise: nil) }
                return
            }
            let bytes = Array(buf[0..<n])
            channel.eventLoop.execute {
                var bb = channel.allocator.buffer(capacity: bytes.count)
                bb.writeBytes(bytes)
                channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bb)), promise: nil)
            }
        }
        source.setCancelHandler { [weak self] in self?.finish() }
        reader = source
        source.resume()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = d.data else { return }
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        switch d.type {
        case .channel:
            queue.async { [fd] in
                var off = 0
                while off < bytes.count {
                    let n = bytes[off...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
                    if n <= 0 { return }
                    off += n
                }
            }
        case .stdErr:
            VigilSSH.trace?("ssh: \(label) stderr \(String(decoding: bytes, as: UTF8.self))")
        default: break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        VigilSSH.trace?("ssh: \(label) ended")
        reader?.cancel()
        reader = nil
        finish()
    }

    private func finish() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            // shutdown so the surface's reader sees EOF even while it holds
            // the peer open; then release our end.
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

// MARK: - Keys

extension Curve25519.Signing.PrivateKey {
    /// The `authorized_keys` line for this key.
    var openSSHPublicLine: String {
        func str(_ b: [UInt8]) -> [UInt8] {
            let n = UInt32(b.count).bigEndian
            return withUnsafeBytes(of: n) { Array($0) } + b
        }
        let blob = str(Array("ssh-ed25519".utf8)) + str(Array(publicKey.rawRepresentation))
        return "ssh-ed25519 \(Data(blob).base64EncodedString()) vigil@iphone"
    }
}
