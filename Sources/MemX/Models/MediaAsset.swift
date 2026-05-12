import Foundation
import Photos
import SwiftUI

// MARK: - MediaAsset Protocol

protocol MediaAssetProtocol: Identifiable, Hashable {
    var id: String { get }              // PHAsset localIdentifier
    var mediaType: MSMediaType { get }
    var creationDate: Date? { get }
    var filename: String? { get }
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    var isFavorite: Bool { get }
    var isSelected: Bool { get set }
}

// MARK: - MSMediaType

enum MSMediaType: String, Codable, Hashable {
    case photo = "Photo"
    case video = "Video"
    case livePhoto = "Live Photo"
    case unknown = "Unknown"

    var icon: String {
        switch self {
        case .photo:     return "photo"
        case .video:     return "video.fill"
        case .livePhoto: return "livephoto"
        case .unknown:   return "questionmark.square"
        }
    }

    init(phMediaType: PHAssetMediaType, subtypes: PHAssetMediaSubtype) {
        if subtypes.contains(.photoLive) {
            self = .livePhoto
        } else {
            switch phMediaType {
            case .image: self = .photo
            case .video: self = .video
            default:     self = .unknown
            }
        }
    }
}

// MARK: - ShotType

enum ShotType: String, Codable, Hashable, CaseIterable {
    case wide
    case medium
    case closeUp
    case group
    case detail
    case motion
}

// MARK: - MotionVector

struct MotionVector: Codable, Hashable {
    var dx: Double
    var dy: Double
    var magnitude: Double
}

// MARK: - MediaAsset (concrete, Codable for persistence)

struct MediaAsset: MediaAssetProtocol, Codable {
    let id: String                      // PHAsset.localIdentifier
    var mediaType: MSMediaType
    var creationDate: Date?
    var filename: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var isFavorite: Bool
    var duration: TimeInterval          // 0 for photos
    var location: AssetLocation?
    var analysisScore: Float?           // populated post-analysis
    var eventLabel: String?             // populated post-clustering
    var qualityScore: Float?
    var emotionScore: Float?
    var noveltyScore: Float?
    var clipStartTime: TimeInterval?    // best segment start offset within video (nil for photos)
    var shotType: ShotType?
    var motionVector: MotionVector?
    var colorTemperature: Double?
    var faceAreaFraction: Double?
    var sceneLabels: [String]?          // Vision VNClassifyImage top-N labels above confidence threshold
    var sceneCaption: String?           // Natural-language caption from Foundation Models (nil if unavailable)
    var semanticSummary: String?        // Edit-aware summary used for mood/content matching
    var semanticEmbedding: [Float]?      // OpenRouter/free embedding for semantic sequencing
    var isSelected: Bool = false

    // Derived
    var isVideo: Bool { mediaType == .video || duration > 0 }
    var aspectRatio: Double { pixelWidth > 0 ? Double(pixelWidth) / Double(pixelHeight) : 1.0 }

    var durationString: String {
        guard duration > 0 else { return "" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes):\(String(format: "%02d", seconds))" : "0:\(String(format: "%02d", seconds))"
    }

    init(phAsset: PHAsset) {
        self.id = phAsset.localIdentifier
        self.mediaType = MSMediaType(phMediaType: phAsset.mediaType, subtypes: phAsset.mediaSubtypes)
        self.creationDate = phAsset.creationDate
        self.filename = phAsset.value(forKey: "filename") as? String
        self.pixelWidth = phAsset.pixelWidth
        self.pixelHeight = phAsset.pixelHeight
        self.isFavorite = phAsset.isFavorite
        self.duration = phAsset.duration
        if let loc = phAsset.location {
            self.location = AssetLocation(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude
            )
        }
    }

    // For mock/preview use
    init(
        id: String = UUID().uuidString,
        mediaType: MSMediaType = .photo,
        creationDate: Date? = nil,
        filename: String? = nil,
        pixelWidth: Int = 1920,
        pixelHeight: Int = 1080,
        isFavorite: Bool = false,
        duration: TimeInterval = 0,
        location: AssetLocation? = nil,
        shotType: ShotType? = nil,
        motionVector: MotionVector? = nil,
        colorTemperature: Double? = nil,
        faceAreaFraction: Double? = nil,
        sceneLabels: [String]? = nil,
        sceneCaption: String? = nil,
        semanticSummary: String? = nil,
        semanticEmbedding: [Float]? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.creationDate = creationDate
        self.filename = filename
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.duration = duration
        self.location = location
        self.shotType = shotType
        self.motionVector = motionVector
        self.colorTemperature = colorTemperature
        self.faceAreaFraction = faceAreaFraction
        self.sceneLabels = sceneLabels
        self.sceneCaption = sceneCaption
        self.semanticSummary = semanticSummary
        self.semanticEmbedding = semanticEmbedding
    }
}

// MARK: - AssetLocation

struct AssetLocation: Codable, Hashable {
    let latitude: Double
    let longitude: Double
}

// MARK: - Album

struct MSAlbum: Identifiable, Hashable {
    let id: String                      // PHAssetCollection.localIdentifier
    let title: String
    let count: Int
    let type: AlbumType
    let startDate: Date?
    let endDate: Date?

    enum AlbumType: String, Hashable {
        case smartAlbum  = "Smart Album"
        case userAlbum   = "Album"
        case moment      = "Moment"

        var icon: String {
            switch self {
            case .smartAlbum: return "bolt.fill"
            case .userAlbum:  return "rectangle.stack.fill"
            case .moment:     return "clock.fill"
            }
        }
    }

    init(collection: PHAssetCollection) {
        self.id = collection.localIdentifier
        self.title = collection.localizedTitle ?? "Untitled"
        let fetchResult = PHAsset.fetchAssets(in: collection, options: nil)
        self.count = fetchResult.count
        self.startDate = collection.startDate
        self.endDate = collection.endDate
        switch collection.assetCollectionType {
        case .smartAlbum: self.type = .smartAlbum
        case .moment:     self.type = .moment
        default:          self.type = .userAlbum
        }
    }

    // Mock init
    init(id: String = UUID().uuidString, title: String, count: Int, type: AlbumType = .userAlbum) {
        self.id = id
        self.title = title
        self.count = count
        self.type = type
        self.startDate = nil
        self.endDate = nil
    }
}

// MARK: - ThumbnailCache

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()
    private init() {}

    func thumbnail(for id: String) -> NSImage? { cache.object(forKey: id as NSString) }

    func store(_ image: NSImage, for id: String) {
        let cost = Int(image.size.width) * Int(image.size.height) * 4
        cache.setObject(image, forKey: id as NSString, cost: cost)
    }

    func clear() { cache.removeAllObjects() }
}
