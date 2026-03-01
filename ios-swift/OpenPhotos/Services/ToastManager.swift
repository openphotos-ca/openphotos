import Foundation
import Combine

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isPinned: Bool
}

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()
    /// Persistent banner shown until dismissed by the user.
    @Published var pinned: Toast?
    /// Transient banner shown for a limited duration.
    @Published var current: Toast?
    private init() {}

    func show(_ message: String, duration: TimeInterval = 3.0) {
        let toast = Toast(message: message, isPinned: false)
        current = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.current == toast {
                self?.current = nil
            }
        }
    }

    func showPinned(_ message: String) {
        pinned = Toast(message: message, isPinned: true)
    }

    func dismissPinned() {
        pinned = nil
    }
}
