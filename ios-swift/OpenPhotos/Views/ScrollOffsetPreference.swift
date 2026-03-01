import SwiftUI

/// A simple preference key to propagate vertical scroll offset (minY in a named coordinate space).
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// Emits the current minY frame value in the given coordinate space via ScrollOffsetPreferenceKey.
    func reportScrollOffset(in space: CoordinateSpace = .global) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: geo.frame(in: space).minY)
            }
        )
    }
}

/// Preference key for measuring a view's height.
struct ViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
