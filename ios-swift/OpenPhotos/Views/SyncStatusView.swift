import SwiftUI
import Combine

struct SyncStatusView: View {
    @ObservedObject private var auth = AuthManager.shared
    @State private var showingUploads = false
    @State private var pending = 0
    @State private var uploading = 0
    @State private var bgQueued = 0
    @State private var failed = 0
    @State private var synced = 0
    @State private var lastSyncAt: Int64 = 0
    @State private var icloudPending = 0
    @State private var icloudDownloading = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pending:")
                Spacer()
                Text("\(pending)").foregroundColor(.secondary)
            }
            HStack {
                Text("Uploading:")
                Spacer()
                Text("\(uploading)").foregroundColor(.secondary)
            }
            HStack(alignment: .top) {
                Text("Files:")
                Spacer()
                Button("Uploads") { showingUploads = true }
            }
            HStack {
                Text("Queued (background):")
                Spacer()
                Text("\(bgQueued)").foregroundColor(.secondary)
            }
            HStack {
                Text("Failed:")
                Spacer()
                Text("\(failed)").foregroundColor(failed > 0 ? .red : .secondary)
            }
            HStack {
                Text("iCloud Pending:")
                Spacer()
                Text("\(icloudPending)").foregroundColor(.secondary)
            }
            HStack {
                Text("Downloading (iCloud):")
                Spacer()
                Text("\(icloudDownloading)").foregroundColor(.secondary)
            }
            HStack {
                Text("Synced:")
                Spacer()
                Text("\(synced)").foregroundColor(.secondary)
            }
            if lastSyncAt > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(lastSyncAt))
                HStack {
                    Text("Last sync:")
                    Spacer()
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Refresh") { refresh() }
            }
        }
        .buttonStyle(.borderless)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SyncRepository.statsChangedNotification)) { _ in
            refresh()
        }
        .onReceive(auth.$syncScope.removeDuplicates()) { _ in
            refresh()
        }
        .onReceive(auth.$syncIncludeUnassigned.removeDuplicates()) { _ in
            refresh()
        }
        .onReceive(HybridUploadManager.shared.$icloudPendingCount.removeDuplicates()) { v in icloudPending = v }
        .onReceive(HybridUploadManager.shared.$icloudDownloadingCount.removeDuplicates()) { v in icloudDownloading = v }
        .sheet(isPresented: $showingUploads) {
            UploadsView().environmentObject(HybridUploadManager.shared)
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = SyncRepository.shared.getStats(
                scope: self.auth.syncScope,
                includeUnassigned: self.auth.syncIncludeUnassigned
            )
            DispatchQueue.main.async {
                pending = s.pending
                uploading = s.uploading
                bgQueued = s.bgQueued
                failed = s.failed
                synced = s.synced
                lastSyncAt = s.lastSyncAt
                icloudPending = HybridUploadManager.shared.icloudPendingCount
                icloudDownloading = HybridUploadManager.shared.icloudDownloadingCount
            }
        }
    }
}
