import SwiftUI

/// A sight's Wikimedia Commons photo with the author and licence credit the
/// licence requires; photo and caption link to the Commons file page. Shows a
/// plain placeholder while loading (no spinner) and nothing at all on any error.
struct CommonsPhotoView: View {
    let fileName: String

    private enum Phase {
        case loading
        case loaded(CommonsPhoto)
        case failed
    }

    @State private var phase = Phase.loading

    private let height: CGFloat = 140

    var body: some View {
        Group {
            switch phase {
            case .loading:
                placeholder
            case .loaded(let photo):
                loaded(photo)
            case .failed:
                EmptyView()
            }
        }
        .task(id: fileName) {
            phase = .loading
            if let photo = await CommonsPhotoCache.shared.photo(fileName: fileName) {
                guard !Task.isCancelled else { return }
                phase = .loaded(photo)
            } else if !Task.isCancelled {
                phase = .failed
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.surfaceRaised)
            .frame(height: height)
            .accessibilityHidden(true)
    }

    private func loaded(_ photo: CommonsPhoto) -> some View {
        VStack(alignment: .leading, spacing: Layout.grid / 2) {
            AsyncImage(url: photo.imageURL) { image in
                switch image {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Color.clear.onAppear { phase = .failed }
                default:
                    Color.surfaceRaised
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)

            Text("Photo: \(photo.author), \(photo.license) · Wikimedia Commons")
                .font(WanderFont.caption)
                .foregroundStyle(.inkMuted)
                .lineLimit(2)
        }
        .contentShape(Rectangle())
        .onTapGesture { UIApplication.shared.open(photo.pageURL) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo by \(photo.author), licence \(photo.license)")
        .accessibilityHint("Opens the Wikimedia Commons page")
        .accessibilityAddTraits(.isLink)
    }
}
