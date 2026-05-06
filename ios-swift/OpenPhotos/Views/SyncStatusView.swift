import SwiftUI
import Combine
import UIKit

struct SyncStatusView: View {
    @ObservedObject private var auth = AuthManager.shared
    @ObservedObject private var uploader = HybridUploadManager.shared
    @State private var showingUploads = false
    @State private var pending = 0
    @State private var uploading = 0
    @State private var bgQueued = 0
    @State private var failed = 0
    @State private var synced = 0
    @State private var lastSyncAt: Int64 = 0
    @State private var icloudPending = 0
    @State private var icloudDownloading = 0
    private let refreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.tr("Pending:"))
                Spacer()
                Text("\(pending)").foregroundColor(.secondary)
            }
            HStack {
                Text(L10n.tr("Uploading:"))
                Spacer()
                Text("\(uploading)").foregroundColor(.secondary)
            }
            HStack(alignment: .top) {
                Text(L10n.tr("Files:"))
                Spacer()
                Button(L10n.tr("Uploads")) { showingUploads = true }
            }
            HStack {
                Text(L10n.tr("Queued (background):"))
                Spacer()
                Text("\(bgQueued)").foregroundColor(.secondary)
            }
            HStack {
                Text(L10n.tr("Failed:"))
                Spacer()
                Text("\(failed)").foregroundColor(failed > 0 ? .red : .secondary)
            }
            HStack {
                Text(L10n.tr("iCloud Pending:"))
                Spacer()
                Text("\(icloudPending)").foregroundColor(.secondary)
            }
            HStack {
                Text(L10n.tr("Downloading (iCloud):"))
                Spacer()
                Text("\(icloudDownloading)").foregroundColor(.secondary)
            }
            HStack {
                Text(L10n.tr("Synced:"))
                Spacer()
                Text("\(synced)").foregroundColor(.secondary)
            }
            if lastSyncAt > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(lastSyncAt))
                HStack {
                    Text(L10n.tr("Last sync:"))
                    Spacer()
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(L10n.tr("Refresh")) { refresh() }
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
        .onReceive(auth.$syncPhotosOnly.removeDuplicates()) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncRunCompleted)) { _ in
            refresh()
        }
        .onReceive(
            uploader.$items.throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
        ) { items in
            uploading = foregroundUploadingAssetCount(for: items)
        }
        .onReceive(HybridUploadManager.shared.$icloudPendingCount.removeDuplicates()) { v in icloudPending = v }
        .onReceive(HybridUploadManager.shared.$icloudDownloadingCount.removeDuplicates()) { v in icloudDownloading = v }
        .onReceive(refreshTimer) { _ in
            guard SyncService.shared.isSyncBusyOrPendingResume()
                || pending > 0
                || bgQueued > 0
                || uploading > 0
                || icloudPending > 0
                || icloudDownloading > 0 else {
                return
            }
            refresh()
        }
        .sheet(isPresented: $showingUploads) {
            UploadsView().environmentObject(HybridUploadManager.shared)
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = SyncRepository.shared.getStats(
                scope: self.auth.syncScope,
                includeUnassigned: self.auth.syncIncludeUnassigned,
                photosOnly: self.auth.syncPhotosOnly
            )
            DispatchQueue.main.async {
                pending = s.pending
                uploading = foregroundUploadingAssetCount(for: uploader.items)
                bgQueued = s.bgQueued
                failed = s.failed
                synced = s.synced
                lastSyncAt = s.lastSyncAt
                icloudPending = uploader.icloudPendingCount
                icloudDownloading = uploader.icloudDownloadingCount
            }
        }
    }

    private func foregroundUploadingAssetCount(for items: [UploadItem]) -> Int {
        Set(
            items.compactMap { item in
                item.status == .uploading ? item.assetLocalIdentifier : nil
            }
        ).count
    }
}
