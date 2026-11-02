import CoreLocation
import Foundation
import MapKit
import RouteEngine

/// Decides whether an Apple Maps result is the same place as one of our POIs.
/// Pure, so it can be tested without MapKit. Wrongly matching is worse than not
/// matching: a card for the wrong place is a bug, a missing card is not.
enum PlaceMatch {
    /// A result further than this from the POI's coordinate is never accepted.
    static let maxDistance: CLLocationDistance = 60
    /// Shorter names ("A", "Bar") are too generic for a containment match.
    static let minContainedLength = 4

    /// Lower-case, no diacritics, letters and digits only. Handles letters that
    /// diacritic folding leaves alone (ł, ø, đ, ß).
    static func normalized(_ name: String) -> String {
        var text = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for (from, to) in [("ł", "l"), ("ø", "o"), ("đ", "d"), ("ß", "ss"), ("æ", "ae"), ("œ", "oe")] {
            text = text.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        return String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Equal, or one contains the other (so "Manufaktura" matches "Manufaktura Łódź").
    static func namesMatch(_ a: String, _ b: String) -> Bool {
        let a = normalized(a), b = normalized(b)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= minContainedLength && long.contains(short)
    }

    /// True when the result is within `maxDistance` and its name matches any of the
    /// POI's names (display name and original local name).
    static func isMatch(poiNames: [String], poiCoordinate: Coordinate,
                        itemName: String?, itemCoordinate: Coordinate) -> Bool {
        guard let itemName, poiCoordinate.distance(to: itemCoordinate) <= maxDistance else { return false }
        return poiNames.contains { namesMatch($0, itemName) }
    }
}

/// Finds the Apple Maps place that matches a POI, for the place card with photos,
/// ratings and hours (iOS 18+). Looked up on demand when a bead is tapped.
@MainActor
final class PlaceInfoService {
    static let shared = PlaceInfoService()

    private enum Entry {
        case match(MKMapItem)
        case noMatch
    }

    /// Session cache by POI id. Failures (offline, throttled) are not cached,
    /// so a later tap tries again.
    private var cache: [String: Entry] = [:]

    /// Names to match against Apple's result, local name first. Apple's names are
    /// in the place's own language, ours are English display names.
    private func names(of poi: POI) -> [String] { [poi.localName, poi.name].compactMap { $0 } }

    /// The matching place, or nil when there is none or we can't tell.
    func place(for poi: POI) async -> MKMapItem? {
        if let hit = cache[poi.id] {
            if case .match(let item) = hit { return item }
            return nil
        }

        let request = MKLocalSearch.Request()
        let names = names(of: poi)
        request.naturalLanguageQuery = names[0]
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(center: poi.coordinate.clLocation,
                                            latitudinalMeters: 300, longitudinalMeters: 300)
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            return nil
        }

        let best = response.mapItems
            .filter { item in
                PlaceMatch.isMatch(poiNames: names, poiCoordinate: poi.coordinate,
                                   itemName: item.name,
                                   itemCoordinate: Coordinate(item.placemark.coordinate))
            }
            .min { lhs, rhs in
                poi.coordinate.distance(to: Coordinate(lhs.placemark.coordinate))
                    < poi.coordinate.distance(to: Coordinate(rhs.placemark.coordinate))
            }
        cache[poi.id] = best.map(Entry.match) ?? .noMatch
        return best
    }
}

// MARK: - Wikimedia Commons photo

/// A Commons photo with the credit Wikimedia's licences require.
struct CommonsPhoto: Equatable {
    let imageURL: URL
    /// Nil when the file's metadata has no author.
    let author: String?
    let license: String
    let licenseURL: URL?
    let pageURL: URL
}

/// Session cache for Commons lookups. Failures aren't cached, so a later tap retries.
@MainActor
final class CommonsPhotoCache {
    static let shared = CommonsPhotoCache()
    private var photos: [String: CommonsPhoto] = [:]

    /// A ~800 px rendition plus author and licence for a Commons file name such as
    /// "Manufaktura Łódź.jpg". Nil on any failure.
    func photo(fileName: String) async -> CommonsPhoto? {
        if let hit = photos[fileName] { return hit }
        guard let photo = await Self.fetch(fileName: fileName) else { return nil }
        photos[fileName] = photo
        return photo
    }

    private nonisolated static func fetch(fileName: String) async -> CommonsPhoto? {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "titles", value: "File:\(fileName)"),
            .init(name: "prop", value: "imageinfo"),
            .init(name: "iiprop", value: "url|extmetadata"),
            .init(name: "iiurlwidth", value: "800"),
            .init(name: "redirects", value: "1"),
            .init(name: "format", value: "json"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("WanderMVP/0.1 (personal walking-route prototype)", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: Any],
              let page = pages.values.first as? [String: Any],
              let info = (page["imageinfo"] as? [[String: Any]])?.first,
              let thumb = (info["thumburl"] as? String) ?? (info["url"] as? String),
              let imageURL = URL(string: thumb),
              let pageURL = (info["descriptionurl"] as? String).flatMap(URL.init(string:)),
              let meta = info["extmetadata"] as? [String: Any]
        else { return nil }

        func value(_ key: String) -> String? {
            ((meta[key] as? [String: Any])?["value"] as? String).map(plainText)
        }
        guard let license = value("LicenseShortName") else { return nil }
        return CommonsPhoto(imageURL: imageURL,
                            author: value("Artist"),
                            license: license,
                            licenseURL: value("LicenseUrl").flatMap(URL.init(string:)),
                            pageURL: pageURL)
    }

    /// Commons credits are HTML snippets; drop the tags and common entities.
    private nonisolated static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
