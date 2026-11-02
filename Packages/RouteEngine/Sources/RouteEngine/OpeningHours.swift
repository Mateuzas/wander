import Foundation

/// A parsed subset of OSM `opening_hours` syntax, enough for "is it open now".
///
/// Supported: weekday ranges and lists (`Mo-Fr`, `Tu,Th`, `Su-Th`), time spans
/// (`10:00-18:00`, past midnight `18:00-02:00`, `10:00-24:00`), open end
/// (`12:00+`, treated as open until midnight), `off`/`closed`, `24/7`, rules
/// separated by `;` or `,`. Later rules replace earlier ones for their days.
/// Public holidays (`PH`, `SH`) are ignored. Days no rule mentions are closed.
/// Anything else (months, weeks, sunrise, free text) fails to parse, and the
/// planner then keeps the POI rather than guessing it is closed.
public struct OpeningHours: Hashable, Sendable {
    /// Open spans per weekday (0 = Monday) in minutes from midnight; an end
    /// above 1440 spills into the next day.
    private var week: [[ClosedRange<Int>]]

    private static let days = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

    public init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "24/7" {
            week = Array(repeating: [0...1440], count: 7)
            return
        }
        // Normalise "Su - Th 10:00 - 22:30, Fr" to "Su-Th 10:00-22:30,Fr".
        let normalised = text
            .replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s*,\s*"#, with: ",", options: .regularExpression)
        var week: [[ClosedRange<Int>]] = Array(repeating: [], count: 7)
        var parsedAnyRule = false

        for part in normalised.split(separator: ";") {
            let tokens = part.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            guard !tokens.isEmpty else { continue }

            var selectedDays: [Int] = []
            var hasSelector = false
            var spans: [ClosedRange<Int>] = []
            var off = false
            var sawTimes = false

            func flush() -> Bool {
                guard sawTimes else { return false }
                let target = hasSelector ? selectedDays : Array(0..<7)
                for day in target { week[day] = off ? [] : spans }
                parsedAnyRule = true
                selectedDays = []; hasSelector = false; spans = []; off = false; sawTimes = false
                return true
            }

            for token in tokens {
                if let range = Self.dayRange(token) {
                    if sawTimes, !flush() { return nil }
                    selectedDays += range
                    hasSelector = true
                } else if token == "PH" || token == "SH" {
                    if sawTimes, !flush() { return nil }
                    hasSelector = true
                } else if token == "off" || token == "closed" {
                    off = true
                    sawTimes = true
                } else if let span = Self.timeSpan(token) {
                    spans.append(span)
                    sawTimes = true
                } else {
                    return nil
                }
            }
            if !flush() { return nil }
        }
        guard parsedAnyRule else { return nil }
        self.week = week
    }

    /// Whether the place is open at `date` in `timeZone`.
    public func isOpen(at date: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let day = (parts.weekday! + 5) % 7          // Calendar: 1 = Sunday
        let minute = parts.hour! * 60 + parts.minute!
        if week[day].contains(where: { $0.lowerBound <= minute && minute < $0.upperBound }) { return true }
        let previous = (day + 6) % 7
        return week[previous].contains { $0.upperBound > 1440 && minute < $0.upperBound - 1440 }
    }

    private static func dayRange(_ token: String) -> [Int]? {
        let ends = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(ends.count),
              let start = days.firstIndex(of: ends[0]),
              let end = ends.count == 2 ? days.firstIndex(of: ends[1]) : start else { return nil }
        var result = [start]
        var day = start
        while day != end {
            day = (day + 1) % 7
            result.append(day)
        }
        return result
    }

    private static func timeSpan(_ token: String) -> ClosedRange<Int>? {
        if token.hasSuffix("+") {
            guard let start = minutes(String(token.dropLast())), start < 1440 else { return nil }
            return start...1440
        }
        let ends = token.split(separator: "-").map(String.init)
        guard ends.count == 2, let start = minutes(ends[0]), var end = minutes(ends[1]),
              start < 1440 else { return nil }
        if end <= start { end += 1440 }
        return start...end
    }

    private static func minutes(_ text: String) -> Int? {
        let hm = text.split(separator: ":")
        guard hm.count == 2, hm[1].count == 2, let h = Int(hm[0]), let m = Int(hm[1]),
              (0...24).contains(h), (0..<60).contains(m), h * 60 + m <= 1440 else { return nil }
        return h * 60 + m
    }
}
