import SwiftUI

/// Horizontal row of category filters. "All" (empty selection) is one chip
/// among the rest; the row scrolls the remembered chip into view on launch so
/// a restored selection is visible, not off to the right. Priority comes first
/// by sort order. Chips get no badge or count on purpose: they're meant to be
/// a calm place, not a to-do list.
///
/// Shared by the feed and the Your Shows grid so the two surfaces filter by
/// the same vocabulary, with a selection remembered per surface.
struct CategoryChips: View {
    let names: [String]
    @Binding var selected: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All", isOn: selected.isEmpty) { selected = "" }
                        .id("")
                    ForEach(names, id: \.self) { name in
                        chip(name, isOn: selected == name) {
                            selected = selected == name ? "" : name
                        }
                        .id(name)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: Capsule())
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
