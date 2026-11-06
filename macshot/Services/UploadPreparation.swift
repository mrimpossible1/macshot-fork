#if !OFFLINE
import Cocoa

/// Last step before a screenshot leaves the Mac. One on-device OCR pass:
/// - covers sensitive text (emails, phone numbers, keys, cards… per the
///   Auto-Redact types in Settings) with solid boxes, and
/// - suggests a readable file name from the screenshot's own text, never
///   built from a line that was redacted.
/// The local history copy is left untouched.
enum UploadPreparation {
    struct Prepared {
        let image: NSImage
        let title: String?
        let redactedCount: Int
    }

    /// Used until types are picked in the capture toolbar's Auto-Redact menu.
    /// Leaves out expiry dates, IP addresses and long hex strings, which
    /// match ordinary dates, version numbers and commit hashes too often.
    static let defaultTypes = ["email", "phone", "ssn", "credit_card", "cvv", "aws_key", "secret_assignment", "bearer"]

    static let autoRedactKey = "uploadAutoRedact"
    static let readableNamesKey = "uploadReadableNames"

    static var autoRedact: Bool { UserDefaults.standard.object(forKey: autoRedactKey) as? Bool ?? true }
    static var readableNames: Bool { UserDefaults.standard.object(forKey: readableNamesKey) as? Bool ?? true }

    static func prepare(_ image: NSImage, completion: @escaping (Prepared) -> Void) {
        let redact = autoRedact
        let name = readableNames
        guard redact || name, let snapshot = try? HistoryImageSnapshot.Image(image) else {
            completion(Prepared(image: image, title: nil, redactedCount: 0))
            return
        }
        let pixels = snapshot.pixels
        let pointSize = snapshot.pointSize
        let enabledTypes = (UserDefaults.standard.array(forKey: "enabledRedactTypes") as? [String]) ?? defaultTypes
        VisionOCR.performTextRecognition(cgImage: pixels) { observations, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let boxes = redact ? redactionBoxes(in: observations, enabledTypes: enabledTypes) : []
                    var title: String?
                    if name {
                        let safeLines = observations
                            .filter { !AutoRedactor.containsSensitiveText($0.text, enabledTypes: enabledTypes) }
                            .map { (text: $0.text, box: $0.boundingBox) }
                        title = ReadableCaptureName.title(from: safeLines)
                    }
                    var output = image
                    if !boxes.isEmpty, let covered = cover(pixels, boxes: boxes) {
                        output = NSImage(cgImage: covered, size: pointSize)
                    }
                    completion(Prepared(image: output, title: title, redactedCount: boxes.count))
                }
            }
        }
    }

    /// Normalized (Vision, bottom-left origin) rects of every sensitive match.
    static func redactionBoxes(in observations: [OCRTextObservation], enabledTypes: [String]?) -> [CGRect] {
        var boxes: [CGRect] = []
        for observation in observations {
            for match in AutoRedactor.sensitiveMatches(in: observation.text, enabledTypes: enabledTypes) {
                boxes.append(observation.boundingBox(for: match.range) ?? observation.boundingBox)
            }
        }
        return boxes
    }

    /// Draws `image` and fills each normalized box (with a little padding)
    /// with a solid dark color. Solid fill, not blur: blurred text can
    /// sometimes be recovered.
    nonisolated static func cover(_ image: CGImage, boxes: [CGRect]) -> CGImage? {
        let width = image.width, height = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: full)
        context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
        for box in boxes {
            let rect = CGRect(x: box.minX * CGFloat(width), y: box.minY * CGFloat(height),
                              width: box.width * CGFloat(width), height: box.height * CGFloat(height))
            let pad = max(2, rect.height * 0.15)
            context.fill(rect.insetBy(dx: -pad, dy: -pad).intersection(full))
        }
        return context.makeImage()
    }
}
#endif
