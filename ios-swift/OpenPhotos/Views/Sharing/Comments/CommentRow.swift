//
//  CommentRow.swift
//  OpenPhotos
//
//  Individual comment row view.
//

import SwiftUI

/// Row view for a single comment
struct CommentRow: View {
    let comment: ShareComment
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(comment.authorDisplayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text(comment.body)
                        .font(.body)

                    Text(relativeTime(from: comment.date))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if canDelete {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Delete Comment", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this comment?")
        }
    }

    /// Get relative time string
    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    CommentRow(
        comment: ShareComment(
            id: "1",
            authorDisplayName: "John Doe",
            authorUserId: "user123",
            viewerSessionId: nil,
            body: "This is a great photo!",
            createdAt: Int64(Date().timeIntervalSince1970)
        ),
        canDelete: true,
        onDelete: {}
    )
    .padding()
}
