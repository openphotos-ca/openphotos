import SwiftUI

struct ToastBanner: View {
    @ObservedObject private var toast = ToastManager.shared

    var body: some View {
        VStack(spacing: 8) {
            if let t = toast.pinned {
                toastRow(t, showsClose: true) { toast.dismissPinned() }
            }
            if let t = toast.current {
                toastRow(t, showsClose: false, onClose: nil)
            }
        }
        .padding(.top, 10)
        .animation(.easeInOut(duration: 0.25), value: toast.pinned != nil)
        .animation(.easeInOut(duration: 0.25), value: toast.current != nil)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func toastRow(_ t: Toast, showsClose: Bool, onClose: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundColor(.white)
            Text(t.message)
                .foregroundColor(.white)
                .lineLimit(3)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
            if showsClose, let onClose {
                Spacer(minLength: 6)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.black.opacity(0.85))
        .clipShape(Capsule())
        // Only accept touches when close is visible.
        .allowsHitTesting(showsClose)
    }
}
