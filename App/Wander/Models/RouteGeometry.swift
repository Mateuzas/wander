import Foundation
import RouteEngine

/// Small polyline helpers for the app. RouteEngine's own geometry is internal,
/// and these only need city-scale accuracy (flat local projection).
enum RouteGeometry {
    /// Metres along a polyline from its start, one entry per point.
    static func cumulativeLengths(_ line: [Coordinate]) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(line.count)
        var total = 0.0
        for (i, point) in line.enumerated() {
            if i > 0 { total += line[i - 1].distance(to: point) }
            result.append(total)
        }
        return result
    }

    /// The first `length` metres of `line`, ending on an interpolated point.
    static func prefix(_ line: [Coordinate], lengths: [Double], length: Double) -> [Coordinate] {
        guard let total = lengths.last, line.count > 1 else { return line }
        if length >= total { return line }
        if length <= 0 { return [line[0]] }
        var result: [Coordinate] = [line[0]]
        for i in 1..<line.count {
            if lengths[i] >= length {
                let span = lengths[i] - lengths[i - 1]
                let t = span > 0 ? (length - lengths[i - 1]) / span : 0
                let a = line[i - 1], b = line[i]
                result.append(Coordinate(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t))
                return result
            }
            result.append(line[i])
        }
        return result
    }

    /// Distance from `point` to the closest spot on `line`, and how far along the line that spot is.
    static func nearest(_ point: Coordinate, on line: [Coordinate]) -> (distance: Double, along: Double) {
        guard let first = line.first else { return (.infinity, 0) }
        guard line.count > 1 else { return (point.distance(to: first), 0) }
        let mLat = 111_320.0
        let mLon = 111_320.0 * cos(point.lat * .pi / 180)
        func xy(_ c: Coordinate) -> (Double, Double) { ((c.lon - point.lon) * mLon, (c.lat - point.lat) * mLat) }

        var best = (distance: Double.infinity, along: 0.0)
        var walked = 0.0
        for i in 1..<line.count {
            let (ax, ay) = xy(line[i - 1]), (bx, by) = xy(line[i])
            let dx = bx - ax, dy = by - ay
            let segment = (dx * dx + dy * dy).squareRoot()
            let t = segment > 0 ? max(0, min(1, -(ax * dx + ay * dy) / (segment * segment))) : 0
            let px = ax + dx * t, py = ay + dy * t
            let d = (px * px + py * py).squareRoot()
            if d < best.distance { best = (d, walked + segment * t) }
            walked += segment
        }
        return best
    }
}
