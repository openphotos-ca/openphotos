//
//  CommentThreadSheet.swift
//  OpenPhotos
//
//  Sheet view for displaying and creating comments on a shared asset.
//

import SwiftUI

/// Sheet for viewing and creating comments on an asset
struct CommentThreadSheet: View {
    let share: Share
    let assetId: String

    @State private var comments: [ShareComment] = []
    @State private var isLoading = false
    @State private var newCommentText = ""
    @State private var isPosting = false
    @Environment(\.dismiss) private var dismiss

    private let shareService = ShareService.shared
    private let canComment: Bool

    init(share: Share, assetId: String) {
        self.share = share
        self.assetId = assetId
        let permissions = SharePermissions(rawValue: share.defaultPermissions)
        self.canComment = permissions.canComment
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading && comments.isEmpty {
                    ProgressView("Loading comments...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if comments.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        Text("No Comments Yet")
                            .font(.headline)

                        Text("Be the first to comment")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(comments) { comment in
                                CommentRow(
                                    comment: comment,
                                    canDelete: canDeleteComment(comment),
                                    onDelete: {
                                        Task {
                                            await deleteComment(comment)
                                        }
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                }

                Divider()

                // Comment input
                if canComment {
                    CommentInputView(
                        text: $newCommentText,
                        isPosting: isPosting,
                        onPost: {
                            Task {
                                await postComment()
                            }
                        }
                    )
                }
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadComments()
            }
        }
    }

    // MARK: - Actions

    /// Load comments for asset
    private func loadComments() async {
        isLoading = true
        defer { isLoading = false }

        do {
            comments = try await shareService.listComments(
                shareId: share.id,
                assetId: assetId
            )
        } catch {
            print("Failed to load comments: \(error)")
        }
    }

    /// Post new comment
    private func postComment() async {
        guard !newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isPosting = true
        defer { isPosting = false }

        do {
            let comment = try await shareService.createComment(
                shareId: share.id,
                assetId: assetId,
                body: newCommentText
            )

            comments.append(comment)
            newCommentText = ""
        } catch {
            print("Failed to post comment: \(error)")
        }
    }

    /// Delete a comment
    private func deleteComment(_ comment: ShareComment) async {
        do {
            try await shareService.deleteComment(
                shareId: share.id,
                commentId: comment.id
            )

            comments.removeAll { $0.id == comment.id }
        } catch {
            print("Failed to delete comment: \(error)")
        }
    }

    /// Check if user can delete comment
    private func canDeleteComment(_ comment: ShareComment) -> Bool {
        // Owner can delete any comment
        // TODO: Check if current user is owner
        // For now, allow deleting own comments
        // TODO: Compare comment.authorUserId with current user ID
        return true
    }
}

#Preview {
    CommentThreadSheet(
        share: Share(
            id: "1",
            ownerOrgId: 1,
            ownerUserId: "user123",
            objectKind: .album,
            objectId: "42",
            defaultPermissions: SharePermissions.commenter.rawValue,
            expiresAt: nil,
            status: .active,
            createdAt: Date(),
            updatedAt: Date(),
            name: "Test Share",
            includeFaces: false,
            includeSubtree: false,
            recipients: []
        ),
        assetId: "asset123"
    )
}
