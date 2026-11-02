import MapKit
import Observation

/// Destination search. As-you-type suggestions come from MKLocalSearchCompleter;
/// picking one resolves it to a place with MKLocalSearch. Both are biased to the
/// region the map is showing.
@MainActor
@Observable
final class SearchService: NSObject {
    struct Suggestion: Identifiable, Hashable {
        let id: Int
        let title: String
        let subtitle: String
        fileprivate let completion: MKLocalSearchCompletion
    }

    enum SearchError: Error {
        case noMatch
    }

    var query = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                completer.cancel()
                suggestions = []
            } else {
                completer.queryFragment = trimmed
            }
        }
    }

    private(set) var suggestions: [Suggestion] = []

    /// The visible map region. Set this as the camera moves.
    var region: MKCoordinateRegion? {
        didSet { if let region { completer.region = region } }
    }

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Resolves a suggestion to a place with a coordinate.
    func place(for suggestion: Suggestion) async throws -> MKMapItem {
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        if let region { request.region = region }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw SearchError.noMatch }
        return item
    }

    /// Searches the typed text directly (Return key without picking a suggestion).
    func place(forText text: String) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let region { request.region = region }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw SearchError.noMatch }
        return item
    }

    func clear() {
        query = ""
    }
}

extension SearchService: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results.enumerated().map { index, completion in
            Suggestion(id: index, title: completion.title, subtitle: completion.subtitle, completion: completion)
        }
        Task { @MainActor in
            // Drop stale results that arrive after the field was cleared.
            guard !self.query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.suggestions = results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
