//
//  BottomBarEnvironment.swift
//  Life247
//
//  Created by Andrew Robertson on 1/17/26.
//

import SwiftUI

/// Environment key for the bottom bar height
/// This allows child views (including those pushed via NavigationLink) to know
/// how much space the bottom bar occupies and adjust their content accordingly.
private struct BottomBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The height of the bottom bar that should be accounted for in content layouts.
    /// Views can use this to add appropriate bottom padding or content margins.
    var bottomBarHeight: CGFloat {
        get { self[BottomBarHeightKey.self] }
        set { self[BottomBarHeightKey.self] = newValue }
    }
}

/// PreferenceKey for BottomBar to report its current height (dynamic with detents)
struct BottomBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Apply bottom safe area for views that need to clear the bottom bar.
    /// Use this on ScrollViews or List contents to ensure they scroll above the bar.
    func bottomBarPadding() -> some View {
        modifier(BottomBarPaddingModifier())
    }
    
    /// Report this view's height as the bottom bar height
    func reportBottomBarHeight() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: BottomBarHeightPreferenceKey.self, value: geo.size.height)
            }
        )
    }
}

private struct BottomBarPaddingModifier: ViewModifier {
    @Environment(\.bottomBarHeight) private var bottomBarHeight
    
    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, bottomBarHeight)
    }
}

