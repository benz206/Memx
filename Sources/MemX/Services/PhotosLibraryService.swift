import Foundation
import Photos
import AppKit
import AVFoundation

// MARK: - PhotosLibraryServiceProtocol

protocol PhotosLibraryServiceProtocol {
    func requestPermission() async -> PHAuthorizationStatus
    func authorizationStatus() -> PHAuthorizationStatus
    func fetchRecentAssets(limit: Int) async -> [MediaAsset]
    func fetchAlbums() async -> [MSAlbum]
    func fetchAssets(in album: MSAlbum, limit: Int) async -> [MediaAsset]
    func fetchThumbnail(for assetID: String, size: CGSize) async -> NSImage?
    func exportAssetForProcessing(_ assetID: String) async throws -> URL
    func fetchAsset(for id: String) -> PHAsset?
}

// MARK: - PhotosLibraryService (real PhotoKit integration)

final class PhotosLibraryService: PhotosLibraryServiceProtocol {

    static let shared = PhotosLibraryService()
    private let imageManager = PHCachingImageManager()
    private init() {}

    // MARK: - Permission

    func requestPermission() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: - Asset Fetching

    func fetchRecentAssets(limit: Int = 200) async -> [MediaAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        options.includeAllBurstAssets = false
        options.includeHiddenAssets = false

        let result = PHAsset.fetchAssets(with: options)
        return extractAssets(from: result)
    }

    func fetchAlbums() async -> [MSAlbum] {
        var albums: [MSAlbum] = []

        // Smart albums (Favorites, Videos, Selfies, etc.)
        let smartOptions = PHFetchOptions()
        let smartResult = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: smartOptions
        )
        smartResult.enumerateObjects { collection, _, _ in
            let album = MSAlbum(collection: collection)
            if album.count > 0 { albums.append(album) }
        }

        // User albums
        let userOptions = PHFetchOptions()
        userOptions.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let userResult = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: userOptions
        )
        userResult.enumerateObjects { collection, _, _ in
            let album = MSAlbum(collection: collection)
            if album.count > 0 { albums.append(album) }
        }

        return albums
    }

    func fetchAssets(in album: MSAlbum, limit: Int = 200) async -> [MediaAsset] {
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [album.id],
            options: nil
        )
        guard let collection = collections.firstObject else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

        let result = PHAsset.fetchAssets(in: collection, options: options)
        return extractAssets(from: result)
    }

    // MARK: - Thumbnail

    func fetchThumbnail(for assetID: String, size: CGSize = CGSize(width: 200, height: 200)) async -> NSImage? {
        // Check cache first
        if let cached = await ThumbnailCache.shared.thumbnail(for: assetID) {
            return cached
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        return await withCheckedContinuation { continuation in
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isFinal = (info?[PHImageResultIsDegradedKey] as? Bool) != true
                guard isFinal, !resumed else { return }
                resumed = true
                let result = image
                Task { @MainActor in
                    if let img = result {
                        ThumbnailCache.shared.store(img, for: assetID)
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Export for Processing

    /// Exports an asset to a temporary local file URL used by PhotoScoringService (Vision) and VideoRenderService.
    func exportAssetForProcessing(_ assetID: String) async throws -> URL {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else {
            throw PhotosServiceError.assetNotFound(assetID)
        }

        switch asset.mediaType {
        case .image:
            return try await exportPhoto(asset)
        case .video:
            return try await exportVideo(asset)
        default:
            throw PhotosServiceError.unsupportedMediaType
        }
    }

    // MARK: - Helpers

    func fetchAsset(for id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func extractAssets(from result: PHFetchResult<PHAsset>) -> [MediaAsset] {
        var assets: [MediaAsset] = []
        result.enumerateObjects { phAsset, _, _ in
            assets.append(MediaAsset(phAsset: phAsset))
        }
        return assets
    }

    private func exportPhoto(_ asset: PHAsset) async throws -> URL {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                guard let data else {
                    continuation.resume(throwing: PhotosServiceError.exportFailed)
                    return
                }
                do {
                    try data.write(to: tempURL)
                    continuation.resume(returning: tempURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Exports a trimmed video clip starting at `startTime` for `duration` seconds.
    func exportVideoClip(assetID: String, startTime: TimeInterval, duration: TimeInterval) async throws -> URL {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { throw PhotosServiceError.assetNotFound(assetID) }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        let timescale: CMTimeScale = 600
        let timeRange = CMTimeRange(
            start:    CMTime(seconds: startTime, preferredTimescale: timescale),
            duration: CMTime(seconds: duration,  preferredTimescale: timescale)
        )

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestExportSession(
                forVideo: asset,
                options: options,
                exportPreset: AVAssetExportPreset1920x1080
            ) { session, _ in
                guard let session else {
                    continuation.resume(throwing: PhotosServiceError.exportFailed)
                    return
                }
                session.outputURL = tempURL
                session.outputFileType = .mov
                session.timeRange = timeRange
                session.exportAsynchronously {
                    if session.status == .completed {
                        continuation.resume(returning: tempURL)
                    } else {
                        continuation.resume(throwing: session.error ?? PhotosServiceError.exportFailed)
                    }
                }
            }
        }
    }

    private func exportVideo(_ asset: PHAsset) async throws -> URL {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestExportSession(
                forVideo: asset,
                options: options,
                exportPreset: AVAssetExportPreset1920x1080
            ) { session, _ in
                guard let session else {
                    continuation.resume(throwing: PhotosServiceError.exportFailed)
                    return
                }
                session.outputURL = tempURL
                session.outputFileType = .mov
                session.exportAsynchronously {
                    if session.status == .completed {
                        continuation.resume(returning: tempURL)
                    } else {
                        continuation.resume(throwing: session.error ?? PhotosServiceError.exportFailed)
                    }
                }
            }
        }
    }
}

// MARK: - Errors

enum PhotosServiceError: LocalizedError {
    case permissionDenied
    case assetNotFound(String)
    case unsupportedMediaType
    case exportFailed
    case unknown

    var errorDescription: String? {
        switch self {
        case .permissionDenied:         return "Photos library access was denied."
        case .assetNotFound(let id):    return "Asset not found: \(id)"
        case .unsupportedMediaType:     return "This media type is not supported for export."
        case .exportFailed:             return "Failed to export asset for processing."
        case .unknown:                  return "An unknown error occurred."
        }
    }
}
