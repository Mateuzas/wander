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
        // FE-15: manifest parse, sha256 check and decode against the bundled file.
        Task.detached(priority: .utility) { DataFeed.selfCheck() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .overlay { LaunchCover() }
        }
    }
}
