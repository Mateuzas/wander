import RouteEngine
import SwiftUI

/// A remote photo filling whatever frame the caller gives it. Until the image is
/// ready, or if it fails, a neutral placeholder with the place's glyph shows in the
/// same frame (no spinner, no layout jump). Cached images appear on the first frame.
struct RemoteImage: View {
    let url: URL?
    /// SF Symbol for the placeholder: the place's glyph.
    let glyph: String
    /// The placeholder's fill: `surfaceRaised` on the sheet, `surface` on a raised card.
    var placeholder: Color = .surfaceRaised
    var glyphSize: CGFloat = 22
    /// Called once loading settles: true with an image, false on failure or no URL.
    var onResult: ((Bool) -> Void)?

    @State private var image: UIImage?

    var body: some View {
        placeholder
            .overlay {
                if image == nil {
                    Image(systemName: glyph)
                        .font(.system(size: glyphSize, weight: .semibold))
                        .foregroundStyle(.inkMuted)
                }
            }
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: url) { await load() }
            .accessibilityHidden(true)
    }

    private func load() async {
        guard let url else {
            image = nil
            onResult?(false)
            return
        }
        if let hit = ImageLoader.shared.cached(url) {
            image = hit
            onResult?(true)
            return
        }
        image = nil
        let loaded = await ImageLoader.shared.image(for: url)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        onResult?(loaded != nil)
    }
}

/// A place's photo filling the caller's frame: `photo` first, else the place's own
/// Commons image, else the glyph placeholder (never an empty frame).
struct PlaceImage: View {
    let poi: POI
    var placeholder: Color = .surfaceRaised
    var glyphSize: CGFloat = 22

    @State private var commonsURL: URL?

    private var url: URL? { poi.photo.flatMap { URL(string: $0.url) } ?? commonsURL }

    var body: some View {
        RemoteImage(url: url, glyph: poi.glyph, placeholder: placeholder, glyphSize: glyphSize)
            .task(id: poi.id) {
                commonsURL = nil
                guard poi.photo == nil, let file = poi.commonsImage else { return }
                let photo = await CommonsPhotoCache.shared.photo(fileName: file)
                guard !Task.isCancelled else { return }
                commonsURL = photo?.imageURL
            }
    }
}

/// A small square photo of a place for compact cards (food nearby, "Up ahead").
struct PlaceThumbnail: View {
    let poi: POI
    var size: CGFloat = 56
    var placeholder: Color = .surfaceRaised

    var body: some View {
        PlaceImage(poi: poi, placeholder: placeholder, glyphSize: size * 0.36)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension POI {
    /// The hook, trimmed; nil when missing or blank (older data files).
    var hookLine: String? {
        guard let text = hook?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The card's one-line pitch: the hook, else the reason for older data. Nil if neither.
    var pitch: String? {
        hookLine ?? (reason.isEmpty ? nil : reason)
    }
}

extension Photo {
    var imageURL: URL? { URL(string: url) }
    var pageURL: URL? { page.flatMap(URL.init(string:)) }

    /// "Photo: Jonas P. · via Mapillary, CC BY-SA", "Photo: Café Lūpa · from lupa.lt",
    /// "Photo: Jonas P., CC BY-SA 4.0 · Wikimedia Commons".
    var creditLine: String {
        let credit = credit.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin: String
        var who = credit
        switch source {
        case .commons:
            if let license { who = [credit, license].filter { !$0.isEmpty }.joined(separator: ", ") }
            origin = "Wikimedia Commons"
        case .mapillary:
            origin = "via Mapillary, \(license ?? "CC BY-SA")"
        case .website:
            origin = domain.map { "from \($0)" } ?? "from the place's website"
        }
        guard !who.isEmpty else { return source == .commons ? "Photo: \(origin)" : "Photo \(origin)" }
        return "Photo: \(who) · \(origin)"
    }

    /// The website's host without "www.", from the page or else the image URL.
    private var domain: String? {
        let host = pageURL?.host() ?? imageURL?.host()
        guard let host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var creditHint: String {
        switch source {
        case .commons: "Opens the Wikimedia Commons page"
        case .mapillary: "Opens the image on Mapillary"
        case .website: "Opens the place's website"
        }
    }
}
