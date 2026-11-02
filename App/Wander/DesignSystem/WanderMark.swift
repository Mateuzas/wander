import SwiftUI

/// The Wander "W" route mark from the brand kit (docs/BRAND.md), drawn with Canvas.
/// For splash, onboarding and empty states. `ring` is the knockout colour around each
/// bead: pass the colour of whatever the mark sits on.
struct WanderMark: View {
    var ring: Color = .surface

    private let box = CGRect(x: 140, y: 240, width: 744, height: 594)
    private let route: [CGPoint] = [
        CGPoint(x: 190, y: 290), CGPoint(x: 350, y: 740), CGPoint(x: 512, y: 430),
        CGPoint(x: 674, y: 740), CGPoint(x: 834, y: 290),
    ]
    private let beads: [(CGPoint, Color)] = [
        (CGPoint(x: 350, y: 740), .sights),
        (CGPoint(x: 512, y: 430), .shops),
        (CGPoint(x: 674, y: 740), .food),
    ]

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / box.width, size.height / box.height)
            let ox = (size.width - box.width * s) / 2 - box.minX * s
            let oy = (size.height - box.height * s) / 2 - box.minY * s
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + p.x * s, y: oy + p.y * s) }

            var path = Path()
            path.move(to: map(route[0]))
            for p in route.dropFirst() { path.addLine(to: map(p)) }
            ctx.stroke(path, with: .color(.wander),
                       style: StrokeStyle(lineWidth: 96 * s, lineCap: .round, lineJoin: .round))

            for (point, color) in beads {
                let c = map(point)
                let r = 78 * s
                let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(circle, with: .color(color))
                ctx.stroke(circle, with: .color(ring), lineWidth: 18 * s)
            }
        }
        .aspectRatio(box.width / box.height, contentMode: .fit)
        .accessibilityLabel("Wander")
    }
}

#Preview {
    WanderMark()
        .frame(width: 240)
        .padding(40)
        .background(Color.surface)
}
