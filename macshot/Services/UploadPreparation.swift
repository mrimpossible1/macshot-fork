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
        /// True when redaction was on but text recognition failed. The
        /// caller must not upload: the image could not be checked.
        let couldNotCheck: Bool
    }

    /// Used until types are picked in the capture toolbar's Auto-Redact menu.
    /// Leaves out expiry dates, IP addresses and long hex strings, which
    /// match ordinary dates, version numbers and commit hashes too often.
    static let defaultTypes = ["email", "phone", "ssn", "credit_card", "cvv", "aws_key", "secret_assignment", "bearer"]

    static let autoRedactKey = "uploadAutoRedact"
    static let readableNamesKey = "uploadReadableNames"

    static var autoRedact: Bool { UserDefaults.standard.object(forKey: autoRedactKey) as? Bool ?? true }
    static var readableNames: Bool { UserDefaults.standard.object(forKey: readableNamesKey) as? Bool ?? true }

    /// `wantsTitle` is false for providers that name files themselves.
    static func prepare(_ image: NSImage, wantsTitle: Bool, completion: @escaping (Prepared) -> Void) {
        let redact = autoRedact
        let name = wantsTitle && readableNames
        guard redact || name, let snapshot = try? HistoryImageSnapshot.Image(image) else {
            // Redaction on but the image can't be read: fail closed.
            completion(Prepared(image: image, title: nil, redactedCount: 0, couldNotCheck: redact))
            return
        }
        let pixels = snapshot.pixels
        let pointSize = snapshot.pointSize
        let enabledTypes = (UserDefaults.standard.array(forKey: "enabledRedactTypes") as? [String]) ?? defaultTypes
        recognize(pixels) { observations, error in
            MainActor.assumeIsolated {
                if redact, error != nil {
                    completion(Prepared(image: image, title: nil, redactedCount: 0, couldNotCheck: true))
                    return
                }
                let found = redact ? sensitiveRegions(in: observations, enabledTypes: enabledTypes, pointSize: pointSize)
                                   : (boxes: [CGRect](), lines: Set<Int>())
                var title: String?
                if name {
                    // Never name a file after a line that held sensitive text.
                    let safeLines = observations.indices
                        .filter { !found.lines.contains($0)
                                  && !AutoRedactor.containsSensitiveText(observations[$0].text, enabledTypes: enabledTypes) }
                        .map { (text: observations[$0].text, box: observations[$0].boundingBox) }
                    title = ReadableCaptureName.title(from: safeLines)
                }
                var output = image
                if !found.boxes.isEmpty {
                    guard let covered = cover(pixels, boxes: found.boxes) else {
                        completion(Prepared(image: image, title: nil, redactedCount: 0, couldNotCheck: true))
                        return
                    }
                    output = NSImage(cgImage: covered, size: pointSize)
                }
                completion(Prepared(image: output, title: title, redactedCount: found.boxes.count, couldNotCheck: false))
            }
        }
    }

    /// Runs OCR off the main thread and delivers results on the main thread.
    /// Nonisolated so the OCR callback isn't treated as main-actor code.
    nonisolated private static func recognize(_ image: CGImage,
                                              then handle: @escaping ([OCRTextObservation], Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextRecognition(cgImage: image) { observations, error in
                DispatchQueue.main.async { handle(observations, error) }
            }
        }
    }

    /// Normalized (Vision, bottom-left origin) rects to cover, plus the
    /// indexes of the lines they came from. Uses the same planner as the
    /// editor's Auto-Redact, so card numbers split across lines are caught.
    static func sensitiveRegions(in observations: [OCRTextObservation], enabledTypes: [String]?,
                                 pointSize: CGSize) -> (boxes: [CGRect], lines: Set<Int>) {
        let lines = observations.map { observation in
            let box = observation.boundingBox
            return PIIRedactionPlanner.Line(text: observation.text,
                bounds: CGRect(x: box.minX * pointSize.width, y: box.minY * pointSize.height,
                               width: box.width * pointSize.width, height: box.height * pointSize.height))
        }
        var boxes: [CGRect] = []
        var indexes = Set<Int>()
        for match in PIIRedactionPlanner.matches(in: lines, enabledTypes: enabledTypes) {
            let observation = observations[match.lineIndex]
            boxes.append(observation.boundingBox(for: match.range) ?? observation.boundingBox)
            indexes.insert(match.lineIndex)
        }
        return (boxes, indexes)
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
