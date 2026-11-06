import RouteEngine
import SwiftUI

/// The place card's hero photo and, when the POI has a Commons category, a swipeable
/// gallery after it (FE-22). The hero is the place's own `photo` (ADR 015) when it has
/// one, else its Commons image. Each photo keeps its own credit caption, linked to its
/// source page. The hero's frame is held from the start with a glyph placeholder (no
/// spinner, no jump); gallery photos that fail are dropped silently, and `failed` is set
/// when nothing is left so the caller can lay the card out without a photo.
struct PlacePhotoView: View {
    /// The place's own hero photo (ADR 015); nil in older data files.
    let lead: Photo?
    /// The POI's main Commons file name, the hero when there is no `lead`.
    let fileName: String?
    /// The POI's Commons category, for up to ten more photos.
    let category: String?
    /// The place's glyph, for the placeholder.
    let glyph: String
    @Binding var failed: Bool

    /// One slide: an image and its credit.
    private struct Slide: Identifiable, Equatable {
        let id: String
        let imageURL: URL?
        let caption: String
        let pageURL: URL?
        let hint: String
    }

    @State private var slides: [Slide] = []
    @State private var brokenImages: Set<String> = []
    @State private var current: String?
    @State private var settled = false

    private var shown: [Slide] { slides.filter { !brokenImages.contains($0.id) } }

    var body: some View {
        Group {
            if !shown.isEmpty {
                gallery
            } else if !settled {
                // Holds the hero's frame while the first photo is looked up.
                hero(url: nil, id: "")
                    .accessibilityHidden(true)
            }
        }
        .task(id: "\(lead?.url ?? "")|\(fileName ?? "")|\(category ?? "")") { await load() }
        .onChange(of: brokenImages) {
            if settled, shown.isEmpty { failed = true }
        }
    }

    // MARK: - Layout

    /// §10 card radius, and the hero's 4:3 shape.
    private static let corner: CGFloat = 12
    private static let aspect: CGFloat = 4.0 / 3.0
    private static let leadID = "lead"

    private var gallery: some View {
        let photos = shown
        let index = photos.firstIndex { $0.id == current } ?? 0
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Layout.grid) {
                ForEach(photos) { photo in
                    slide(photo)
                        .containerRelativeFrame(.horizontal)
                        .id(photo.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .scrollDisabled(photos.count < 2)
        .overlay(alignment: .topLeading) {
            if photos.count > 1 {
                Text("\(index + 1) / \(photos.count)")
                    .font(WanderFont.caption)
                    .foregroundStyle(.ink)
                    .padding(.horizontal, Layout.grid)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(Layout.grid)
                    .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
            }
        }
    }

    private func hero(url: URL?, id: String) -> some View {
        Color.clear
            .aspectRatio(Self.aspect, contentMode: .fit)
            .overlay {
                RemoteImage(url: url, glyph: glyph, glyphSize: 34) { ok in
                    // The lead keeps its placeholder on failure (it's the card's hero);
                    // gallery photos that fail are dropped.
                    if !ok, !id.isEmpty, id != Self.leadID { brokenImages.insert(id) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
    }

    private func slide(_ photo: Slide) -> some View {
        VStack(alignment: .leading, spacing: Layout.grid / 2) {
            hero(url: photo.imageURL, id: photo.id)
                .accessibilityHidden(true)
            credit(photo)
        }
    }

    @ViewBuilder
    private func credit(_ photo: Slide) -> some View {
        let text = Text(photo.caption)
            .font(WanderFont.caption)
            .foregroundStyle(.inkMuted)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        if let page = photo.pageURL {
            Link(destination: page) { text }
                .accessibilityLabel(photo.caption)
                .accessibilityHint(photo.hint)
        } else {
            text
        }
    }

    // MARK: - Loading

    /// The hero first so it appears at once; the gallery follows without blocking it.
    private func load() async {
        slides = []
        brokenImages = []
        current = nil
        settled = false
        failed = false

        let cache = CommonsPhotoCache.shared
        if let lead, let url = lead.imageURL {
            slides = [Slide(id: Self.leadID, imageURL: url, caption: lead.creditLine,
                            pageURL: lead.pageURL, hint: lead.creditHint)]
        } else if let fileName, let main = await cache.photo(fileName: fileName) {
            guard !Task.isCancelled else { return }
            slides = [Self.slide(main)]
        }
        guard !Task.isCancelled else { return }
        current = slides.first?.id
        if let category {
            // The Commons main image is already the hero unless the lead came from elsewhere.
            let shownFile = lead == nil || lead?.source == .commons ? fileName : nil
            let more = await cache.gallery(category: category, excluding: shownFile)
            guard !Task.isCancelled else { return }
            // A Commons lead can also be a member of the category; skip exact repeats.
            let leadURL = slides.first?.imageURL
            slides += more.map(Self.slide).filter { $0.imageURL != leadURL }
            if current == nil { current = slides.first?.id }
        }
        settled = true
        if slides.isEmpty { failed = true }
    }

    private static func slide(_ photo: CommonsPhoto) -> Slide {
        let credit = [photo.author, photo.license].compactMap { $0 }.joined(separator: ", ")
        return Slide(id: photo.id, imageURL: photo.imageURL,
                     caption: "Photo: \(credit) · Wikimedia Commons",
                     pageURL: photo.pageURL, hint: "Opens the Wikimedia Commons page")
    }
}
