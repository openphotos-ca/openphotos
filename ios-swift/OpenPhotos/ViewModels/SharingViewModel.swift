//
//  SharingViewModel.swift
//  OpenPhotos
//
//  View model for managing the main sharing view and its tabs.
//

import Foundation
import SwiftUI
import SwiftData

/// View model for the main sharing interface
@MainActor
class SharingViewModel: ObservableObject {
    @Published var selectedTab: ShareTab = .sharedWithMe

    // My Shares
    @Published var outgoingShares: [Share] = []
    @Published var isLoadingOutgoing = false
    @Published var outgoingError: String?

    // Shared with Me
    @Published var receivedShares: [Share] = []
    @Published var isLoadingReceived = false
    @Published var receivedError: String?

    // Public Links
    @Published var publicLinks: [PublicLink] = []
    @Published var isLoadingPublicLinks = false
    @Published var publicLinksError: String?

    private let shareService = ShareService.shared
    private var modelContext: ModelContext?

    /// Initialize with optional model context for caching
    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

    // MARK: - Load Data

    /// Load all data for current tab
    func loadData() async {
        switch selectedTab {
        case .myShares:
            await loadOutgoingShares()
        case .sharedWithMe:
            await loadReceivedShares()
        case .publicLinks:
            await loadPublicLinks()
        }
    }

    /// Load outgoing shares (My Shares)
    func loadOutgoingShares(forceRefresh: Bool = false) async {
        isLoadingOutgoing = true
        outgoingError = nil

        // Try loading from cache first
        if !forceRefresh, let cached = loadCachedOutgoingShares(), !cached.isEmpty {
            outgoingShares = cached
            isLoadingOutgoing = false
            // Refresh in background
            Task {
                await refreshOutgoingShares()
            }
            return
        }

        await refreshOutgoingShares()
    }

    /// Refresh outgoing shares from server
    private func refreshOutgoingShares() async {
        do {
            let shares = try await shareService.listOutgoingShares()
            outgoingShares = shares
            cacheOutgoingShares(shares)
            isLoadingOutgoing = false
        } catch {
            outgoingError = error.localizedDescription
            isLoadingOutgoing = false
        }
    }

    /// Load received shares (Shared with Me)
    func loadReceivedShares(forceRefresh: Bool = false) async {
        isLoadingReceived = true
        receivedError = nil

        // Try loading from cache first
        if !forceRefresh, let cached = loadCachedReceivedShares(), !cached.isEmpty {
            receivedShares = cached
            isLoadingReceived = false
            // Refresh in background
            Task {
                await refreshReceivedShares()
            }
            return
        }

        await refreshReceivedShares()
    }

    /// Refresh received shares from server
    private func refreshReceivedShares() async {
        do {
            let shares = try await shareService.listReceivedShares()
            receivedShares = shares
            cacheReceivedShares(shares)
            isLoadingReceived = false
        } catch {
            receivedError = error.localizedDescription
            isLoadingReceived = false
        }
    }

    /// Load public links
    func loadPublicLinks(forceRefresh: Bool = false) async {
        isLoadingPublicLinks = true
        publicLinksError = nil

        // Try loading from cache first
        if !forceRefresh, let cached = loadCachedPublicLinks(), !cached.isEmpty {
            publicLinks = cached
            isLoadingPublicLinks = false
            // Refresh in background
            Task {
                await refreshPublicLinks()
            }
            return
        }

        await refreshPublicLinks()
    }

    /// Refresh public links from server
    private func refreshPublicLinks() async {
        do {
            let links = try await shareService.listPublicLinks()
            publicLinks = links
            cachePublicLinks(links)
            isLoadingPublicLinks = false
        } catch {
            publicLinksError = error.localizedDescription
            isLoadingPublicLinks = false
        }
    }

    // MARK: - Cache Management

    private func loadCachedOutgoingShares() -> [Share]? {
        guard let modelContext = modelContext else { return nil }

        let descriptor = FetchDescriptor<CachedShare>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        guard let cached = try? modelContext.fetch(descriptor) else { return nil }
        return cached.filter { !$0.isStale }.map { $0.toShare() }
    }

    private func cacheOutgoingShares(_ shares: [Share]) {
        guard let modelContext = modelContext else { return }

        // Clear old cached shares
        let descriptor = FetchDescriptor<CachedShare>()
        if let existing = try? modelContext.fetch(descriptor) {
            existing.forEach { modelContext.delete($0) }
        }

        // Cache new shares
        shares.forEach { share in
            let cached = CachedShare(from: share)
            modelContext.insert(cached)
        }

        try? modelContext.save()
    }

    private func loadCachedReceivedShares() -> [Share]? {
        // Same implementation as outgoing
        return loadCachedOutgoingShares()
    }

    private func cacheReceivedShares(_ shares: [Share]) {
        cacheOutgoingShares(shares)
    }

    private func loadCachedPublicLinks() -> [PublicLink]? {
        guard let modelContext = modelContext else { return nil }

        let descriptor = FetchDescriptor<CachedPublicLink>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        guard let cached = try? modelContext.fetch(descriptor) else { return nil }
        return cached.filter { !$0.isStale }.map { $0.toPublicLink() }
    }

    private func cachePublicLinks(_ links: [PublicLink]) {
        guard let modelContext = modelContext else { return }

        // Clear old cached links
        let descriptor = FetchDescriptor<CachedPublicLink>()
        if let existing = try? modelContext.fetch(descriptor) {
            existing.forEach { modelContext.delete($0) }
        }

        // Cache new links
        links.forEach { link in
            let cached = CachedPublicLink(from: link)
            modelContext.insert(cached)
        }

        try? modelContext.save()
    }

    // MARK: - Actions

    /// Delete a share
    func deleteShare(_ share: Share) async throws {
        try await shareService.deleteShare(id: share.id)
        outgoingShares.removeAll { $0.id == share.id }
    }

    /// Delete a public link
    func deletePublicLink(_ link: PublicLink) async throws {
        try await shareService.deletePublicLink(id: link.id)
        publicLinks.removeAll { $0.id == link.id }
    }
}
