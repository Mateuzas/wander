import SwiftUI

/// 22 pt circle in the category color with a white glyph. Selected: 30 pt with a white ring.
struct Bead: View {
    let category: POICategory
    var isSelected = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = isSelected ? Layout.beadSelected : Layout.bead
        Circle()
            .fill(category.color)
            .overlay {
                Image(systemName: category.glyph)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                if isSelected {
                    Circle().strokeBorder(.white, lineWidth: 2)
                }
            }
            .frame(width: size, height: size)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isSelected)
            .accessibilityLabel(category.spokenName)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    HStack(spacing: Layout.margin) {
        ForEach(POICategory.allCases, id: \.self) { Bead(category: $0) }
        Bead(category: .photo, isSelected: true)
    }
    .padding()
    .background(.surface)
}
