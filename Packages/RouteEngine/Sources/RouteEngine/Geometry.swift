import Foundation

/// Flat x/y metres around a reference point (equirectangular). Accurate enough
/// at city scale for distances to a polyline and headings.
struct LocalProjection {
    let origin: Coordinate
    private let kx: Double
    private let ky: Double

    init(origin: Coordinate) {
        self.origin = origin
        ky = Coordinate.earthRadius * .pi / 180
        kx = ky * cos(origin.lat * .pi / 180)
    }

    func point(_ c: Coordinate) -> SIMD2<Double> {
        SIMD2((c.lon - origin.lon) * kx, (c.lat - origin.lat) * ky)
    }
}

/// A polyline measured for nearest-point queries.
struct MeasuredPolyline {
    private let projection: LocalProjection
    private let points: [SIMD2<Double>]
    /// Metres from the start to each vertex.
    private let cumulative: [Double]

    init(_ coordinates: [Coordinate], projection: LocalProjection) {
        self.projection = projection
        points = coordinates.map(projection.point)
        var total = 0.0
        var cumulative = [0.0]
        for i in points.indices.dropFirst() {
            total += length(points[i] - points[i - 1])
            cumulative.append(total)
        }
        self.cumulative = cumulative
    }

    /// Distance from `c` to the polyline and how far along it the closest point is.
    func nearest(to c: Coordinate) -> (distance: Double, along: Double) {
        let p = projection.point(c)
        guard let first = points.first else { return (.infinity, 0) }
        guard points.count > 1 else { return (length(p - first), 0) }
        var best = (distance: Double.infinity, along: 0.0)
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let ab = b - a
            let len2 = dot(ab, ab)
            let t = len2 > 0 ? min(1, max(0, dot(p - a, ab) / len2)) : 0
            let d = length(p - (a + t * ab))
            if d < best.distance {
                best = (d, cumulative[i - 1] + t * len2.squareRoot())
            }
        }
        return best
    }
}

func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a * b).sum() }
func length(_ v: SIMD2<Double>) -> Double { dot(v, v).squareRoot() }

/// Angle between two vectors in degrees, 0...180. Nil if either is zero.
func angleDegrees(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double? {
    let la = length(a), lb = length(b)
    guard la > 0, lb > 0 else { return nil }
    return acos(min(1, max(-1, dot(a, b) / (la * lb)))) * 180 / .pi
}
