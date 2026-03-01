//
//  ToastView.swift
//  OpenPhotos
//
//  Toast notification component for displaying temporary messages.
//  Auto-dismisses after a configurable duration with slide-in/out animation.
//

import SwiftUI

/// Toast notification view that appears as a banner at the top of the screen
/// Automatically dismisses after the specified duration
struct ToastView: View {
    /// The message to display in the toast
    let message: String

    /// Binding to control toast visibility
    @Binding var isShowing: Bool

    /// Duration in seconds before auto-dismiss (default: 3.0)
    var duration: Double = 3.0

    /// Toast type for styling (success, error, info)
    var type: ToastType = .info

    /// Animation namespace for transitions
    @Namespace private var animation

    var body: some View {
        VStack {
            if isShowing {
                HStack(spacing: 12) {
                    // Icon based on type
                    Image(systemName: type.iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)

                    // Message text
                    Text(message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(type.backgroundColor)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                )
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    // Auto-dismiss after duration
                    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isShowing = false
                        }
                    }
                }
                .onTapGesture {
                    // Allow manual dismiss by tapping
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isShowing = false
                    }
                }
            }

            Spacer()
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isShowing)
    }
}

/// Toast type for visual styling
enum ToastType {
    case success
    case error
    case info
    case warning

    /// Icon name for the toast type
    var iconName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        }
    }

    /// Background color for the toast type
    var backgroundColor: Color {
        switch self {
        case .success:
            return Color.green.opacity(0.9)
        case .error:
            return Color.red.opacity(0.9)
        case .info:
            return Color.blue.opacity(0.9)
        case .warning:
            return Color.orange.opacity(0.9)
        }
    }
}

// MARK: - View Extension for Easy Toast Usage

extension View {
    /// Adds a toast overlay to any view
    /// - Parameters:
    ///   - message: The message to display
    ///   - isShowing: Binding to control visibility
    ///   - type: Toast type (success, error, info, warning)
    ///   - duration: Duration in seconds before auto-dismiss
    /// - Returns: View with toast overlay
    func toast(
        message: String,
        isShowing: Binding<Bool>,
        type: ToastType = .info,
        duration: Double = 3.0
    ) -> some View {
        ZStack {
            self

            ToastView(
                message: message,
                isShowing: isShowing,
                duration: duration,
                type: type
            )
            .zIndex(1000)
        }
    }
}

// MARK: - Preview

#Preview {
    struct ToastPreviewWrapper: View {
        @State private var showSuccess = false
        @State private var showError = false
        @State private var showInfo = false

        var body: some View {
            VStack(spacing: 20) {
                Button("Show Success Toast") {
                    withAnimation {
                        showSuccess = true
                    }
                }

                Button("Show Error Toast") {
                    withAnimation {
                        showError = true
                    }
                }

                Button("Show Info Toast") {
                    withAnimation {
                        showInfo = true
                    }
                }
            }
            .toast(
                message: "Share created successfully!",
                isShowing: $showSuccess,
                type: .success
            )
            .toast(
                message: "Failed to create share. Please try again.",
                isShowing: $showError,
                type: .error
            )
            .toast(
                message: "Loading share targets...",
                isShowing: $showInfo,
                type: .info
            )
        }
    }

    return ToastPreviewWrapper()
}
