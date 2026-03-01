import SwiftUI

struct SyncAlbumsView: View {
    @ObservedObject private var auth = AuthManager.shared
    @State private var albumTree: [AlbumTreeNode] = []
    @State private var expanded: Set<Int64> = []
    @State private var syncEnabledMap: [Int64: Bool] = [:]
    @State private var lockedMap: [Int64: Bool] = [:]
    @State private var showPinSheet: Bool = false
    @State private var pinMode: PinSheetMode = .set
    @State private var pendingLockAlbumId: Int64?
    @State private var pendingLockUnassigned: Bool = false

    var body: some View {
        List {
            Section {
                UnassignedRow(
                    isEnabled: Binding(
                        get: { auth.syncIncludeUnassigned },
                        set: { auth.setSyncIncludeUnassigned($0) }
                    ),
                    isLocked: Binding(
                        get: { auth.syncUnassignedLocked },
                        set: { val in toggleUnassignedLocked(val) }
                    )
                )
            }
            Section(footer:
                        Text("Lock controls encryption: a locked album uploads items as end‑to‑end encrypted. The switch on the right selects the album for syncing.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
            ) {
                ForEach(albumTree, id: \.id) { node in
                    SyncAlbumRow(
                        node: node,
                        expanded: $expanded,
                        isEnabled: Binding(
                            get: { syncEnabledMap[node.id] ?? false },
                            set: { val in toggle(node.id, val) }
                        ),
                        isLocked: Binding(
                            get: { lockedMap[node.id] ?? false },
                            set: { val in toggleLocked(node.id, val) }
                        ),
                        onRefresh: { load() },
                        onToggleLocked: { albumId, locked in toggleLocked(albumId, locked) }
                    )
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Selected Albums")
        .onAppear { load() }
        .sheet(isPresented: $showPinSheet) {
            PinSheetView(mode: pinMode) {
                if let aid = pendingLockAlbumId {
                    if AlbumService.shared.setAlbumLocked(albumId: aid, locked: true) {
                        lockedMap[aid] = true
                    }
                    pendingLockAlbumId = nil
                }
                if pendingLockUnassigned {
                    auth.setSyncUnassignedLocked(true)
                    pendingLockUnassigned = false
                }
            }
        }
    }

    private func load() {
        let albums = AlbumService.shared.getAllAlbums()
        albumTree = AlbumService.shared.buildAlbumTree(from: albums)
        expanded = Set(albumTree.map { $0.id })
        syncEnabledMap = AlbumService.shared.getSyncEnabledMap()
        lockedMap = AlbumService.shared.getLockedMap()
    }

    private func toggle(_ albumId: Int64, _ enabled: Bool) {
        if AlbumService.shared.setAlbumSyncEnabled(albumId: albumId, enabled: enabled) {
            syncEnabledMap[albumId] = enabled
        }
    }

    private func toggleLocked(_ albumId: Int64, _ locked: Bool) {
        if locked {
            // Try to bypass prompt if session verified or biometric quick verify succeeds
            if PinManager.shared.isSessionVerified() || PinManager.shared.quickVerifyWithBiometrics(prompt: "Verify to lock album") {
                if AlbumService.shared.setAlbumLocked(albumId: albumId, locked: true) { lockedMap[albumId] = true }
                return
            }
            pendingLockAlbumId = albumId
            pendingLockUnassigned = false
            let hasEnv = E2EEManager.shared.hasEnvelope()
            pinMode = hasEnv ? .verify : .set
            print("[LOCKED] toggleLocked → locked=\(locked) hasEnvelope=\(hasEnv) albumId=\(albumId) pinMode=\(pinMode)")
            showPinSheet = true
            return
        }
        if AlbumService.shared.setAlbumLocked(albumId: albumId, locked: locked) { lockedMap[albumId] = locked; print("[LOCKED] disabled for albumId=\(albumId)") }
    }

    private func toggleUnassignedLocked(_ locked: Bool) {
        if locked {
            if PinManager.shared.isSessionVerified() || PinManager.shared.quickVerifyWithBiometrics(prompt: "Verify to lock Unassigned") {
                auth.setSyncUnassignedLocked(true)
                return
            }
            pendingLockAlbumId = nil
            pendingLockUnassigned = true
            let hasEnv = E2EEManager.shared.hasEnvelope()
            pinMode = hasEnv ? .verify : .set
            print("[LOCKED] toggleLocked → locked=\(locked) hasEnvelope=\(hasEnv) albumId=Unassigned pinMode=\(pinMode)")
            showPinSheet = true
            return
        }
        auth.setSyncUnassignedLocked(false)
        pendingLockUnassigned = false
    }
}

private struct UnassignedRow: View {
    @Binding var isEnabled: Bool
    @Binding var isLocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 16) // align with chevron column in album rows
            Button(action: { isLocked.toggle() }) {
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 22))
                    .foregroundColor(isLocked ? .blue : .secondary)
                    .accessibilityLabel(isLocked ? "Unlock album" : "Lock album")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unassigned")
                Text("Sync photos not in any album")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
        }
        .padding(.vertical, 6)
    }
}

private struct SyncAlbumRow: View {
    @ObservedObject var node: AlbumTreeNode
    @Binding var expanded: Set<Int64>
    @Binding var isEnabled: Bool
    @Binding var isLocked: Bool
    var onRefresh: () -> Void
    var onToggleLocked: (Int64, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if node.depth > 0 { Spacer().frame(width: CGFloat(node.depth * 16)) }
                if !node.children.isEmpty {
                    Button(action: { toggleExpand() }) {
                        Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                } else { Spacer().frame(width: 16) }
                // Lock/unlock toggle button (leading side). Default unlocked.
                Button(action: {
                    let newVal = !isLocked
                    onToggleLocked(node.id, newVal)
                }) {
                    Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 22))
                        .foregroundColor(isLocked ? .blue : .secondary)
                        .accessibilityLabel(isLocked ? "Unlock album" : "Lock album")
                }
                .buttonStyle(.plain)
                Text(node.album.name)
                Spacer()
                // Locked toggle
                HStack(spacing: 10) {
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                }
            }
            .padding(.vertical, 6)
            .contextMenu {
                Button("Enable for subtree") {
                    if AlbumService.shared.setSubtreeSyncEnabled(albumId: node.id, enabled: true) { onRefresh() }
                }
                Button("Disable for subtree") {
                    if AlbumService.shared.setSubtreeSyncEnabled(albumId: node.id, enabled: false) { onRefresh() }
                }
            }
            if expanded.contains(node.id) {
                ForEach(node.children, id: \.id) { child in
                    SyncAlbumRow(
                        node: child,
                        expanded: $expanded,
                        isEnabled: Binding(
                            get: { isEnabledFor(child.id) },
                            set: { val in setEnabledFor(child.id, val) }
                        ),
                        isLocked: Binding(
                            get: { AlbumService.shared.getLockedMap()[child.id] ?? false },
                            set: { val in onToggleLocked(child.id, val) }
                        ),
                        onRefresh: onRefresh,
                        onToggleLocked: onToggleLocked
                    )
                }
            }
        }
    }

    private func toggleExpand() {
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
    }

    private func isEnabledFor(_ albumId: Int64) -> Bool { (AlbumService.shared.getSyncEnabledMap()[albumId] ?? false) }
    private func setEnabledFor(_ albumId: Int64, _ enabled: Bool) {
        _ = AlbumService.shared.setAlbumSyncEnabled(albumId: albumId, enabled: enabled)
    }

    // state comes from binding `isLocked`
}

// MARK: - PIN Sheet
enum PinSheetMode { case set, verify }

struct PinSheetView: View {
    let mode: PinSheetMode
    let onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin: String = ""
    @State private var pinConfirm: String = ""
    @State private var error: String?
    @State private var fetchedEnvelope: Bool = false

    var body: some View {
        let shouldSet = (mode == .set) && !E2EEManager.shared.hasEnvelope()
        VStack(spacing: 16) {
            Text(shouldSet ? "Set PIN" : "Enter PIN").font(.headline)
            SecureField("PIN", text: $pin).keyboardType(.numberPad)
            if shouldSet { SecureField("Confirm PIN", text: $pinConfirm).keyboardType(.numberPad) }
            if PinManager.shared.canUseBiometricQuickVerify() {
                Button("Use Face ID / Touch ID") {
                    if PinManager.shared.quickVerifyWithBiometrics() { dismiss(); onSuccess() }
                }.buttonStyle(.bordered)
            }
            if let e = error { Text(e).foregroundColor(.red).font(.footnote) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(shouldSet ? "Save" : "Unlock") {
                    let p = pin.trimmingCharacters(in: .whitespacesAndNewlines)
                    let c = pinConfirm.trimmingCharacters(in: .whitespacesAndNewlines)
                    if shouldSet {
                        guard !p.isEmpty, p == c else { error = "PINs do not match"; return }
                        print("[PIN] UI set PIN len=\(p.count)")
                        PinManager.shared.setPin(p)
                        PinManager.shared.markSessionVerified()
                        if PinManager.shared.isBiometricsEnabled() { _ = PinManager.shared.ensureBiometricToken() }
                        dismiss(); onSuccess()
                    } else {
                        print("[PIN] UI verify PIN len=\(p.count)")
                        // Prefer server envelope verification when available
                        if let env = E2EEManager.shared.loadEnvelope() {
                            Task {
                                do {
                                    let ok = try E2EEManager.shared.unlockWithPassword(password: p, envelope: env)
                                    DispatchQueue.main.async {
                                        if ok {
                                            // Cache session and save UMK for future biometric quick unlocks
                                            PinManager.shared.markSessionVerified()
                                            if let umk = E2EEManager.shared.umk, umk.count == 32 { _ = E2EEManager.shared.saveDeviceWrappedUMK(umk) }
                                            dismiss(); onSuccess()
                                        } else { error = "Incorrect PIN" }
                                    }
                                } catch {
                                    DispatchQueue.main.async { self.error = error.localizedDescription }
                                }
                            }
                        } else {
                            // Fallback to local PIN if no envelope could be fetched
                            if PinManager.shared.verifyPin(p) { dismiss(); onSuccess() } else { error = "Incorrect PIN" }
                        }
                    }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .presentationDetents([.fraction(0.30)])
        .onAppear {
            // Auto attempt biometric quick verify if available
            if PinManager.shared.quickVerifyWithBiometrics(prompt: "Verify to continue") { dismiss(); onSuccess(); return }
            // If no local envelope yet, attempt to fetch from server once
            if !E2EEManager.shared.hasEnvelope() && !fetchedEnvelope {
                fetchedEnvelope = true
                Task { await E2EEManager.shared.syncEnvelopeFromServer(); _ = E2EEManager.shared.hasEnvelope() }
            }
        }
    }
}
