import Foundation
import Network
import Observation

/// One message each way over a plain TCP connection: a four-byte length, then
/// the sealed bytes. The sealing is the security; the connection only
/// carries it.
enum DeviceSetupWire {
    static let queue = DispatchQueue(label: "Lineup.deviceSetup")
    /// Far above any real setup, and low enough that a stray connection can't
    /// make the TV hold a large buffer.
    static let limit = 8 << 20

    static func send(_ data: Data, on connection: NWConnection) async throws {
        var frame = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
        frame.append(data)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
    }

    static func receive(on connection: NWConnection) async throws -> Data {
        let header = try await read(4, from: connection)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= limit else { throw DeviceSetupError.unreadable }
        return try await read(length, from: connection)
    }

    private static func read(_ count: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { done.resume(throwing: error); return }
                guard let data, data.count == count else { done.resume(throwing: DeviceSetupError.closed); return }
                done.resume(returning: data)
            }
        }
    }

    /// Runs `work`, or gives up after `limit`. A connection waits on its own
    /// callbacks rather than on the task, so giving up cancels it: that is what
    /// lets the work finish.
    static func within<T: Sendable>(_ limit: Duration, cancelling connection: NWConnection,
                                    _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: work)
            group.addTask {
                try await Task.sleep(for: limit)
                throw DeviceSetupError.timedOut
            }
            do {
                guard let first = try await group.next() else { throw DeviceSetupError.timedOut }
                group.cancelAll()
                return first
            } catch {
                connection.cancel()
                group.cancelAll()
                throw error
            }
        }
    }
}

/// Resumes a continuation once, however many state changes arrive.
final class DeviceSetupOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// A mark one callback can leave for another, from any thread.
final class DeviceSetupFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

/// The phone's side.
enum DeviceSetupSender {
    /// Where a send has got to, for the phone to say.
    enum Stage: Sendable, Equatable {
        case connecting
        case sending
        case waiting
    }

    /// Sends a setup to the TV whose code was read, and waits for the TV to
    /// say it took it. Each step has its own allowance. Reaching the TV can
    /// wait on the phone asking for local network access the first time, and
    /// that wait used to eat the TV's time to answer: the setup arrived, the
    /// TV took it, and the phone had already said it couldn't reach it.
    /// `endpoint` is for tests; the phone finds the TV by the name in its code.
    static func send(_ payload: DeviceSetupPayload, pairing: DeviceSetupPairing,
                     to endpoint: NWEndpoint? = nil,
                     reach: Duration = .seconds(60), answer: Duration = .seconds(45),
                     stage: @escaping @Sendable (Stage) async -> Void = { _ in }) async throws {
        let target = endpoint ?? .service(name: pairing.service, type: DeviceSetupPairing.serviceType,
                                          domain: "local.", interface: nil)
        let body = try pairing.seal(JSONEncoder().encode(payload), .toTV)
        let connection = NWConnection(to: target, using: .tcp)
        defer { connection.cancel() }
        let denied = DeviceSetupFlag()

        await stage(.connecting)
        do {
            try await DeviceSetupWire.within(reach, cancelling: connection) {
                try await ready(connection, denied: denied)
            }
        } catch DeviceSetupError.timedOut {
            throw denied.isRaised ? DeviceSetupError.localNetworkDenied : DeviceSetupError.unreachable
        } catch let error as DeviceSetupError {
            throw error
        } catch {
            throw DeviceSetupError.unreachable
        }

        await stage(.sending)
        do {
            try await DeviceSetupWire.within(.seconds(30), cancelling: connection) {
                try await DeviceSetupWire.send(body, on: connection)
            }
        } catch {
            throw DeviceSetupError.unreachable
        }

        await stage(.waiting)
        let reply: DeviceSetupReply
        do {
            reply = try await DeviceSetupWire.within(answer, cancelling: connection) {
                let sealed = try await DeviceSetupWire.receive(on: connection)
                return try JSONDecoder().decode(DeviceSetupReply.self, from: pairing.open(sealed, .reply))
            }
        } catch DeviceSetupError.wrongCode {
            throw DeviceSetupError.wrongCode
        } catch {
            // The whole setup reached the TV, which may well have taken it:
            // say that, rather than that nothing happened.
            throw DeviceSetupError.unconfirmed
        }
        guard reply.ok else { throw DeviceSetupError.refused(reply.message ?? "") }
    }

    private static func ready(_ connection: NWConnection, denied: DeviceSetupFlag) async throws {
        let once = DeviceSetupOnce()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { done.resume() }
                case .waiting(let error):
                    // Waiting on local network access reads the same while the
                    // phone is still asking for it as once it has been turned
                    // down, so this only notes it. Allowed, the connection goes
                    // on by itself; if the time runs out, it says why.
                    if case .dns(let code) = error, code == -65570 { denied.raise() }
                case .failed:
                    once.run { done.resume(throwing: DeviceSetupError.unreachable) }
                case .cancelled:
                    once.run { done.resume(throwing: DeviceSetupError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: DeviceSetupWire.queue)
        }
    }
}

/// The TV's side: advertises itself while its code is on screen, and takes the
/// first setup sealed with that code. One sealed with any other code, an older
/// screen's or another TV's, is turned away and the TV keeps waiting.
@MainActor @Observable
final class DeviceSetupReceiver {
    enum Phase: Equatable {
        case starting
        case waiting
        case receiving
        /// Taken; the sources are loading.
        case settling
        case finished(DeviceSetup.Applied)
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var pairing: DeviceSetupPairing
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private let advertises: Bool
    @ObservationIgnored private let take: @MainActor (DeviceSetupPayload) throws -> DeviceSetup.Applied
    @ObservationIgnored private let settle: @MainActor (DeviceSetupPayload, DeviceSetup.Applied) async -> Void
    /// The port it listens on, once listening. Tests connect to it directly.
    @ObservationIgnored private(set) var port: UInt16?

    /// `take` writes the setup and says what it brought; the phone hears back
    /// once it has. `settle` then loads what arrived.
    init(pairing: DeviceSetupPairing = .make(), advertises: Bool = true,
         take: @escaping @MainActor (DeviceSetupPayload) throws -> DeviceSetup.Applied,
         settle: @escaping @MainActor (DeviceSetupPayload, DeviceSetup.Applied) async -> Void) {
        self.pairing = pairing
        self.advertises = advertises
        self.take = take
        self.settle = settle
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            if advertises {
                listener.service = NWListener.Service(name: pairing.service, type: DeviceSetupPairing.serviceType)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: DeviceSetupWire.queue)
        } catch {
            phase = .failed(Self.cantListen)
        }
    }

    /// Stops listening. A setup already being written finishes.
    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    /// A new code, for another try.
    func restart() {
        stop()
        busy = false
        pairing = .make()
        phase = .starting
        start()
    }

    private static let cantListen = "This Apple TV couldn’t get ready for your iPhone. Check it’s on your network, then try again."

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            if phase == .starting { phase = .waiting }
        case .failed:
            stop()
            if phase == .starting || phase == .waiting { phase = .failed(Self.cantListen) }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, !busy else { connection.cancel(); return }
        busy = true
        connection.start(queue: DeviceSetupWire.queue)
        let pairing = pairing
        Task {
            defer { connection.cancel() }
            guard let sealed = try? await DeviceSetupWire.within(.seconds(20), cancelling: connection, {
                try await DeviceSetupWire.receive(on: connection)
            }) else {
                busy = false
                return
            }
            guard let opened = try? pairing.open(sealed, .toTV) else {
                // Sealed with another code, an older screen's or another TV's.
                // The answer can't be sealed with a key this TV doesn't have,
                // so it is a byte the phone can't open, and the phone says to
                // scan the code showing now. This TV keeps waiting, free for
                // the right code at once, before the answer is out.
                busy = false
                _ = try? await DeviceSetupWire.within(.seconds(5), cancelling: connection) {
                    try await DeviceSetupWire.send(Data([0]), on: connection)
                }
                return
            }
            phase = .receiving
            var taken: (DeviceSetupPayload, DeviceSetup.Applied)?
            let reply: DeviceSetupReply
            do {
                let payload = try JSONDecoder().decode(DeviceSetupPayload.self, from: opened)
                let applied = try take(payload)
                taken = (payload, applied)
                reply = DeviceSetupReply(ok: true)
            } catch {
                reply = DeviceSetupReply(ok: false, message: (error as? LocalizedError)?.errorDescription)
            }
            if let answer = try? pairing.seal(JSONEncoder().encode(reply), .reply) {
                _ = try? await DeviceSetupWire.within(.seconds(10), cancelling: connection) {
                    try await DeviceSetupWire.send(answer, on: connection)
                }
            }
            guard case let (payload, applied)? = taken else {
                phase = .failed(reply.message ?? DeviceSetupError.unreadable.errorDescription ?? "")
                busy = false
                return
            }
            stop()
            phase = .settling
            await settle(payload, applied)
            phase = .finished(applied)
        }
    }
}
