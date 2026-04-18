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
    func resolveAssets(for localIdentifiers: [String]) async -> [MediaAsset]
}

// MARK: - PHAssetCache (serial-queue-protected)

actor PHAssetCache {
    static let shared = PHAssetCache()
    private var store: [String: PHAsset] = [:]
    private init() {}

    func phAsset(for localIdentifier: String) -> PHAsset? {
        if let cached = store[localIdentifier] { return cached }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = result.firstObject else { return nil }
        store[localIdentifier] = asset
        return asset
    }

    func prime(_ phAsset: PHAsset) {
        store[phAsset.localIdentifier] = phAsset
    }

    func invalidate(_ localIdentifier: String) {
        store.removeValue(forKey: localIdentifier)
    }
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

        let smartResult = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: PHFetchOptions()
        )
        smartResult.enumerateObjects { collection, _, _ in
            let album = MSAlbum(collection: collection)
            if album.count > 0 { albums.append(album) }
        }

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

    func resolveAssets(for localIdentifiers: [String]) async -> [MediaAsset] {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var map: [String: MediaAsset] = [:]
        var phAssets: [PHAsset] = []
        fetchResult.enumerateObjects { phAsset, _, _ in
            map[phAsset.localIdentifier] = MediaAsset(phAsset: phAsset)
            phAssets.append(phAsset)
        }
        for phAsset in phAssets {
            await PHAssetCache.shared.prime(phAsset)
        }
        return localIdentifiers.compactMap { map[$0] }
    }

    // MARK: - Thumbnail

    func fetchThumbnail(for assetID: String, size: CGSize = CGSize(width: 200, height: 200)) async -> NSImage? {
        if let cached = await ThumbnailCache.shared.thumbnail(for: assetID) {
            return cached
        }

        guard let asset = await PHAssetCache.shared.phAsset(for: assetID) else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                Task { @MainActor in
                    if let img = image {
                        ThumbnailCache.shared.store(img, for: assetID)
                    }
                }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Export for Processing

    func exportAssetForProcessing(_ assetID: String) async throws -> URL {
        guard let asset = await PHAssetCache.shared.phAsset(for: assetID) else {
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
            .appendingPathComponent("memx-\(UUID().uuidString)")
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

    func exportVideoClip(assetID: String, startTime: TimeInterval, duration: TimeInterval) async throws -> URL {
        guard let asset = await PHAssetCache.shared.phAsset(for: assetID) else {
            throw PhotosServiceError.assetNotFound(assetID)
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memx-\(UUID().uuidString)")
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
            .appendingPathComponent("memx-\(UUID().uuidString)")
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

    // MARK: - Temp File Cleanup

    func cleanupTemporaryFiles() {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.path
        guard let contents = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }
        for name in contents where name.hasPrefix("memx-") {
            let url = URL(fileURLWithPath: tmpDir).appendingPathComponent(name)
            try? fm.removeItem(at: url)
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
