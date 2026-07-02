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
    var colorTemperature: Double?
    var faceAreaFraction: Double?
    var sceneLabels: [String]?          // Vision VNClassifyImage top-N labels above confidence threshold
    var sceneCaption: String?           // Natural-language caption from Foundation Models (nil if unavailable)
    var semanticSummary: String?        // Edit-aware summary used for mood/content matching
    var semanticEmbedding: [Float]?      // on-device NLEmbedding for semantic sequencing
    var visualEmbedding: [Float]?        // Vision FeaturePrint (free, on-device) for match-cut continuity
    var motionEnergy: Float?             // 0 still … 1 high-action/jumping — matched against audio energy
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
        colorTemperature: Double? = nil,
        faceAreaFraction: Double? = nil,
        sceneLabels: [String]? = nil,
        sceneCaption: String? = nil,
        semanticSummary: String? = nil,
        semanticEmbedding: [Float]? = nil,
        visualEmbedding: [Float]? = nil,
        motionEnergy: Float? = nil
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
        self.colorTemperature = colorTemperature
        self.faceAreaFraction = faceAreaFraction
        self.sceneLabels = sceneLabels
        self.sceneCaption = sceneCaption
        self.semanticSummary = semanticSummary
        self.semanticEmbedding = semanticEmbedding
        self.visualEmbedding = visualEmbedding
        self.motionEnergy = motionEnergy
    }
}

// MARK: - Codable
// Embeddings are stored as raw Float32 data (base64 in JSON) instead of
// decimal number arrays — roughly 5x smaller in projects.json, which is
// rewritten on every save. Legacy [Float] payloads still decode.

extension MediaAsset {
    private enum CodingKeys: String, CodingKey {
        case id, mediaType, creationDate, filename, pixelWidth, pixelHeight
        case isFavorite, duration, location, analysisScore, eventLabel
        case qualityScore, emotionScore, noveltyScore, clipStartTime
        case shotType, colorTemperature, faceAreaFraction
        case sceneLabels, sceneCaption, semanticSummary
        case semanticEmbedding, visualEmbedding, motionEnergy, isSelected
    }

    private static func embeddingData(_ v: [Float]?) -> Data? {
        v?.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decodeEmbedding(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> [Float]? {
        if let data = try? c.decodeIfPresent(Data.self, forKey: key) {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return try c.decodeIfPresent([Float].self, forKey: key)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mediaType = try c.decode(MSMediaType.self, forKey: .mediaType)
        creationDate = try c.decodeIfPresent(Date.self, forKey: .creationDate)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        location = try c.decodeIfPresent(AssetLocation.self, forKey: .location)
        analysisScore = try c.decodeIfPresent(Float.self, forKey: .analysisScore)
        eventLabel = try c.decodeIfPresent(String.self, forKey: .eventLabel)
        qualityScore = try c.decodeIfPresent(Float.self, forKey: .qualityScore)
        emotionScore = try c.decodeIfPresent(Float.self, forKey: .emotionScore)
        noveltyScore = try c.decodeIfPresent(Float.self, forKey: .noveltyScore)
        clipStartTime = try c.decodeIfPresent(TimeInterval.self, forKey: .clipStartTime)
        shotType = try c.decodeIfPresent(ShotType.self, forKey: .shotType)
        colorTemperature = try c.decodeIfPresent(Double.self, forKey: .colorTemperature)
        faceAreaFraction = try c.decodeIfPresent(Double.self, forKey: .faceAreaFraction)
        sceneLabels = try c.decodeIfPresent([String].self, forKey: .sceneLabels)
        sceneCaption = try c.decodeIfPresent(String.self, forKey: .sceneCaption)
        semanticSummary = try c.decodeIfPresent(String.self, forKey: .semanticSummary)
        semanticEmbedding = try Self.decodeEmbedding(c, .semanticEmbedding)
        visualEmbedding = try Self.decodeEmbedding(c, .visualEmbedding)
        motionEnergy = try c.decodeIfPresent(Float.self, forKey: .motionEnergy)
        isSelected = try c.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mediaType, forKey: .mediaType)
        try c.encodeIfPresent(creationDate, forKey: .creationDate)
        try c.encodeIfPresent(filename, forKey: .filename)
        try c.encode(pixelWidth, forKey: .pixelWidth)
        try c.encode(pixelHeight, forKey: .pixelHeight)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(duration, forKey: .duration)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(analysisScore, forKey: .analysisScore)
        try c.encodeIfPresent(eventLabel, forKey: .eventLabel)
        try c.encodeIfPresent(qualityScore, forKey: .qualityScore)
        try c.encodeIfPresent(emotionScore, forKey: .emotionScore)
        try c.encodeIfPresent(noveltyScore, forKey: .noveltyScore)
        try c.encodeIfPresent(clipStartTime, forKey: .clipStartTime)
        try c.encodeIfPresent(shotType, forKey: .shotType)
        try c.encodeIfPresent(colorTemperature, forKey: .colorTemperature)
        try c.encodeIfPresent(faceAreaFraction, forKey: .faceAreaFraction)
        try c.encodeIfPresent(sceneLabels, forKey: .sceneLabels)
        try c.encodeIfPresent(sceneCaption, forKey: .sceneCaption)
        try c.encodeIfPresent(semanticSummary, forKey: .semanticSummary)
        try c.encodeIfPresent(Self.embeddingData(semanticEmbedding), forKey: .semanticEmbedding)
        try c.encodeIfPresent(Self.embeddingData(visualEmbedding), forKey: .visualEmbedding)
        try c.encodeIfPresent(motionEnergy, forKey: .motionEnergy)
        try c.encode(isSelected, forKey: .isSelected)
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
        // estimatedAssetCount avoids a full asset fetch per album; smart
        // albums can report NSNotFound, where the real fetch is required.
        let estimated = collection.estimatedAssetCount
        self.count = estimated == NSNotFound
            ? PHAsset.fetchAssets(in: collection, options: nil).count
            : estimated
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
