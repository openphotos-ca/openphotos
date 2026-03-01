import SwiftUI

struct SelectedAlbumsPlaceholder: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            Text("Album selection UI coming soon")
                .font(.headline)
            Text("For now, all albums are treated as not-selected unless toggled via future UI.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
        .navigationTitle("Selected Albums")
    }
}

