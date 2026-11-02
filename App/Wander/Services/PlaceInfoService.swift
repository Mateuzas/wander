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

    static func isMatch(poiName: String, poiCoordinate: Coordinate,
                        itemName: String?, itemCoordinate: Coordinate) -> Bool {
        guard let itemName, poiCoordinate.distance(to: itemCoordinate) <= maxDistance else { return false }
        return namesMatch(poiName, itemName)
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

    /// The matching place, or nil when there is none or we can't tell.
    func place(for poi: POI) async -> MKMapItem? {
        if let hit = cache[poi.id] {
            if case .match(let item) = hit { return item }
            return nil
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = poi.name
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
                PlaceMatch.isMatch(poiName: poi.name, poiCoordinate: poi.coordinate,
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

// MARK: - Wikimedia Commons fallback (disabled)

/// A Commons photo with the credit Wikimedia's licences require.
struct CommonsPhoto: Equatable {
    let imageURL: URL
    let author: String
    let license: String
    let licenseURL: URL?
    let pageURL: URL
}

extension PlaceInfoService {
    // TODO: enable once the data agent adds `commonsImage` (a Commons file name,
    // sights only) to POI. Until then the property doesn't exist and this stays off.
    static let commonsFallbackEnabled = false

    /// Fetches a 800 px rendition plus author and licence for a Commons file name
    /// such as "Manufaktura Łódź.jpg". Returns nil on any failure.
    func commonsPhoto(fileName: String) async -> CommonsPhoto? {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "titles", value: "File:\(fileName)"),
            .init(name: "prop", value: "imageinfo"),
            .init(name: "iiprop", value: "url|extmetadata"),
            .init(name: "iiurlwidth", value: "800"),
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
            ((meta[key] as? [String: Any])?["value"] as? String).map(Self.plainText)
        }
        guard let license = value("LicenseShortName") else { return nil }
        return CommonsPhoto(imageURL: imageURL,
                            author: value("Artist") ?? "Unknown author",
                            license: license,
                            licenseURL: value("LicenseUrl").flatMap(URL.init(string:)),
                            pageURL: pageURL)
    }

    /// Commons credits are HTML snippets; drop the tags.
    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
