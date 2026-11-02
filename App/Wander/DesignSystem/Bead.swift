import RouteEngine
import SwiftUI

/// 22 pt circle in the category color with a white glyph. Selected: 30 pt with a white ring.
/// Popular places (must-sees) are bigger, 30 pt, with a white ring and a small star, and
/// keep their category color so the color coding still works.
struct Bead: View {
    let category: POICategory
    var isSelected = false
    var isPopular = false
    /// Place name for VoiceOver, read after the category ("Photo spot, Mural on Stiklių").
    var name: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat {
        switch (isPopular, isSelected) {
        case (true, true): Layout.beadPopular + 6
        case (true, false): Layout.beadPopular
        case (false, true): Layout.beadSelected
        case (false, false): Layout.bead
        }
    }

    var body: some View {
        Circle()
            .fill(category.color)
            .overlay {
                Image(systemName: category.glyph)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                if isSelected || isPopular {
                    Circle().strokeBorder(.white, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isPopular { star }
            }
            .frame(width: size, height: size)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isSelected)
            .accessibilityLabel(
                [category.spokenName, isPopular ? "popular" : nil, name].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A small white disc with a category-colored star, tucked on the bead's upper right.
    private var star: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(category.color)
            .frame(width: 14, height: 14)
            .background(.white, in: Circle())
            .offset(x: 4, y: -4)
    }
}

private extension Layout {
    /// Popular beads: larger than the 22 pt ordinary bead.
    static let beadPopular: CGFloat = 30
}

#Preview {
    VStack(spacing: Layout.margin) {
        HStack(spacing: Layout.margin) {
            ForEach(POICategory.allCases, id: \.self) { Bead(category: $0) }
            Bead(category: .photo, isSelected: true)
        }
        HStack(spacing: Layout.margin) {
            ForEach(POICategory.allCases, id: \.self) { Bead(category: $0, isPopular: true) }
            Bead(category: .photo, isSelected: true, isPopular: true)
        }
    }
    .padding()
    .background(.surface)
}
