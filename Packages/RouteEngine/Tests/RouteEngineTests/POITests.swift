import Foundation
import Testing
@testable import RouteEngine

struct POITests {
    @Test func decodesSchema() throws {
        let json = """
        {
          "city": "Łódź",
          "generated": "2026-11-02",
          "pois": [
            {"id": "osm:node:1", "name": "Mural", "lat": 51.77, "lon": 19.45,
             "category": "photo", "score": 82, "kind": "passby", "reason": "Street art"},
            {"id": "osm:way:2", "name": "Café", "lat": 51.76, "lon": 19.46,
             "category": "food", "score": 40, "kind": "stop"}
          ]
        }
        """
        let file = try JSONDecoder().decode(POIFile.self, from: Data(json.utf8))
        #expect(file.city == "Łódź")
        #expect(file.pois.count == 2)
        #expect(file.pois[0].category == .photo)
        #expect(file.pois[0].kind == .passby)
        #expect(file.pois[0].score == 82)
        #expect(file.pois[1].reason == "")
        #expect(file.pois[1].coordinate == Coordinate(lat: 51.76, lon: 19.46))
    }

    @Test func roundTrips() throws {
        let poi = POI(id: "osm:node:3", name: "Shop", lat: 1, lon: 2, category: .shop, score: 50, kind: .stop, reason: "Indie")
        let data = try JSONEncoder().encode(poi)
        #expect(try JSONDecoder().decode(POI.self, from: data) == poi)
    }
}
