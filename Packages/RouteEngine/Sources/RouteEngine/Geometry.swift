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

    /// Total length in metres.
    var totalLength: Double { cumulative.last ?? 0 }

    /// Distance from `c` to the polyline and how far along it the closest point is.
    /// With `within`, only that stretch of the line (metres from the start) counts.
    func nearest(to c: Coordinate, within range: ClosedRange<Double>? = nil) -> (distance: Double, along: Double) {
        let p = projection.point(c)
        guard let first = points.first else { return (.infinity, 0) }
        guard points.count > 1 else { return (length(p - first), 0) }
        var best = (distance: Double.infinity, along: 0.0)
        for i in 1..<points.count {
            let start = cumulative[i - 1], end = cumulative[i]
            let a = points[i - 1], b = points[i]
            let ab = b - a
            let segment = end - start
            var lo = 0.0, hi = 1.0
            if let range {
                guard end >= range.lowerBound, start <= range.upperBound else { continue }
                if segment > 0 {
                    lo = max(0, (range.lowerBound - start) / segment)
                    hi = min(1, (range.upperBound - start) / segment)
                }
            }
            let len2 = dot(ab, ab)
            let t = len2 > 0 ? min(hi, max(lo, dot(p - a, ab) / len2)) : 0
            let d = length(p - (a + t * ab))
            if d < best.distance {
                best = (d, start + t * segment)
            }
        }
        return best
    }

    /// Projected point and unit direction of travel at `along` metres. The
    /// direction is nil where the line has no length.
    func position(at along: Double) -> (point: SIMD2<Double>, direction: SIMD2<Double>?) {
        guard points.count > 1 else { return (points.first ?? .zero, nil) }
        var i = 1
        while i < points.count - 1 && cumulative[i] < along { i += 1 }
        // Skip zero-length segments when looking for a direction.
        var j = i
        while j < points.count - 1 && cumulative[j] - cumulative[j - 1] <= 0 { j += 1 }
        let a = points[i - 1], b = points[i]
        let segment = cumulative[i] - cumulative[i - 1]
        let t = segment > 0 ? min(1, max(0, (along - cumulative[i - 1]) / segment)) : 0
        let d = points[j] - points[j - 1]
        let len = length(d)
        return (a + t * (b - a), len > 0 ? d / len : nil)
    }

    func point(_ c: Coordinate) -> SIMD2<Double> { projection.point(c) }
}

func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a * b).sum() }
func length(_ v: SIMD2<Double>) -> Double { dot(v, v).squareRoot() }

/// Angle between two vectors in degrees, 0...180. Nil if either is zero.
func angleDegrees(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double? {
    let la = length(a), lb = length(b)
    guard la > 0, lb > 0 else { return nil }
    return acos(min(1, max(-1, dot(a, b) / (la * lb)))) * 180 / .pi
}
