import UIKit

final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    private init() {}

    func begin(_ name: String) -> UIBackgroundTaskIdentifier {
        var taskId = UIBackgroundTaskIdentifier.invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Expiration handler
            self.end(taskId)
        }
        return taskId
    }

    func end(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}

