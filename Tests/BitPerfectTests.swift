import AVFoundation
import XCTest
@testable import Idiophile_One

/// Sample-by-sample checks of the processing chain, with reproducible pseudo-random signals.
final class BitPerfectTests: XCTestCase {
    private let transparent = SignalPath(eq: .graphic(gains: Array(repeating: 0, count: 10)), bandsActive: false,
                                         replayGainDB: nil, digitalGainDB: 0)

    /// Deterministic signal covering the whole integer range, including both extremes.
    private func signal(bits: Int, rate: Double, seconds: Double = 2, seed: UInt64 = 42) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let scale = Float(1 << (bits - 1))
        var state = seed
        for ch in 0..<2 {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                var value = Int64(state >> 33) % Int64(scale) * (state & 1 == 0 ? 1 : -1)
                if i == 0 { value = -Int64(scale) }          // most negative
                if i == 1 { value = Int64(scale) - 1 }       // most positive
                data[i] = Float(value) / scale
            }
        }
        return buffer
    }

    func testTransparentPathIsBitPerfect16() throws {
        let report = try BitPerfectVerifier.verify(reference: signal(bits: 16, rate: 44100), sourceBits: 16, path: transparent)
        XCTAssertTrue(report.isIdentical, "\(report.differingSamples) samples differ")
    }

    func testTransparentPathIsBitPerfect24At96k() throws {
        let report = try BitPerfectVerifier.verify(reference: signal(bits: 24, rate: 96000), sourceBits: 24, path: transparent)
        XCTAssertTrue(report.isIdentical, "\(report.differingSamples) samples differ")
    }

    func testEqualizerIsDetected() throws {
        var path = transparent
        path.eq = .graphic(gains: [0, 0, 0, 0, 0, 3, 0, 0, 0, 0])
        path.bandsActive = true
        let report = try BitPerfectVerifier.verify(reference: signal(bits: 16, rate: 44100), sourceBits: 16, path: path)
        XCTAssertFalse(report.isIdentical)
        XCTAssertFalse(path.isTransparent)
    }

    func testBypassedFlatEqualizerIsTransparent() throws {
        var path = transparent
        path.eq = .graphic(gains: [6, 3, 0, -2, 0, 0, 1, 0, 0, 4])   // gains set but bands bypassed
        let report = try BitPerfectVerifier.verify(reference: signal(bits: 24, rate: 48000), sourceBits: 24, path: path)
        XCTAssertTrue(report.isIdentical, "\(report.differingSamples) samples differ")
    }

    func testReplayGainIsDetected() throws {
        var path = transparent
        path.replayGainDB = -6
        let report = try BitPerfectVerifier.verify(reference: signal(bits: 16, rate: 44100), sourceBits: 16, path: path)
        XCTAssertFalse(report.isIdentical)
    }

    func testDigitalVolumeIsDetected() throws {
        var path = transparent
        path.digitalGainDB = -0.1
        let report = try BitPerfectVerifier.verify(reference: signal(bits: 24, rate: 44100), sourceBits: 24, path: path)
        XCTAssertFalse(report.isIdentical)
        XCTAssertNotNil(report.maxErrorDBFS)
    }

    /// FLAC encoded by Apple's encoder, decoded by AVAudioFile, played through the chain:
    /// the integers must come back unchanged.
    func testFlacFileRoundTrip24() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("ref.wav"), flac = dir.appendingPathComponent("ref.flac")

        let source = signal(bits: 24, rate: 96000, seconds: 1, seed: 7)
        let wavSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 96000,
                                          AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                                          AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {
            let out = try AVAudioFile(forWriting: wav, settings: wavSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try out.write(from: source)
        }
        let encoder = Process()
        encoder.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        encoder.arguments = ["-f", "flac", "-d", "flac@96000", wav.path, flac.path]
        try encoder.run()
        encoder.waitUntilExit()
        XCTAssertEqual(encoder.terminationStatus, 0)

        let report = try BitPerfectVerifier.verify(url: flac, path: transparent)
        XCTAssertEqual(report.sourceBits, 24)
        XCTAssertTrue(report.isIdentical, "\(report.differingSamples) samples differ")

        // And the decoded file equals what was written.
        let decoded = try AVAudioFile(forReading: flac)
        let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: source.frameLength)!
        try decoded.read(into: buffer, frameCount: source.frameLength)
        for ch in 0..<2 {
            for i in 0..<Int(source.frameLength) where buffer.floatChannelData![ch][i] != source.floatChannelData![ch][i] {
                return XCTFail("decoded sample \(i) channel \(ch) differs")
            }
        }
    }

    /// Inverting polarity negates every sample exactly (and is never mistaken for bit-perfect).
    func testPolarityInversionIsExactNegation() throws {
        var path = transparent
        path.invertPolarity = true
        XCTAssertFalse(path.isTransparent)
        let source = signal(bits: 24, rate: 48000)
        let rendered = try BitPerfectVerifier.render(source, path: path)
        for ch in 0..<2 {
            for i in 0..<Int(source.frameLength) where rendered.floatChannelData![ch][i] != -source.floatChannelData![ch][i] {
                return XCTFail("sample \(i) channel \(ch): \(rendered.floatChannelData![ch][i]) vs \(-source.floatChannelData![ch][i])")
            }
        }
        let report = try BitPerfectVerifier.verify(reference: source, sourceBits: 24, path: path)
        XCTAssertFalse(report.isIdentical)
    }

    func testInvertedTwiceIsTransparentAgain() throws {
        // The signs cancel in the mixer volume.
        var path = transparent
        XCTAssertEqual(path.mixerVolume, 1)
        path.invertPolarity = true
        XCTAssertEqual(path.mixerVolume, -1)
        path.digitalGainDB = -6
        XCTAssertEqual(path.mixerVolume, -pow(10, -6 / 20), accuracy: 1e-6)
    }

    /// A 32-bit integer file cannot be proven through a float32 path: the reference has already
    /// lost its low bits, so the verifier must refuse rather than say "identical".
    func testThirtyTwoBitSourceIsNotClaimedBitPerfect() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for c in 0..<2 { for i in 0..<4800 { buffer.floatChannelData![c][i] = 0.3 * sin(Float(i) * 0.05) } }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {   // the file is finalised when it is released
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        XCTAssertThrowsError(try BitPerfectVerifier.verify(url: url, path: transparent)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("32-bit"), "\(error.localizedDescription)")
        }
    }
}
