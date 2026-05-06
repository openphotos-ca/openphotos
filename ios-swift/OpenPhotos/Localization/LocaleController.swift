import Foundation
import ObjectiveC

final class LocaleController: ObservableObject {
    static let shared = LocaleController()

    static let modeSystem = "system"
    static let modeEnglish = "en"
    static let modeSimplifiedChinese = "zh-Hans"
    static let modeFrench = "fr"
    static let modeSpanish = "es"

    private let key = "language.mode"

    @Published private(set) var mode: String

    var localeIdentifier: String {
        mode == Self.modeSystem ? resolvedSystemLanguage() : mode
    }

    var swiftUILocale: Locale {
        Locale(identifier: localeIdentifier)
    }

    private init() {
        mode = UserDefaults.standard.string(forKey: key) ?? Self.modeSystem
        if !Self.isSupportedMode(mode) {
            mode = Self.modeSystem
        }
        apply()
    }

    func setMode(_ next: String) {
        let normalized = Self.isSupportedMode(next) ? next : Self.modeSystem
        guard normalized != mode else { return }
        mode = normalized
        UserDefaults.standard.set(normalized, forKey: key)
        apply()
    }

    func apply() {
        let language = localeIdentifier
        Bundle.setOpenPhotosLanguage(language == Self.modeEnglish ? nil : language)
    }

    func displayName(for mode: String) -> String {
        switch mode {
        case Self.modeEnglish: return "English"
        case Self.modeSimplifiedChinese: return "简体中文"
        case Self.modeFrench: return "Français"
        case Self.modeSpanish: return "Español"
        default: return NSLocalizedString("System", comment: "System language option")
        }
    }

    private static func isSupportedMode(_ value: String) -> Bool {
        value == modeSystem
            || value == modeEnglish
            || value == modeSimplifiedChinese
            || value == modeFrench
            || value == modeSpanish
    }

    private func resolvedSystemLanguage() -> String {
        for raw in Locale.preferredLanguages {
            let tag = raw.lowercased()
            if tag.hasPrefix("en") { return Self.modeEnglish }
            if tag.hasPrefix("fr") { return Self.modeFrench }
            if tag.hasPrefix("es") { return Self.modeSpanish }
            if tag.hasPrefix("zh") {
                if tag.contains("hant") || tag.contains("tw") || tag.contains("hk") || tag.contains("mo") {
                    return Self.modeEnglish
                }
                return Self.modeSimplifiedChinese
            }
        }
        return Self.modeEnglish
    }
}

private var openPhotosBundleKey: UInt8 = 0

private final class OpenPhotosLocalizedBundle: Bundle {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = objc_getAssociatedObject(self, &openPhotosBundleKey) as? Bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

private extension Bundle {
    static func setOpenPhotosLanguage(_ language: String?) {
        object_setClass(Bundle.main, OpenPhotosLocalizedBundle.self)
        guard let language,
              let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            objc_setAssociatedObject(Bundle.main, &openPhotosBundleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        objc_setAssociatedObject(Bundle.main, &openPhotosBundleKey, bundle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
