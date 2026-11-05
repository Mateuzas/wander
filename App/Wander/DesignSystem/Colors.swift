import SwiftUI
import UIKit

// Color tokens from PLAN.md §10. Category colors (sights, shops, food) are for
// beads and their glyphs only, never large fills.
extension ShapeStyle where Self == Color {
    /// Sheet background.
    static var surface: Color { Color(light: 0xF3F5F6, dark: 0x161B22) }
    /// Cards, selected control.
    static var surfaceRaised: Color { Color(light: 0xFFFFFF, dark: 0x1F2630) }
    /// Primary text.
    static var ink: Color { Color(light: 0x18212C, dark: 0xEDF0F3) }
    /// Secondary text, fast route line.
    static var inkMuted: Color { Color(light: 0x5E6A78, dark: 0x9AA6B4) }
    /// Wander route, primary button, selection.
    static var wander: Color { Color(light: 0x5B3DF5, dark: 0x8C7BFF) }
    /// Photo/sight beads.
    static var sights: Color { Color(light: 0xE9A21B, dark: 0xF2B53D) }
    /// Shop beads.
    static var shops: Color { Color(light: 0x1C9E8B, dark: 0x35BBA7) }
    /// Food beads.
    static var food: Color { Color(light: 0xE5532D, dark: 0xF06A45) }
    /// The user-location dot and its heading beam: MapKit's own dot colour (system
    /// blue), set explicitly on both so they can't diverge. Not a §10 token: the
    /// dot is a platform convention, and the route stays violet.
    static var userLocation: Color { Color(uiColor: .systemBlue) }
}

extension Color {
    /// A color that resolves to `light` or `dark` with the current trait collection.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
