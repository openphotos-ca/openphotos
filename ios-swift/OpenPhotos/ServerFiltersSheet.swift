import SwiftUI
import UIKit

/// A lightweight image loader for face thumbnails that attaches Authorization headers via AuthorizedHTTPClient.
private final class FaceThumbLoader: ObservableObject {
    static let shared = FaceThumbLoader()
    private init() {}
    private let cache = NSCache<NSString, UIImage>()

    func image(for personId: String, url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: personId as NSString) { return cached }
        // Disk cache first
        if let data = DiskImageCache.shared.readData(bucket: .faces, key: personId), let ui = UIImage(data: data) {
            cache.setObject(ui, forKey: personId as NSString)
            return ui
        }
        var req = URLRequest(url: url)
        do {
            let (data, _) = try await AuthorizedHTTPClient.shared.request(req)
            // Try as image; if SVG, skip (server returns SVG fallback sometimes)
            if let ui = UIImage(data: data) {
                _ = DiskImageCache.shared.write(bucket: .faces, key: personId, data: data, ext: "jpg")
                cache.setObject(ui, forKey: personId as NSString)
                return ui
            }
        } catch {}
        return nil
    }
}

/// RemoteFaceThumbView renders an authenticated face thumbnail image for a given person id.
/// Shared between Filters and Manage Faces screens.
struct RemoteFaceThumbView: View {
    let personId: String
    let size: CGFloat

    @State private var image: UIImage? = nil
    @ObservedObject private var loader = FaceThumbLoader.shared

    var body: some View {
        ZStack {
            Color(.systemGray6)
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.square").font(.system(size: size/3)).foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: personId) { await load() }
    }

    private func load() async {
        guard let url = ServerPhotosService.shared.getFaceThumbnailUrl(personId: personId) else { return }
        if let ui = await loader.image(for: personId, url: url) {
            await MainActor.run { self.image = ui }
        }
    }
}

/// Filters sheet for the server-backed Photos tab. Mirrors the web filters UX.
struct ServerFiltersSheet: View {
    @EnvironmentObject var viewModel: ServerGalleryViewModel
    @Binding var isPresented: Bool

    @State private var metadata: ServerFilterMetadata? = nil
    @State private var loading: Bool = false
    @State private var loadError: String? = nil

    var body: some View {
        NavigationView {
            List {
                facesSection
                timeRangeSection
                typeSection
                ratingSection
                locationSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear all") { clearAll() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
            .task { await fetchMetadata() }
        }
    }

    // MARK: - Sections

    private var facesSection: some View {
        Section(header: HStack { Text("Faces"); Spacer(); manageFacesButton }) {
            if loading && metadata == nil {
                HStack { ProgressView(); Text("Loading faces…").foregroundColor(.secondary) }
            } else if let faces = metadata?.faces, !faces.isEmpty {
                // Grid layout tuned for dense packing: 1px spacing and fixed height showing 3 rows.
                let faceSize: CGFloat = 80
                let labelHeight: CGFloat = 16
                let tileVSpacing: CGFloat = 2
                let rowSpacing: CGFloat = 1
                let rowsVisible = 3
                let visibleHeight = CGFloat(rowsVisible) * (faceSize + labelHeight + tileVSpacing) + CGFloat(rowsVisible - 1) * rowSpacing

                let columns = [ GridItem(.adaptive(minimum: faceSize), spacing: rowSpacing) ]

                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: rowSpacing) {
                        ForEach(faces, id: \.person_id) { f in
                            let selected = viewModel.selectedFaces.contains(f.person_id)
                            VStack(alignment: .leading, spacing: 2) {
                                RemoteFaceThumbView(personId: f.person_id, size: faceSize)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selected ? Color.purple : Color.clear, lineWidth: 2)
                                    )
                                    .cornerRadius(8)
                                Text("\(f.name ?? f.person_id) (\(f.photo_count))")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundColor(selected ? .purple : .primary)
                            }
                            .onTapGesture { toggleFace(f.person_id) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: visibleHeight)
            } else {
                Text("No faces found").foregroundColor(.secondary)
            }
        }
    }

    private var manageFacesButton: some View {
        Button("Manage") { /* placeholder per spec */ }
            .buttonStyle(.bordered)
            .font(.footnote)
    }

    private var timeRangeSection: some View {
        Section(header: HStack { Text("Time Range"); Spacer(); clearDatesHeaderButton }) {
            // Display Start and End pickers on their own rows with inline labels.
            DatePicker(
                "Start",
                selection: Binding(get: { viewModel.dateStart ?? Date() }, set: { viewModel.dateStart = $0 }),
                displayedComponents: [.date]
            )
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))

            DatePicker(
                "End",
                selection: Binding(get: { viewModel.dateEnd ?? Date() }, set: { viewModel.dateEnd = $0 }),
                displayedComponents: [.date]
            )
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        }
    }

    private var clearDatesHeaderButton: some View {
        Button("Clear dates") {
            viewModel.dateStart = nil
            viewModel.dateEnd = nil
        }
        .buttonStyle(.bordered)
        .font(.footnote)
    }

    private var typeSection: some View {
        Section(header: Text("Type")) {
            HStack(spacing: 8) {
                Toggle(isOn: $viewModel.typeScreenshot) { Text("Screenshots") }
                Toggle(isOn: $viewModel.typeLive) { Text("Live Photos") }
            }
        }
    }

    private var ratingSection: some View {
        Section(header: Text("Rating")) {
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { n in
                    Button(action: { viewModel.ratingMin = n }) {
                        Image(systemName: (viewModel.ratingMin ?? 0) >= n ? "star.fill" : "star")
                            .foregroundColor(.red)
                            .font(.system(size: 18, weight: .regular))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain) // Ensure tappable inside List rows
                    .padding(.vertical, 6)
                }
                Button("Clear") { viewModel.ratingMin = nil }
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
            }
        }
    }

    private var locationSection: some View {
        Section(header: Text("Location")) {
            Picker("Country", selection: Binding(get: { viewModel.country ?? "" }, set: { viewModel.country = $0.isEmpty ? nil : $0 })) {
                Text("Any").tag("")
                ForEach(metadata?.countries ?? [], id: \.self) { c in Text(c).tag(c) }
            }
            TextField("Province/State", text: Binding(get: { viewModel.region ?? "" }, set: { viewModel.region = $0.isEmpty ? nil : $0 }))
            Picker("City", selection: Binding(get: { viewModel.city ?? "" }, set: { viewModel.city = $0.isEmpty ? nil : $0 })) {
                Text("Any").tag("")
                ForEach(metadata?.cities ?? [], id: \.self) { c in Text(c).tag(c) }
            }
            Text("Note: Location filters are placeholders in v1.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions
    private func fetchMetadata() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let m = try await ServerPhotosService.shared.getFilterMetadata()
            await MainActor.run { self.metadata = m }
        } catch {
            await MainActor.run { self.loadError = error.localizedDescription }
        }
    }

    private func toggleFace(_ id: String) {
        if viewModel.selectedFaces.contains(id) { viewModel.selectedFaces.remove(id) }
        else { viewModel.selectedFaces.insert(id) }
    }

    private func clearAll() {
        viewModel.selectedFaces.removeAll()
        viewModel.dateStart = nil
        viewModel.dateEnd = nil
        viewModel.typeScreenshot = false
        viewModel.typeLive = false
        viewModel.ratingMin = nil
        viewModel.country = nil
        viewModel.region = nil
        viewModel.city = nil
    }
}
