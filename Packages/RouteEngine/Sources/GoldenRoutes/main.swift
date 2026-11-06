import Foundation
import RouteEngine

// Prints a summary table of plans for the golden A→B pairs (PLAN.md section 6, Testing).
// Uses the offline haversine provider, so no network is needed.
//
// Usage: golden-routes [golden_routes.json] [--pois path] [--preset name | --weights photos=1,fame=0.5,...]
//                      [--time 2026-11-07T14:00]
//   --preset   a WeightPreset: balanced, photoSpots, famousSights, hiddenGems
//   --streets  verify on L-shaped streets (like real routing, often shorter than the
//              planner's 1.3× straight-line estimate) instead of the estimate itself
//   --passes   also list the free pass-by highlights on each Recommended route
//   --sequence walk the routes in order on one day: each route's Recommended stops
//              are added to PlanRequest.seen for the routes after it
//   --weights  value POIs by signals instead of score (keys: photos, fame, quality, independent)
//   --time     local time in the file's time zone; skips POIs closed then

struct GoldenFile: Decodable {
    struct Route: Decodable {
        var name: String
        var from: [Double]
        var to: [Double]
    }
    var city: String
    var pois: String
    var timeZone: String
    var routes: [Route]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("golden-routes: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
let poisOverride = option("--pois")
let weightsArg = option("--weights")
let presetArg = option("--preset")
let useStreets = args.contains("--streets")
let showPasses = args.contains("--passes")
let sequence = args.contains("--sequence")
args.removeAll { $0 == "--streets" || $0 == "--passes" || $0 == "--sequence" }
let timeArg = option("--time")

let goldenURL = URL(fileURLWithPath: args.first ?? "golden_routes.json")
guard let goldenData = try? Data(contentsOf: goldenURL),
      let golden = try? JSONDecoder().decode(GoldenFile.self, from: goldenData) else {
    fail("cannot read \(goldenURL.path)")
}
guard let timeZone = TimeZone(identifier: golden.timeZone) else { fail("unknown time zone \(golden.timeZone)") }
let poisURL = poisOverride.map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: golden.pois, relativeTo: goldenURL.deletingLastPathComponent())
guard let poisData = try? Data(contentsOf: poisURL) else {
    fail("cannot read \(poisURL.standardizedFileURL.path); pass --pois")
}
let file = try JSONDecoder().decode(POIFile.self, from: poisData)

var weights: SignalWeights?
if let presetArg {
    guard let preset = WeightPreset(rawValue: presetArg) else {
        fail("unknown preset \(presetArg); use " + WeightPreset.allCases.map(\.rawValue).joined(separator: ", "))
    }
    weights = preset.weights
}
if let weightsArg {
    var w = SignalWeights()
    for pair in weightsArg.split(separator: ",") {
        let kv = pair.split(separator: "=")
        guard kv.count == 2, let value = Double(kv[1]) else { fail("bad --weights entry \(pair)") }
        switch kv[0] {
        case "photos": w.photos = value
        case "fame": w.fame = value
        case "quality": w.quality = value
        case "independent": w.independent = value
        default: fail("unknown weight \(kv[0])")
        }
    }
    weights = w
}

var time: Date?
if let timeArg {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
    guard let date = formatter.date(from: timeArg) else { fail("bad --time, use 2026-11-07T14:00") }
    time = date
}

/// Walks along streets in an L (east/west, then north/south): a stand-in for
/// MKDirections, since real street routes rarely match the 1.3× estimate.
struct StreetWalkingTime: WalkingTimeProvider {
    func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        let corner = Coordinate(lat: from.lat, lon: to.lon)
        let distance = from.distance(to: corner) + corner.distance(to: to)
        return Leg(from: from, to: to, duration: distance / HaversineWalkingTime.defaultSpeed,
                   distance: distance, polyline: [from, corner, to])
    }
}

func minutes(_ seconds: Double) -> String { String(format: "%.1f", seconds / 60) }
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
func lpad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}
func glyph(_ c: POICategory) -> String {
    switch c { case .photo: "📷"; case .shop: "🛍"; case .food: "🍴" }
}

let withHours = file.pois.compactMap(\.openingHours)
let parsed = withHours.filter { OpeningHours($0) != nil }.count
print("Golden routes: \(golden.city), \(file.pois.count) POIs (generated \(file.generated)), \(useStreets ? "L-shaped street" : "haversine") provider"
      + (sequence ? ", one day in sequence (earlier Recommended stops are seen)" : ""))
print("Value: " + (presetArg.map { "preset \($0), " } ?? "") + (weights.map { "signals × weights \($0)" } ?? "score")
      + " · time: " + (timeArg.map { "\($0) \(golden.timeZone)" } ?? "not checked")
      + " · opening hours parsed: \(parsed)/\(withHours.count)\n")
print(pad("#", 3) + pad("Route", 36) + pad("Mode", 12) + lpad("Fast", 6) + lpad("Total", 7) + lpad("Extra", 7)
      + lpad("Wp", 4) + lpad("Hl", 4) + "  Waypoints (value, +min)")
print(String(repeating: "─", count: 140))

let planner = Planner()
let cap = planner.config.recommendedMaxExtra
let provider: WalkingTimeProvider = useStreets ? StreetWalkingTime() : HaversineWalkingTime()
var withinCap = 0, twoHighlights = 0, noFit: [String] = []
var reasonCounts: [String: Int] = [:]
var waypointCounts: [String: Int] = [:]
var foodPerRoute: [Int] = []
var stopsPerRoute: [Int] = []
var extras: [Double] = []
var seen: Set<String> = []
var seenAgain = 0

for (index, route) in golden.routes.enumerated() {
    let origin = Coordinate(lat: route.from[0], lon: route.from[1])
    let destination = Coordinate(lat: route.to[0], lon: route.to[1])
    // Both modes in one call, as the app does.
    let modePlans = try await planner.plans(
        PlanRequest(origin: origin, destination: destination, mode: .direct, weights: weights,
                    pois: file.pois, time: time, timeZone: timeZone, seen: sequence ? seen : []),
        provider: provider)
    for mode in Mode.allCases {
        let plan = modePlans[mode]!
        let debug = Dictionary(uniqueKeysWithValues: plan.candidates.map { ($0.poi.id, $0) })
        let names = plan.waypoints.map { poi in
            let d = debug[poi.id]
            return "\(glyph(poi.category)) \(poi.name) (\(Int((d?.value ?? 0).rounded())), +\(minutes(d?.estimatedExtraTime ?? 0)))"
        }.joined(separator: " · ")
        print(pad(mode == .direct ? "\(index + 1)" : "", 3) + pad(mode == .direct ? route.name : "", 36)
              + pad(mode.rawValue, 12)
              + lpad(minutes(plan.baseline.duration), 6) + lpad(minutes(plan.totalTime), 7)
              + lpad("+" + minutes(plan.extraTime), 7)
              + lpad("\(plan.waypoints.count)", 4)
              + lpad("\(plan.highlights.count)", 4) + "  "
              + (plan.noDetourFit ? "(nothing worth a detour)" : names))
        if plan.noDetourFit { noFit.append("\(index + 1)") }
    }
    let plan = modePlans[.recommended]!
    for poi in plan.waypoints { waypointCounts["\(glyph(poi.category)) \(poi.name)", default: 0] += 1 }
    foodPerRoute.append(plan.waypoints.filter { $0.category == .food }.count)
    stopsPerRoute.append(plan.waypoints.count)
    extras.append(plan.extraTime)
    if plan.extraTime <= cap * 1.1 { withinCap += 1 }
    if plan.highlights.count >= 2 { twoHighlights += 1 }
    for c in plan.candidates {
        if case .rejected(let reason) = c.status { reasonCounts[reason.rawValue, default: 0] += 1 }
    }
    let stops = plan.waypoints.map(\.id)
    seenAgain += stops.filter { seen.contains($0) }.count
    seen.formUnion(stops)
    // Pass-by highlights on the Recommended route, for eyeballing.
    let passby = plan.highlights.filter { $0.role == .passby }.map { "\($0.poi.name) (\($0.poi.score))" }
    if showPasses, !passby.isEmpty {
        print(pad("", 51) + "recommended passes: " + passby.prefix(6).joined(separator: ", ")
              + (passby.count > 6 ? ", +\(passby.count - 6) more" : ""))
    }
    print("")
}

let n = golden.routes.count
let sortedExtras = extras.sorted()
let median = n % 2 == 1 ? sortedExtras[n / 2] : (sortedExtras[n / 2 - 1] + sortedExtras[n / 2]) / 2
print("Constants: recommendedMaxExtra \(minutes(cap)) min, minValuePerMinute \(planner.config.minValuePerMinute)")
print("Recommended extra time: min \(minutes(sortedExtras.first!)), median \(minutes(median)), max \(minutes(sortedExtras.last!)) min"
      + "   (target: median 8–18, max ≤ \(minutes(cap * 1.1)))")
print("Recommended within cap (+10%):    \(withinCap)/\(n)   (target: all)")
print("Recommended with ≥2 highlights:   \(twoHighlights)/\(n)   (target: ≥8)")
print("Recommended stops per route: " + stopsPerRoute.map(String.init).joined(separator: " "))
print("Nothing worth a detour: " + (noFit.isEmpty ? "none" : "routes " + noFit.joined(separator: ", ")))
let repeated = waypointCounts.filter { $0.value > 1 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
print("Recommended stops used on 2+ routes: " + (repeated.isEmpty ? "none"
    : repeated.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")))
print("Recommended stops already used on an earlier route: \(seenAgain) of \(waypointCounts.values.reduce(0, +))")
print("Recommended food stops per route: " + foodPerRoute.map(String.init).joined(separator: " ")
      + "   (distinct stops: \(waypointCounts.count))")
print("Recommended rejections: " + reasonCounts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
    .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
