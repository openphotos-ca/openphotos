import Foundation

final class ServerUpdateService {
    struct Artifact: Decodable {
        let platform: String
        let arch: String
        let url: String
        let sha256: String?
    }

    struct UpdateStatus: Decodable {
        let currentVersion: String
        let latestVersion: String?
        let available: Bool
        let channel: String
        let checkedAt: String?
        let status: String
        let installMode: String
        let installArch: String
        let installSupported: Bool
        let releaseNotesUrl: String?
        let artifact: Artifact?
        let installCommand: String?
        let manualSteps: [String]
        let lastError: String?
    }

    enum FetchResult {
        case authorized(UpdateStatus)
        case forbidden
        case failure(String)
    }

    static let shared = ServerUpdateService()

    private init() {}

    func getStatus() async -> FetchResult {
        let ts = Int(Date().timeIntervalSince1970)
        let url = AuthorizedHTTPClient.shared.buildURL(
            path: "/api/server/update-status",
            queryItems: [URLQueryItem(name: "_", value: String(ts))]
        )
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")

        do {
            let (data, http) = try await AuthorizedHTTPClient.shared.request(req)
            if http.statusCode == 403 {
                return .forbidden
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure(body.isEmpty ? "Failed to load update status (\(http.statusCode))." : body)
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let status = try decoder.decode(UpdateStatus.self, from: data)
            return .authorized(status)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
