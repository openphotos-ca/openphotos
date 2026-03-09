import Foundation

extension Notification.Name {
    static let authUnauthorized = Notification.Name("AuthUnauthorized")
    static let syncRunCompleted = Notification.Name("SyncRunCompleted")
}

enum SyncRunCompletedUserInfoKey {
    static let version = "version"
}
