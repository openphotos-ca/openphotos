import Foundation
import SwiftUI

/// View model powering the server-backed "Manage Faces" experience.
/// Mirrors the web client's /faces/manage page:
/// - Loads all known persons from `/api/faces`
/// - Supports multi-select and merge flows (select → choose primary → edit → submit)
/// - Allows editing a single person (name, birth date) without merging
/// - Supports deleting one or more persons
/// - Exposes a lightweight preview of items for the currently active person
@MainActor
final class ManageFacesViewModel: ObservableObject {
    /// High-level interaction mode for the toolbar and grid.
    enum Mode {
        /// Default state: user can tap faces to select and then choose actions.
        case idle
        /// User is explicitly selecting multiple faces to merge.
        case mergeSelect
        /// User is choosing which selected face should be kept as the primary.
        case choosePrimary
        /// User is editing name / birth date prior to merge or for a single person.
        case edit
        /// Merge is in flight; UI should show a non-interactive "Merging…" status.
        case merging
    }

    // MARK: - Published state

    /// All persons returned from the server's `/api/faces` endpoint.
    @Published var persons: [ServerPhotosService.ServerPerson] = []

    /// Global loading flag while the persons list is being refreshed.
    @Published var isLoading: Bool = false

    /// Optional user-facing error message when loading faces fails.
    @Published var loadError: String?

    /// Current interaction mode (toolbar + grid behavior).
    @Published var mode: Mode = .idle

    /// Set of selected person ids (used for merge and delete actions).
    @Published var selection: Set<String> = []

    /// The person id chosen as the "primary" during a merge.
    @Published var primaryId: String?

    /// Editable display name for the primary person.
    @Published var editName: String = ""

    /// Editable birth date (ISO `YYYY-MM-DD` or empty) for the primary person.
    @Published var editBirthDate: String = ""

    /// The person id whose items should be previewed in the lower grid.
    @Published var activePersonId: String?

    /// Items used for the preview grid; derived from `/api/photos` with `filter_faces`.
    @Published var previewItems: [ServerPhoto] = []

    /// Loading flag specifically for the preview items section.
    @Published var isLoadingPreview: Bool = false

    // MARK: - Private state

    /// Tracks the most recently tapped selection to reproduce a sensible "active" face.
    private var lastSelectedPersonId: String?

    /// Service wrapper for server photo / faces APIs.
    private let service = ServerPhotosService.shared

    /// Maximum number of preview items to show for a face (matches web rough behavior).
    private let previewLimit: Int = 30

    // MARK: - Derived values

    /// Total count of faces currently loaded.
    var totalCount: Int { persons.count }

    /// Number of faces currently selected.
    var selectedCount: Int { selection.count }

    /// Convenience accessor to resolve a person by id from the loaded list.
    func person(for id: String) -> ServerPhotosService.ServerPerson? {
        persons.first(where: { $0.person_id == id })
    }

    // MARK: - Loading

    /// Load or refresh the persons list from the server.
    /// Resets merge/edit state so the UI always reflects the latest server truth.
    func loadPersons() async {
        if isLoading { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let list = try await service.getPersons()
            // Sort by human-friendly label (display name, falling back to id).
            let sorted = list.sorted { lhs, rhs in
                let ln = lhs.display_name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rn = rhs.display_name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let left = (ln?.isEmpty == false ? ln! : lhs.person_id)
                let right = (rn?.isEmpty == false ? rn! : rhs.person_id)
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
            persons = sorted
        } catch {
            persons = []
            loadError = error.localizedDescription
        }

        // Reset selection/merge state on refresh.
        selection.removeAll()
        primaryId = nil
        editName = ""
        editBirthDate = ""
        lastSelectedPersonId = nil
        activePersonId = nil
        previewItems = []
        mode = .idle
    }

    // MARK: - Selection & active person

    /// Toggle selection state for a given person id and recompute the active person.
    func toggleSelection(personId: String) {
        if selection.contains(personId) {
            selection.remove(personId)
            if lastSelectedPersonId == personId {
                // Fall back to any remaining selection (order is not guaranteed).
                lastSelectedPersonId = selection.first
            }
        } else {
            selection.insert(personId)
            lastSelectedPersonId = personId
        }

        if selection.isEmpty {
            primaryId = nil
        }

        recomputeActivePerson()
    }

    /// Explicitly mark a person as the primary merge target.
    func setPrimary(personId: String) {
        primaryId = personId
        // Ensure the primary is part of the selection set as well.
        selection.insert(personId)
        recomputeActivePerson()
    }

    /// Reset all merge-related state and clear selection.
    func resetMergeFlow() {
        mode = .idle
        selection.removeAll()
        primaryId = nil
        editName = ""
        editBirthDate = ""
        lastSelectedPersonId = nil
        activePersonId = nil
        previewItems = []
    }

    /// Recompute which face should be treated as "active" for preview.
    private func recomputeActivePerson() {
        let candidate = primaryId ?? lastSelectedPersonId
        if candidate != activePersonId {
            activePersonId = candidate
        }
        // If nothing is selected, clear the preview.
        if activePersonId == nil {
            previewItems = []
        }
    }

    // MARK: - Merge flow helpers

    /// Start the merge flow. Preserves any existing selection and chooses the next mode.
    func startMerge() {
        primaryId = nil
        if selection.count >= 2 {
            mode = .choosePrimary
        } else {
            mode = .mergeSelect
        }
    }

    /// Advance from "select faces to merge" to "choose primary" once enough faces are selected.
    func nextFromSelect() {
        guard selection.count >= 2 else { return }
        primaryId = nil
        mode = .choosePrimary
    }

    /// Advance from "choose primary" into the edit step, pre-filling name and birth date.
    func nextFromChoosePrimary() {
        guard let primaryId = primaryId else { return }

        // Gather selected persons and primary.
        let selectedPersons = persons.filter { selection.contains($0.person_id) }
        guard !selectedPersons.isEmpty else { return }
        let primary = person(for: primaryId)

        // Prefer a non-default name on the primary; otherwise any non-default among selected.
        let primaryName = getDisplayName(primary)
        var nameCandidate: String? = isDefaultName(primaryName) ? nil : primaryName
        if nameCandidate == nil {
            for p in selectedPersons {
                let candidate = getDisplayName(p)
                if !isDefaultName(candidate) {
                    nameCandidate = candidate
                    break
                }
            }
        }

        // Birth date preference: primary, then any selected with a birth date.
        let birthCandidate = primary?.birth_date ?? selectedPersons.first(where: { $0.birth_date != nil })?.birth_date

        editName = (nameCandidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let birthCandidate {
            // Server uses ISO timestamps; keep only the YYYY-MM-DD portion if present.
            editBirthDate = String(birthCandidate.prefix(10))
        } else {
            editBirthDate = ""
        }

        mode = .edit
    }

    /// Begin editing a single person outside of the merge flow.
    /// This reuses the same edit state and submit handler, but with zero merge sources.
    func beginSingleEdit(personId: String) {
        selection = [personId]
        primaryId = personId
        lastSelectedPersonId = personId
        let p = person(for: personId)
        editName = getDisplayName(p)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let b = p?.birth_date {
            editBirthDate = String(b.prefix(10))
        } else {
            editBirthDate = ""
        }
        recomputeActivePerson()
        mode = .edit
    }

    /// Return a human-friendly display name for a person, if available.
    private func getDisplayName(_ person: ServerPhotosService.ServerPerson?) -> String? {
        guard let p = person else { return nil }
        let trimmed = p.display_name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Treat purely numeric ids like `p123` as "default" and not user-provided.
    private func isDefaultName(_ name: String?) -> Bool {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return true }
        // Match the web behavior: names of the form "p<number>" are auto-generated.
        let pattern = "^p\\d+$"
        return raw.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Actions

    /// Submit the current merge/edit operation.
    /// - If multiple faces are selected, merges them into the primary.
    /// - If only a single face is selected, only updates its metadata.
    func submitMergeOrSave() async {
        guard let primaryId = primaryId else { return }

        // Determine which person ids should be merged into the primary.
        let sources = selection.filter { $0 != primaryId }

        if sources.isEmpty && editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && editBirthDate.isEmpty {
            // Nothing to do: no merge and no metadata changes.
            mode = .edit
            return
        }

        mode = .merging
        do {
            // Perform merge when there are additional sources.
            if !sources.isEmpty {
                try await service.mergeFaces(targetPersonId: primaryId, sourcePersonIds: Array(sources))
            }

            // Apply updated metadata if fields are provided.
            let trimmedName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
            let namePayload = trimmedName.isEmpty ? nil : trimmedName
            let birthPayload = editBirthDate.isEmpty ? nil : editBirthDate
            if namePayload != nil || birthPayload != nil {
                try await service.updatePerson(personId: primaryId, displayName: namePayload, birthDate: birthPayload)
            }

            let totalMerged = sources.count + 1
            let label = sources.isEmpty ? "Updated face" : "Merged \(totalMerged) faces"
            ToastManager.shared.show(label)

            // Refresh list and reset local state.
            await loadPersons()
        } catch {
            // Keep the user in edit mode so they can adjust their inputs.
            mode = .edit
            let msg = error.localizedDescription.isEmpty ? "Merge failed" : "Merge failed: \(error.localizedDescription)"
            ToastManager.shared.show(msg)
        }
    }

    /// Delete all currently selected persons.
    func deleteSelectedPersons() async {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }

        do {
            try await service.deletePersons(personIds: ids)
            let suffix = ids.count == 1 ? "" : "s"
            ToastManager.shared.show("Deleted \(ids.count) face\(suffix)")
            await loadPersons()
        } catch {
            let msg = error.localizedDescription.isEmpty ? "Delete failed" : "Delete failed: \(error.localizedDescription)"
            ToastManager.shared.show(msg)
        }
    }

    /// Load preview items for the currently active person, if any.
    func loadPreviewItemsIfNeeded() async {
        guard let personId = activePersonId else {
            previewItems = []
            return
        }
        if isLoadingPreview { return }
        isLoadingPreview = true
        defer { isLoadingPreview = false }

        do {
            var query = ServerPhotoListQuery()
            query.page = 1
            query.limit = previewLimit
            // Limit by faces: match the web's filter behavior.
            query.filter_faces = personId
            query.filter_faces_mode = "any"
            let res = try await service.listPhotos(query: query)
            previewItems = Array(res.photos.prefix(previewLimit))
        } catch {
            // Surface a generic error via toast but keep the UI usable.
            let msg = error.localizedDescription.isEmpty ? "Failed to load items" : "Failed to load items: \(error.localizedDescription)"
            ToastManager.shared.show(msg)
            previewItems = []
        }
    }
}

