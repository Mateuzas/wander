import Foundation
import Observation
import RouteEngine

/// The phone's swipe memory (ADR 016): every reaction per place, plus the places
/// walked, kept in Application Support/swipe-memory.json. No account, nothing
/// leaves the phone.
@MainActor
@Observable
final class SwipeMemoryStore {
    private struct File: Codable {
        var memory: SwipeMemory
        /// Place id → when it was last walked past as a stop.
        var walked: [String: Date]
    }

    private(set) var memory: SwipeMemory
    /// Place id → when it was last walked as a stop.
    private(set) var walked: [String: Date]

    @ObservationIgnored private let url: URL?

    init(url: URL? = SwipeMemoryStore.defaultURL) {
        self.url = url
        let file = url
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder.memory.decode(File.self, from: $0) }
        memory = file?.memory ?? SwipeMemory()
        walked = file?.walked ?? [:]
    }

    /// Places walked today: they count as seen and go to the back of the deck.
    func seen(now: Date = .now, calendar: Calendar = .current) -> Set<String> {
        Set(walked.filter { calendar.isDate($0.value, inSameDayAs: now) }.keys)
    }

    func record(_ reaction: Reaction, for poi: POI, at date: Date = .now) {
        memory.record(reaction, for: poi, at: date)
        save()
    }

    /// Puts back what was there before a swipe (one-level undo).
    func restore(_ entry: SwipeMemory.Entry?, for poiId: String) {
        if let entry {
            memory.entries[poiId] = entry
        } else {
            memory.forget(poiId)
        }
        save()
    }

    func markWalked(_ ids: some Sequence<String>, at date: Date = .now) {
        var changed = false
        for id in ids {
            walked[id] = date
            changed = true
        }
        if changed { save() }
    }

    // MARK: - File

    nonisolated static var defaultURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("swipe-memory.json")
    }

    /// Small (a few hundred entries at most), so it's written whole on every change.
    private func save() {
        guard let url else { return }
        // Walks older than a week no longer matter for "seen today".
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 3600)
        walked = walked.filter { $0.value > cutoff }
        guard let data = try? JSONEncoder.memory.encode(File(memory: memory, walked: walked)) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

private extension JSONEncoder {
    static var memory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var memory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
