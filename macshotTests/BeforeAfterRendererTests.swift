import Cocoa
import ImageIO
import XCTest

final class BeforeAfterRendererTests: XCTestCase {

    func testTallShotsSitSideBySideAtTheSmallerHeight() {
        let layout = BeforeAfterRenderer.sideBySideLayout(before: CGSize(width: 800, height: 1200),
                                                          after: CGSize(width: 400, height: 600))
        XCTAssertEqual(layout.before, CGRect(x: 32, y: 32, width: 400, height: 600))
        XCTAssertEqual(layout.after, CGRect(x: 32 + 400 + 24, y: 32, width: 400, height: 600))
        XCTAssertEqual(layout.canvas, CGSize(width: 400 + 400 + 24 + 64, height: 664))
    }

    func testWideShotsStackWithBeforeOnTop() {
        let layout = BeforeAfterRenderer.sideBySideLayout(before: CGSize(width: 2000, height: 1000),
                                                          after: CGSize(width: 2000, height: 1000))
        XCTAssertGreaterThan(layout.before.minY, layout.after.maxY, "before is above after")
        XCTAssertEqual(layout.before.width, layout.after.width)
    }

    func testFittedNeverUpscales() {
        XCTAssertEqual(BeforeAfterRenderer.fitted(CGSize(width: 300, height: 200), maxSide: 1400), CGSize(width: 300, height: 200))
        XCTAssertEqual(BeforeAfterRenderer.fitted(CGSize(width: 2800, height: 1400), maxSide: 1400), CGSize(width: 1400, height: 700))
    }

    func testSideBySideImageHasTheLayoutSize() throws {
        let image = try XCTUnwrap(BeforeAfterRenderer.sideBySide(before: solid(400, 600, red: 1), after: solid(400, 600, red: 0)))
        XCTAssertEqual(image.width, 400 + 400 + 24 + 64)
        XCTAssertEqual(image.height, 664)
    }

    func testGIFLoopsAndFadesBothWays() throws {
        let data = try XCTUnwrap(BeforeAfterRenderer.gif(before: solid(200, 100, red: 1), after: solid(200, 100, red: 0), fadeFrames: 4))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1 + 4 + 1 + 4)
        let properties = CGImageSourceCopyProperties(source, nil) as? [String: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount as String] as? Int ?? 0, 0, "loops forever")
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(first.width, 200)
        XCTAssertEqual(first.height, 100)
    }

    private func solid(_ width: Int, _ height: Int, red: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
