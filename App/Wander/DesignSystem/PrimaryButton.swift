import SwiftUI

/// Full-width, `wander` fill, white text, 52 pt tall (§10). One per screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WanderFont.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Layout.primaryButtonHeight)
            .background(.wander, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

/// Plain `wander` text action with a 44 pt touch target ("Open in Google Maps", "Skip").
struct TextActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WanderFont.body.weight(.semibold))
            .foregroundStyle(.wander)
            .frame(minHeight: Layout.minTouch, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == TextActionStyle {
    static var textAction: TextActionStyle { TextActionStyle() }
}
