import CoreText
import SwiftUI

// Type scale from PLAN.md §10. One family, Instrument Sans (bundled variable
// font, OFL), falling back to SF Pro if it fails to register. Every style is
// relative to a system text style so Dynamic Type scales it.
enum Typography {
    static let family = "Instrument Sans"

    /// Registers the bundled font for this process. Call once at launch.
    /// Registering at runtime avoids a UIAppFonts entry in the generated Info.plist.
    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "InstrumentSans", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

/// Text styles. A namespace rather than a `Font` extension, because `Font`
/// already has `title`, `body` and `caption`.
enum WanderFont {
    /// 34 / 600, tabular. Total minutes in the plan summary.
    static var stat: Font { custom(34, .semibold, relativeTo: .largeTitle).monospacedDigit() }
    /// 24 / 600. Destination name.
    static var title: Font { custom(24, .semibold, relativeTo: .title2) }
    /// 18 / 600. Highlight names.
    static var heading: Font { custom(18, .semibold, relativeTo: .headline) }
    /// 18 / 400. A place's hook line (FE-22): the body style a step up, under the place's name.
    static var hook: Font { custom(18, .regular, relativeTo: .body) }
    /// 16 / 400. Reasons, instructions.
    static var body: Font { custom(16, .regular, relativeTo: .body) }
    /// 13 / 500, tabular. Distances, secondary details.
    static var caption: Font { custom(13, .medium, relativeTo: .footnote).monospacedDigit() }

    private static func custom(_ size: CGFloat, _ weight: Font.Weight, relativeTo style: Font.TextStyle) -> Font {
        Font.custom(Typography.family, size: size, relativeTo: style).weight(weight)
    }
}
