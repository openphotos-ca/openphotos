import Foundation
import LocalAuthentication

// Persisted user choices for security-related behavior.
// Defaults:
// - Include Location/Caption/Description in locked uploads: ON
// - Remember unlock TTL: 1 hour
final class SecurityPreferences: ObservableObject {
    static let shared = SecurityPreferences()

    // UserDefaults keys
    private let kIncludeLocation = "security.includeLocation"
    private let kIncludeCaption = "security.includeCaption"
    private let kIncludeDescription = "security.includeDescription"
    private let kRememberUnlockSeconds = "security.rememberUnlock.seconds"

    private init() {
        // Prime defaults on first access
        if UserDefaults.standard.object(forKey: kIncludeLocation) == nil {
            UserDefaults.standard.set(true, forKey: kIncludeLocation)
        }
        if UserDefaults.standard.object(forKey: kIncludeCaption) == nil {
            UserDefaults.standard.set(true, forKey: kIncludeCaption)
        }
        if UserDefaults.standard.object(forKey: kIncludeDescription) == nil {
            UserDefaults.standard.set(true, forKey: kIncludeDescription)
        }
        if UserDefaults.standard.object(forKey: kRememberUnlockSeconds) == nil {
            UserDefaults.standard.set(3600, forKey: kRememberUnlockSeconds) // 1 hour default
        }
    }

    var includeLocation: Bool {
        get { UserDefaults.standard.bool(forKey: kIncludeLocation) }
        set { UserDefaults.standard.set(newValue, forKey: kIncludeLocation) }
    }

    var includeCaption: Bool {
        get { UserDefaults.standard.bool(forKey: kIncludeCaption) }
        set { UserDefaults.standard.set(newValue, forKey: kIncludeCaption) }
    }

    var includeDescription: Bool {
        get { UserDefaults.standard.bool(forKey: kIncludeDescription) }
        set { UserDefaults.standard.set(newValue, forKey: kIncludeDescription) }
    }

    // Seconds: 900 (15m), 3600 (1h), 86400 (24h)
    var rememberUnlockSeconds: Int {
        get { UserDefaults.standard.integer(forKey: kRememberUnlockSeconds) }
        set { UserDefaults.standard.set(newValue, forKey: kRememberUnlockSeconds) }
    }

    // Helper: whether device supports biometrics. If not, we must require PIN every time.
    func biometricsAvailable() -> Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
}

