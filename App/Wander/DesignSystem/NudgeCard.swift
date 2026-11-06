import RouteEngine
import SwiftUI

/// "Up ahead" card: raised surface, the place's photo (or its bead) on the left, the
/// name, its hook and where it is, one text button. No shadow or border (§10).
struct NudgeCard: View {
    let category: POICategory
    var glyph: String?
    /// The place, for its square photo (FE-22); nil shows the bead.
    var poi: POI?
    let title: String
    /// The hook, or the reason for older data; nil when there is neither.
    var pitch: String?
    let detail: String
    var actionTitle = "Skip"
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Layout.grid * 1.5) {
            if let poi {
                PlaceThumbnail(poi: poi, size: 56, placeholder: .surface)
            } else {
                Bead(category: category, glyph: glyph)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(WanderFont.heading)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                if let pitch {
                    Text(pitch)
                        .font(WanderFont.body)
                        .foregroundStyle(.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail)
                    .font(WanderFont.caption)
                    .foregroundStyle(.inkMuted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([category.spokenName, title, pitch, detail].compactMap { $0 }.joined(separator: ", "))
            Spacer(minLength: Layout.grid)
            Button(actionTitle, action: action)
                .buttonStyle(.textAction)
                .frame(minWidth: Layout.minTouch)
        }
        .padding(.leading, poi == nil ? Layout.margin : Layout.grid * 1.5)
        .padding(.trailing, Layout.grid)
        .padding(.vertical, Layout.grid * 1.5)
        .background(.surfaceRaised, in: RoundedRectangle(cornerRadius: Layout.margin, style: .continuous))
    }
}

#Preview {
    NudgeCard(category: .photo, title: "Mural on Stiklių", pitch: "A whale swims up a four-storey wall",
              detail: "Street art · on your right, 40 m") {}
        .padding(Layout.margin)
        .background(.surface)
}
