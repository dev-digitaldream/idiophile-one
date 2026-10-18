import AVFoundation
import XCTest
@testable import Idiophile_One

final class ResolutionTests: XCTestCase {
    /// Writes a stereo 24-bit WAV of evenly spaced sines up to `topHz`, plus a faint noise floor.
    private func makeFile(rate: Double, topHz: Double, seconds: Double = 3, spacing: Double = 250,
                          amplitude: Float = 0.004, quantizeTo bits: Int = 24) throws -> URL {
        let frames = Int(rate * seconds)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let tones = stride(from: 300.0, through: topHz, by: spacing).map { ($0, Double($0.hashValue % 628) / 100) }
        var seed: UInt64 = 99
        let step = Float(1 << (24 - bits)) / 8_388_608
        for c in 0..<2 {
            let data = buffer.floatChannelData![c]
            for i in 0..<frames {
                let t = Double(i) / rate
                var v = 0.0
                for (f, phase) in tones { v += sin(2 * .pi * f * t + phase) }
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Float(Int64(seed >> 40) - (1 << 23)) / Float(1 << 23) * 1e-6
                var sample = amplitude * Float(v) + noise
                if bits < 24 { sample = (sample / step).rounded() * step }
                data[i] = sample
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    func testUpsampledFileIsDetected() throws {
        // A "96 kHz" file whose content ends at 20 kHz (a 44.1 kHz master in a bigger box).
        let url = try makeFile(rate: 96_000, topHz: 20_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try XCTUnwrap(ResolutionScanner.scan(url: url, claimedBits: 24))
        XCTAssertEqual(report.verdict, .upsampled(fromHz: 44_100))
        XCTAssertEqual(try XCTUnwrap(report.cutoffHz), 20_000, accuracy: 1_000)
    }

    func testTrueHighResReachesNyquist() throws {
        let url = try makeFile(rate: 96_000, topHz: 47_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try XCTUnwrap(ResolutionScanner.scan(url: url, claimedBits: 24))
        XCTAssertEqual(report.verdict, .fullBand)
    }

    func testLossySignatureAt16kHz() throws {
        let url = try makeFile(rate: 44_100, topHz: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try XCTUnwrap(ResolutionScanner.scan(url: url, claimedBits: 16))
        guard case .lossySignature(let cutoff) = report.verdict else { return XCTFail("\(report.verdict)") }
        XCTAssertEqual(cutoff, 16_000, accuracy: 1_000)
    }

    func testFullBandCDIsNotFlagged() throws {
        let url = try makeFile(rate: 44_100, topHz: 21_000)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try XCTUnwrap(ResolutionScanner.scan(url: url, claimedBits: 16)).verdict, .fullBand)
    }

    func testPaddedBitDepthIsDetected() throws {
        // 16-bit content stored in a 24-bit file: the low 8 bits are always zero.
        let url = try makeFile(rate: 48_000, topHz: 18_000, quantizeTo: 16)
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try XCTUnwrap(ResolutionScanner.scan(url: url, claimedBits: 24))
        XCTAssertEqual(report.effectiveBits, 16)
        XCTAssertTrue(report.depthIsPadded)
    }

    func testTrue24BitUsesLowBits() throws {
        let url = try makeFile(rate: 48_000, topHz: 18_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try XCTUnwrap(ResolutionScanner.scan(url: url, claimedBits: 24))
        XCTAssertEqual(report.effectiveBits, 24)
        XCTAssertFalse(report.depthIsPadded)
    }

    func testVerdictRules() {
        XCTAssertEqual(ResolutionScanner.verdict(sampleRate: 192_000, cutoff: 22_050), .upsampled(fromHz: 44_100))
        XCTAssertEqual(ResolutionScanner.verdict(sampleRate: 96_000, cutoff: 30_000), .limited(cutoffHz: 30_000))
        XCTAssertEqual(ResolutionScanner.verdict(sampleRate: 44_100, cutoff: 12_500), .lossySignature(cutoffHz: 12_500))
        XCTAssertEqual(ResolutionScanner.verdict(sampleRate: 44_100, cutoff: 8_000), .limited(cutoffHz: 8_000))
        XCTAssertEqual(ResolutionScanner.verdict(sampleRate: 44_100, cutoff: nil), .fullBand)
    }

    /// Left and right in opposite phase must not cancel into "silence".
    func testOutOfPhaseChannelsAreNotSilence() throws {
        let rate = 48_000.0, frames = Int(rate * 3)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let v = 0.2 * Float(sin(2 * .pi * 1000 * Double(i) / rate))
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = -v
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
        let report = try XCTUnwrap(ResolutionScanner.scan(url: url, claimedBits: 24))
        XCTAssertNotEqual(report.verdict, .silent)
        XCTAssertGreaterThan(report.windowsMeasured, 0)
    }
}
