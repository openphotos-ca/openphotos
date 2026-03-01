import SwiftUI
import Combine

struct UploadsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var uploader: HybridUploadManager
    // Sorting can be O(n log n) and can run frequently while uploads are active.
    // Cache and update it on a throttled stream to keep scrolling/tapping responsive.
    @State private var sortedItemsCache: [UploadItem] = []

    var body: some View {
        NavigationView {
            VStack {
                List(sortedItemsCache) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.filename)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(statusText(item))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(progressText(item))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ProgressView(value: progressValue(item))
                                .frame(width: 120)
                        }
                    }
                }
                .listStyle(.plain)

                VStack(spacing: 12) {
                    Toggle("Keep screen on during upload", isOn: Binding(
                        get: { uploader.keepScreenOn },
                        set: { uploader.keepScreenOn = $0 }
                    ))

                    Button("Switch to Background Uploads") {
                        uploader.switchToBackgroundUploads()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("Uploads")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            sortedItemsCache = sortItems(uploader.items)
        }
        .onReceive(
            uploader.$items.throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
        ) { items in
            sortedItemsCache = sortItems(items)
        }
    }

    private func sortItems(_ items: [UploadItem]) -> [UploadItem] {
        items.sorted { a, b in
            let aIncomplete = isIncomplete(a)
            let bIncomplete = isIncomplete(b)
            if aIncomplete != bIncomplete { return aIncomplete && !bIncomplete }
            if a.enqueuedAt != b.enqueuedAt { return a.enqueuedAt > b.enqueuedAt }
            if a.creationTs != b.creationTs { return a.creationTs > b.creationTs }
            return a.filename.localizedCaseInsensitiveCompare(b.filename) == .orderedAscending
        }
    }

    private func isIncomplete(_ item: UploadItem) -> Bool {
        switch item.status {
        case .completed, .canceled:
            return false
        default:
            return true
        }
    }

    private func statusText(_ item: UploadItem) -> String {
        switch item.status {
        case .queued: return "Queued"
        case .exporting: return "Exporting"
        case .uploading: return "Uploading"
        case .backgroundQueued: return "Background queued"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }

    private func progressValue(_ item: UploadItem) -> Double {
        guard item.totalBytes > 0 else { return 0 }
        return Double(item.sentBytes) / Double(item.totalBytes)
    }

    private func progressText(_ item: UploadItem) -> String {
        let sent = ByteCountFormatter.string(fromByteCount: item.sentBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
        return "\(sent) / \(total)"
    }
}
