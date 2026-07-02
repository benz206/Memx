import CoreGraphics
import XCTest

@testable import MemXCore

final class ColorTemperatureTests: XCTestCase {
    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let side = 32
        let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    func testWarmImageScoresHigh() {
        let warmth = PhotoScoringService.colorTemperature(for: solidImage(red: 1, green: 0.3, blue: 0.1))
        XCTAssertNotNil(warmth)
        XCTAssertGreaterThan(warmth ?? 0, 0.65)
    }

    func testCoolImageScoresLow() {
        let warmth = PhotoScoringService.colorTemperature(for: solidImage(red: 0.1, green: 0.3, blue: 1))
        XCTAssertNotNil(warmth)
        XCTAssertLessThan(warmth ?? 1, 0.35)
    }

    func testNeutralGrayIsCentered() {
        let warmth = PhotoScoringService.colorTemperature(for: solidImage(red: 0.5, green: 0.5, blue: 0.5))
        XCTAssertNotNil(warmth)
        XCTAssertEqual(warmth ?? 0, 0.5, accuracy: 0.05)
    }
}
