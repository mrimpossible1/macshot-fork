import Cocoa

/// Names a capture after its most prominent text, so a shared file reads
/// "Stripe payout settings 2026-11-06 at 01.51.07.png" instead of a bare date.
/// Recognition runs on-device through `VisionOCR`; nothing leaves the Mac.
enum ReadableCaptureName {
    nonisolated static let maxWords = 8
    nonisolated static let maxCharacters = 60

    /// Picks the best title from recognized lines. `box` is Vision's
    /// normalized rect (origin bottom-left, 0...1). Larger text wins (headings,
    /// window titles), with a nudge toward the top of the image.
    nonisolated static func title(from lines: [(text: String, box: CGRect)]) -> String? {
        var best: (text: String, score: Double)?
        for line in lines {
            let text = clean(line.text)
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            // Skip noise: single glyphs, numbers, timestamps, very long paragraphs.
            guard letters >= 3, text.count <= 120 else { continue }
            let words = text.split(separator: " ").count
            var score = Double(line.box.height) * (1 + 0.35 * Double(line.box.maxY))
            if words >= 2 { score *= 1.15 }
            if words > 12 { score *= 0.6 }
            if best == nil || score > best!.score { best = (text, score) }
        }
        guard let chosen = best?.text else { return nil }
        let words = chosen.split(separator: " ").prefix(maxWords).joined(separator: " ")
        let capped = String(words.prefix(maxCharacters)).trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
        return capped.isEmpty ? nil : capped
    }

    /// Keeps letters, digits and light punctuation; collapses whitespace.
    nonisolated static func clean(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-&'.,+#@"))
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars { scalars.append(allowed.contains(scalar) ? scalar : " ") }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
    }

    /// "Stripe payout settings 2026-11-06 at 01.51.07". Seconds keep quick
    /// repeat captures of the same screen from colliding.
    nonisolated static func filename(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return FilenameSanitizer.sanitize("\(title) \(formatter.string(from: date))")
    }

    /// Recognizes text in `image` and hands back a title on the main thread,
    /// or nil when there is no usable text (a photo, an empty window).
    nonisolated static func suggestTitle(for image: CGImage, completion: @escaping (String?) -> Void) {
        VisionOCR.performTextRecognition(cgImage: image) { observations, _ in
            let title = Self.title(from: observations.map { (text: $0.text, box: $0.boundingBox) })
            DispatchQueue.main.async { completion(title) }
        }
    }
}
