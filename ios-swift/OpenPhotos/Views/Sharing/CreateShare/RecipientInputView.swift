//
//  RecipientInputView.swift
//  OpenPhotos
//
//  View for adding recipients to a share by selecting from available users/groups.
//

import SwiftUI

/// View for adding recipients
struct RecipientInputView: View {
    @Binding var recipients: [RecipientInput]

    @State private var selectedType: RecipientInput.RecipientType = .user
    @State private var showTargetPicker = false

    private var excludedTargetKeys: Set<String> {
        Set(recipients.map { recipientKey(type: $0.type, identifier: $0.identifier) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recipients")
                .font(.headline)

            // Type selector (segmented control)
            Picker("Type", selection: $selectedType) {
                ForEach(RecipientInput.RecipientType.allCases, id: \.self) { type in
                    Text(type.typeLabel).tag(type)
                }
            }
            .pickerStyle(.segmented)

            // Selection row
            Button {
                showTargetPicker = true
            } label: {
                HStack {
                    Text("Select \(selectedType.typeLabel)")
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            // Recipient chips
            if !recipients.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(recipients) { recipient in
                        RecipientChip(
                            recipient: recipient,
                            onRemove: {
                                removeRecipient(recipient)
                            }
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showTargetPicker) {
            ShareTargetPickerSheet(
                selectedType: selectedType,
                excludedTargetKeys: excludedTargetKeys,
                onSelect: { target in
                    addRecipient(from: target)
                    showTargetPicker = false
                }
            )
        }
    }

    /// Add recipient from target selection.
    private func addRecipient(from target: ShareTarget) {
        guard
            let targetId = target.id,
            let targetType = RecipientInput.RecipientType(rawValue: target.kind)
        else {
            return
        }

        let key = recipientKey(type: targetType, identifier: targetId)
        guard !excludedTargetKeys.contains(key) else { return }

        let recipient = RecipientInput(
            type: targetType,
            identifier: targetId,
            displayName: target.displayName
        )
        recipients.append(recipient)
    }

    /// Remove recipient
    private func removeRecipient(_ recipient: RecipientInput) {
        recipients.removeAll { $0.id == recipient.id }
    }

    private func recipientKey(type: RecipientInput.RecipientType, identifier: String) -> String {
        "\(type.rawValue):\(identifier)"
    }
}

/// Sheet for selecting a share target (user or group)
struct ShareTargetPickerSheet: View {
    let selectedType: RecipientInput.RecipientType
    let excludedTargetKeys: Set<String>
    let onSelect: (ShareTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targets: [ShareTarget] = []
    @State private var searchQuery = ""
    @State private var isLoading = true
    @State private var error: String?

    private let shareService = ShareService.shared
    private let currentUserId = AuthManager.shared.userId

    private var candidateTargetsForType: [ShareTarget] {
        targets.filter { target in
            guard target.kind == selectedType.rawValue, let targetId = target.id else {
                return false
            }
            if selectedType == .user, let currentUserId = currentUserId, targetId == currentUserId {
                return false
            }
            return true
        }
    }

    private var selectableTargetsForType: [ShareTarget] {
        candidateTargetsForType.filter { target in
            guard let key = targetRecipientKey(target) else { return false }
            return !excludedTargetKeys.contains(key)
        }
    }

    var filteredTargets: [ShareTarget] {
        let filtered = selectableTargetsForType
        if searchQuery.isEmpty {
            return filtered
        }
        return filtered.filter {
            $0.label.localizedCaseInsensitiveContains(searchQuery) ||
            ($0.email?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
    }

    private var emptyDescription: String {
        if !searchQuery.isEmpty {
            return "No \(selectedType.typeLabel.lowercased())s match your search"
        }
        if !candidateTargetsForType.isEmpty {
            return "All available \(selectedType.typeLabel.lowercased())s have already been added"
        }
        return "No \(selectedType.typeLabel.lowercased())s available to share with"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                } else if let error = error {
                    ContentUnavailableView(
                        "Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if filteredTargets.isEmpty {
                    ContentUnavailableView(
                        "No \(selectedType.typeLabel)s",
                        systemImage: selectedType == .user ? "person.slash" : "person.3.slash",
                        description: Text(emptyDescription)
                    )
                } else {
                    List(filteredTargets) { target in
                        Button {
                            onSelect(target)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: target.iconName)
                                    .font(.title2)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.displayName)
                                        .foregroundColor(.primary)
                                    if let email = target.email {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .searchable(text: $searchQuery, prompt: "Search \(selectedType.typeLabel.lowercased())s")
                }
            }
            .navigationTitle("Select \(selectedType.typeLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await loadTargets()
        }
    }

    private func loadTargets() async {
        isLoading = true
        error = nil

        do {
            targets = try await shareService.listShareTargets()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func targetRecipientKey(_ target: ShareTarget) -> String? {
        guard
            let targetId = target.id,
            let targetType = RecipientInput.RecipientType(rawValue: target.kind)
        else {
            return nil
        }
        return "\(targetType.rawValue):\(targetId)"
    }
}

/// Chip for displaying a recipient
struct RecipientChip: View {
    let recipient: RecipientInput
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption)

            Text(recipient.displayName)
                .font(.subheadline)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.systemGray5))
        .clipShape(Capsule())
    }

    private var iconName: String {
        switch recipient.type {
        case .user: return "person.fill"
        case .group: return "person.2.fill"
        }
    }
}

/// Flow layout for wrapping chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                     y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    // New line
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

#Preview {
    RecipientInputView(recipients: .constant([
        RecipientInput(type: .user, identifier: "user-123", displayName: "John Doe"),
        RecipientInput(type: .group, identifier: "group-456", displayName: "Family")
    ]))
    .padding()
}
