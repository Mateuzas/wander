import Foundation
import RouteEngine

// Prints a summary table of plans for the golden A→B pairs (PLAN.md section 6, Testing).
// Usage: golden-routes [golden_routes.json] [--pois path/to/pois.json]
// Uses the offline haversine provider, so no network is needed.

struct GoldenFile: Decodable {
    struct Route: Decodable {
        var name: String
        var from: [Double]
        var to: [Double]
    }
    var city: String
    var pois: String
    var routes: [Route]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("golden-routes: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var poisOverride: String?
if let i = args.firstIndex(of: "--pois") {
    guard i + 1 < args.count else { fail("--pois needs a path") }
    poisOverride = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let goldenURL = URL(fileURLWithPath: args.first ?? "golden_routes.json")
guard let goldenData = try? Data(contentsOf: goldenURL),
      let golden = try? JSONDecoder().decode(GoldenFile.self, from: goldenData) else {
    fail("cannot read \(goldenURL.path)")
}
let poisURL = poisOverride.map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: golden.pois, relativeTo: goldenURL.deletingLastPathComponent())
guard let poisData = try? Data(contentsOf: poisURL) else {
    fail("cannot read \(poisURL.standardizedFileURL.path); pass --pois")
}
let file = try JSONDecoder().decode(POIFile.self, from: poisData)

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

print("Golden routes: \(golden.city), \(file.pois.count) POIs (generated \(file.generated)), haversine provider\n")
print(pad("#", 3) + pad("Route", 36) + pad("Mode", 9) + lpad("Fast", 6) + lpad("Total", 7) + lpad("Extra", 7)
      + lpad("Wp", 4) + lpad("Hl", 4) + "  Waypoints (score, +min)")
print(String(repeating: "─", count: 140))

let planner = Planner()
let provider = HaversineWalkingTime()
var explorerWithin = 0, explorerTwoHighlights = 0, noFit: [String] = []
var reasonCounts: [String: Int] = [:]

for (index, route) in golden.routes.enumerated() {
    let origin = Coordinate(lat: route.from[0], lon: route.from[1])
    let destination = Coordinate(lat: route.to[0], lon: route.to[1])
    for mode in Mode.allCases {
        let request = PlanRequest(origin: origin, destination: destination, mode: mode, pois: file.pois)
        let plan = try await planner.plan(request, provider: provider)
        let extraByID = Dictionary(uniqueKeysWithValues: plan.candidates.map { ($0.poi.id, $0.estimatedExtraTime ?? 0) })
        let names = plan.waypoints.map {
            "\(glyph($0.category)) \($0.name) (\($0.score), +\(minutes(extraByID[$0.id] ?? 0)))"
        }.joined(separator: " · ")
        let label = mode == .direct ? "\(index + 1)" : ""
        let title = mode == .direct ? route.name : ""
        print(pad(label, 3) + pad(title, 36) + pad(mode.rawValue, 9)
              + lpad(minutes(plan.baseline.duration), 6) + lpad(minutes(plan.totalTime), 7)
              + lpad("+" + minutes(plan.extraTime), 7) + lpad("\(plan.waypoints.count)", 4)
              + lpad("\(plan.highlights.count)", 4) + "  "
              + (plan.noDetourFit ? "(no detour fits)" : names))
        if mode == .explorer {
            if plan.extraTime <= mode.budget * 1.1 { explorerWithin += 1 }
            if plan.highlights.count >= 2 { explorerTwoHighlights += 1 }
            for c in plan.candidates {
                if case .rejected(let reason) = c.status { reasonCounts[reason.rawValue, default: 0] += 1 }
            }
        }
        if plan.noDetourFit { noFit.append("\(index + 1) \(mode.rawValue)") }
    }
    // Pass-by highlights on the Explorer route, for eyeballing.
    let explorer = try await planner.plan(PlanRequest(origin: origin, destination: destination, mode: .explorer, pois: file.pois), provider: provider)
    let passby = explorer.highlights.filter { $0.role == .passby }.map { "\($0.poi.name) (\($0.poi.score))" }
    if !passby.isEmpty { print(pad("", 48) + "explorer passes: " + passby.prefix(6).joined(separator: ", ") + (passby.count > 6 ? ", +\(passby.count - 6) more" : "")) }
    print("")
}

let n = golden.routes.count
print("Explorer within budget (+10%): \(explorerWithin)/\(n)   (target: all)")
print("Explorer with ≥2 highlights:   \(explorerTwoHighlights)/\(n)   (target: ≥8)")
print("No detour fits: \(noFit.isEmpty ? "none" : noFit.joined(separator: ", "))")
print("Explorer rejections: " + reasonCounts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
