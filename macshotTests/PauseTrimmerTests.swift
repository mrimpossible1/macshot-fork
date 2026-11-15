import XCTest

final class PauseTrimmerTests: XCTestCase {

    private func w(_ text: String, _ start: Double, _ end: Double) -> CaptionTimeline.Word {
        CaptionTimeline.Word(text: text, start: start, end: end)
    }

    private func rounded(_ cuts: [(Double, Double)]) -> [[Double]] {
        cuts.map { [($0.0 * 100).rounded() / 100, ($0.1 * 100).rounded() / 100] }
    }

    func testLongPauseIsCutWithPadding() {
        let words = [w("Hello", 0, 0.5), w("there", 0.6, 1.0), w("friend", 3.0, 3.5)]
        let cuts = PauseTrimmer.cutRanges(words: words, trimStart: 0, trimEnd: 3.5)
        XCTAssertEqual(rounded(cuts), [[1.15, 2.85]])
    }

    func testShortPausesStay() {
        let words = [w("one", 0, 0.4), w("two", 0.8, 1.2), w("three", 1.5, 2.0)]
        XCTAssertTrue(PauseTrimmer.cutRanges(words: words, trimStart: 0, trimEnd: 2.0).isEmpty)
    }

    func testFillerInShortGapIsCut() {
        let words = [w("So", 0, 0.3), w("um,", 0.35, 0.6), w("anyway", 0.7, 1.2)]
        let cuts = PauseTrimmer.cutRanges(words: words, trimStart: 0, trimEnd: 1.2)
        XCTAssertEqual(rounded(cuts), [[0.35, 0.65]])
    }

    func testLeadingAndTrailingSilenceAreCut() {
        let words = [w("Hi", 2.0, 2.4), w("all", 2.5, 2.9)]
        let cuts = PauseTrimmer.cutRanges(words: words, trimStart: 0, trimEnd: 6)
        XCTAssertEqual(rounded(cuts), [[0, 1.85], [3.05, 6]])
    }

    func testRespectsTrimRange() {
        let words = [w("a", 1, 1.2), w("b", 5, 5.2)]
        let cuts = PauseTrimmer.cutRanges(words: words, trimStart: 1, trimEnd: 5.2)
        XCTAssertEqual(rounded(cuts), [[1.35, 4.85]])
        XCTAssertTrue(cuts.allSatisfy { $0.0 >= 1 && $0.1 <= 5.2 })
    }

    func testNothingIsCutWithoutRealSpeech() {
        XCTAssertTrue(PauseTrimmer.cutRanges(words: [], trimStart: 0, trimEnd: 30).isEmpty)
        XCTAssertTrue(PauseTrimmer.cutRanges(words: [w("um", 3, 3.4), w("Uh.", 8, 8.3)], trimStart: 0, trimEnd: 30).isEmpty)
    }

    func testFillerDetectionIgnoresCaseAndPunctuation() {
        XCTAssertTrue(PauseTrimmer.isFiller("Um,"))
        XCTAssertTrue(PauseTrimmer.isFiller("uh."))
        XCTAssertFalse(PauseTrimmer.isFiller("umbrella"))
        XCTAssertFalse(PauseTrimmer.isFiller("like"))
    }

    func testAutomaticFlagSurvivesRoundTripAndOldFilesDecode() throws {
        let cut = VideoCutSegment(startTime: 1, endTime: 2, isAutomatic: true)
        let copy = try JSONDecoder().decode(VideoCutSegment.self, from: JSONEncoder().encode(cut))
        XCTAssertTrue(copy.isAutomatic)
        let old = try JSONDecoder().decode(VideoCutSegment.self, from: Data(#"{"startTime":1,"endTime":2}"#.utf8))
        XCTAssertFalse(old.isAutomatic)
    }
}
