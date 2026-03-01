//
//  ShareTargetsList.swift
//  OpenPhotos
//
//  Scrollable list of users and groups that can be added as share recipients.
//  Shows checkmarks for selected items and supports tap-to-toggle selection.
//

import SwiftUI

/// List view for displaying and selecting share targets (users and groups)
struct ShareTargetsList: View {
    /// Available targets to display
    let targets: [ShareTarget]

    /// Currently selected targets
    let selectedTargets: [ShareTarget]

    /// Loading state for targets
    let isLoading: Bool

    /// Callback when a target is tapped for selection
    let onToggle: (ShareTarget) -> Void

    var body: some View {
        let _ = print("🔍 ShareTargetsList body - isLoading: \(isLoading), targets count: \(targets.count)")

        return Group {
            if isLoading {
                // Show loading spinner
                let _ = print("🔍 ShareTargetsList showing loading spinner")
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
            } else if targets.isEmpty {
                // Empty state
                let _ = print("🔍 ShareTargetsList showing empty state")
                Text("No users or groups available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                // List of targets - use ForEach directly for Form compatibility
                let _ = print("🔍 ShareTargetsList rendering \(targets.count) targets")
                ForEach(targets) { target in
                    ShareTargetRow(
                        target: target,
                        isSelected: isSelected(target),
                        onToggle: onToggle
                    )
                }
            }
        }
        .onAppear {
            print("🔍 ShareTargetsList appeared")
        }
    }

    /// Check if a target is selected
    private func isSelected(_ target: ShareTarget) -> Bool {
        return selectedTargets.contains(where: { $0.id == target.id })
    }
}

/// Individual row for a share target
private struct ShareTargetRow: View {
    let target: ShareTarget
    let isSelected: Bool
    let onToggle: (ShareTarget) -> Void

    var body: some View {
        Button(action: {
            onToggle(target)
        }) {
            HStack(spacing: 12) {
                // Icon (user or group)
                Image(systemName: target.iconName)
                    .font(.system(size: 18))
                    .foregroundColor(iconColor)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(iconBackgroundColor))

                // Label and subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.label)
                        .font(.body)
                        .foregroundColor(.primary)

                    // Show email for users if available
                    if target.kind == "user", let email = target.email {
                        Text(email)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Show "group" label for groups
                    if target.kind == "group" {
                        Text("group")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Checkmark for selected items
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Icon color based on target kind
    private var iconColor: Color {
        switch target.kind {
        case "group":
            return .orange
        case "user":
            return .blue
        default:
            return .gray
        }
    }

    /// Icon background color based on target kind
    private var iconBackgroundColor: Color {
        switch target.kind {
        case "group":
            return .orange.opacity(0.15)
        case "user":
            return .blue.opacity(0.15)
        default:
            return .gray.opacity(0.15)
        }
    }
}

// MARK: - Recipient Chips View

/// Displays selected recipients as removable chips
struct RecipientChipsView: View {
    /// Selected recipients to display as chips
    let recipients: [ShareTarget]

    /// Callback when a recipient chip is removed
    let onRemove: (ShareTarget) -> Void

    var body: some View {
        if recipients.isEmpty {
            Text("No recipients selected")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
        } else {
            // Wrap chips in rows
            FlowLayout(spacing: 8) {
                ForEach(recipients) { recipient in
                    ShareTargetChip(
                        target: recipient,
                        onRemove: onRemove
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// Individual share target chip with remove button
private struct ShareTargetChip: View {
    let target: ShareTarget
    let onRemove: (ShareTarget) -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Icon
            Image(systemName: target.iconName)
                .font(.system(size: 12))
                .foregroundColor(.white)

            // Label
            Text(target.label)
                .font(.subheadline)
                .foregroundColor(.white)

            // Remove button
            Button(action: {
                onRemove(target)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(chipColor)
        )
    }

    /// Chip color based on target kind
    private var chipColor: Color {
        switch target.kind {
        case "group":
            return .orange
        case "user":
            return .blue
        default:
            return .gray
        }
    }
}

// Note: FlowLayout is defined in RecipientInputView.swift and is reused here

// MARK: - Preview

#Preview("Share Targets List") {
    struct PreviewWrapper: View {
        @State private var selected: [ShareTarget] = []

        let targets = [
            ShareTarget(kind: "user", id: "1", label: "Alice Williams", email: "alice@example.com"),
            ShareTarget(kind: "user", id: "2", label: "Bob Smith", email: "bob@example.com"),
            ShareTarget(kind: "group", id: "3", label: "Test Group 2", email: nil),
            ShareTarget(kind: "group", id: "4", label: "testgroup", email: nil),
            ShareTarget(kind: "user", id: "5", label: "Charlie Davis", email: "charlie@example.com"),
        ]

        var body: some View {
            VStack(spacing: 20) {
                ShareTargetsList(
                    targets: targets,
                    selectedTargets: selected,
                    isLoading: false,
                    onToggle: { target in
                        if let index = selected.firstIndex(where: { $0.id == target.id }) {
                            selected.remove(at: index)
                        } else {
                            selected.append(target)
                        }
                    }
                )

                Divider()

                RecipientChipsView(
                    recipients: selected,
                    onRemove: { target in
                        selected.removeAll(where: { $0.id == target.id })
                    }
                )

                Spacer()
            }
            .padding()
        }
    }

    return PreviewWrapper()
}
