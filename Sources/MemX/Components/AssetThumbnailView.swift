import SwiftUI
import Photos

// MARK: - AssetThumbnailView
// Loads and caches thumbnails from PhotoKit. Falls back to type icon.

struct AssetThumbnailView: View {
    let asset: MediaAsset
    var size: CGFloat = 120
    var cornerRadius: CGFloat = MS.Radius.md
    var isSelected: Bool = false
    var showOverlay: Bool = true

    @State private var image: NSImage? = nil
    @State private var isLoading: Bool = true

    private var thumbnailSize: CGSize { CGSize(width: size * 2, height: size * 2) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Thumbnail image
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if isLoading {
                    MSSkeletonBlock(height: size)
                        .frame(width: size, height: size)
                } else {
                    fallbackIcon
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // Overlay: duration badge for videos
            if showOverlay, asset.isVideo, !asset.durationString.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(asset.durationString)
                        .font(MS.Font.micro)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
            }

            // Live photo badge
            if showOverlay, asset.mediaType == .livePhoto {
                Image(systemName: "livephoto")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay(selectionOverlay)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: asset.id) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var fallbackIcon: some View {
        ZStack {
            MSColor.surface2
            Image(systemName: asset.mediaType.icon)
                .font(.system(size: size * 0.22))
                .foregroundStyle(MSColor.inkFaint)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.accentColor, in: Circle())
                        .padding(6),
                    alignment: .topTrailing
                )
        }
    }

    private func loadThumbnail() async {
        isLoading = true
        image = nil
        image = await PhotosLibraryService.shared.fetchThumbnail(for: asset.id, size: thumbnailSize)
        isLoading = false
    }
}

// MARK: - AssetGridCell

struct AssetGridCell: View {
    let asset: MediaAsset
    var isSelected: Bool
    var size: CGFloat = 120
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                AssetThumbnailView(
                    asset: asset,
                    size: size,
                    isSelected: isSelected
                )

                Text(asset.creationDate.map { formatDate($0) } ?? "—")
                    .font(MS.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? MSColor.inkBright : MSColor.inkMuted)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }
}
