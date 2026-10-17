import Testing
@testable import RouteEngine

struct HaversineTests {
    @Test func distanceIsZeroForSamePoint() {
        let p = Coordinate(lat: 52.3731, lon: 4.8926)
        #expect(p.distance(to: p) == 0)
    }

    @Test func distanceMatchesKnownPair() {
        // Amsterdam Centraal → Dam Square, roughly 900 m in a straight line.
        let centraal = Coordinate(lat: 52.3791, lon: 4.9003)
        let dam = Coordinate(lat: 52.3731, lon: 4.8926)
        let d = centraal.distance(to: dam)
        #expect(d > 800 && d < 950)
    }

    @Test func providerAppliesTortuosityAndSpeed() async throws {
        let a = Coordinate(lat: 0, lon: 0)
        let b = Coordinate(lat: 0, lon: 0.01)
        let provider = HaversineWalkingTime()
        let leg = try await provider.leg(from: a, to: b)
        #expect(abs(leg.duration - a.distance(to: b) * 1.3 / 1.35) < 0.001)
    }
}
