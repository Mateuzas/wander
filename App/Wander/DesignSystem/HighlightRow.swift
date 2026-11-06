import RouteEngine
import SwiftUI

/// Bead, name (Heading), reason (Body, muted), distance (Caption, trailing).
/// Rows are separated by spacing in their container, never dividers.
struct HighlightRow: View {
    let category: POICategory
    var glyph: String?
    let name: String
    var reason: String?
    var distance: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.grid * 1.5) {
            Bead(category: category, glyph: glyph)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            VStack(alignment: .leading, spacing: Layout.grid / 2) {
                Text(name)
                    .font(WanderFont.heading)
                    .foregroundStyle(.ink)
                if let reason {
                    Text(reason)
                        .font(WanderFont.body)
                        .foregroundStyle(.inkMuted)
                }
            }
            Spacer(minLength: Layout.grid)
            if let distance {
                Text(distance)
                    .font(WanderFont.caption)
                    .foregroundStyle(.inkMuted)
            }
        }
        .frame(minHeight: Layout.minTouch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([category.spokenName, name, reason, distance].compactMap { $0 }.joined(separator: ", "))
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Layout.margin) {
        HighlightRow(category: .photo, name: "Archikatedra", reason: "Historic church, popular photo spot", distance: "220 m")
        HighlightRow(category: .food, glyph: "cup.and.saucer", name: "Bułkęs", reason: "Independent bakery", distance: "1.1 km")
    }
    .padding(Layout.margin)
    .background(.surface)
}
