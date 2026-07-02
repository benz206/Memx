import SwiftUI
import Photos

// MARK: - AssetThumbnailView
// Loads and caches thumbnails from PhotoKit. Falls back to type icon.

struct AssetThumbnailView: View {
    let asset: MediaAsset
    var size: CGFloat = 120
    var cornerRadius: CGFloat = MS.Radius.sm
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
            Color.secondary.opacity(0.1)
            Image(systemName: asset.mediaType.icon)
                .font(.system(size: size * 0.3))
                .foregroundStyle(.secondary)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2.5)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
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
            VStack(alignment: .leading, spacing: 5) {
                AssetThumbnailView(
                    asset: asset,
                    size: size,
                    isSelected: isSelected
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.filename ?? asset.id.prefix(8).description)
                        .font(MS.Font.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(asset.creationDate.map { formatDate($0) } ?? "—")
                        .font(MS.Font.micro)
                        .foregroundStyle(.secondary)
                }
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
