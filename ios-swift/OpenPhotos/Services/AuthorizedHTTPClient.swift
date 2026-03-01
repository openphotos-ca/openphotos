import Foundation

struct AuthorizedHTTPClient {
    static let shared = AuthorizedHTTPClient()

    private init() {}

    private func notifyUnauthorized() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .authUnauthorized, object: nil)
        }
    }

    // MARK: - URL helpers

    private func joinedURL(_ path: String) -> URL {
        let base = AuthManager.shared.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + normalizedPath)!
    }

    func buildURL(path: String, queryItems: [URLQueryItem]? = nil) -> URL {
        var comps = URLComponents(url: joinedURL(path), resolvingAgainstBaseURL: false)!
        if let queryItems, !queryItems.isEmpty { comps.queryItems = queryItems }
        return comps.url!
    }

    func request(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Ensure token is fresh
        await AuthManager.shared.refreshIfNeeded()
        var req1 = req
        AuthManager.shared.authHeader().forEach { k, v in req1.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req1)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "HTTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response"])
        }
        if http.statusCode == 401 {
            // Try a forced refresh once
            let refreshed = await AuthManager.shared.forceRefresh()
            guard refreshed else {
                notifyUnauthorized()
                throw NSError(domain: "HTTP", code: 401, userInfo: [NSLocalizedDescriptionKey: "Unauthorized"])
            }
            var retry = req
            AuthManager.shared.authHeader().forEach { k, v in retry.setValue(v, forHTTPHeaderField: k) }
            let (d2, r2) = try await URLSession.shared.data(for: retry)
            guard let h2 = r2 as? HTTPURLResponse else {
                throw NSError(domain: "HTTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response"])
            }
            if h2.statusCode == 401 {
                notifyUnauthorized()
                throw NSError(domain: "HTTP", code: 401, userInfo: [NSLocalizedDescriptionKey: "Unauthorized"])
            }
            return (d2, h2)
        }
        return (data, http)
    }

    // MARK: - JSON helpers

    func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        let req = URLRequest(url: url)
        let (data, http) = try await request(req)
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func postJSON<T: Decodable, Body: Encodable>(_ url: URL, body: Body) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, http) = try await request(req)
        if !(200..<300).contains(http.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyStr])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // Relative helpers using server base URL
    func getJSON<T: Decodable>(path: String, query: [String: String]? = nil) async throws -> T {
        var items: [URLQueryItem]? = nil
        if let query { items = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let url = buildURL(path: path, queryItems: items)
        return try await getJSON(url)
    }

    func postJSON<T: Decodable, Body: Encodable>(path: String, body: Body) async throws -> T {
        let url = joinedURL(path)
        return try await postJSON(url, body: body)
    }
}
