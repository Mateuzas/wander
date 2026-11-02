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
             "category": "photo", "score": 82, "kind": "passby", "reason": "Street art",
             "commonsImage": "Mural in Łódź.jpg", "localName": "Mural przy Piotrkowskiej",
             "commonsCategory": "Murals in Łódź", "popular": true},
            {"id": "osm:way:2", "name": "Café", "lat": 51.76, "lon": 19.46,
             "category": "food", "score": 40, "kind": "stop", "type": "cafe",
             "signals": {"photos": 0.82, "fame": 0.4, "quality": 0.6, "independent": true},
             "cuisine": ["italian"], "openingHours": "Mo-Sa 10:00-20:00"}
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
        #expect(file.pois[0].type == nil && file.pois[0].signals == nil && file.pois[0].openingHours == nil)
        #expect(file.pois[1].type == "cafe")
        #expect(file.pois[1].signals == Signals(photos: 0.82, fame: 0.4, quality: 0.6, independent: true))
        #expect(file.pois[1].cuisine == ["italian"])
        #expect(file.pois[1].openingHours == "Mo-Sa 10:00-20:00")
        #expect(file.pois[1].coordinate == Coordinate(lat: 51.76, lon: 19.46))
        #expect(file.pois[0].commonsImage == "Mural in Łódź.jpg")
        #expect(file.pois[1].commonsImage == nil)
        #expect(file.pois[0].localName == "Mural przy Piotrkowskiej")
        #expect(file.pois[1].localName == nil)
        #expect(file.pois[0].commonsCategory == "Murals in Łódź" && file.pois[0].popular == true)
        #expect(file.pois[1].commonsCategory == nil && file.pois[1].popular == nil)
    }

    @Test func roundTrips() throws {
        let poi = POI(id: "osm:node:3", name: "Shop", lat: 1, lon: 2, category: .shop, score: 50, kind: .stop, reason: "Indie",
                      type: "books", signals: Signals(photos: 0.1, fame: 0, quality: 0.5, independent: true),
                      openingHours: "Mo-Fr 10:00-18:00")
        let data = try JSONEncoder().encode(poi)
        #expect(try JSONDecoder().decode(POI.self, from: data) == poi)
    }
}
