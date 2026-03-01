//
//  ShareLoadingIndicator.swift
//  OpenPhotos
//
//  Reusable components for loading, error, and empty states in sharing views.
//

import SwiftUI

/// Error view with retry button
struct ErrorView: View {
    let message: String
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                retryAction()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

/// Empty state view with icon and optional action
struct ShareEmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var action: (() -> Void)? = nil
    var actionView: AnyView? = nil

    init(icon: String, title: String, message: String, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
        self.actionView = nil
    }

    init<Content: View>(icon: String, title: String, message: String, @ViewBuilder actionView: () -> Content) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = nil
        self.actionView = AnyView(actionView())
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let actionView = actionView {
                actionView
            } else if let action = action {
                Button("Get Started") {
                    action()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

/// Loading indicator with message
struct ShareLoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

/// Offline indicator banner
struct OfflineIndicator: View {
    var body: some View {
        HStack {
            Image(systemName: "wifi.slash")
            Text("Showing cached data")
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.2))
    }
}

#Preview("Error View") {
    ErrorView(message: "Failed to load shares", retryAction: {})
}

#Preview("Empty State") {
    ShareEmptyStateView(
        icon: "tray.2",
        title: "No Items",
        message: "Nothing to show here"
    )
}

#Preview("Loading") {
    ShareLoadingView(message: "Loading shares...")
}

#Preview("Offline") {
    OfflineIndicator()
}
