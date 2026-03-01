//
//  CommentInputView.swift
//  OpenPhotos
//
//  Input field for composing comments.
//

import SwiftUI

/// Input view for composing a new comment
struct CommentInputView: View {
    @Binding var text: String
    let isPosting: Bool
    let onPost: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField("Add a comment...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isFocused)
                .disabled(isPosting)

            if isPosting {
                ProgressView()
                    .frame(width: 24, height: 24)
            } else {
                Button {
                    onPost()
                    isFocused = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(canPost ? .blue : .gray)
                }
                .disabled(!canPost)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    /// Check if can post
    private var canPost: Bool {
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPosting
    }
}

#Preview {
    VStack {
        Spacer()
        CommentInputView(
            text: .constant(""),
            isPosting: false,
            onPost: {}
        )
    }
}
