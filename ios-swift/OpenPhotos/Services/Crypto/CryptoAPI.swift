import Foundation

struct CryptoEnvelopeResponse: Decodable { let envelope: AnyDecodable? }

// Lightweight AnyDecodable for envelope passthrough
struct AnyDecodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { self.value = b; return }
        if let i = try? c.decode(Int.self) { self.value = i; return }
        if let d = try? c.decode(Double.self) { self.value = d; return }
        if let s = try? c.decode(String.self) { self.value = s; return }
        if let arr = try? c.decode([AnyDecodable].self) { self.value = arr.map { $0.value }; return }
        if let obj = try? c.decode([String: AnyDecodable].self) { self.value = obj.mapValues { $0.value }; return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON")
    }
}

final class CryptoAPI {
    static let shared = CryptoAPI()
    private init() {}

    func getEnvelope() async throws -> [String: Any]? {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/crypto/envelope")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        AuthManager.shared.authHeader().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let decoded = try JSONDecoder().decode(CryptoEnvelopeResponse.self, from: data)
        return decoded.envelope?.value as? [String: Any]
    }

    func saveEnvelope(_ envelope: [String: Any]) async throws -> Bool {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/crypto/envelope")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        AuthManager.shared.authHeader().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }
        let body = try JSONSerialization.data(withJSONObject: envelope, options: [])
        req.httpBody = body
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return true
    }
}
