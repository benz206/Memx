import Foundation
import Photos
import AppKit
import AVFoundation
import OSLog

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
    private let logger = Logger(subsystem: "com.memx.app", category: "photos")
    private init() {}

    // MARK: - Permission

    func requestPermission() async -> PHAuthorizationStatus {
        logger.info("requestPermission started")
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let statusStr: String
        switch status {
        case .authorized: statusStr = "authorized"
        case .denied: statusStr = "denied"
        case .limited: statusStr = "limited"
        case .restricted: statusStr = "restricted"
        case .notDetermined: statusStr = "notDetermined"
        @unknown default: statusStr = "unknown"
        }
        logger.info("requestPermission complete: \(statusStr, privacy: .public)")
        return status
    }

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: - Asset Fetching

    func fetchRecentAssets(limit: Int = 200) async -> [MediaAsset] {
        logger.info("fetchRecentAssets started: limit=\(limit)")
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        options.includeAllBurstAssets = false
        options.includeHiddenAssets = false

        let result = PHAsset.fetchAssets(with: options)
        let assets = extractAssets(from: result)
        logger.info("fetchRecentAssets complete: \(assets.count) assets")
        return assets
    }

    func fetchAlbums() async -> [MSAlbum] {
        var albums: [MSAlbum] = []
        var smartCount = 0

        let smartResult = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: PHFetchOptions()
        )
        smartResult.enumerateObjects { collection, _, _ in
            let album = MSAlbum(collection: collection)
            if album.count > 0 { albums.append(album); smartCount += 1 }
        }

        let userOptions = PHFetchOptions()
        userOptions.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let userResult = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: userOptions
        )
        var userCount = 0
        userResult.enumerateObjects { collection, _, _ in
            let album = MSAlbum(collection: collection)
            if album.count > 0 { albums.append(album); userCount += 1 }
        }

        logger.info("fetchAlbums complete: smart=\(smartCount) user=\(userCount) total=\(albums.count)")
        return albums
    }

    func fetchAssets(in album: MSAlbum, limit: Int = 200) async -> [MediaAsset] {
        logger.info("fetchAssets started: album=\(album.title, privacy: .public) limit=\(limit)")
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [album.id],
            options: nil
        )
        guard let collection = collections.firstObject else {
            logger.warning("fetchAssets: collection not found for album \(album.id, privacy: .public)")
            return []
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

        let result = PHAsset.fetchAssets(in: collection, options: options)
        let assets = extractAssets(from: result)
        logger.info("fetchAssets complete: \(assets.count) assets")
        return assets
    }

    func resolveAssets(for localIdentifiers: [String]) async -> [MediaAsset] {
        logger.info("resolveAssets started: \(localIdentifiers.count) requested")
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
        let resolved = localIdentifiers.compactMap { map[$0] }
        if resolved.count < localIdentifiers.count {
            logger.warning("resolveAssets incomplete: \(resolved.count)/\(localIdentifiers.count) resolved")
        } else {
            logger.info("resolveAssets complete: \(resolved.count)/\(localIdentifiers.count) resolved")
        }
        return resolved
    }

    // MARK: - Thumbnail

    func fetchThumbnail(for assetID: String, size: CGSize = CGSize(width: 200, height: 200)) async -> NSImage? {
        if let cached = await ThumbnailCache.shared.thumbnail(for: assetID) {
            logger.debug("thumbnail cache hit: \(assetID, privacy: .public)")
            return cached
        }
        logger.debug("thumbnail cache miss: \(assetID, privacy: .public)")

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
            ) { [logger] image, _ in
                if image == nil {
                    logger.warning("thumbnail unavailable for \(assetID, privacy: .public)")
                }
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
            logger.error("exportAssetForProcessing failed: asset not found \(assetID, privacy: .public)")
            throw PhotosServiceError.assetNotFound(assetID)
        }

        let typeStr = asset.mediaType == .image ? "image" : "video"
        logger.info("exportAssetForProcessing started: \(typeStr, privacy: .public) \(assetID, privacy: .public)")
        let start = Date()

        do {
            let url: URL
            switch asset.mediaType {
            case .image:
                url = try await exportPhoto(asset)
            case .video:
                url = try await exportVideo(asset)
            default:
                throw PhotosServiceError.unsupportedMediaType
            }
            logger.info("exportAssetForProcessing complete: \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            return url
        } catch {
            logger.error("exportAssetForProcessing error: \(error.localizedDescription, privacy: .public)")
            throw error
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
        logger.info("exportPhoto started: \(asset.localIdentifier, privacy: .public)")
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
            ) { [logger] data, _, _, _ in
                guard let data else {
                    logger.error("exportPhoto failed: no data for \(asset.localIdentifier, privacy: .public)")
                    continuation.resume(throwing: PhotosServiceError.exportFailed)
                    return
                }
                do {
                    try data.write(to: tempURL)
                    logger.info("exportPhoto success: \(data.count) bytes")
                    continuation.resume(returning: tempURL)
                } catch {
                    logger.error("exportPhoto write failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func exportVideoClip(assetID: String, startTime: TimeInterval, duration: TimeInterval) async throws -> URL {
        logger.info("exportVideoClip started: \(assetID, privacy: .public) start=\(String(format: "%.2f", startTime))s duration=\(String(format: "%.2f", duration))s")
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

        let session: AVAssetExportSession = try await withCheckedThrowingContinuation { continuation in
            imageManager.requestExportSession(
                forVideo: asset,
                options: options,
                exportPreset: AVAssetExportPreset1920x1080
            ) { [logger] session, _ in
                if let session {
                    continuation.resume(returning: session)
                } else {
                    logger.error("exportVideoClip: requestExportSession returned nil for \(assetID, privacy: .public)")
                    continuation.resume(throwing: PhotosServiceError.exportFailed)
                }
            }
        }

        let start = Date()
        session.timeRange = timeRange
        do {
            try await session.export(to: tempURL, as: .mov)
        } catch {
            logger.error("exportVideoClip failed for \(assetID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        logger.info("exportVideoClip complete: \(assetID, privacy: .public) (\(String(format: "%.2f", Date().timeIntervalSince(start)))s)")
        return tempURL
    }

    private func exportVideo(_ asset: PHAsset) async throws -> URL {
        logger.info("exportVideo started: \(asset.localIdentifier, privacy: .public)")
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memx-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        let session: AVAssetExportSession = try await withCheckedThrowingContinuation { continuation in
            imageManager.requestExportSession(
                forVideo: asset,
                options: options,
                exportPreset: AVAssetExportPreset1920x1080
            ) { [logger] session, _ in
                if let session {
                    continuation.resume(returning: session)
                } else {
                    logger.error("exportVideo: requestExportSession returned nil for \(asset.localIdentifier, privacy: .public)")
                    continuation.resume(throwing: PhotosServiceError.exportFailed)
                }
            }
        }

        let start = Date()
        do {
            try await session.export(to: tempURL, as: .mov)
        } catch {
            logger.error("exportVideo failed for \(asset.localIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        logger.info("exportVideo complete: \(asset.localIdentifier, privacy: .public) (\(String(format: "%.2f", Date().timeIntervalSince(start)))s)")
        return tempURL
    }

    // MARK: - Temp File Cleanup

    func cleanupTemporaryFiles() {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.path
        guard let contents = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }
        var deleted = 0
        for name in contents where name.hasPrefix("memx-") {
            let url = URL(fileURLWithPath: tmpDir).appendingPathComponent(name)
            if (try? fm.removeItem(at: url)) != nil { deleted += 1 }
        }
        logger.info("cleanupTemporaryFiles: deleted \(deleted) files")
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
