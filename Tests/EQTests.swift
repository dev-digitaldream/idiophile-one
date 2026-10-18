import AVFoundation
import XCTest
@testable import Idiophile_One

final class EQTests: XCTestCase {
    private func band(_ kind: EQBand.Kind, _ f: Double, gain: Double = 0, q: Double = 0.707) -> EQBand {
        EQBand(kind: kind, frequency: f, gainDB: gain, q: q)
    }

    // MARK: Filter maths (RBJ cookbook)

    func testPeakingFilterHitsItsGainAtTheCentre() {
        for fs in [44_100.0, 48_000, 96_000] {
            let c = band(.peak, 1000, gain: 6, q: 1).coefficients(sampleRate: fs)
            XCTAssertEqual(c.responseDB(at: 1000, sampleRate: fs), 6, accuracy: 0.01, "fs \(fs)")
            XCTAssertEqual(c.responseDB(at: 40, sampleRate: fs), 0, accuracy: 0.1)
            XCTAssertEqual(c.responseDB(at: 16_000, sampleRate: fs), 0, accuracy: 0.6)
        }
    }

    func testPeakingBandwidthFollowsQ() {
        // Half the gain (−3 dB below a +6 dB peak) lies at fc·(√(1+1/4Q²) ± 1/2Q) for the bandwidth edge.
        let q = 2.0, fs = 48_000.0
        let c = band(.peak, 1000, gain: 6, q: q).coefficients(sampleRate: fs)
        let wide = band(.peak, 1000, gain: 6, q: 0.5).coefficients(sampleRate: fs)
        XCTAssertGreaterThan(wide.responseDB(at: 2000, sampleRate: fs), c.responseDB(at: 2000, sampleRate: fs) + 1)
    }

    func testShelvesReachTheirGainAtTheExtremes() {
        let fs = 48_000.0
        let low = band(.lowShelf, 100, gain: 6).coefficients(sampleRate: fs)
        XCTAssertEqual(low.responseDB(at: 20, sampleRate: fs), 6, accuracy: 0.3)
        XCTAssertEqual(low.responseDB(at: 100, sampleRate: fs), 3, accuracy: 0.1)      // half the gain at fc
        XCTAssertEqual(low.responseDB(at: 5000, sampleRate: fs), 0, accuracy: 0.2)
        let high = band(.highShelf, 8000, gain: -5).coefficients(sampleRate: fs)
        XCTAssertEqual(high.responseDB(at: 18_000, sampleRate: fs), -5, accuracy: 0.6)
        XCTAssertEqual(high.responseDB(at: 8000, sampleRate: fs), -2.5, accuracy: 0.1)
        XCTAssertEqual(high.responseDB(at: 200, sampleRate: fs), 0, accuracy: 0.1)
    }

    func testPassFiltersAreThreeDBDownAtCutoff() {
        let fs = 48_000.0
        XCTAssertEqual(band(.highPass, 100).coefficients(sampleRate: fs).responseDB(at: 100, sampleRate: fs), -3.01, accuracy: 0.05)
        XCTAssertEqual(band(.lowPass, 1000).coefficients(sampleRate: fs).responseDB(at: 1000, sampleRate: fs), -3.01, accuracy: 0.05)
        XCTAssertLessThan(band(.highPass, 100).coefficients(sampleRate: fs).responseDB(at: 20, sampleRate: fs), -20)
        XCTAssertEqual(band(.highPass, 100).coefficients(sampleRate: fs).responseDB(at: 5000, sampleRate: fs), 0, accuracy: 0.05)
    }

    func testNotchRemovesItsFrequency() {
        let c = band(.notch, 1000, q: 5).coefficients(sampleRate: 48_000)
        XCTAssertLessThan(c.responseDB(at: 1000, sampleRate: 48_000), -60)
        XCTAssertEqual(c.responseDB(at: 4000, sampleRate: 48_000), 0, accuracy: 0.2)
    }

    // MARK: Profiles

    func testHeadroomKeepsTheLoudestPointAtOrBelowZero() {
        var profile = EQProfile(bands: [band(.peak, 1000, gain: 6, q: 1)])
        XCTAssertEqual(profile.headroomDB(), -6, accuracy: 0.25)
        profile.preampDB = -6   // an AutoEq-style preamp already makes room
        XCTAssertEqual(profile.headroomDB(), 0, accuracy: 0.25)
        profile.preampDB = -10
        XCTAssertEqual(profile.headroomDB(), 0, accuracy: 1e-9)
        XCTAssertEqual(EQProfile().headroomDB(), 0)
    }

    func testFlatnessIgnoresNeutralBandsButNotPassFilters() {
        XCTAssertTrue(EQProfile(bands: [band(.peak, 1000, gain: 0), band(.lowShelf, 90, gain: 0.001)]).isFlat)
        XCTAssertFalse(EQProfile(bands: [band(.peak, 1000, gain: 1)]).isFlat)
        XCTAssertFalse(EQProfile(bands: [band(.highPass, 20)]).isFlat)
        XCTAssertFalse(EQProfile(preampDB: -3).isFlat)
        var off = band(.peak, 1000, gain: 6); off.enabled = false
        XCTAssertTrue(EQProfile(bands: [off]).isFlat)
    }

    func testParsesAnAutoEqFile() throws {
        let text = """
            Preamp: -6.2 dB
            Filter 1: ON PK Fc 31 Hz Gain 2.5 dB Q 1.41
            Filter 2: ON LSC Fc 105 Hz Gain 4.3 dB Q 0.70
            Filter 3: ON HSC Fc 10000 Hz Gain -3.1 dB Q 0.70
            Filter 4: OFF PK Fc 3000 Hz Gain 5.0 dB Q 2.00
            Filter 5: ON HP Fc 20 Hz Q 0.71
            Filter 6: ON PK Fc 2500 Hz Gain 3 dB BW Oct 1.0
            Not a filter line
            """
        let profile = try XCTUnwrap(EQProfile.parse(text, name: "Test"))
        XCTAssertEqual(profile.preampDB, -6.2)
        XCTAssertEqual(profile.bands.count, 6)
        XCTAssertEqual(profile.bands[0].kind, .peak)
        XCTAssertEqual(profile.bands[1].kind, .lowShelf)
        XCTAssertEqual(profile.bands[1].gainDB, 4.3)
        XCTAssertEqual(profile.bands[2].frequency, 10_000)
        XCTAssertFalse(profile.bands[3].enabled)
        XCTAssertEqual(profile.bands[4].kind, .highPass)
        XCTAssertEqual(profile.bands[5].q, 1.414, accuracy: 0.01)   // one octave wide
        XCTAssertNil(EQProfile.parse("nothing useful here", name: "x"))
    }

    func testTextRoundTrip() throws {
        let original = EQProfile(name: "Round trip", preampDB: -4.5, bands: [
            band(.peak, 62, gain: 3.2, q: 1.1), band(.highShelf, 9000, gain: -2.4, q: 0.7), band(.highPass, 25, q: 0.71)])
        let parsed = try XCTUnwrap(EQProfile.parse(original.text, name: original.name))
        XCTAssertEqual(parsed.preampDB, -4.5)
        XCTAssertEqual(parsed.bands.map(\.kind), original.bands.map(\.kind))
        for (a, b) in zip(parsed.bands, original.bands) {
            XCTAssertEqual(a.frequency, b.frequency, accuracy: 0.01)
            XCTAssertEqual(a.gainDB, b.gainDB, accuracy: 0.06)
            XCTAssertEqual(a.q, b.q, accuracy: 0.006)
        }
    }

    func testSetupChoosesBetweenFadersAndProfile() {
        var setup = EQSetup()
        setup.graphic[5] = 4
        let custom = EQProfile(name: "Custom", bands: [band(.peak, 100, gain: 2)])
        setup.parametric = custom
        XCTAssertEqual(setup.profile.name, "Graphic")        // the faders are in use
        setup.useParametric = true
        XCTAssertEqual(setup.profile, custom)
    }

    // MARK: Through the engine

    private func sine(_ hz: Double, rate: Double = 48_000, seconds: Double = 2, amplitude: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = Int(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<2 { for i in 0..<frames { buffer.floatChannelData![c][i] = amplitude * Float(sin(2 * .pi * hz * Double(i) / rate)) } }
        return buffer
    }

    private func levelDB(of buffer: AVAudioPCMBuffer, from: Double = 0.5) -> Double {
        let data = buffer.floatChannelData![0]
        let start = Int(Double(buffer.frameLength) * from)
        var sum = 0.0
        for i in start..<Int(buffer.frameLength) { sum += Double(data[i]) * Double(data[i]) }
        return 10 * log10(sum / Double(Int(buffer.frameLength) - start))
    }

    private func gainThroughEngine(_ profile: EQProfile, at hz: Double, rate: Double = 48_000) throws -> Double {
        let input = sine(hz, rate: rate)
        let path = SignalPath(eq: profile, bandsActive: true, replayGainDB: nil, digitalGainDB: 0)
        let output = try BitPerfectVerifier.render(input, path: path)
        return levelDB(of: output) - levelDB(of: input)
    }

    func testTheRealTimeUnitMatchesTheMaths() throws {
        // Preamp −10 dB leaves no headroom adjustment; a +6 dB peak at 1 kHz nets −4 dB there.
        let profile = EQProfile(preampDB: -10, bands: [band(.peak, 1000, gain: 6, q: 1)])
        XCTAssertEqual(try gainThroughEngine(profile, at: 1000), -4, accuracy: 0.1)
        XCTAssertEqual(try gainThroughEngine(profile, at: 100), -10, accuracy: 0.2)
        XCTAssertEqual(try gainThroughEngine(profile, at: 1000, rate: 96_000), -4, accuracy: 0.1)
    }

    func testHeadroomIsAppliedInTheEngine() throws {
        // +6 dB peak, no preamp: the app adds −6 dB so the loudest point is 0 dB, never clipping.
        let profile = EQProfile(bands: [band(.peak, 1000, gain: 6, q: 1)])
        XCTAssertEqual(try gainThroughEngine(profile, at: 1000), 0, accuracy: 0.25)
        XCTAssertEqual(try gainThroughEngine(profile, at: 100), -6, accuracy: 0.3)
    }

    func testFlatEqualizerInThePathIsBitExact() throws {
        let source = sine(997, seconds: 1, amplitude: 0.7)
        let path = SignalPath(eq: .graphic(gains: Array(repeating: 0, count: 10)), bandsActive: true,
                              replayGainDB: nil, digitalGainDB: 0)
        XCTAssertTrue(path.isTransparent)
        let output = try BitPerfectVerifier.render(source, path: path)
        for ch in 0..<2 {
            for i in 0..<Int(source.frameLength) where output.floatChannelData![ch][i] != source.floatChannelData![ch][i] {
                return XCTFail("sample \(i) differs")
            }
        }
    }

    func testGraphicFadersMatchTheirOctaveBands() throws {
        var gains = [Float](repeating: 0, count: 10)
        gains[5] = 6    // 1 kHz
        let profile = EQProfile.graphic(gains: gains)
        // The graphic path uses the same unit: net gain at 1 kHz = +6 − 6 headroom = 0, 100 Hz ≈ −6.
        XCTAssertEqual(try gainThroughEngine(profile, at: 1000), 0, accuracy: 0.3)
        XCTAssertLessThan(try gainThroughEngine(profile, at: 100), -4.5)
    }

    func testBuiltInPresetsLoad() {
        XCTAssertEqual(EQPresetStore.builtIn.count, 2)
        XCTAssertEqual(EQPresetStore.builtIn[0].bands.count, 10)
        XCTAssertEqual(EQPresetStore.builtIn[0].preampDB, -6.1, accuracy: 0.001)
    }

    func testLevelMatchNeverBoostsAndLevelsLouderProfile() {
        let quiet = EQProfile(name: "q", preampDB: -6, bands: [])
        let loud = EQProfile(name: "l", preampDB: 0, bands: [band(.peak, 1000, gain: 3, q: 0.5)])
        XCTAssertEqual(quiet.levelDB(), -6, accuracy: 0.01)
        XCTAssertGreaterThan(loud.levelDB(), quiet.levelDB() - 1)
        let path = SignalPath(eq: loud, bandsActive: true, replayGainDB: nil, digitalGainDB: 0, levelMatchDB: -4)
        XCTAssertEqual(path.eqGainDB + path.levelMatchDB, loud.preampDB + loud.headroomDB() - 4, accuracy: 0.001)
        XCTAssertFalse(path.isTransparent)
    }
}
