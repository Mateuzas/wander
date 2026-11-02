import SwiftUI

/// Picks up from the static launch screen (`UILaunchScreen` in App/Wander-Info.plist:
/// `LaunchBackground` colour, `LaunchMark` image, 120 pt wide, centred on the full
/// screen) and fades it out once the app's first frame is up. It never blocks
/// touches, so the map underneath loads and works straight away.
struct LaunchCover: View {
    /// Same width as the `LaunchMark` asset's intrinsic size.
    static let markWidth: CGFloat = 120

    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if visible {
            ZStack {
                Color.surface
                WanderMark()
                    .frame(width: Self.markWidth)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
            .task {
                // One run-loop turn so the app's first frame is on screen underneath.
                await Task.yield()
                if reduceMotion {
                    visible = false
                } else {
                    withAnimation(.easeOut(duration: 0.6)) { visible = false }
                }
            }
        }
    }
}

#Preview {
    LaunchCover()
}
