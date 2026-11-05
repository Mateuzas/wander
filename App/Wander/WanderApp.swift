import RouteEngine
import SwiftUI

@main
struct WanderApp: App {
    init() {
        Typography.registerFonts()
        #if DEBUG
        for glyph in POICategory.allGlyphs {
            assert(UIImage(systemName: glyph) != nil, "Missing SF Symbol: \(glyph)")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .overlay { LaunchCover() }
        }
    }
}
