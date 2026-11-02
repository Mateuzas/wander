import SwiftUI

/// The hero photo of a sight and, when the POI has a Commons category, a swipeable
/// gallery after it. Each photo keeps its own author and licence caption, linked to
/// its Commons file page. A plain placeholder shows while the first photo loads (no
/// spinner); anything that fails is dropped silently, and `failed` is set when
/// nothing is left so the caller can lay the card out without a photo.
struct CommonsPhotoView: View {
    /// The POI's main Commons file name, shown first.
    let fileName: String?
    /// The POI's Commons category, for up to ten more photos.
    let category: String?
    @Binding var failed: Bool

    private enum Phase: Equatable {
        case loading
        case ready
        case empty
    }

    @State private var phase = Phase.loading
    @State private var photos: [CommonsPhoto] = []
    @State private var brokenImages: Set<String> = []
    @State private var current: String?

    private var shown: [CommonsPhoto] { photos.filter { !brokenImages.contains($0.id) } }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(.surfaceRaised)
                    .aspectRatio(Self.aspect, contentMode: .fit)
                    .accessibilityHidden(true)
            case .ready where !shown.isEmpty:
                gallery
            default:
                EmptyView()
            }
        }
        .task(id: "\(fileName ?? "")|\(category ?? "")") { await load() }
        .onChange(of: brokenImages) {
            if phase == .ready, shown.isEmpty { failed = true }
        }
    }

    // MARK: - Layout

    /// §10 card radius, and the hero's 4:3 shape.
    private static let corner: CGFloat = 12
    private static let aspect: CGFloat = 4.0 / 3.0

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

    private func slide(_ photo: CommonsPhoto) -> some View {
        VStack(alignment: .leading, spacing: Layout.grid / 2) {
            Color.surfaceRaised
                .aspectRatio(Self.aspect, contentMode: .fit)
                .overlay {
                    AsyncImage(url: photo.imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Color.clear.onAppear { brokenImages.insert(photo.id) }
                        default:
                            Color.clear
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                .accessibilityHidden(true)

            Link(destination: photo.pageURL) {
                Text(caption(photo))
                    .font(WanderFont.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .accessibilityLabel(caption(photo))
            .accessibilityHint("Opens the Wikimedia Commons page")
        }
    }

    private func caption(_ photo: CommonsPhoto) -> String {
        let credit = [photo.author, photo.license].compactMap { $0 }.joined(separator: ", ")
        return "Photo: \(credit) · Wikimedia Commons"
    }

    // MARK: - Loading

    /// Main photo first so it appears at once; the gallery follows without blocking it.
    private func load() async {
        phase = .loading
        photos = []
        brokenImages = []
        current = nil
        failed = false

        let cache = CommonsPhotoCache.shared
        let main = if let fileName { await cache.photo(fileName: fileName) } else { CommonsPhoto?.none }
        guard !Task.isCancelled else { return }
        if let main {
            photos = [main]
            current = main.id
            phase = .ready
        }
        if let category {
            let more = await cache.gallery(category: category, excluding: main?.fileName)
            guard !Task.isCancelled else { return }
            photos += more
            if current == nil { current = photos.first?.id }
            if !photos.isEmpty { phase = .ready }
        }
        if photos.isEmpty {
            phase = .empty
            failed = true
        }
    }
}
