import Foundation

/// CapabilitiesService fetches server capabilities such as enterprise availability.
/// The response is expected to include `{ ee: boolean }`.
final class CapabilitiesService {
    struct Capabilities: Decodable {
        let ee: Bool?
        let version: String?
    }

    static let shared = CapabilitiesService()
    private init() {}

    private var cached: Capabilities? = nil
    private var cachedServerURL: String? = nil
    private var lastFetch: Date? = nil

    private func normalizedServerURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    func invalidate() {
        cached = nil
        cachedServerURL = nil
        lastFetch = nil
    }

    func get(force: Bool = false) async throws -> Capabilities {
        let serverURL = normalizedServerURL(AuthManager.shared.serverURL)
        if !force,
           let c = cached,
           let ts = lastFetch,
           cachedServerURL == serverURL,
           Date().timeIntervalSince(ts) < 300 {
            return c
        }
        let ts = Int(Date().timeIntervalSince1970)
        let url = AuthorizedHTTPClient.shared.buildURL(
            path: "/api/capabilities",
            queryItems: [URLQueryItem(name: "_", value: String(ts))]
        )
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")

        // Purge any previously cached capabilities response before fetching.
        URLCache.shared.removeCachedResponse(for: req)
        let (data, http) = try await AuthorizedHTTPClient.shared.request(req)
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        let caps = try JSONDecoder().decode(Capabilities.self, from: data)
        cached = caps
        cachedServerURL = serverURL
        lastFetch = Date()
        return caps
    }
}
