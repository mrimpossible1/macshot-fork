import AVFoundation
import Foundation

/// One-click mic clean-up for the video editor (MacShotty). Renders the first
/// audio track (the mic in MacShotty recordings) once into a lossless file
/// beside the project:
/// 1. a high-pass filter removes rumble and desk thumps,
/// 2. a gentle gate lowers background noise between words,
/// 3. the voice is leveled to a steady loudness, and
/// 4. a soft limiter keeps peaks from clipping.
/// The composition then uses that file in place of the original track, so
/// cuts, speed changes and freezes line up exactly like the original audio.
/// The DSP is pure and runs in two streaming passes, so memory stays bounded
/// however long the recording is.
nonisolated enum AudioCleanup {
    static let version = 1
    static let sampleRate: Double = 48_000
    static let frameLength = 960  // 20 ms

    enum CleanupError: LocalizedError {
        case noAudio, readFailed, writeFailed
        var errorDescription: String? {
            switch self {
            case .noAudio: return "This recording has no audio to clean up."
            case .readFailed: return "Couldn't read the recording's audio."
            case .writeFailed: return "Couldn't save the cleaned-up audio."
            }
        }
    }

    // MARK: Pure DSP

    struct Analysis: Equatable {
        /// Makeup gain applied to the voice.
        var gain: Float
        /// Frames quieter than this (RMS) count as background noise.
        var gateThreshold: Float
    }

    /// Target voice loudness: about -20 dBFS RMS.
    static let targetRMS: Float = 0.1
    /// How far the gate lowers background noise: about -15 dB.
    static let gateFloor: Float = 0.18
    static let limiterThreshold: Float = 0.89  // -1 dBFS

    /// Picks the noise floor (quietest 10% of frames) and the voice level
    /// (RMS of frames clearly above it) from per-frame RMS values.
    static func analyze(frameRMS: [Float]) -> Analysis {
        let audible = frameRMS.filter { $0.isFinite && $0 > 0.000_001 }.sorted()
        guard let loudest = audible.last else { return Analysis(gain: 1, gateThreshold: 0) }
        let noise = audible[Int(Double(audible.count - 1) * 0.1)]
        let speech = audible.filter { $0 > max(noise * 4, 0.003) }
        let level = speech.isEmpty ? loudest : (speech.reduce(0) { $0 + $1 * $1 } / Float(speech.count)).squareRoot()
        let gain = min(max(targetRMS / max(level, 0.000_001), 0.5), 10)
        // Never gate the voice itself: keep the threshold well under it.
        let gate = min(max(noise * 2.5, 0.0005), level * 0.25)
        return Analysis(gain: gain, gateThreshold: gate)
    }

    /// Second-order Butterworth high-pass (RBJ cookbook).
    struct HighPass {
        private let b0, b1, b2, a1, a2: Float
        private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        init(cutoff: Double = 80, sampleRate: Double = AudioCleanup.sampleRate) {
            let w0 = 2 * Double.pi * cutoff / sampleRate
            let alpha = sin(w0) / (2 * 0.7071)
            let cosw = cos(w0)
            let a0 = 1 + alpha
            b0 = Float((1 + cosw) / 2 / a0)
            b1 = Float(-(1 + cosw) / a0)
            b2 = Float((1 + cosw) / 2 / a0)
            a1 = Float(-2 * cosw / a0)
            a2 = Float((1 - alpha) / a0)
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// Soft knee above -1 dBFS; output never exceeds 0.995.
    static func limit(_ x: Float) -> Float {
        let a = abs(x), t = limiterThreshold
        guard a > t else { return x }
        let y = t + (0.995 - t) * tanh((a - t) / (1 - t))
        return x < 0 ? -y : y
    }

    /// Filters, gates, levels and limits audio frame by frame.
    struct Processor {
        let analysis: Analysis
        private var highPass = HighPass()
        private var gateGain: Float = 1
        // ~5 ms attack (opening for speech), ~80 ms release.
        private let attack: Float = 1 - exp(-1 / Float(0.005 * AudioCleanup.sampleRate))
        private let release: Float = 1 - exp(-1 / Float(0.080 * AudioCleanup.sampleRate))

        init(analysis: Analysis) { self.analysis = analysis }

        mutating func process(_ frame: inout [Float]) {
            for i in frame.indices { frame[i] = highPass.process(frame[i]) }
            let level = AudioCleanup.rms(frame[...])
            let target: Float = level < analysis.gateThreshold ? AudioCleanup.gateFloor : 1
            for i in frame.indices {
                gateGain += (target - gateGain) * (target > gateGain ? attack : release)
                frame[i] = AudioCleanup.limit(frame[i] * gateGain * analysis.gain)
            }
        }
    }

    // MARK: Files

    /// Where a document's cleaned audio lives: beside its project when it has
    /// one, else in Caches keyed by the source path.
    static func outputURL(projectDirectory: URL?, sourcePath: String) -> URL? {
        // Keyed to the source's path, size and date, so a replaced source
        // never reuses audio cleaned from the old file.
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourcePath)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let date = Int64(((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0).rounded())
        var hash: UInt64 = 5381
        for byte in "\(sourcePath)|\(size)|\(date)".utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let name = "clean-audio-v\(version)-" + String(hash, radix: 16) + ".m4a"
        if let projectDirectory { return projectDirectory.appendingPathComponent(name) }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("CleanAudio", isDirectory: true).appendingPathComponent(name)
    }

    /// Renders the cleaned first audio track of `asset` to `url` off the main
    /// thread. Writes to a temporary file and moves it into place when done.
    static func render(asset: AVAsset, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try renderSynchronously(asset: asset, to: url)
        }.value
    }

    private static func renderSynchronously(asset: AVAsset, to url: URL) throws {
        guard let track = asset.tracks(withMediaType: .audio).first else { throw CleanupError.noAudio }

        // Pass 1: measure.
        var analyzer = HighPass()
        var levels: [Float] = []
        try readFrames(asset: asset, track: track) { frame in
            var filtered = frame
            for i in filtered.indices { filtered[i] = analyzer.process(filtered[i]) }
            levels.append(rms(filtered[...]))
        }
        guard !levels.isEmpty else { throw CleanupError.noAudio }
        var processor = Processor(analysis: analyze(frameRMS: levels))

        // Pass 2: process and write.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(to: temp) { file in
            // Keep the original track's start offset so audio stays in sync.
            let lead = Int((max(0, track.timeRange.start.seconds) * sampleRate).rounded())
            if lead > 0 { try append([Float](repeating: 0, count: lead), to: file) }
            try readFrames(asset: asset, track: track) { frame in
                var out = frame
                processor.process(&out)
                try append(out, to: file)
            }
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: temp, to: url)
    }

    private static func write(to url: URL, _ body: (AVAudioFile) throws -> Void) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw CleanupError.writeFailed
        }
        try body(file)
    }  // the file is closed when it goes out of scope

    private static func append(_ samples: [Float], to file: AVAudioFile) throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    /// Streams the track as mono 48 kHz float frames of `frameLength`.
    private static func readFrames(asset: AVAsset, track: AVAssetTrack, _ body: ([Float]) throws -> Void) throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw CleanupError.readFailed }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CleanupError.readFailed }
        reader.add(output)
        guard reader.startReading() else { throw CleanupError.readFailed }
        var pending: [Float] = []
        pending.reserveCapacity(frameLength * 4)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { reader.cancelReading(); throw CleanupError.readFailed }
            pending.append(contentsOf: chunk)
            var start = 0
            while pending.count - start >= frameLength {
                try body(Array(pending[start..<start + frameLength]))
                start += frameLength
            }
            pending.removeFirst(start)
        }
        if reader.status == .failed { throw CleanupError.readFailed }
        if !pending.isEmpty { try body(pending) }
    }
}
