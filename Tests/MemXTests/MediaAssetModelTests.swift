import XCTest
@testable import MemXCore

final class MediaAssetModelTests: XCTestCase {

    // MARK: - isVideo

    func testIsVideoTrueForVideoMediaType() {
        let asset = MediaAsset(mediaType: .video, duration: 10)
        XCTAssertTrue(asset.isVideo)
    }

    func testIsVideoTrueWhenDurationPositive() {
        let asset = MediaAsset(mediaType: .photo, duration: 5)
        XCTAssertTrue(asset.isVideo)
    }

    func testIsVideoFalseForPhoto() {
        let asset = MediaAsset(mediaType: .photo, duration: 0)
        XCTAssertFalse(asset.isVideo)
    }

    func testIsVideoFalseForLivePhotoWithZeroDuration() {
        let asset = MediaAsset(mediaType: .livePhoto, duration: 0)
        XCTAssertFalse(asset.isVideo)
    }

    // MARK: - aspectRatio

    func testAspectRatioWidescreen() {
        let asset = MediaAsset(pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertEqual(asset.aspectRatio, 1920.0 / 1080.0, accuracy: 0.0001)
    }

    func testAspectRatioPortrait() {
        let asset = MediaAsset(pixelWidth: 1080, pixelHeight: 1920)
        XCTAssertEqual(asset.aspectRatio, 1080.0 / 1920.0, accuracy: 0.0001)
    }

    func testAspectRatioDefaultsToOneWhenWidthZero() {
        let asset = MediaAsset(pixelWidth: 0, pixelHeight: 1080)
        XCTAssertEqual(asset.aspectRatio, 1.0, accuracy: 0.0001)
    }

    func testAspectRatioSquare() {
        let asset = MediaAsset(pixelWidth: 1000, pixelHeight: 1000)
        XCTAssertEqual(asset.aspectRatio, 1.0, accuracy: 0.0001)
    }

    // MARK: - durationString

    func testDurationStringEmptyForPhotos() {
        let asset = MediaAsset(mediaType: .photo, duration: 0)
        XCTAssertEqual(asset.durationString, "")
    }

    func testDurationStringSecondsOnly() {
        let asset = MediaAsset(duration: 14)
        XCTAssertEqual(asset.durationString, "0:14")
    }

    func testDurationStringSingleDigitSeconds() {
        let asset = MediaAsset(duration: 7)
        XCTAssertEqual(asset.durationString, "0:07")
    }

    func testDurationStringWithMinutes() {
        let asset = MediaAsset(duration: 65)
        XCTAssertEqual(asset.durationString, "1:05")
    }

    func testDurationStringMultipleMinutes() {
        let asset = MediaAsset(duration: 214)
        XCTAssertEqual(asset.durationString, "3:34")
    }

    func testDurationStringExactOneMinute() {
        let asset = MediaAsset(duration: 60)
        XCTAssertEqual(asset.durationString, "1:00")
    }

    // MARK: - MSMediaType

    func testMSMediaTypePhotoIcon() {
        XCTAssertFalse(MSMediaType.photo.icon.isEmpty)
    }

    func testMSMediaTypeVideoIcon() {
        XCTAssertFalse(MSMediaType.video.icon.isEmpty)
    }

    func testMSMediaTypeLivePhotoIcon() {
        XCTAssertFalse(MSMediaType.livePhoto.icon.isEmpty)
    }

    func testMSMediaTypeUnknownIcon() {
        XCTAssertFalse(MSMediaType.unknown.icon.isEmpty)
    }

    // MARK: - AssetLocation

    func testAssetLocationStoresCoordinates() {
        let loc = AssetLocation(latitude: 38.717, longitude: -9.142)
        XCTAssertEqual(loc.latitude, 38.717, accuracy: 0.0001)
        XCTAssertEqual(loc.longitude, -9.142, accuracy: 0.0001)
    }

    func testAssetLocationCodableRoundTrip() throws {
        let loc = AssetLocation(latitude: 51.5074, longitude: -0.1278)
        let data = try JSONEncoder().encode(loc)
        let decoded = try JSONDecoder().decode(AssetLocation.self, from: data)
        XCTAssertEqual(decoded.latitude, loc.latitude, accuracy: 0.0001)
        XCTAssertEqual(decoded.longitude, loc.longitude, accuracy: 0.0001)
    }

    // MARK: - MediaAsset init defaults

    func testMediaAssetDefaultsPhotoType() {
        let asset = MediaAsset()
        XCTAssertEqual(asset.mediaType, .photo)
    }

    func testMediaAssetDefaultDimensions() {
        let asset = MediaAsset()
        XCTAssertEqual(asset.pixelWidth, 1920)
        XCTAssertEqual(asset.pixelHeight, 1080)
    }

    func testMediaAssetNotFavoriteByDefault() {
        let asset = MediaAsset()
        XCTAssertFalse(asset.isFavorite)
    }

    func testMediaAssetNotSelectedByDefault() {
        let asset = MediaAsset()
        XCTAssertFalse(asset.isSelected)
    }

    // MARK: - MSAlbum mock init

    func testMSAlbumMockInit() {
        let album = MSAlbum(title: "Summer 2024", count: 134, type: .userAlbum)
        XCTAssertEqual(album.title, "Summer 2024")
        XCTAssertEqual(album.count, 134)
        XCTAssertEqual(album.type, .userAlbum)
        XCTAssertNil(album.startDate)
        XCTAssertNil(album.endDate)
    }

    func testMSAlbumTypeIcons() {
        XCTAssertFalse(MSAlbum.AlbumType.smartAlbum.icon.isEmpty)
        XCTAssertFalse(MSAlbum.AlbumType.userAlbum.icon.isEmpty)
        XCTAssertFalse(MSAlbum.AlbumType.moment.icon.isEmpty)
    }
}
