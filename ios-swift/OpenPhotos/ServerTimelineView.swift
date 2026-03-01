import SwiftUI

// MARK: - Server Timeline (Rewritten)
//
// This file implements the server-backed Photos Timeline layout from scratch,
// preserving the external interface (props/callbacks) while replacing the
// internal structure for clarity, reliability, and maintainability.
//
// Key design points:
// - Single source of scroll truth via ScrollViewOffsetSpy (UIScrollView KVO).
// - Top inset spacer lives inside the ScrollView to avoid overlay collisions.
// - Year → Month → Day grouping with headers and a 4-column grid of tiles.
// - Year rail on regular width, Year picker sheet on compact width.
// - Selection overlays preserved; infinite scroll trigger near end of each day.

// MARK: Models used for grouping (private)
private struct DayGroup: Identifiable { let id: Int; let date: Date; let items: [ServerPhoto] }
private struct MonthSection: Identifiable { let id: Int; let monthDate: Date; let days: [DayGroup] }
private struct YearSection: Identifiable { let id: Int; let year: Int; let months: [MonthSection] }

/// Server timeline mirrors the local timeline semantics (month headers with day subgroups),
/// but uses server data (ServerPhoto) and emits scroll offset changes upstream so the parent
/// can show/hide the header.
struct ServerTimelineView: View {
    // Input data
    let photos: [ServerPhoto]
    /// Optional full year list (e.g., from `/api/buckets/years`). When non-empty, the year rail/picker
    /// uses this instead of deriving years from the currently-loaded `photos` window.
    var availableYears: [Int] = []
    /// Called when the user picks a year that is not currently loaded in `photos` (no year anchor yet).
    /// The parent can respond by loading the appropriate page window and reloading.
    var onPickYear: ((Int) -> Void)? = nil

    // Layout integration
    // Spacer height (in points) placed at top of scroll content to ensure tiles start below the
    // overlaid header. When the header hides, parent passes 0; when visible, parent passes the
    // measured height.
    var topInset: CGFloat = 0

    // Selection state (owned by parent)
    var selectionBarVisible: Bool = false
    var isSelectionMode: Bool = false
    var selected: Set<String> = []

    // Callbacks
    var onToggleSelection: ((String) -> Void)? = nil
    var onOpen: ((ServerPhoto) -> Void)? = nil
    var onNearEnd: (() -> Void)? = nil
    var onScrollOffsetChange: ((CGFloat) -> Void)? = nil
    var onRefresh: (() async -> Void)? = nil

    // Environment
    @Environment(\.horizontalSizeClass) private var hSize

    // Layout constants
    private let spacing: CGFloat = 2
    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(minimum: 70, maximum: 250), spacing: 2), count: 4)

    // Derived (grouped) sections (memoized to avoid recomputation during scroll)
    @State private var sections: [YearSection] = []
    @State private var groupingToken: Int = 0
    private var showYearRail: Bool { hSize == .regular }
    private var loadedYears: [Int] { sections.map { $0.year } }
    private var years: [Int] { !availableYears.isEmpty ? availableYears : loadedYears }

    // UI state
    @State private var showYearPicker = false
    @State private var activeYear: Int? = nil
    @State private var pendingScrollYear: Int? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Offset reporting via Geometry preference in the ScrollView's own coordinate space.
                        // Reports minY which goes negative as you scroll down.
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geo.frame(in: .named("TLScroll")).minY
                            )
                        }
                        .frame(height: 0)
                        
                        // Spacer equal to header height so content starts below the overlaid bars
                        Color.clear.frame(height: max(0, topInset))

                        // Timeline sections
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(sections) { year in
                                YearAnchorView(year: year.year)
                                    .id("year-\(year.year)")

                                ForEach(year.months) { month in
                                    MonthHeader(date: month.monthDate)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 8)

                                    ForEach(month.days) { day in
                                        DayHeader(date: day.date)
                                            .padding(.horizontal, 16)
                                            .padding(.top, 6)

                                        LazyVGrid(columns: columns, spacing: spacing) {
                                            ForEach(Array(day.items.enumerated()), id: \.element.asset_id) { idx, p in
                                                let columnsCount: CGFloat = 4
                                                let totalSpacing = spacing * (columnsCount - 1) + spacing * 2
                                                let size = ((UIScreen.main.bounds.width - totalSpacing) / columnsCount).rounded(.down)

                                                RemoteThumbnailView(photo: p, cellSize: size)
                                                    .overlay(alignment: .topTrailing) {
                                                        if isSelectionMode {
                                                            let isSel = selected.contains(p.asset_id)
                                                            ZStack {
                                                                Circle()
                                                                    .fill(isSel ? Color.white : Color.black.opacity(0.35))
                                                                    .frame(width: 26, height: 26)
                                                                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                                                                    .foregroundColor(isSel ? .blue : .white)
                                                                    .font(.system(size: 18, weight: .semibold))
                                                            }
                                                            .padding(6)
                                                            .allowsHitTesting(false)
                                                        }
                                                    }
                                                    .onTapGesture {
                                                        if isSelectionMode { onToggleSelection?(p.asset_id) }
                                                        else { onOpen?(p) }
                                                    }
                                                    // Near-end trigger for paging: when any day's items approach
                                                    .onAppear {
                                                        if idx >= day.items.count - 4 { onNearEnd?() }
                                                    }
                                            }
                                        }
                                        .padding(.horizontal, spacing)
                                    }
                                }
                            }
                        }
                        // Reserve space for selection bar if visible to avoid overlap
                        .padding(.bottom, selectionBarVisible ? 80 : 0)
                    }
                }
                .refreshable {
                    if let onRefresh {
                        await onRefresh()
                    }
                }
                // Secondary coordinate space for year anchor tracking (independent from KVO spy)
                .coordinateSpace(name: "TLScroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { minY in
                    // Transform to match parent convention: y increases as user scrolls down.
                    let y = max(0, -minY)
                    // Avoid SwiftUI "Modifying state during view update" warnings by deferring callbacks.
                    DispatchQueue.main.async { onScrollOffsetChange?(y) }
                }
                .onPreferenceChange(YearPosKey.self) { positions in
                    guard !positions.isEmpty else { return }
                    // Pick the year whose anchor is nearest to top (>= 0); fallback to farthest above
                    let nonNeg = positions.filter { $0.minY >= 0 }
                    let next: Int? = nonNeg.min(by: { $0.minY < $1.minY })?.year
                        ?? positions.max(by: { $0.minY < $1.minY })?.year
                    guard let yr = next else { return }
                    // Defer to avoid SwiftUI "Modifying state during view update" warnings.
                    DispatchQueue.main.async {
                        if yr != activeYear { activeYear = yr }
                    }
                }

                // Year rail (regular width)
                if showYearRail && !years.isEmpty {
                    YearRail(years: years, activeYear: activeYear) { year in
                        handleYearSelection(year, proxy: proxy)
                    }
                    .padding(.trailing, 8)
                    .padding(.top, 100)
                }
            }
            // Year picker (compact width)
            .overlay(alignment: .bottomTrailing) {
                if !showYearRail && !years.isEmpty {
                    Button { showYearPicker = true } label: {
                        HStack(spacing: 6) { Image(systemName: "calendar"); Text("Years") }
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(Color(.systemBackground))
                                    .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                            )
                    }
                    .padding(.trailing, 12)
                    .padding(.bottom, 16)
                }
            }
            .sheet(isPresented: $showYearPicker) {
                YearPickerSheet(years: years, activeYear: activeYear) { year in
                    showYearPicker = false
                    DispatchQueue.main.async { handleYearSelection(year, proxy: proxy) }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: loadedYears) { _ in
                guard let yr = pendingScrollYear else { return }
                guard loadedYears.contains(yr) else { return }
                let target = yr
                DispatchQueue.main.async {
                    guard pendingScrollYear == target else { return }
                    pendingScrollYear = nil
                    withAnimation(nil) { proxy.scrollTo("year-\(target)", anchor: .top) }
                }
            }
        }
        // Build sections on first appear and whenever photo source changes.
        // Grouping can be expensive for large result sets; compute off the main thread.
        .onAppear { rebuildSections(photos) }
        .onChange(of: photos) { rebuildSections($0) }
    }

    // MARK: Grouping
    private func handleYearSelection(_ year: Int, proxy: ScrollViewProxy) {
        // If we already have the year loaded, this is a pure scroll.
        if loadedYears.contains(year) {
            withAnimation(nil) { proxy.scrollTo("year-\(year)", anchor: .top) }
            return
        }

        // Otherwise ask the parent to load that year (e.g., by loading the matching page window).
        if pendingScrollYear == year { return }
        pendingScrollYear = year
        onPickYear?(year)
    }

    private func rebuildSections(_ items: [ServerPhoto]) {
        groupingToken += 1
        let token = groupingToken
        let snapshot = items

        // First render: compute synchronously for small sets to avoid a blank timeline.
        if sections.isEmpty, snapshot.count <= 300 {
            sections = groupPhotos(snapshot)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let built = groupPhotos(snapshot)
            DispatchQueue.main.async {
                guard token == groupingToken else { return }
                sections = built
            }
        }
    }

    private func groupPhotos(_ items: [ServerPhoto]) -> [YearSection] {
        let cal = Calendar.current
        // Build nested grouping: [year: [monthComponents: [dayComponents: [ServerPhoto]]]]
        var grouped: [Int: [DateComponents: [DateComponents: [ServerPhoto]]]] = [:]
        for p in items {
            let d = Date(timeIntervalSince1970: TimeInterval(p.created_at))
            let comps = cal.dateComponents([.year, .month, .day], from: d)
            guard let y = comps.year, let m = comps.month, let day = comps.day else { continue }

            var yearDict = grouped[y] ?? [:]
            let monthKey = DateComponents(year: y, month: m)
            var monthDict = yearDict[monthKey] ?? [:]
            let dayKey = DateComponents(year: y, month: m, day: day)
            var arr = monthDict[dayKey] ?? []
            arr.append(p)
            monthDict[dayKey] = arr
            yearDict[monthKey] = monthDict
            grouped[y] = yearDict
        }

        func date(_ dc: DateComponents) -> Date { cal.date(from: dc) ?? .distantPast }
        func monthId(_ dc: DateComponents) -> Int { (dc.year ?? 0) * 100 + (dc.month ?? 0) }
        func dayId(_ dc: DateComponents) -> Int { (dc.year ?? 0) * 10000 + (dc.month ?? 0) * 100 + (dc.day ?? 0) }
        let years = grouped.keys.sorted(by: >) // newest year first

        var out: [YearSection] = []
        for y in years {
            guard let monthDict = grouped[y] else { continue }
            let months: [MonthSection] = monthDict.keys
                .sorted { date($0) > date($1) } // newest month first
                .map { mk in
                    let monthDate = date(mk)
                    let days: [DayGroup] = (monthDict[mk] ?? [:]).keys
                        .sorted { date($0) > date($1) } // newest day first
                        .map { dk in
                            let dayDate = date(dk)
                            // Within day: newest items first
                            let ordered = (monthDict[mk]?[dk] ?? []).sorted { $0.created_at > $1.created_at }
                            return DayGroup(id: dayId(dk), date: dayDate, items: ordered)
                        }
                    return MonthSection(id: monthId(mk), monthDate: monthDate, days: days)
                }
            out.append(YearSection(id: y, year: y, months: months))
        }
        return out
    }
}

// MARK: - Headers & Year Rail
private struct MonthHeader: View {
    let date: Date
    private static let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; return f }()
    var body: some View { Text(Self.f.string(from: date)).font(.title3).fontWeight(.semibold) }
}

private struct DayHeader: View {
    let date: Date
    private static let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, EEE"; return f }()
    var body: some View { Text(Self.f.string(from: date)).font(.subheadline).foregroundColor(.secondary) }
}

private struct YearRail: View {
    let years: [Int]
    let activeYear: Int?
    let onTap: (Int) -> Void
    var body: some View {
        VStack(spacing: 6) {
            ForEach(years, id: \.self) { y in
                let active = (activeYear == y)
                Button(action: { onTap(y) }) {
                    Text(String(y))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(active ? .white : .blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(active ? Color.blue : Color.blue.opacity(0.08)))
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground).opacity(0.85))
                .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
        )
    }
}

private struct YearPickerSheet: View {
    let years: [Int]
    let activeYear: Int?
    let onPick: (Int) -> Void
    private var grid: [GridItem] { Array(repeating: GridItem(.flexible(minimum: 60, maximum: 160), spacing: 12), count: 3) }
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: grid, spacing: 12) {
                    ForEach(years, id: \.self) { y in
                        let active = (activeYear == y)
                        Button(action: { onPick(y) }) {
                            Text(String(y))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(active ? .white : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(RoundedRectangle(cornerRadius: 10).fill(active ? Color.blue : Color(.systemGray6)))
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Jump to Year")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Year anchor tracking (separate from KVO offset)
private struct YearPos: Equatable { let year: Int; let minY: CGFloat }
private struct YearPosKey: PreferenceKey {
    static var defaultValue: [YearPos] = []
    static func reduce(value: inout [YearPos], nextValue: () -> [YearPos]) { value.append(contentsOf: nextValue()) }
}
private struct YearAnchorView: View {
    let year: Int
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: YearPosKey.self, value: [YearPos(year: year, minY: geo.frame(in: .named("TLScroll")).minY)])
        }
        .frame(height: 1)
    }
}
