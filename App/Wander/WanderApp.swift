import SwiftUI

@main
struct WanderApp: App {
    init() {
        Typography.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .overlay { LaunchCover() }
        }
    }
}
