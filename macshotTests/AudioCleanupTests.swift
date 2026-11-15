import XCTest

final class AudioCleanupTests: XCTestCase {

    private func sine(_ amplitude: Float, frequency: Double = 220, count: Int = AudioCleanup.frameLength) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / AudioCleanup.sampleRate)) }
    }

    func testAnalysisLevelsQuietSpeechUp() {
        // 90 quiet-noise frames, 100 speech frames at ~-34 dBFS RMS.
        let levels = [Float](repeating: 0.001, count: 90) + [Float](repeating: 0.02, count: 100)
        let analysis = AudioCleanup.analyze(frameRMS: levels)
        XCTAssertEqual(analysis.gain, 5, accuracy: 0.01)          // 0.1 / 0.02
        XCTAssertEqual(analysis.gateThreshold, 0.0025, accuracy: 0.0001)
        XCTAssertLessThan(analysis.gateThreshold, 0.02)
    }

    func testAnalysisClampsGainAndHandlesSilence() {
        XCTAssertEqual(AudioCleanup.analyze(frameRMS: [Float](repeating: 0.0001, count: 10)).gain, 10)
        XCTAssertEqual(AudioCleanup.analyze(frameRMS: [Float](repeating: 0.8, count: 10)).gain, 0.5)
        XCTAssertEqual(AudioCleanup.analyze(frameRMS: []), AudioCleanup.Analysis(gain: 1, gateThreshold: 0))
    }

    func testLimiterKeepsPeaksUnderFullScale() {
        XCTAssertEqual(AudioCleanup.limit(0.5), 0.5)
        XCTAssertLessThan(AudioCleanup.limit(4), 1)
        XCTAssertGreaterThan(AudioCleanup.limit(-4), -1)
        XCTAssertGreaterThan(AudioCleanup.limit(1.2), AudioCleanup.limit(0.95))
    }

    func testHighPassRemovesDCAndKeepsVoice() {
        var dc = AudioCleanup.HighPass()
        var last: Float = 1
        for _ in 0..<48_000 { last = dc.process(1) }
        XCTAssertLessThan(abs(last), 0.001)

        var voice = AudioCleanup.HighPass()
        let out = sine(0.5, frequency: 440, count: 9600).map { voice.process($0) }
        XCTAssertGreaterThan(AudioCleanup.rms(out[4800...]), 0.3)
    }

    func testProcessorLowersNoiseAndRaisesSpeech() {
        let analysis = AudioCleanup.Analysis(gain: 4, gateThreshold: 0.01)
        var processor = AudioCleanup.Processor(analysis: analysis)
        var noise: [Float] = []
        for _ in 0..<10 { var f = sine(0.004); processor.process(&f); noise = f }
        // Gated (×0.18) then gained (×4): quieter than the gain alone would give.
        XCTAssertLessThan(AudioCleanup.rms(noise[...]), 0.004 * 0.707 * 4 * 0.5)

        var speech: [Float] = []
        for _ in 0..<10 { var f = sine(0.05); processor.process(&f); speech = f }
        XCTAssertGreaterThan(AudioCleanup.rms(speech[...]), 0.05 * 0.707 * 2)
        XCTAssertTrue(speech.allSatisfy { abs($0) < 1 })
    }

    func testCleanAudioFlagRoundTripsAndDefaultsOff() throws {
        let project = VideoProject(sourceDuration: 10, look: VideoLook())
        project.cleanAudio = true
        let copy = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project))
        XCTAssertTrue(copy.cleanAudio)
        let old = try JSONDecoder().decode(VideoProject.self, from: Data(#"{"sourceDuration":10}"#.utf8))
        XCTAssertFalse(old.cleanAudio)
    }

    func testOutputLivesBesideTheProject() {
        let dir = URL(fileURLWithPath: "/tmp/take-1")
        XCTAssertEqual(AudioCleanup.outputURL(projectDirectory: dir, sourcePath: "/x.mp4")?.deletingLastPathComponent(), dir)
        let a = AudioCleanup.outputURL(projectDirectory: nil, sourcePath: "/a.mp4")
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, AudioCleanup.outputURL(projectDirectory: nil, sourcePath: "/b.mp4"))
        XCTAssertEqual(a, AudioCleanup.outputURL(projectDirectory: nil, sourcePath: "/a.mp4"))
    }
}
