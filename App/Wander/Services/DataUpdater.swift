import CryptoKit
import Foundation
import os
import RouteEngine

/// Keeps the city's places fresh from the nightly publish (ADR 013, CONTRACTS §3b).
///
/// At most every 6 h it fetches `manifest.json` (ETag / If-None-Match). When the
/// city's sha256 differs from the data in use, it downloads the city file, checks
/// the sha256, decodes it with `POIFile`, and only then atomically replaces the
/// cached copy in Application Support. It also refuses a file older than the
/// data in use, or with under half the bundled file's POIs (FE-21). Any failure
/// leaves the current data alone and is logged quietly: no error UI, and the
/// bundled file always works.
@MainActor
final class DataUpdater {
    /// The published data, schema major version 1 (ADR 013).
    nonisolated static let baseURL = URL(string: "https://mateuzas.github.io/wander/data/v1/")!
    /// Shortest gap between two manifest checks (CONTRACTS §3b).
    nonisolated static let minInterval: TimeInterval = 6 * 60 * 60

    private static let lastCheckKey = "dataUpdater.lastCheck"
    private static let etagKey = "dataUpdater.manifestETag"

    let city: String
    private let defaults: UserDefaults
    private let session: URLSession
    private var running = false

    init(city: String = POIStore.pilotCity, defaults: UserDefaults = .standard) {
        self.city = city
        self.defaults = defaults
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData  // the ETag is ours
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Checks for a newer city file if the last check is 6 h old or more.
    /// `current` describes the data in use (cached or bundled).
    /// Returns the new file once it is verified and safely on disk, otherwise nil.
    func refreshIfDue(current: DataFeed.Baseline, now: Date = .now) async -> DataFeed.Update? {
        guard !running else { return nil }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now.timeIntervalSince(last) < Self.minInterval, now >= last {
            return nil
        }
        running = true
        defer { running = false }
        do {
            return try await refresh(current: current, now: now)
        } catch {
            DataFeed.log.notice("Update skipped: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func refresh(current: DataFeed.Baseline, now: Date) async throws -> DataFeed.Update? {
        var request = URLRequest(url: DataFeed.manifestURL)
        // Only trust a 304 when there is a cached download it could refer to.
        if let etag = defaults.string(forKey: Self.etagKey), DataFeed.cachedFileExists(city: city) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (body, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 304:
            defaults.set(now, forKey: Self.lastCheckKey)
            DataFeed.log.debug("Manifest unchanged")
            return nil
        case 404:
            // Nothing published yet (before the first nightly run): no update.
            defaults.set(now, forKey: Self.lastCheckKey)
            DataFeed.log.info("No manifest published yet")
            return nil
        case 200:
            break
        default:
            throw DataFeed.Failure.http(status)
        }

        let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        guard let manifest = DataFeed.parseManifest(body) else {
            // Unknown schema or unreadable: ignore it until it changes.
            markChecked(now: now, etag: etag)
            DataFeed.log.notice("Manifest ignored: unsupported schema or unreadable")
            return nil
        }
        guard let entry = manifest.cities[city] else {
            markChecked(now: now, etag: etag)
            return nil
        }
        if let currentSHA256 = current.sha256, DataFeed.sameDigest(currentSHA256, entry.sha256) {
            markChecked(now: now, etag: etag)
            DataFeed.log.debug("City file unchanged")
            return nil
        }
        guard let fileURL = DataFeed.fileURL(for: entry) else { throw DataFeed.Failure.badURL }

        let (data, fileResponse) = try await session.data(from: fileURL)
        let fileStatus = (fileResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard fileStatus == 200 else { throw DataFeed.Failure.http(fileStatus) }
        let file = try DataFeed.verify(data, sha256: entry.sha256, city: city)
        do {
            try DataFeed.accept(file, over: current)
        } catch {
            // Not retried until the manifest changes: the same file would fail again.
            markChecked(now: now, etag: etag)
            throw error
        }
        try DataFeed.store(data, city: city)
        // Remember the ETag only now, so a failed download is retried next time.
        markChecked(now: now, etag: etag)
        DataFeed.log.info("Places updated: \(file.pois.count) POIs, generated \(file.generated, privacy: .public)")
        return DataFeed.Update(file: file, sha256: entry.sha256.lowercased())
    }

    private func markChecked(now: Date, etag: String?) {
        defaults.set(now, forKey: Self.lastCheckKey)
        if let etag { defaults.set(etag, forKey: Self.etagKey) } else { defaults.removeObject(forKey: Self.etagKey) }
    }
}

/// The updater's verification steps as small pure functions, so the DEBUG
/// self-check can exercise them without the network.
enum DataFeed {
    static let log = Logger(subsystem: "com.mateuzas.wander", category: "DataUpdater")
    static let supportedSchema = 1

    static var manifestURL: URL { DataUpdater.baseURL.appendingPathComponent("manifest.json") }

    /// The data in use, for judging a download (FE-21).
    struct Baseline {
        var sha256: String?
        /// `generated` of the data in use.
        var generated: String
        /// POIs in the bundled file; 0 if it is missing.
        var bundledCount: Int
    }

    /// A verified city file and the digest of its bytes.
    struct Update {
        var file: POIFile
        var sha256: String
    }

    enum Failure: Error, Equatable {
        case http(Int)
        case badURL
        case checksumMismatch
        case wrongCity(String)
        case noPOIs
        /// Fewer than half the bundled file's POIs: likely a broken publish.
        case tooSmall(Int)
        /// Generated before the data in use.
        case older(String)
    }

    /// Smallest share of the bundled file's POI count a download may have.
    static let minShareOfBundled = 0.5

    /// FE-21: a verified download is used only if it isn't suspiciously small and
    /// isn't older than the data in use.
    static func accept(_ file: POIFile, over current: Baseline) throws {
        if current.bundledCount > 0, Double(file.pois.count) < Double(current.bundledCount) * minShareOfBundled {
            throw Failure.tooSmall(file.pois.count)
        }
        if isNewer(current.generated, than: file.generated) { throw Failure.older(file.generated) }
    }

    /// FE-21 load order: the cached download is used only when it is newer than
    /// the bundled file; ties go to the bundled one.
    static func preferCached(_ cached: POIFile, over bundled: POIFile) -> Bool {
        isNewer(cached.generated, than: bundled.generated)
    }

    /// Compares two `generated` values as dates; as text if either can't be read.
    static func isNewer(_ a: String, than b: String) -> Bool {
        if let da = parseDate(a), let db = parseDate(b) { return da > db }
        return a > b
    }

    /// `manifest.json` (CONTRACTS §3b).
    struct Manifest: Decodable, Equatable {
        struct City: Decodable, Equatable {
            var url: String
            var sha256: String
            var bytes: Int?
            var pois: Int?
            var generated: String?
        }

        var schema: Int
        var generated: String
        var cities: [String: City]
    }

    /// The manifest, or nil if it is unreadable or not schema 1.
    static func parseManifest(_ data: Data) -> Manifest? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schema == supportedSchema else { return nil }
        return manifest
    }

    /// The city file's URL; a relative `url` resolves against the base URL.
    static func fileURL(for entry: Manifest.City) -> URL? {
        guard let url = URL(string: entry.url, relativeTo: DataUpdater.baseURL)?.absoluteURL,
              url.scheme == "https" else { return nil }
        return url
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sameDigest(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }

    /// Decodes a city file and checks it is for `city` and not empty.
    static func decode(_ data: Data, city: String) throws -> POIFile {
        let file = try JSONDecoder().decode(POIFile.self, from: data)
        // The file says "Vilnius"; the slug is "vilnius".
        guard file.city.lowercased() == city.lowercased() else { throw Failure.wrongCity(file.city) }
        guard !file.pois.isEmpty else { throw Failure.noPOIs }
        return file
    }

    /// A downloaded file is used only if its sha256 matches the manifest and it decodes.
    static func verify(_ data: Data, sha256: String, city: String) throws -> POIFile {
        guard sameDigest(sha256Hex(data), sha256) else { throw Failure.checksumMismatch }
        return try decode(data, city: city)
    }

    // MARK: - Cache on disk

    /// Application Support/Data/pois-<city>.json
    static func cacheURL(city: String) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return support.appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("pois-\(city).json")
    }

    static func cachedFileExists(city: String) -> Bool {
        guard let url = cacheURL(city: city) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes verified data. `.atomic` writes a temporary file and renames it over
    /// the old one, so the previous copy stays until the new one is complete.
    static func store(_ data: Data, city: String) throws {
        guard var url = cacheURL(city: city) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // Re-downloadable, so keep it out of the user's backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Caption

    /// "today", "yesterday", "3 days ago", "last week" for the file's `generated`
    /// ("2026-11-05" or a full ISO 8601 timestamp); nil if it can't be read.
    static func relativeDate(_ generated: String, now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let date = parseDate(generated) else { return nil }
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.calendar = calendar
        if day >= today { return formatter.localizedString(from: DateComponents(day: 0)) }
        return formatter.localizedString(for: day, relativeTo: today)
    }

    static func parseDate(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        full.formatOptions.insert(.withFractionalSeconds)
        if let date = full.date(from: text) { return date }
        // A date-only value is a calendar day, read in the phone's time zone.
        let dayOnly = DateFormatter()
        dayOnly.calendar = Calendar(identifier: .gregorian)
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = .current
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: text)
    }
}

#if DEBUG
extension DataFeed {
    /// Exercises the verification steps with a sample manifest and the bundled
    /// file (the app has no unit-test target). Runs once at launch in Debug
    /// builds; a failure trips an assertion.
    static func selfCheck(city: String = POIStore.pilotCity, bundle: Bundle = .main) {
        let sample = Data("""
            {"schema": 1, "generated": "2026-11-06T02:41:07Z",
             "cities": {"vilnius": {"url": "pois-vilnius.json", "sha256": "ABC123",
                                    "bytes": 10, "pois": 2, "generated": "2026-11-06T02:40:00Z"}}}
            """.utf8)
        let manifest = parseManifest(sample)
        assert(manifest?.cities["vilnius"]?.sha256 == "ABC123", "manifest parse")
        assert(manifest.flatMap { $0.cities["vilnius"] }.flatMap(fileURL(for:))?.absoluteString
               == "https://mateuzas.github.io/wander/data/v1/pois-vilnius.json", "relative url")
        assert(parseManifest(Data(#"{"schema": 2, "generated": "x", "cities": {}}"#.utf8)) == nil, "schema 2 ignored")
        assert(parseManifest(Data("<html>404</html>".utf8)) == nil, "garbage ignored")
        assert(fileURL(for: .init(url: "http://example.com/a.json", sha256: "")) == nil, "http refused")

        guard let url = bundle.url(forResource: "pois-\(city)", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("bundled pois-\(city).json missing")
            return
        }
        let digest = sha256Hex(data)
        assert(digest.count == 64, "sha256 hex length")
        assert((try? verify(data, sha256: digest.uppercased(), city: city)) != nil, "bundled file verifies")
        assert((try? verify(data, sha256: String(repeating: "0", count: 64), city: city)) == nil, "bad sha rejected")
        assert((try? verify(data, sha256: digest, city: "riga")) == nil, "wrong city rejected")
        let truncated = data.prefix(data.count / 2)
        assert((try? verify(truncated, sha256: sha256Hex(truncated), city: city)) == nil, "corrupt file rejected")

        // FE-21: newest data wins; suspiciously small or older downloads are refused.
        if let bundled = try? decode(data, city: city) {
            var older = bundled, newer = bundled
            older.generated = "2000-01-01T00:00:00Z"
            newer.generated = "2999-01-01T00:00:00Z"
            assert(!preferCached(older, over: bundled), "older cached loses to newer bundled")
            assert(!preferCached(bundled, over: bundled), "tie goes to bundled")
            assert(preferCached(newer, over: bundled), "newer cached wins")
            let baseline = Baseline(sha256: digest, generated: bundled.generated, bundledCount: bundled.pois.count)
            var small = newer
            small.pois = Array(bundled.pois.prefix(bundled.pois.count / 2 - 1))
            assert((try? accept(small, over: baseline)) == nil, "too-small download rejected")
            assert((try? accept(older, over: baseline)) == nil, "older download rejected")
            assert((try? accept(newer, over: baseline)) != nil, "newer full download accepted")
        } else {
            assertionFailure("bundled file decodes")
        }

        let noon = parseDate("2026-11-06T12:00:00Z")!
        assert(parseDate("2026-11-05") != nil && parseDate("nonsense") == nil, "date parse")
        assert(relativeDate("2026-11-06T12:00:00Z", now: noon) != nil, "relative date")
        log.debug("DataFeed self-check passed (bundled sha256 \(digest, privacy: .public))")
    }
}
#endif
