import Foundation
import Testing
@testable import RouteEngine

struct OpeningHoursTests {
    static let warsaw = TimeZone(identifier: "Europe/Warsaw")!

    /// 2026-11-02 is a Monday.
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.warsaw
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 2 + day, hour: hour, minute: minute))!
    }

    func open(_ raw: String, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Bool? {
        OpeningHours(raw)?.isOpen(at: at(day, hour, minute), in: Self.warsaw)
    }

    @Test func simpleWeekdayRules() {
        let raw = "Mo-Fr 10:00-18:00; Sa 10:00-15:00"
        #expect(open(raw, 0, 9, 59) == false)
        #expect(open(raw, 0, 10) == true)
        #expect(open(raw, 4, 17, 59) == true)
        #expect(open(raw, 4, 18) == false)
        #expect(open(raw, 5, 14) == true)
        #expect(open(raw, 6, 12) == false)   // Sunday not mentioned
    }

    @Test func pastMidnightSpillsIntoNextDay() {
        let raw = "Mo-Th 13:00-01:00; Fr-Sa 12:00-02:00; Su off"
        #expect(open(raw, 1, 0, 30) == true)   // Tuesday 00:30, from Monday
        #expect(open(raw, 6, 1, 30) == true)   // Sunday 01:30, from Saturday
        #expect(open(raw, 6, 13) == false)
        #expect(open(raw, 0, 0, 30) == false)  // Monday 00:30: Sunday is off
        #expect(open("Mo-Th 10:00-24:00", 0, 23, 59) == true)
        #expect(open("Mo-Th 10:00-00:00", 0, 23, 59) == true)
    }

    @Test func wrapsListsCommasAndSpaces() {
        let raw = "Su - Th 10:00 - 22:30, Fr - Sa 10:00 - 23:30"
        #expect(open(raw, 6, 22) == true)      // Sunday
        #expect(open(raw, 4, 23) == true)      // Friday
        #expect(open(raw, 3, 23) == false)     // Thursday
        #expect(open("Tu-Sa 15:00-22:00, Mo off", 0, 16) == false)
        #expect(open("Tu-Fr: 12:00-18:00; Sa-Su: 10:00-18:00", 5, 11) == true)
        #expect(open("Mo off; Tu, Fr-Sa 19:03-02:03; We-Th 18:03-23:03", 4, 20) == true)
        #expect(open("Mo off; Tu, Fr-Sa 19:03-02:03; We-Th 18:03-23:03", 3, 23, 30) == false)
    }

    @Test func holidaysOpenEndAndAlways() {
        #expect(open("Mo-Sa 09:00-21:00; Su 10:00-19:00; PH off", 6, 12) == true)
        #expect(open("Mo-Fr 10:00-18:00; Sa 10:00-13:00; Su,PH off", 6, 12) == false)
        #expect(open("We,Th 14:00-19:00; Fr-Su,PH 11:00-19:00", 6, 12) == true)
        #expect(open("12:00+", 2, 23) == true)
        #expect(open("12:00+", 2, 11) == false)
        #expect(open("24/7", 3, 4) == true)
        #expect(open("closed", 3, 12) == false)
    }

    @Test func rejectsWhatItCannotRead() {
        #expect(OpeningHours("\"od poniedziałku do niedzieli od dwunastej\"") == nil)
        #expect(OpeningHours("Permanently closed") == nil)
        #expect(OpeningHours("Mo-Fr") == nil)
        #expect(OpeningHours("Jan-Mar Mo-Fr 10:00-16:00") == nil)
        #expect(OpeningHours("Mo-Fr sunrise-sunset") == nil)
        #expect(OpeningHours("") == nil)
    }

    @Test func plannerSkipsClosedStops() async throws {
        var closed = Grid.poi("closed", east: 1000, north: 150, category: .food, score: 90)
        closed.openingHours = "Mo-Fr 10:00-18:00"
        var unreadable = Grid.poi("unreadable", east: 500, north: -150, category: .food, score: 80)
        unreadable.openingHours = "ask at the bar"
        let open = Grid.poi("noHours", east: 1500, north: 150, category: .shop, score: 70)
        let sunday = at(6, 12)

        let request = PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .explorer,
                                  pois: [closed, unreadable, open], time: sunday, timeZone: Self.warsaw)
        let result = try await Planner().plan(request, provider: HaversineWalkingTime())
        #expect(!result.waypoints.contains { $0.id == "closed" })
        #expect(result.candidates.first { $0.poi.id == "closed" }?.status == .rejected(.closed))
        #expect(Set(result.waypoints.map(\.id)) == ["unreadable", "noHours"])

        // Without a time, hours are not checked.
        var anyTime = request
        anyTime.time = nil
        let noTime = try await Planner().plan(anyTime, provider: HaversineWalkingTime())
        #expect(noTime.waypoints.contains { $0.id == "closed" })
    }
}
