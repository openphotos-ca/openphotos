import SwiftUI
import Photos

// MARK: - Timeline Grouping Models

private struct DayGroup: Identifiable {
    let id: Int
    let date: Date
    let assets: [PHAsset]
}

private struct MonthSection: Identifiable {
    let id: Int
    let monthDate: Date
    let dayGroups: [DayGroup]
}

private struct YearSection: Identifiable {
    let id: Int
    let year: Int
    let months: [MonthSection]
}

// MARK: - Photos Timeline View (Month headers with Day subgroups)

struct PhotosTimelineView: View {
    @EnvironmentObject var viewModel: GalleryViewModel
    @Environment(\.horizontalSizeClass) private var hSize
    // Reports minY in local space (negative when scrolled down) for header toggle
    var onScrollOffsetChange: ((CGFloat) -> Void)? = nil
    // Top spacer height inside the scrollable content to prevent header overlap (when header is overlaid)
    var topInset: CGFloat = 0

    private var sections: [YearSection] {
        buildSections(from: viewModel.filteredMedia, orderNewestFirst: viewModel.sortOption == .dateNewest)
    }

    private let spacing: CGFloat = 2
    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(minimum: 70, maximum: 250), spacing: 2), count: 4)

    private var showYearRail: Bool { hSize == .regular }
    private var years: [Int] { sections.map { $0.year } }
    @State private var showYearPicker = false
    @State private var activeYear: Int? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Match the grid's offset reporting: a zero-height probe at the top
                        // of the ScrollView content that reports its minY within a named
                        // local coordinate space. This yields 0 at rest and negative values
                        // as you scroll down, which is exactly what GalleryView.handleScroll
                        // expects.
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geo.frame(in: .named("LocalTimelineScroll")).minY
                            )
                        }
                        .frame(height: 0)

                        // Spacer equal to header height so content starts below the overlaid bars
                        Color.clear.frame(height: max(0, topInset))

                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(sections) { year in
                                YearAnchorView(year: year.year)
                                    .id("year-\(year.year)")

                                ForEach(year.months) { month in
                                    MonthHeaderView(date: month.monthDate)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 8)

                                    ForEach(month.dayGroups) { day in
                                        DayHeaderView(date: day.date)
                                            .padding(.horizontal, 16)
                                            .padding(.top, 6)

                                        LazyVGrid(columns: columns, spacing: spacing) {
                                            ForEach(Array(day.assets.enumerated()), id: \.element.localIdentifier) { _, asset in
                                                let columnsCount: CGFloat = 4
                                                let totalSpacing = spacing * (columnsCount - 1) + spacing * 2
                                                let size = ((UIScreen.main.bounds.width - totalSpacing) / columnsCount).rounded(.down)
                                                MediaThumbnailView(asset: asset, cellSize: size)
                                                    .environmentObject(viewModel)
                                            }
                                        }
                                        .padding(.horizontal, spacing)
                                    }
                                }
                            }
                        }
                        .padding(
                            .bottom,
                            (viewModel.isSelectionMode || !viewModel.selectedPhotos.isEmpty) ? 80 : 0
                        )
                    }
                }
                // Coordinate space used for year anchor tracking below; offset reporting uses the local probe above.
                .coordinateSpace(name: "LocalTimelineScroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { y in
                    onScrollOffsetChange?(y)
                }
                
                if showYearRail && !years.isEmpty {
                    YearRail(years: years, activeYear: activeYear) { year in
                        withAnimation(nil) { proxy.scrollTo("year-\(year)", anchor: .top) }
                    }
                    .padding(.trailing, 8)
                    .padding(.top, 100)
                }
            }
            .coordinateSpace(name: "TimelineScroll")
            .onPreferenceChange(YearPosKey.self) { positions in
                guard !positions.isEmpty else { return }
                let nonNeg = positions.filter { $0.minY >= 0 }
                let next: Int? = nonNeg.min(by: { $0.minY < $1.minY })?.year
                    ?? positions.max(by: { $0.minY < $1.minY })?.year
                if let yr = next, yr != activeYear {
                    DispatchQueue.main.async { if activeYear != yr { activeYear = yr } }
                }
            }
            // Scroll offset is reported via the UIScrollView spy inside the ScrollView content.
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
                    DispatchQueue.main.async { withAnimation(nil) { proxy.scrollTo("year-\(year)", anchor: .top) } }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func buildSections(from assets: [PHAsset], orderNewestFirst: Bool) -> [YearSection] {
        let calendar = Calendar.current
        var groups: [Int: [DateComponents: [DateComponents: [PHAsset]]]] = [:]

        for asset in assets {
            guard let d = asset.creationDate else { continue }
            let comps = calendar.dateComponents([.year, .month, .day], from: d)
            guard let y = comps.year, let m = comps.month, let day = comps.day else { continue }
            var yearDict = groups[y] ?? [:]
            let monthKey = DateComponents(year: y, month: m)
            var monthDict = yearDict[monthKey] ?? [:]
            let dayKey = DateComponents(year: y, month: m, day: day)
            var dayArray = monthDict[dayKey] ?? []
            dayArray.append(asset)
            monthDict[dayKey] = dayArray
            yearDict[monthKey] = monthDict
            groups[y] = yearDict
        }

        let yearSort: (Int, Int) -> Bool = { a, b in orderNewestFirst ? a > b : a < b }
        let monthSort: (DateComponents, DateComponents) -> Bool = { a, b in
            if let ad = Calendar.current.date(from: a), let bd = Calendar.current.date(from: b) {
                return orderNewestFirst ? ad > bd : ad < bd
            }
            return false
        }
        let daySort: (DateComponents, DateComponents) -> Bool = { a, b in
            if let ad = Calendar.current.date(from: a), let bd = Calendar.current.date(from: b) {
                return orderNewestFirst ? ad > bd : ad < bd
            }
            return false
        }

        var yearSections: [YearSection] = []
        for y in groups.keys.sorted(by: yearSort) {
            guard let monthDict = groups[y] else { continue }
            var monthSections: [MonthSection] = []
            for mKey in monthDict.keys.sorted(by: monthSort) {
                guard let days = monthDict[mKey] else { continue }
                let monthDate = Calendar.current.date(from: mKey) ?? Date()
                var dayGroups: [DayGroup] = []
                for dKey in days.keys.sorted(by: daySort) {
                    let dayDate = Calendar.current.date(from: dKey) ?? Date()
                    let orderedAssets = (days[dKey] ?? []).sorted { (a, b) in
                        let ad = a.creationDate ?? Date.distantPast
                        let bd = b.creationDate ?? Date.distantPast
                        return orderNewestFirst ? ad > bd : ad < bd
                    }
                    let dayId = (dKey.year ?? 0) * 10000 + (dKey.month ?? 0) * 100 + (dKey.day ?? 0)
                    dayGroups.append(DayGroup(id: dayId, date: dayDate, assets: orderedAssets))
                }
                let monthId = (mKey.year ?? 0) * 100 + (mKey.month ?? 0)
                monthSections.append(MonthSection(id: monthId, monthDate: monthDate, dayGroups: dayGroups))
            }
            yearSections.append(YearSection(id: y, year: y, months: monthSections))
        }
        return yearSections
    }
}

private struct MonthHeaderView: View {
    let date: Date
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; return f
    }()
    var body: some View { Text(Self.fmt.string(from: date)).font(.title3).fontWeight(.semibold) }
}

private struct DayHeaderView: View {
    let date: Date
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, EEE"; return f
    }()
    var body: some View { Text(Self.fmt.string(from: date)).font(.subheadline).foregroundColor(.secondary) }
}

private struct YearRail: View {
    let years: [Int]
    let activeYear: Int?
    let onTap: (Int) -> Void
    var body: some View {
        VStack(spacing: 6) {
            ForEach(years, id: \.self) { year in
                let isActive = (activeYear == year)
                Button(action: { onTap(year) }) {
                    Text(String(year))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isActive ? .white : .blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(isActive ? Color.blue : Color.blue.opacity(0.08)))
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

// MARK: - Year Picker Sheet for compact width
private struct YearPickerSheet: View {
    let years: [Int]
    let activeYear: Int?
    let onPick: (Int) -> Void
    private var grid: [GridItem] { Array(repeating: GridItem(.flexible(minimum: 60, maximum: 160), spacing: 12), count: 3) }
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: grid, spacing: 12) {
                    ForEach(years, id: \.self) { year in
                        let isActive = (activeYear == year)
                        Button(action: { onPick(year) }) {
                            Text(String(year))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(isActive ? .white : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(RoundedRectangle(cornerRadius: 10).fill(isActive ? Color.blue : Color(.systemGray6)))
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

// MARK: - Scroll Spy: Year anchor tracking
private struct YearPos: Equatable { let year: Int; let minY: CGFloat }
private struct YearPosKey: PreferenceKey { static var defaultValue: [YearPos] = []; static func reduce(value: inout [YearPos], nextValue: () -> [YearPos]) { value.append(contentsOf: nextValue()) } }
private struct YearAnchorView: View {
    let year: Int
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: YearPosKey.self, value: [YearPos(year: year, minY: geo.frame(in: .named("TimelineScroll")).minY)])
        }
        .frame(height: 1)
    }
}
