import Foundation
import Photos
import PhotosUI
import Observation

@Observable
final class ImportViewModel {

    // MARK: State
    var recentAssets: [MediaAsset] = []
    var albums: [MSAlbum] = []
    var selectedAlbum: MSAlbum? = nil
    var albumAssets: [MediaAsset] = []
    var selectedAssetIDs: Set<String> = []
    var searchText: String = ""
    var sortOrder: AssetSortOrder = .newestFirst
    var filterType: AssetFilterType = .all

    // MARK: Loading
    var isLoadingRecents: Bool = false
    var isLoadingAlbums: Bool = false
    var isLoadingAlbumAssets: Bool = false
    var importProgress: Double = 0

    // MARK: PhotosPicker
    var photosPickerItems: [PhotosPickerItem] = []
    var importedPickerAssets: [MediaAsset] = []
    var isImportingFromPicker: Bool = false

    // MARK: Computed
    var visibleAssets: [MediaAsset] {
        var assets = selectedAlbum != nil ? albumAssets : recentAssets
        if !searchText.isEmpty {
            assets = assets.filter {
                $0.filename?.localizedCaseInsensitiveContains(searchText) == true ||
                $0.eventLabel?.localizedCaseInsensitiveContains(searchText) == true
            }
        }
        switch filterType {
        case .all:     break
        case .photos:  assets = assets.filter { $0.mediaType == .photo || $0.mediaType == .livePhoto }
        case .videos:  assets = assets.filter { $0.mediaType == .video }
        case .favorites: assets = assets.filter(\.isFavorite)
        }
        switch sortOrder {
        case .newestFirst: assets.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldestFirst: assets.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .bestScore:   assets.sort { ($0.analysisScore ?? 0) > ($1.analysisScore ?? 0) }
        }
        return assets
    }

    var selectedAssets: [MediaAsset] {
        (recentAssets + albumAssets + importedPickerAssets)
            .filter { selectedAssetIDs.contains($0.id) }
            .removingDuplicates()
    }

    var hasSelection: Bool { !selectedAssetIDs.isEmpty }
    var selectionCount: Int { selectedAssetIDs.count }

    private let photosService = PhotosLibraryService.shared

    // MARK: - Load

    func loadRecents() async {
        guard !isLoadingRecents else { return }
        isLoadingRecents = true
        let status = photosService.authorizationStatus()
        if status == .authorized || status == .limited {
            recentAssets = await photosService.fetchRecentAssets(limit: 300)
        } else {
            // Use mock data in unauthorized state (simulator / demo)
            recentAssets = MockDataProvider.mockAssets()
        }
        isLoadingRecents = false
    }

    func loadAlbums() async {
        guard !isLoadingAlbums else { return }
        isLoadingAlbums = true
        let status = photosService.authorizationStatus()
        if status == .authorized || status == .limited {
            albums = await photosService.fetchAlbums()
        } else {
            albums = MockDataProvider.mockAlbums()
        }
        isLoadingAlbums = false
    }

    func selectAlbum(_ album: MSAlbum?) async {
        selectedAlbum = album
        guard let album else { return }
        isLoadingAlbumAssets = true
        let status = photosService.authorizationStatus()
        if status == .authorized || status == .limited {
            albumAssets = await photosService.fetchAssets(in: album, limit: 300)
        } else {
            albumAssets = MockDataProvider.mockAssets()
        }
        isLoadingAlbumAssets = false
    }

    // MARK: - Selection

    func toggleSelection(_ asset: MediaAsset) {
        if selectedAssetIDs.contains(asset.id) {
            selectedAssetIDs.remove(asset.id)
        } else {
            selectedAssetIDs.insert(asset.id)
        }
    }

    func selectAll() {
        selectedAssetIDs = Set(visibleAssets.map(\.id))
    }

    func deselectAll() {
        selectedAssetIDs.removeAll()
    }

    // MARK: - PhotosPicker Import

    func handlePickerSelection(_ items: [PhotosPickerItem]) async {
        isImportingFromPicker = true
        importProgress = 0

        for (i, item) in items.enumerated() {
            defer { importProgress = Double(i + 1) / Double(items.count) }

            // Load the PHAsset identifier from the picker item
            guard let assetID = item.itemIdentifier else { continue }
            let asset = MediaAsset(id: assetID, filename: "Imported \(i+1)")
            importedPickerAssets.append(asset)
            selectedAssetIDs.insert(assetID)
        }

        isImportingFromPicker = false
    }

    // MARK: - Thumbnail

    func thumbnail(for asset: MediaAsset, size: CGSize = CGSize(width: 200, height: 200)) async -> NSImage? {
        await photosService.fetchThumbnail(for: asset.id, size: size)
    }
}

// MARK: - Supporting Enums

enum AssetSortOrder: String, CaseIterable {
    case newestFirst = "Newest First"
    case oldestFirst = "Oldest First"
    case bestScore   = "Best Score"
}

enum AssetFilterType: String, CaseIterable {
    case all       = "All"
    case photos    = "Photos"
    case videos    = "Videos"
    case favorites = "Favorites"

    var icon: String {
        switch self {
        case .all:       return "square.grid.2x2.fill"
        case .photos:    return "photo.fill"
        case .videos:    return "video.fill"
        case .favorites: return "heart.fill"
        }
    }
}

// MARK: - Array Dedup Helper

private extension Array where Element: Identifiable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}
