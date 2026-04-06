import UIKit

final class IdleTimerManager {
    static let shared = IdleTimerManager()
    private let stateQueue = DispatchQueue(label: "openphotos.idle-timer")
    private var activeReasons: Set<String> = []

    private init() {}

    func setActive(_ active: Bool, reason: String) {
        let shouldDisable = stateQueue.sync {
            if active {
                activeReasons.insert(reason)
            } else {
                activeReasons.remove(reason)
            }
            return !activeReasons.isEmpty
        }
        apply(disabled: shouldDisable)
    }

    func setDisabled(_ disabled: Bool) {
        setActive(disabled, reason: "legacy")
    }

    private func apply(disabled: Bool) {
        if Thread.isMainThread {
            UIApplication.shared.isIdleTimerDisabled = disabled
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = disabled
            }
        }
    }
}
