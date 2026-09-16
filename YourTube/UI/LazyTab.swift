import SwiftUI

/// A tab that isn't built until it's first opened.
///
/// `TabView` builds every tab's content the moment the tab bar appears and
/// keeps it alive for the life of the app, so four tabs' worth of queries ran
/// from launch no matter which one you were looking at (issue #66). This holds
/// a placeholder until its tab is selected for the first time, and from then
/// on keeps the real content — a tab you have visited keeps its scroll
/// position and its navigation stack when you come back to it, which is the
/// half of `TabView`'s behaviour worth keeping.
struct LazyTab<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: () -> Content

    @State private var hasBeenSelected = false

    var body: some View {
        ZStack {
            if hasBeenSelected {
                content()
            } else {
                Color(.systemBackground)
                    .ignoresSafeArea()
            }
        }
        .onChange(of: isSelected, initial: true) {
            if isSelected { hasBeenSelected = true }
        }
    }
}
