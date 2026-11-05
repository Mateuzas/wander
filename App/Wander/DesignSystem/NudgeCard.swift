import RouteEngine
import SwiftUI

/// "Up ahead" card: raised surface, bead on the left, two lines of text, one text button.
/// No shadow or border (§10).
struct NudgeCard: View {
    let category: POICategory
    var glyph: String?
    let title: String
    let detail: String
    var actionTitle = "Skip"
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Layout.grid * 1.5) {
            Bead(category: category, glyph: glyph)
            VStack(alignment: .leading, spacing: Layout.grid / 2) {
                Text(title)
                    .font(WanderFont.heading)
                    .foregroundStyle(.ink)
                Text(detail)
                    .font(WanderFont.body)
                    .foregroundStyle(.inkMuted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(category.spokenName), \(title), \(detail)")
            Spacer(minLength: Layout.grid)
            Button(actionTitle, action: action)
                .buttonStyle(.textAction)
                .frame(minWidth: Layout.minTouch)
        }
        .padding(.leading, Layout.margin)
        .padding(.trailing, Layout.grid)
        .padding(.vertical, Layout.grid * 1.5)
        .background(.surfaceRaised, in: RoundedRectangle(cornerRadius: Layout.margin, style: .continuous))
    }
}

#Preview {
    NudgeCard(category: .photo, title: "Mural on Stiklių", detail: "Street art · on your right, 40 m") {}
        .padding(Layout.margin)
        .background(.surface)
}
