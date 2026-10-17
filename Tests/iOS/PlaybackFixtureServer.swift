import Foundation
import Network

/// A local HTTP origin for generated media. Covers extensionless server routes,
/// byte-range reads, and a paced raw live stream without a provider account.
final class PlaybackFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "lineup.test-media-origin")
    private let media: Data
    private let contentType: String
    private let live: Bool
    private let stallsBeforeHeaders: Bool
    private let redirectsVideoRoute: Bool
    private var redirectCount = 0
    private var rangeCount = 0
    private let onStalledRequest: (@Sendable () -> Void)?
    private var reportedStall = false
    private var connections: [NWConnection] = []
    // NWListener.port can be .any (0) until the ready callback. Reading it
    // immediately made the playback tests connect to 127.0.0.1:0.
    private var readyPort: UInt16?

    init(file: URL, contentType: String, live: Bool = false,
         stallsBeforeHeaders: Bool = false, onReady: (@Sendable () -> Void)? = nil,
         onStalledRequest: (@Sendable () -> Void)? = nil, redirectsVideoRoute: Bool = false) throws {
        media = try Data(contentsOf: file)
        self.contentType = contentType
        self.live = live
        self.stallsBeforeHeaders = stallsBeforeHeaders
        self.redirectsVideoRoute = redirectsVideoRoute
        self.onStalledRequest = onStalledRequest
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = self.listener.port?.rawValue, port > 0 {
                self.readyPort = port
                onReady?()
            } else {
                self.readyPort = nil
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, header: Data())
        }
        listener.start(queue: queue)
    }

    var port: UInt16? { queue.sync { readyPort } }
    var requestCounts: (redirects: Int, ranges: Int) { queue.sync { (redirectCount, rangeCount) } }
    func url(path: String) -> URL? { port.flatMap { URL(string: "http://127.0.0.1:\($0)/\(path)") } }
    func stop() {
        listener.cancel()
        queue.sync {
            readyPort = nil
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, header: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var next = header
            if let bytes { next.append(bytes) }
            guard next.count <= 65_536 else { connection.cancel(); return }
            if let request = String(data: next, encoding: .utf8), request.contains("\r\n\r\n") {
                self.respond(connection, request: request)
            } else if !complete { self.receive(connection, header: next) }
            else { connection.cancel() }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : ""
        if redirectsVideoRoute, target.hasPrefix("/videos/") {
            redirectCount += 1
            let header = "HTTP/1.1 302 Found\r\nLocation: /origin/selected-release\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        if stallsBeforeHeaders {
            if !reportedStall { reportedStall = true; onStalledRequest?() }
            return
        }
        if live {
            let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { connection.cancel(); return }
                self.sendLive(connection, offset: 0)
            })
            return
        }
        let rangeLine = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
        if rangeLine != nil { rangeCount += 1 }
        let rangeValue = rangeLine?.split(separator: ":", maxSplits: 1).last.map(String.init)
        guard let range = PlaybackFixtureByteRange.resolve(rangeValue, count: media.count) else {
            let header = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(media.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        var header = "HTTP/1.1 \(rangeLine == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: \(contentType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(range.count)\r\nConnection: close\r\n"
        if rangeLine != nil { header += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(media.count)\r\n" }
        var response = Data((header + "\r\n").utf8)
        if !request.hasPrefix("HEAD ") { response.append(media[range]) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendLive(_ connection: NWConnection, offset: Int) {
        guard case .ready = connection.state else { return }
        // 36 seconds of TS, sent in 100 ms chunks at approximately real time.
        // Stay on MPEG-TS packet boundaries so FFmpeg sees normal carriage.
        let count = max(188, (media.count / 360 / 188) * 188)
        let end = min(offset + count, media.count)
        guard offset < end else { connection.cancel(); return }
        connection.send(content: media.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.sendLive(connection, offset: end) }
        })
    }
}
