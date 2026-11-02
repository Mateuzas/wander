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

// MARK: - Wikimedia Commons photos

/// A Commons photo with the credit Wikimedia's licences require.
struct CommonsPhoto: Equatable, Identifiable {
    /// File name without the "File:" prefix, spaces not underscores.
    let fileName: String
    let imageURL: URL
    /// Nil when the file's metadata has no author.
    let author: String?
    let license: String
    let licenseURL: URL?
    let pageURL: URL

    var id: String { fileName }
}

/// Session cache for Commons lookups. Failures aren't cached, so a later tap retries.
@MainActor
final class CommonsPhotoCache {
    static let shared = CommonsPhotoCache()
    /// Extra gallery photos beyond the main one.
    static let galleryLimit = 10

    private var photos: [String: CommonsPhoto] = [:]
    private var galleries: [String: [CommonsPhoto]] = [:]

    /// A ~800 px rendition plus author and licence for a Commons file name such as
    /// "Manufaktura Łódź.jpg". Nil on any failure.
    func photo(fileName: String) async -> CommonsPhoto? {
        if let hit = photos[fileName] { return hit }
        let query = [
            "titles": "File:\(fileName)", "redirects": "1",
        ]
        guard let pages = await Self.fetchPages(query), let photo = pages.compactMap(Self.photo(from:)).first
        else { return nil }
        photos[fileName] = photo
        return photo
    }

    /// Up to `galleryLimit` more images from a Commons category, never `excluding`
    /// the main photo. Empty on any failure, so the caller just shows what it has.
    func gallery(category: String, excluding fileName: String?) async -> [CommonsPhoto] {
        if let hit = galleries[category] { return Self.without(fileName, in: hit) }
        let query = [
            "generator": "categorymembers", "gcmtitle": "Category:\(category)",
            "gcmtype": "file", "gcmlimit": "\(Self.galleryLimit + 6)",
            "redirects": "1",
        ]
        guard let pages = await Self.fetchPages(query) else { return [] }
        let all = pages
            .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
            .compactMap(Self.photo(from:))
        galleries[category] = all
        return Self.without(fileName, in: all)
    }

    private static func without(_ fileName: String?, in photos: [CommonsPhoto]) -> [CommonsPhoto] {
        Array(photos.filter { $0.fileName != fileName }.prefix(galleryLimit))
    }

    private nonisolated static let imageTypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]

    /// One API call: imageinfo (800 px thumbnail, url, credit) for the given titles or generator.
    private nonisolated static func fetchPages(_ extra: [String: String]) async -> [[String: Any]]? {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        var items: [String: String] = [
            "action": "query", "prop": "imageinfo", "iiprop": "url|extmetadata|mime",
            "iiurlwidth": "800", "format": "json",
        ]
        items.merge(extra) { $1 }
        components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("WanderMVP/0.1 (personal walking-route prototype)", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: Any]
        else { return nil }
        return pages.values.compactMap { $0 as? [String: Any] }
    }

    /// Nil for anything that isn't a plain photo (SVG, audio, PDF, missing file).
    private nonisolated static func photo(from page: [String: Any]) -> CommonsPhoto? {
        guard let title = page["title"] as? String, title.hasPrefix("File:"),
              let info = (page["imageinfo"] as? [[String: Any]])?.first,
              let mime = info["mime"] as? String, imageTypes.contains(mime),
              let thumb = (info["thumburl"] as? String) ?? (info["url"] as? String),
              let imageURL = URL(string: thumb),
              let pageURL = (info["descriptionurl"] as? String).flatMap(URL.init(string:)),
              let meta = info["extmetadata"] as? [String: Any]
        else { return nil }

        func value(_ key: String) -> String? {
            ((meta[key] as? [String: Any])?["value"] as? String).map(plainText)
        }
        guard let license = value("LicenseShortName") else { return nil }
        return CommonsPhoto(fileName: String(title.dropFirst("File:".count)),
                            imageURL: imageURL,
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
