import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
enum XtreamDownloadChecks {
    @MainActor final class Recorder {
        var updates: [XtreamDownloadUpdate] = []
    }

    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadCheckProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func request(_ path: String) -> URLRequest {
            URLRequest(url: URL(string: "https://lineup-download.invalid/" + path)!, timeoutInterval: 3)
        }

        // The injected protocol is the only source of this payload: falling
        // back to a shared session cannot accidentally make the check pass.
        let plain = try await XtreamDownload.data(for: request("plain"), session: session, progress: nil)
        precondition(plain.0 == DownloadCheckProtocol.payload)
        precondition((plain.1 as? HTTPURLResponse)?.statusCode == 200)

        let recorder = Recorder()
        let measured = try await XtreamDownload.data(for: request("progress"), session: session,
            progress: { recorder.updates.append($0) })
        precondition(measured.0 == DownloadCheckProtocol.payload)
        precondition(recorder.updates.last?.finished == true)
        precondition(recorder.updates.last?.received == Int64(measured.0.count))
        precondition(recorder.updates.last?.expected == Int64(measured.0.count))
        precondition(recorder.updates.filter(\.finished).count == 1)

        let empty = Recorder()
        let nothing = try await XtreamDownload.data(for: request("empty"), session: session,
            progress: { empty.updates.append($0) })
        precondition(nothing.0.isEmpty)
        precondition(empty.updates.last?.finished == true && empty.updates.last?.received == 0)

        for reportsProgress in [false, true] {
            let failed = Recorder()
            let report: XtreamDownload.Progress = { update in failed.updates.append(update) }
            let progress = reportsProgress ? report : nil
            do {
                _ = try await XtreamDownload.data(for: request("offline"), session: session, progress: progress)
                preconditionFailure("Provider errors must reach the cache-preserving refresh handler")
            } catch let error as URLError {
                precondition(error.code == .notConnectedToInternet)
            }
            precondition(!failed.updates.contains(where: \.finished))
        }
        print("Provider transport checks passed: injected session, progress, empty response, and failure propagation")
    }
}

private final class DownloadCheckProtocol: URLProtocol {
    static let payload = Data("prepared event channel data".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.lastPathComponent == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let data = url.lastPathComponent == "empty" ? Data() : Self.payload
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/octet-stream", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
