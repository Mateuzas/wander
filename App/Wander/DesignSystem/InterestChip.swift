import RouteEngine
import SwiftUI

/// Sights / Shops / Food toggle. The category color appears only on the glyph (§10).
/// On: raised surface, ink text. Off: no fill, muted text and glyph.
struct InterestChip: View {
    let category: POICategory
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: Layout.grid * 0.75) {
                Image(systemName: category.glyph)
                    .foregroundStyle(isOn ? category.color : Color.inkMuted)
                Text(category.chipTitle)
                    .font(WanderFont.body)
                    .foregroundStyle(isOn ? Color.ink : Color.inkMuted)
            }
            .padding(.horizontal, Layout.grid * 1.5)
            .frame(minHeight: Layout.minTouch)
            .background {
                if isOn { Capsule().fill(.surfaceRaised) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.chipTitle)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
