import Foundation

/// A connection owns its transport. Credentials never enter shared cookies,
/// image URLs, logs, or a redirect to a different server.
final class MediaIntegrationHTTP: @unchecked Sendable {
    let base: URL
    let session: URLSession
    private let redirects: IntegrationRedirects?

    init(address: String, session: URLSession? = nil) throws {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw MediaIntegrationError.invalidAddress }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? "" : "/" + components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = components.url else { throw MediaIntegrationError.invalidAddress }
        self.base = base
        if let session { self.session = session; redirects = nil }
        else {
            let delegate = IntegrationRedirects(base: base)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            redirects = delegate
        }
    }

    deinit { if redirects != nil { session.invalidateAndCancel() } }

    func url(_ path: [String], query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        let encoded = try path.map { part -> String in
            guard !part.isEmpty, part != ".", part != "..", let encoded = part.addingPercentEncoding(withAllowedCharacters: allowed)
            else { throw MediaIntegrationError.invalidResponse }
            return encoded
        }
        components.percentEncodedPath += "/" + encoded.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url else { throw MediaIntegrationError.invalidAddress }
        return result
    }

    func send(_ path: [String], method: String = "GET", query: [URLQueryItem] = [],
              headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try url(path, query: query))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw MediaIntegrationError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap { value -> TimeInterval? in
                if let seconds = TimeInterval(value), seconds.isFinite { return max(0, seconds) }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
            }
            throw MediaIntegrationError.http(response.statusCode, retryAfter: retry)
        }
        guard data.count <= 16 * 1024 * 1024 else { throw MediaIntegrationError.invalidResponse }
        return (data, response)
    }

    func resolvedURL(_ reference: String?) -> URL? {
        guard var reference else { return nil }
        // Native API media links can be origin-relative. Keep a configured
        // reverse-proxy prefix without duplicating an already prefixed URL.
        if reference.hasPrefix("/"), !reference.hasPrefix("//"), !base.path.isEmpty,
           !reference.hasPrefix(base.path + "/") { reference = base.path + reference }
        guard let directory = URL(string: base.absoluteString + "/"),
              let url = URL(string: reference, relativeTo: directory)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func body(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
}

private final class IntegrationRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let base: URL
    init(base: URL) { self.base = base }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Mutations must never be replayed under another method by a 301/302.
        guard task.originalRequest?.httpMethod == "GET", let url = request.url,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.path.hasPrefix(base.path + "/") else { completionHandler(nil); return }
        completionHandler(request)
    }
}

enum MediaIntegrationError: LocalizedError, Sendable {
    case invalidAddress, invalidResponse, disconnected
    case http(Int, retryAfter: TimeInterval?)
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a full HTTP or HTTPS server address, including its path prefix."
        case .invalidResponse: return "The server returned an unsupported response. Check its version and connection settings."
        case .disconnected: return "This connection was removed. Connect again in Settings."
        case .unavailable(let reason): return reason
        case .http(let code, let retry):
            switch code {
            case 401: return "Your sign-in has expired or the credentials were refused. Reconnect in Settings."
            case 403: return "This account does not have permission, or its profile needs to be unlocked again."
            case 404: return "This item or API route is unavailable on the server."
            case 409, 412, 428: return "The server state changed. Refresh before trying this action again."
            case 429: return retry.flatMap { $0.isFinite && $0 < 86_400
                ? "The server is limiting requests. Try again in \(Int(max(1, $0))) seconds." : nil }
                ?? "The server is limiting requests. Please try again shortly."
            default: return "The server could not complete this action (HTTP \(code)). Refresh its status before retrying."
            }
        }
    }
}
