import AVFoundation
import XCTest
@testable import Idiophile_One

/// Reference signals from EBU TECH 3341 / ITU-R BS.1770.
final class LoudnessTests: XCTestCase {
    private func measure(rate: Double, seconds: Double, channels: Int = 2,
                         _ sample: (Int, Double) -> Float) -> LoudnessMeter {
        let meter = LoudnessMeter(sampleRate: rate, channels: channels)
        let frames = Int(rate * seconds)
        var planes = (0..<channels).map { c in (0..<frames).map { sample(c, Double($0) / rate) } }
        let pointers = planes.indices.map { i in planes[i].withUnsafeMutableBufferPointer { UnsafePointer($0.baseAddress!) } }
        // Feed in odd-sized chunks to exercise the hop bookkeeping.
        var start = 0
        while start < frames {
            let n = min(7_919, frames - start)
            meter.process(pointers.map { $0 + start }, frames: n)
            start += n
        }
        withExtendedLifetime(planes) {}
        return meter
    }

    /// A 997 Hz stereo sine at −20 dBFS peak reads −20.0 LUFS.
    func testSineAtMinus20dBFS() {
        for rate in [44100.0, 48000, 96000] {
            let amp = Float(pow(10, -20.0 / 20))
            let m = measure(rate: rate, seconds: 10) { _, t in amp * Float(sin(2 * .pi * 997 * t)) }
            XCTAssertEqual(m.integratedLUFS ?? -99, -20.0, accuracy: 0.1, "rate \(rate)")
        }
    }

    /// Loudness scales 1 LU per dB.
    func testLevelChangeIsLinear() {
        let quiet = measure(rate: 48000, seconds: 8) { _, t in 0.05 * Float(sin(2 * .pi * 997 * t)) }
        let loud = measure(rate: 48000, seconds: 8) { _, t in 0.5 * Float(sin(2 * .pi * 997 * t)) }
        XCTAssertEqual((loud.integratedLUFS ?? 0) - (quiet.integratedLUFS ?? 0), 20, accuracy: 0.05)
    }

    /// Silence is below the absolute gate: no measurement rather than −∞.
    func testSilenceHasNoLoudness() {
        XCTAssertNil(measure(rate: 44100, seconds: 5) { _, _ in 0 }.integratedLUFS)
    }

    /// Gating: a loud passage followed by a long very quiet one measures the loud part.
    func testRelativeGateIgnoresQuietPassage() {
        let loudOnly = measure(rate: 48000, seconds: 6) { _, t in 0.3 * Float(sin(2 * .pi * 997 * t)) }
        let withQuiet = measure(rate: 48000, seconds: 20) { _, t in
            (t < 6 ? 0.3 : 0.003) * Float(sin(2 * .pi * 997 * t))
        }
        // The 400 ms blocks straddling the change are loud enough to pass the gate, as the
        // standard intends, which pulls the figure down by about 0.1 LU; the 14 s of quiet
        // passage (−40 dB) are ignored (without gating it would read near −29 LUFS).
        XCTAssertEqual(withQuiet.integratedLUFS ?? -99, loudOnly.integratedLUFS ?? 0, accuracy: 0.25)
    }

    /// The K-weighting rolls off deep bass: 30 Hz reads well below 997 Hz at equal level.
    func testKWeightingAttenuatesBass() {
        let mid = measure(rate: 48000, seconds: 8) { _, t in 0.3 * Float(sin(2 * .pi * 997 * t)) }
        let bass = measure(rate: 48000, seconds: 8) { _, t in 0.3 * Float(sin(2 * .pi * 30 * t)) }
        XCTAssertLessThan((bass.integratedLUFS ?? 0) - (mid.integratedLUFS ?? 0), -1.5)
    }

    func testAlbumFigureUsesAllBlocks() {
        let loud = measure(rate: 48000, seconds: 6) { _, t in 0.4 * Float(sin(2 * .pi * 997 * t)) }
        let soft = measure(rate: 48000, seconds: 6) { _, t in 0.1 * Float(sin(2 * .pi * 997 * t)) }
        let album = LoudnessMeter.integratedLUFS(blocks: loud.blocks + soft.blocks) ?? 0
        let l = loud.integratedLUFS ?? 0, s = soft.integratedLUFS ?? 0
        // Equal-length tracks 12 dB apart: the energy mean sits about 3 dB under the loud one.
        XCTAssertGreaterThan(album, s)
        XCTAssertLessThan(album, l)
        XCTAssertEqual(album, l - 3.0, accuracy: 0.7)
    }

    func testReplayGainReference() {
        XCTAssertEqual(LoudnessAnalyzer.gain(forLUFS: -9), -9, accuracy: 1e-6)
        XCTAssertEqual(LoudnessAnalyzer.gain(forLUFS: -23), 5, accuracy: 1e-6)
    }
}
