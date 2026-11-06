import Foundation

/// Where along the route the walker probably is: a probability for every
/// `spacing` metres of the route, updated with each fix (a grid filter).
///
/// Matching each fix to the nearest point on the route on its own is not
/// enough on Recommended plans: legs to and from a stop often run back along
/// the same street, or along a parallel one a block away, and under GPS noise
/// a single fix is often nearer the wrong pass. Once matched there, a search
/// near the last position can't get back. The filter instead keeps every
/// plausible position open and weighs it by the fixes so far and by how far a
/// walker can move between fixes (mostly forward, at walking pace). The wrong
/// pass then needs a long run of fixes that fit it better, not one noisy fix.
///
/// Only the stretch of positions that are still plausible is kept (usually a
/// few dozen), so an update is cheap. `reset()` reopens the whole route.
struct RouteFilter {
    /// Metres between positions.
    let spacing: Double
    /// Projected positions every `spacing` metres from the start.
    private let points: [SIMD2<Double>]
    /// Probability of each position in `lo...hi`; zero elsewhere.
    private var weights: [Double]
    private var lo = 0
    private var hi = -1

    /// Share of the movement model for walking forward at about walking pace;
    /// the rest allows anything from walking back to running.
    private let forwardShare = 0.9
    /// Smallest likelihood of a fix at any position, so one stray fix that
    /// still passes the accuracy filter can't rule out the right position.
    private let outlierFloor = 0.01
    /// Positions less likely than this times the most likely one are dropped.
    private let prune = 1e-12

    init(line: MeasuredPolyline, spacing: Double = 2) {
        self.spacing = spacing
        points = line.sample(every: spacing)
        weights = Array(repeating: 0, count: points.count)
    }

    /// Forgets everything: the next fix is matched against the whole route.
    mutating func reset() {
        for i in weights.indices where i >= lo && i <= hi { weights[i] = 0 }
        lo = 0
        hi = -1
    }

    /// Updates with a fix at projected point `p`, `sigma` metres of GPS error
    /// and `gap` seconds after the previous update. Returns the most likely
    /// position (averaged with its neighbours), in metres from the start.
    mutating func update(_ p: SIMD2<Double>, sigma: Double, gap: TimeInterval, config: WalkConfig) -> Double {
        let n = points.count
        guard n > 0 else { return 0 }
        if hi < lo {
            lo = 0
            hi = n - 1
            for i in 0..<n { weights[i] = 1 / Double(n) }
        } else {
            // Normal walking: forward at about walking pace (give or take half
            // a metre per second). Anything else (stopping, turning back,
            // running) is allowed but less likely.
            let pace = config.walkingSpeed * gap, sd = 0.5 * gap + 0.5
            let forward = offsets(max(0, pace - 3 * sd), pace + 3 * sd)
            let other = offsets(-(config.walkingSpeed * gap + 2), config.maxSpeed * gap + 2)
            let newLo = max(0, lo + min(forward.a, other.a)), newHi = min(n - 1, hi + max(forward.b, other.b))
            let o = spread(other, to: newLo...newHi)
            let f: [Double]
            if forward.b - forward.a <= 64 {
                let kernel = (forward.a...forward.b).map { j -> Double in
                    let x = (Double(j) * spacing - pace) / sd
                    return exp(-x * x / 2)
                }
                f = spread(kernel, from: forward.a, to: newLo...newHi)
            } else {
                f = spread(forward, to: newLo...newHi)   // long gap: an even spread is close enough
            }
            for i in lo...hi { weights[i] = 0 }
            for i in newLo...newHi {
                weights[i] = forwardShare * f[i - newLo] + (1 - forwardShare) * o[i - newLo]
            }
            lo = newLo
            hi = newHi
        }

        // Gaussian likelihood relative to the nearest position, so a fix far
        // from the whole stretch still pulls towards the part it's nearest.
        var d2 = [Double](repeating: 0, count: hi - lo + 1)
        var nearest = Double.infinity
        for i in lo...hi {
            let d = p - points[i]
            d2[i - lo] = dot(d, d)
            nearest = min(nearest, d2[i - lo])
        }
        let scale = 1 / (2 * sigma * sigma)
        var total = 0.0, best = lo
        for i in lo...hi {
            weights[i] *= exp(-(d2[i - lo] - nearest) * scale) + outlierFloor
            total += weights[i]
            if weights[i] > weights[best] { best = i }
        }
        guard total > 0 else {
            reset()
            return update(p, sigma: sigma, gap: 0, config: config)
        }
        let floor = weights[best] * prune
        var newLo = lo, newHi = hi
        while weights[newLo] < floor { weights[newLo] = 0; newLo += 1 }
        while weights[newHi] < floor { weights[newHi] = 0; newHi -= 1 }
        lo = newLo
        hi = newHi
        for i in lo...hi { weights[i] /= total }
        // Average over the most likely position and its neighbours, for a
        // position finer than `spacing`.
        var sum = 0.0, mass = 0.0
        for i in max(lo, best - 5)...min(hi, best + 5) {
            sum += weights[i] * Double(i)
            mass += weights[i]
        }
        return sum / mass * spacing
    }

    /// A move of `from...to` metres (negative is back) as whole positions.
    private func offsets(_ from: Double, _ to: Double) -> (a: Int, b: Int) {
        let a = Int((from / spacing).rounded(.down))
        return (a, max(a, Int((to / spacing).rounded(.up))))
    }

    /// Spreads each kept position's probability over the positions `from`,
    /// `from + 1`, ... ahead in proportion to `kernel`, for the positions in
    /// `range`. Probability that would leave the route stays at its start or end.
    private func spread(_ kernel: [Double], from a: Int, to range: ClosedRange<Int>) -> [Double] {
        let n = points.count
        let total = kernel.reduce(0, +)
        var out = [Double](repeating: 0, count: range.count)
        for k in lo...hi where weights[k] > 0 {
            for (j, share) in kernel.enumerated() {
                let target = min(n - 1, max(0, k + a + j))
                out[target - range.lowerBound] += weights[k] * share / total
            }
        }
        return out
    }

    /// Spreads each kept position's probability evenly over `kernel` positions
    /// ahead, for the positions in `range`. Probability that would leave the
    /// route stays at its start or end.
    private func spread(_ kernel: (a: Int, b: Int), to range: ClosedRange<Int>) -> [Double] {
        let n = points.count, (a, b) = kernel
        let width = Double(b - a + 1)
        // prefix[k - lo] = weights[lo] + ... + weights[k - 1]
        var prefix = [Double](repeating: 0, count: hi - lo + 2)
        for k in lo...hi { prefix[k - lo + 1] = prefix[k - lo] + weights[k] }
        func sum(_ lower: Int, _ upper: Int) -> Double {   // weights[lower...upper], clamped to lo...hi
            let l = max(lo, lower), u = min(hi, upper)
            return u >= l ? prefix[u - lo + 1] - prefix[l - lo] : 0
        }
        var out = range.map { sum($0 - b, $0 - a) / width }
        if range.upperBound == n - 1 || range.lowerBound == 0 {
            for k in lo...hi {
                let past = min(b - a + 1, max(0, k + b - (n - 1)))   // offsets j with k + j > n - 1
                let before = min(b - a + 1, max(0, -(k + a)))       // offsets j with k + j < 0
                if range.upperBound == n - 1 { out[out.count - 1] += weights[k] * Double(past) / width }
                if range.lowerBound == 0 { out[0] += weights[k] * Double(before) / width }
            }
        }
        return out
    }
}

extension MeasuredPolyline {
    /// Projected points every `spacing` metres from the start, and the end.
    func sample(every spacing: Double) -> [SIMD2<Double>] {
        let count = Int((totalLength / spacing).rounded(.up)) + 1
        return (0..<count).map { position(at: min(totalLength, Double($0) * spacing)).point }
    }
}
