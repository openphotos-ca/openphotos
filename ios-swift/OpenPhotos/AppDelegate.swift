import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        HybridUploadManager.shared.setBackgroundCompletionHandler(completionHandler)
    }
}

