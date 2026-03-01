import UIKit

final class IdleTimerManager {
    static let shared = IdleTimerManager()
    private init() {}

    func setDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

