import Foundation

enum AppLinks {
    // Customize these as needed
    static let website = URL(string: "https://openphotos.ca")
    static let privacyPolicy = URL(string: "https://openphotos.ca/privacy")
    static let terms = URL(string: "https://openphotos.ca/terms")
    static let github = URL(string: "https://github.com/openphotos-ca/openphotos")

    static let supportEmailAddress = "support@openphotos.ca"
    static var supportEmail: URL? {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = supportEmailAddress
        // Optional: prefill subject/body
        comps.queryItems = [
            URLQueryItem(name: "subject", value: "OpenPhotos iOS Support")
        ]
        return comps.url
    }
}
