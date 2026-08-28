import Foundation
import CryptoKit
import NIOCore
import NIOPosix
import NIOSSH

/// One ssh connection to a Mac: the phone's whole transport.
///
/// `exec` runs a command and returns its stdout (`vigild dir`); `stream`
/// runs a command whose stdin/stdout become one end of a socketpair
/// (`vigild proxy <pane>`), so the Attach backend speaks its frames on a
/// plain fd and never learns a network exists.
///
/// THE contract, learned from two crashes: NIO channels are touched ONLY
/// from their event loop. App code never reads a `Channel` (not even
/// `isActive`); it reads `state`, which a handler on the loop owns and
/// publishes to the main actor. Every NIO call below is wrapped in
/// `loop.submit`/`flatSubmit`. Every step leaves a receipt with its
/// duration.
final class VigilSSH {
    struct Endpoint: Equatable, CustomStringConvertible {
        var host: String
        var port: Int
        var user: String
        var description: String { "\(user)@\(host):\(port)" }
    }

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case closed(String)
    }

    enum Failure: Error, LocalizedError {
        case notConnected
        case exec(String, Int32)
        case timeout(String)
        case hostKeyRejected
        case closedBeforeAuth(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "not connected"
            case .exec(let cmd, let code): return "\(cmd) exited \(code)"
            case .timeout(let what): return "\(what) timed out"
            case .hostKeyRejected: return "host key rejected"
            case .closedBeforeAuth(let why): return "closed before auth: \(why)"
            }
        }
    }

    let endpoint: Endpoint
    private let key: Curve25519.Signing.PrivateKey
    private let trust: (String) -> Bool
    /// One loop for the app: NIO asserts when a group is deallocated
    /// without a shutdown, and a connection that fails at first contact is
    /// dropped right there.
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let loop: EventLoop = VigilSSH.group.next()
    private var channel: Channel?
    private var ssh: NIOSSHHandler?
    /// Owned by the loop (ConnectionWatch writes it), read from anywhere.
    private let lock = NSLock()
    private var _state: State = .idle
    private(set) var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    /// Delivered on the main actor whenever `state` changes.
    var onStateChange: ((State) -> Void)?
    static var trace: ((String) -> Void)?

    init(endpoint: Endpoint, key: Curve25519.Signing.PrivateKey, trust: @escaping (String) -> Bool) {
        self.endpoint = endpoint
        self.key = key
        self.trust = trust
    }

    private func setState(_ new: State, why: String) {
        state = new
        Self.trace?("ssh: \(endpoint) \(new) (\(why))")
        let cb = onStateChange
        Task { @MainActor in cb?(new) }
    }

    // MARK: Connect / close

    func connect() async throws {
        setState(.connecting, why: "connect")
        let t0 = ContinuousClock.now
        let auth = KeyAuth(user: endpoint.user, key: key)
        let hostTrust = HostTrust(endpoint: endpoint, trust: trust)
        // "Connected" means AUTHENTICATED: NIO's connect future resolves on
        // the TCP handshake, and a channel opened before user auth
        // completes fails at creation (the leaked-promise crash).
        let ready = loop.makePromise(of: Void.self)
        let watch = ConnectionWatch(ready: ready) { [weak self] why in self?.setState(.closed(why), why: "watch") }
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(.seconds(8))
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: hostTrust)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil),
                    watch,
                ])
            }
        do {
            let ch = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
            Self.trace?("ssh: \(endpoint) tcp up in \(Self.ms(since: t0))ms, authenticating")
            let authTimer = loop.scheduleTask(in: .seconds(10)) {
                ready.fail(Failure.timeout("auth"))
                ch.close(promise: nil)
            }
            try await ready.futureResult.get()
            authTimer.cancel()
            let handler = try await ch.eventLoop.submit {
                try ch.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
            }.get()
            channel = ch
            ssh = handler
            setState(.connected, why: "authenticated in \(Self.ms(since: t0))ms")
        } catch {
            setState(.closed(error.localizedDescription), why: "connect failed after \(Self.ms(since: t0))ms")
            throw error
        }
    }

    func close() {
        guard let channel else { return }
        self.channel = nil
        ssh = nil
        loop.execute { channel.close(promise: nil) }
    }

    // MARK: Exec

    /// Run a command, return its stdout. Non-zero exit fails; stderr goes
    /// to the trace; 20s without completion fails.
    func exec(_ command: String, timeout: TimeAmount = .seconds(20)) async throws -> Data {
        guard state == .connected, let ssh, let channel else { throw Failure.notConnected }
        let t0 = ContinuousClock.now
        let done = loop.makePromise(of: (Data, Int32).self)
        let created = loop.makePromise(of: Channel.self)
        loop.execute {
            ssh.createChannel(created, channelType: .session) { child, _ in
                child.pipeline.addHandler(ExecCollector(done: done))
            }
        }
        let child: Channel
        do {
            child = try await created.futureResult.get()
        } catch {
            // No channel, no collector: nobody else will complete `done`.
            done.fail(error)
            Self.trace?("ssh: exec '\(command)' channel failed: \(error)")
            throw error
        }
        let timer = loop.scheduleTask(in: timeout) {
            done.fail(Failure.timeout("exec \(command)"))
            child.close(promise: nil)
        }
        defer { timer.cancel() }
        do {
            try await child.eventLoop.flatSubmit {
                child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
            }.get()
        } catch {
            // The collector completes `done` on the close this forces.
            Self.trace?("ssh: exec '\(command)' request failed: \(error)")
            child.close(promise: nil)
            throw error
        }
        let (data, status) = try await done.futureResult.get()
        Self.trace?("ssh: exec '\(command)' -> \(data.count)B exit \(status) in \(Self.ms(since: t0))ms")
        _ = channel
        if status != 0 { throw Failure.exec(command, status) }
        return data
    }

    // MARK: Stream

    /// Run a command whose stdin/stdout is a byte stream, and hand back an
    /// fd carrying it. The caller owns the fd; closing it ends the command;
    /// the command ending shuts the fd down (the reader sees EOF).
    func stream(_ command: String) async throws -> Int32 {
        guard state == .connected, let ssh else { throw Failure.notConnected }
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let pump = FdPump(fd: fds[1], label: command)
        let created = loop.makePromise(of: Channel.self)
        loop.execute {
            ssh.createChannel(created, channelType: .session) { child, _ in
                child.pipeline.addHandler(pump)
            }
        }
        do {
            let child = try await created.futureResult.get()
            try await child.eventLoop.flatSubmit {
                child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
            }.get()
        } catch {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
            throw error
        }
        Self.trace?("ssh: stream '\(command)' open, app fd \(fds[0]), pump fd \(fds[1])")
        return fds[0]
    }

    private static func ms(since t0: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - t0) / .milliseconds(1))
    }
}

// MARK: - Parent channel handlers

/// Owns the connection's liveness: completes `ready` on user auth, and is
/// the ONLY writer of `closed`.
private final class ConnectionWatch: ChannelInboundHandler {
    typealias InboundIn = Any
    private let ready: EventLoopPromise<Void>
    private let closed: (String) -> Void
    private var authed = false
    private var reported = false
    init(ready: EventLoopPromise<Void>, closed: @escaping (String) -> Void) {
        self.ready = ready
        self.closed = closed
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !authed {
            authed = true
            ready.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }
    func channelInactive(context: ChannelHandlerContext) {
        report("connection closed")
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        report("\(error)")
        context.close(promise: nil)
    }
    private func report(_ why: String) {
        guard !reported else { return }
        reported = true
        if !authed {
            authed = true
            ready.fail(VigilSSH.Failure.closedBeforeAuth(why))
        }
        closed(why)
    }
}

private final class KeyAuth: NIOSSHClientUserAuthenticationDelegate {
    let user: String
    let key: Curve25519.Signing.PrivateKey
    private var offered = false
    init(user: String, key: Curve25519.Signing.PrivateKey) {
        self.user = user
        self.key = key
    }
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            VigilSSH.trace?("ssh: auth refused (offered=\(offered), methods=\(availableMethods))")
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        VigilSSH.trace?("ssh: offering ed25519 key as \(user)")
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: user, serviceName: "",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))))
    }
}

private final class HostTrust: NIOSSHClientServerAuthenticationDelegate {
    let endpoint: VigilSSH.Endpoint
    let trust: (String) -> Bool
    init(endpoint: VigilSSH.Endpoint, trust: @escaping (String) -> Bool) {
        self.endpoint = endpoint
        self.trust = trust
    }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        if trust(line) {
            validationCompletePromise.succeed(())
        } else {
            VigilSSH.trace?("ssh: host key for \(endpoint.host) REJECTED")
            validationCompletePromise.fail(VigilSSH.Failure.hostKeyRejected)
        }
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
/// socketpair is `fd`; the other end belongs to the Attach backend. Reads
/// happen on a dispatch source, writes to the channel hop to its loop,
/// writes to the fd run on one serial queue so order is total.
private final class FdPump: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let fd: Int32
    private let label: String
    private var reader: DispatchSourceRead?
    private let queue = DispatchQueue(label: "vigil.ssh.pump")
    private var closed = false
    private var inBytes = 0
    private var outBytes = 0

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
                VigilSSH.trace?("ssh: \(self.label) app side closed (read \(n)), closing channel")
                self.reader?.cancel()
                channel.eventLoop.execute { channel.close(promise: nil) }
                return
            }
            self.outBytes += n
            let bytes = Array(buf[0..<n])
            channel.eventLoop.execute {
                var bb = channel.allocator.buffer(capacity: bytes.count)
                bb.writeBytes(bytes)
                channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bb)), promise: nil)
            }
        }
        reader = source
        source.resume()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = d.data else { return }
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        switch d.type {
        case .channel:
            inBytes += bytes.count
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
        VigilSSH.trace?("ssh: \(label) ended (in \(inBytes)B, out \(outBytes)B)")
        reader?.cancel()
        reader = nil
        finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        VigilSSH.trace?("ssh: \(label) error \(error)")
        context.close(promise: nil)
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
