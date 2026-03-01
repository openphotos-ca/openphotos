import SwiftUI

/// Full-screen "Manage Faces" UI for the server-backed Photos tab.
/// Mirrors the web client's faces/manage page:
/// - Grid of persons with face thumbnails, names, and photo counts
/// - Merge flow (select → choose primary → edit → submit)
/// - Delete action for one or more persons
/// - Optional single-person edit without merge
/// - Preview of items containing the active face
struct ManageFacesView: View {
    @Environment(\.dismiss) private var dismiss

    /// View model bound to the server's faces and photos APIs.
    @StateObject private var viewModel = ManageFacesViewModel()

    /// Local alert toggle for delete confirmation.
    @State private var showDeleteAlert: Bool = false

    /// Layout constants for the faces grid.
    private let faceSize: CGFloat = 96

    private var faceGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: faceSize), spacing: 8)]
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                toolbar
                Divider()
                facesGrid
                Divider()
                previewSection
            }
        }
        .task {
            // Initial load of persons from the server.
            await viewModel.loadPersons()
        }
        .task(id: viewModel.activePersonId) {
            // Refresh preview items whenever the active face changes.
            await viewModel.loadPreviewItemsIfNeeded()
        }
        .alert("Delete faces?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteSelectedPersons()
                }
            }
        } message: {
            Text("This will delete \(viewModel.selectedCount) face\(viewModel.selectedCount == 1 ? "" : "s"). This cannot be undone.")
        }
    }

    // MARK: - Header

    /// Top header row with back button, title, total count, and selection count.
    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .strokeBorder(Color(.separator))
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Manage Faces")
                    .font(.headline)
                Text("\(viewModel.totalCount) total")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if viewModel.selectedCount > 0 {
                Text("\(viewModel.selectedCount) selected")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.98))
        .overlay(
            Divider()
                .offset(y: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Toolbar

    /// Secondary toolbar row with context-specific actions based on the current mode.
    private var toolbar: some View {
        HStack(spacing: 8) {
            switch viewModel.mode {
            case .idle:
                Button {
                    viewModel.startMerge()
                } label: {
                    Text("Merge Faces")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.selectedCount < 2)

                Button {
                    showDeleteAlert = true
                } label: {
                    Text("Delete")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.selectedCount == 0)

                if let error = viewModel.loadError {
                    Spacer()
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

            case .mergeSelect:
                Text("Select at least two faces to merge")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") {
                    viewModel.resetMergeFlow()
                }
                .buttonStyle(.bordered)
                Button("Next") {
                    viewModel.nextFromSelect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedCount < 2)

            case .choosePrimary:
                Text("Pick the face to keep as primary")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") {
                    viewModel.resetMergeFlow()
                }
                .buttonStyle(.bordered)
                Button("Next") {
                    viewModel.nextFromChoosePrimary()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.primaryId == nil)

            case .edit:
                editToolbarContent

            case .merging:
                Text("Merging…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    /// Toolbar content for the edit step (name and birth date fields).
    private var editToolbarContent: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Name")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                TextField("Optional name", text: $viewModel.editName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
            }

            HStack(spacing: 4) {
                Text("Birth")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                TextField("YYYY-MM-DD", text: $viewModel.editBirthDate)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 130)
            }

            Spacer()

            Button("Cancel") {
                viewModel.resetMergeFlow()
            }
            .buttonStyle(.bordered)

            Button("Submit") {
                Task {
                    await viewModel.submitMergeOrSave()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Faces grid

    /// Grid of face tiles (thumbnail + label + count) with selection and primary styling.
    private var facesGrid: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.persons.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading faces…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.top, 32)
            } else if viewModel.persons.isEmpty {
                Text("No faces found")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.top, 32)
            } else {
                // In merge flows, mirror the web behavior by restricting the grid
                // to only the faces that are part of the current selection.
                let personsToRender: [ServerPhotosService.ServerPerson] = {
                    switch viewModel.mode {
                    case .choosePrimary, .edit:
                        let selectedIds = viewModel.selection
                        let filtered = viewModel.persons.filter { selectedIds.contains($0.person_id) }
                        // Fallback to full list if selection is empty for any reason.
                        return filtered.isEmpty ? viewModel.persons : filtered
                    default:
                        return viewModel.persons
                    }
                }()

                LazyVGrid(columns: faceGridColumns, spacing: 10) {
                    ForEach(personsToRender, id: \.person_id) { person in
                        faceTile(for: person)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    /// Single face tile that handles selection, primary highlighting, and editing.
    private func faceTile(for person: ServerPhotosService.ServerPerson) -> some View {
        let isSelected = viewModel.selection.contains(person.person_id)
        let isPrimary = (viewModel.primaryId == person.person_id)

        // Choose border color based on current mode.
        let borderColor: Color = {
            switch viewModel.mode {
            case .choosePrimary, .edit:
                return isPrimary ? Color.accentColor : Color(.separator)
            default:
                return isSelected ? Color.accentColor : Color(.separator)
            }
        }()

        let borderWidth: CGFloat = (isSelected || isPrimary) ? 2 : 1

        // Stronger highlight color used for overlays and checkmarks when selected/primary.
        let highlightColor: Color = isPrimary ? Color.accentColor : Color.accentColor

        /// Whether this tile should receive the strong highlight (background/shadow) treatment.
        /// In the "choose primary" step we only emphasize the current primary, even if multiple
        /// faces remain selected from the prior step. In other modes, any selected/primary face
        /// is emphasized.
        let isActivelyHighlighted: Bool = {
            switch viewModel.mode {
            case .choosePrimary, .edit:
                return isPrimary
            default:
                return isSelected || isPrimary
            }
        }()

        let name = (person.display_name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? person.person_id
        let count = person.face_count ?? 0

        return VStack(spacing: 4) {
            Button {
                // Depending on the mode, tapping the thumbnail selects or sets primary.
                switch viewModel.mode {
                case .choosePrimary:
                    viewModel.setPrimary(personId: person.person_id)
                default:
                    viewModel.toggleSelection(personId: person.person_id)
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    // Base face thumbnail with a stronger visual treatment when active.
                    RemoteFaceThumbView(personId: person.person_id, size: faceSize)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isActivelyHighlighted ? highlightColor.opacity(0.18) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(borderColor, lineWidth: borderWidth)
                        )
                        .cornerRadius(10)
                        .shadow(color: isActivelyHighlighted ? highlightColor.opacity(0.35) : Color.clear,
                                radius: isActivelyHighlighted ? 4 : 0,
                                x: 0,
                                y: isActivelyHighlighted ? 2 : 0)

                    // Checkmark badge in the top‑right corner.
                    // In the "choose primary" step, only the chosen primary gets a checkmark badge.
                    // In all other modes, any selected/primary face shows the badge.
                    Group {
                        switch viewModel.mode {
                        case .choosePrimary, .edit:
                            if isPrimary {
                                checkmarkBadge(color: highlightColor)
                            }
                        default:
                            if isSelected || isPrimary {
                                checkmarkBadge(color: highlightColor)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                // Label row opens the single-person edit flow.
                viewModel.beginSingleEdit(personId: person.person_id)
            } label: {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                    if count > 0 {
                        Text("(\(count))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    /// Small circular checkmark badge used to indicate selection/primary on a face tile.
    private func checkmarkBadge(color: Color) -> some View {
        ZStack {
            Circle()
                .fill(Color.white)
            Circle()
                .stroke(color, lineWidth: 2)
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(color)
        }
        .frame(width: 24, height: 24)
        .padding(4)
    }

    // MARK: - Preview section

    /// Lower section showing items for the currently active face, if any.
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let active = viewModel.activePersonId {
                    Text("Items for \(active)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text("Select a face to preview items")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if let _ = viewModel.activePersonId {
                if viewModel.isLoadingPreview {
                    Text("Loading items…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                } else if viewModel.previewItems.isEmpty {
                    Text("No items found for this face.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                } else {
                    let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(viewModel.previewItems.prefix(10), id: \.asset_id) { photo in
                            let columnsCount: CGFloat = 5
                            let spacing: CGFloat = 4
                            let totalSpacing = spacing * (columnsCount - 1) + spacing * 2
                            let size = ((UIScreen.main.bounds.width - totalSpacing) / columnsCount).rounded(.down)
                            RemoteThumbnailView(photo: photo, cellSize: size)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }
}
