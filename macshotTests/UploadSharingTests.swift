#if !OFFLINE
import Cocoa
import XCTest

/// Readable names, link formats and pre-upload redaction.
final class UploadSharingTests: XCTestCase {

    // MARK: Readable names

    func testTitlePrefersLargeTextAndSkipsNoise() {
        let lines: [(text: String, box: CGRect)] = [
            (text: "12:41", box: CGRect(x: 0.9, y: 0.95, width: 0.05, height: 0.02)),
            (text: "Payout settings", box: CGRect(x: 0.1, y: 0.8, width: 0.4, height: 0.06)),
            (text: "Manage how and when Stripe sends your money to your bank account.",
             box: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.025)),
            (text: "»", box: CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.1)),
        ]
        XCTAssertEqual(ReadableCaptureName.title(from: lines), "Payout settings")
    }

    func testTitleIsNilWithoutUsableText() {
        XCTAssertNil(ReadableCaptureName.title(from: []))
        XCTAssertNil(ReadableCaptureName.title(from: [(text: "12 / 34", box: CGRect(x: 0, y: 0, width: 1, height: 0.2))]))
    }

    func testTitleIsCleanedAndCapped() {
        let long = "★ Welcome   to the   Impossible: analytics dashboard for every app we ship this year ★"
        let title = ReadableCaptureName.title(from: [(text: long, box: CGRect(x: 0, y: 0.5, width: 1, height: 0.05))])
        XCTAssertEqual(title, "Welcome to the Impossible analytics dashboard for every")
    }

    func testFilenameAddsSortableTimestamp() {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 6
        components.hour = 1; components.minute = 51; components.second = 7
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(ReadableCaptureName.filename(title: "Payout settings", date: date), "Payout settings 2026-11-06 at 01.51.07")
    }

    // MARK: Link formats

    func testDisplayNameComesFromTheLink() {
        XCTAssertEqual(UploadLinkClipboard.displayName(forLink: "https://www.dropbox.com/scl/fi/abc/Payout%20settings.png?rlkey=k&dl=0"),
                       "Payout settings")
        XCTAssertEqual(UploadLinkClipboard.displayName(forLink: "https://www.dropbox.com/home/Share?preview=Shot%201.png"), "Shot 1")
        XCTAssertEqual(UploadLinkClipboard.displayName(forLink: ""), "Screenshot")
    }

    func testMarkdownAndHTMLAreEscaped() {
        XCTAssertEqual(UploadLinkClipboard.markdown(link: "https://x.test/a(1).png", name: "Fix [prod]"),
                       "[Fix \\[prod\\]](https://x.test/a%281%29.png)")
        XCTAssertEqual(UploadLinkClipboard.html(link: "https://x.test/?a=1&b=\"2\"", name: "<Q&A>"),
                       "<a href=\"https://x.test/?a=1&amp;b=&quot;2&quot;\">&lt;Q&amp;A&gt;</a>")
    }

    // MARK: Pre-upload redaction

    func testSensitiveMatchesBecomeBoxes() {
        let text = "Contact joel@example.com today"
        let emailBox = CGRect(x: 0.3, y: 0.5, width: 0.3, height: 0.05)
        let observation = OCRTextObservation(text: text, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.05)) { _ in emailBox }
        let plain = OCRTextObservation(text: "Nothing to hide here", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05))
        let boxes = UploadPreparation.redactionBoxes(in: [observation, plain], enabledTypes: UploadPreparation.defaultTypes)
        XCTAssertEqual(boxes, [emailBox])
    }

    func testDefaultTypesLeaveDatesAlone() {
        let observation = OCRTextObservation(text: "Released 10/26 build 1024 768", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 0.1))
        XCTAssertTrue(UploadPreparation.redactionBoxes(in: [observation], enabledTypes: UploadPreparation.defaultTypes).isEmpty)
    }

    func testCoverFillsTheBoxAndKeepsTheRest() throws {
        let size = 100
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let white = try XCTUnwrap(context.makeImage())

        let covered = try XCTUnwrap(UploadPreparation.cover(white, boxes: [CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)]))
        XCTAssertEqual(covered.width, size)
        XCTAssertEqual(covered.height, size)
        XCTAssertLessThan(try brightness(covered, x: 50, y: 50), 0.2)
        XCTAssertGreaterThan(try brightness(covered, x: 5, y: 5), 0.9)
    }

    private func brightness(_ image: CGImage, x: Int, y: Int) throws -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return Double(pixel[0]) / 255
    }
}
#endif
