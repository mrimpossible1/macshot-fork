import Foundation

/// Plans cuts that remove dead air and filler words ("um", "uh") from a
/// recording, using the on-device transcript's word timings. Pure and
/// deterministic: the editor applies the result as automatic cuts, which a
/// second run replaces and Undo reverts.
nonisolated enum PauseTrimmer {
    /// Spoken fillers, matched after lowercasing and trimming punctuation.
    static let fillerWords: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhm", "erm", "er", "ah", "ahh", "hmm", "hm", "mm", "mmm",
    ]

    /// Pauses at least this long are cut.
    static let defaultMinPause: Double = 0.7
    /// Breathing room kept on each side of speech next to a cut pause.
    static let defaultPadding: Double = 0.15
    /// A gap holding a filler word is cut when at least this long…
    static let fillerMinGap: Double = 0.25
    /// …keeping this much around the neighbouring words.
    static let fillerPadding: Double = 0.05
    /// Shortest cut worth making (matches VideoCutSegment.minDuration).
    static let minCut: Double = 0.1

    static func isFiller(_ text: String) -> Bool {
        let word = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        return fillerWords.contains(word)
    }

    /// Source-time ranges to cut, sorted and non-overlapping, inside
    /// `trimStart…trimEnd`. Returns nothing when no real speech was found, so
    /// a silent or music-only recording is never cut away.
    static func cutRanges(words: [CaptionTimeline.Word], trimStart: Double, trimEnd: Double,
                          minPause: Double = defaultMinPause,
                          padding: Double = defaultPadding) -> [(Double, Double)] {
        guard trimStart.isFinite, trimEnd.isFinite, trimEnd > trimStart else { return [] }
        let sorted = words
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.end > trimStart && $0.start < trimEnd }
            .sorted { $0.start < $1.start }
        guard sorted.contains(where: { !isFiller($0.text) }) else { return [] }

        var cuts: [(Double, Double)] = []
        func addCut(_ start: Double, _ end: Double) {
            let s = max(trimStart, start), e = min(trimEnd, end)
            guard e - s >= minCut else { return }
            cuts.append((s, e))
        }

        var lastSpeechEnd: Double?   // nil until the first real word
        var gapHasFiller = false
        for word in sorted {
            if isFiller(word.text) {
                gapHasFiller = true
                continue
            }
            let start = max(trimStart, word.start)
            if let previous = lastSpeechEnd {
                let gap = start - previous
                if gap >= minPause {
                    addCut(previous + padding, start - padding)
                } else if gapHasFiller, gap >= fillerMinGap {
                    addCut(previous + fillerPadding, start - fillerPadding)
                }
            } else if start - trimStart >= minPause || (gapHasFiller && start - trimStart >= fillerMinGap) {
                // Leading silence (and any opening "um") before the first word.
                addCut(trimStart, start - (gapHasFiller && start - trimStart < minPause ? fillerPadding : padding))
            }
            lastSpeechEnd = max(lastSpeechEnd ?? start, min(trimEnd, word.end))
            gapHasFiller = false
        }
        // Trailing silence (and any closing "um") after the last word.
        if let last = lastSpeechEnd {
            let tail = trimEnd - last
            if tail >= minPause || (gapHasFiller && tail >= fillerMinGap) {
                addCut(last + (tail >= minPause ? padding : fillerPadding), trimEnd)
            }
        }
        return cuts
    }

    /// Total seconds the cuts remove.
    static func totalDuration(_ cuts: [(Double, Double)]) -> Double {
        cuts.reduce(0) { $0 + max(0, $1.1 - $1.0) }
    }
}
