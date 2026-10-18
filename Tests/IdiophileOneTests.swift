import XCTest
@testable import Idiophile_One

final class VolumeSafetyTests: XCTestCase {
    func testTrimNeverRaisesLevel() {
        for target in stride(from: Float(-60), through: 0, by: 5) {
            for actual in stride(from: Float(-80), through: 0, by: 2.5) {
                let trim = VolumeSafety.digitalTrim(target: target, deviceActual: actual)
                XCTAssertLessThanOrEqual(trim, 0)
                // Heard level = device + trim must never exceed the request (devices are ≤ 0 dB here).
                if actual <= 0 { XCTAssertLessThanOrEqual(actual + trim, target + 0.0001, "device \(actual) target \(target)") }
            }
        }
    }

    func testDeviceThatCannotGoLowEnoughGetsDigitalComplement() {
        // FiiO E10 stops at −55 dB; knob asks −60 dB.
        XCTAssertEqual(VolumeSafety.digitalTrim(target: -60, deviceActual: -55), -5)
    }

    func testFailedWriteLeavesDeviceLoudButTrimCompensates() {
        // Device stuck at 0 dB while −20 dB was requested.
        XCTAssertEqual(VolumeSafety.digitalTrim(target: -20, deviceActual: 0), -20)
    }

    func testUnknownDeviceStateAttenuatesInSoftware() {
        XCTAssertEqual(VolumeSafety.digitalTrim(target: -18, deviceActual: nil), -18)
    }

    func testAdoptionNeverLouder() {
        let knob = PlayerEngine.knobPosition(forDB: -15)
        // Newly plugged DAC at full output: keep −15 dB.
        XCTAssertEqual(VolumeSafety.adoptedPosition(knob: knob, deviceDB: 0, limit: 1), knob, accuracy: 1e-9)
        // DAC already quieter than the knob: follow the DAC.
        XCTAssertEqual(VolumeSafety.adoptedPosition(knob: knob, deviceDB: -30, limit: 1),
                       PlayerEngine.knobPosition(forDB: -30), accuracy: 1e-9)
        // Limit wins.
        let limit = PlayerEngine.knobPosition(forDB: -20)
        XCTAssertEqual(VolumeSafety.adoptedPosition(knob: knob, deviceDB: 0, limit: limit), limit, accuracy: 1e-9)
        // Muted stays muted.
        XCTAssertEqual(VolumeSafety.adoptedPosition(knob: 0, deviceDB: 0, limit: 1), 0)
    }

    func testOwnWriteEchoIsNotAVolumeKey() {
        // Asked −58 dB; the DAC stops at −55 dB and the app adds −3 dB digitally. The DAC's
        // notification reports −55 dB: that is our own doing.
        let trim = VolumeSafety.digitalTrim(target: -58, deviceActual: -55)
        XCTAssertEqual(trim, -3)
        XCTAssertTrue(VolumeSafety.isOwnWrite(actualDB: -55, expectedDB: -55))
        XCTAssertTrue(VolumeSafety.isOwnWrite(actualDB: -54.9, expectedDB: -55))
        // A real key press moves the level away from what we set.
        XCTAssertFalse(VolumeSafety.isOwnWrite(actualDB: -51.5, expectedDB: -55))
        XCTAssertFalse(VolumeSafety.isOwnWrite(actualDB: -50, expectedDB: nil))
        // Keys are judged from the device's own level, not from the knob's request.
        XCTAssertTrue(VolumeSafety.shouldFollowDeviceChange(fromDB: -55, toDB: -51.5))
        XCTAssertFalse(VolumeSafety.shouldFollowDeviceChange(fromDB: -55, toDB: -20))
    }

    func testDeviceResetIsNotAVolumeKey() {
        // Volume keys: steps of about 3.4 dB are followed, in both directions.
        XCTAssertTrue(VolumeSafety.shouldFollowDeviceChange(fromDB: -30, toDB: -26.6))
        XCTAssertTrue(VolumeSafety.shouldFollowDeviceChange(fromDB: -30, toDB: -45))
        // A USB re-enumeration resetting to a loud default is refused.
        XCTAssertFalse(VolumeSafety.shouldFollowDeviceChange(fromDB: -50, toDB: -14.2))
        XCTAssertFalse(VolumeSafety.shouldFollowDeviceChange(fromDB: -50, toDB: 0))
    }

    func testNewDeviceStartsQuiet() {
        // Knob at −3 dB from the speakers; a new pair of headphones must not get −3 dB.
        let loud = PlayerEngine.knobPosition(forDB: -3)
        let start = VolumeSafety.startPosition(stored: nil, current: loud, limit: 1, deviceDB: 0)
        XCTAssertEqual(PlayerEngine.knobGainDB(start), -30, accuracy: 0.01)
        // Already quieter than the ceiling: unchanged.
        let quiet = PlayerEngine.knobPosition(forDB: -42)
        XCTAssertEqual(VolumeSafety.startPosition(stored: nil, current: quiet, limit: 1, deviceDB: nil), quiet, accuracy: 1e-9)
    }

    func testKnownDeviceRecoversItsVolumeButNeverAboveItsCurrentLevel() {
        let saved = PlayerEngine.knobPosition(forDB: -20)
        XCTAssertEqual(VolumeSafety.startPosition(stored: saved, current: 1, limit: 1, deviceDB: nil), saved, accuracy: 1e-9)
        // The DAC was left at −35 dB by someone else: stay there.
        let deviceLevel = PlayerEngine.knobPosition(forDB: -35)
        XCTAssertEqual(VolumeSafety.startPosition(stored: saved, current: 1, limit: 1, deviceDB: -35), deviceLevel, accuracy: 1e-9)
        // Per-device limit wins over the saved volume.
        let limit = PlayerEngine.knobPosition(forDB: -25)
        XCTAssertEqual(VolumeSafety.startPosition(stored: saved, current: 1, limit: limit, deviceDB: nil), limit, accuracy: 1e-9)
        // A muted device stays muted.
        XCTAssertEqual(VolumeSafety.startPosition(stored: 0, current: 1, limit: 1, deviceDB: 0), 0)
    }

    func testKnobLawRoundTrip() {
        // The bottom of the travel is mute by design; check the audible range.
        for db in stride(from: Float(-59.5), through: 0, by: 0.5) {
            XCTAssertEqual(PlayerEngine.knobGainDB(PlayerEngine.knobPosition(forDB: db)), db, accuracy: 1e-4)
        }
        XCTAssertEqual(PlayerEngine.knobGainDB(0), -.infinity)
    }
}

final class ReplayGainTests: XCTestCase {
    func testPeakLimitsGain() {
        let tags = ReplayGainTags(trackGain: 6, albumGain: 2, trackPeak: 0.8, albumPeak: 0.95)
        // +6 dB on a 0.8 peak would clip: limited to −20·log10(0.8) ≈ +1.94 dB.
        XCTAssertEqual(ReplayGainMode.track.gain(for: tags)!, 1.938, accuracy: 0.01)
        XCTAssertEqual(ReplayGainMode.album.gain(for: tags)!, 0.446, accuracy: 0.01)
        XCTAssertNil(ReplayGainMode.off.gain(for: tags))
    }

    func testFallsBackBetweenTrackAndAlbum() {
        XCTAssertEqual(ReplayGainMode.album.gain(for: ReplayGainTags(trackGain: -7))!, -7)
        XCTAssertNil(ReplayGainMode.track.gain(for: ReplayGainTags()))
    }
}

final class MeterTests: XCTestCase {
    func testVUBallisticsMatchIEC() {
        var needle = NeedleBallistics(position: 0, velocity: 0)
        var t = 0.0, rise: Double?, peak = 0.0
        while t < 1.5 {
            needle.step(toward: 1, dt: 0.001)
            t += 0.001
            if rise == nil, needle.position >= 0.99 { rise = t }
            peak = max(peak, needle.position)
        }
        XCTAssertEqual(rise!, 0.3, accuracy: 0.015, "99 % in 300 ms")
        XCTAssertEqual(peak - 1, 0.013, accuracy: 0.004, "1–1.5 % overshoot")
    }

    func testSpectrumAtLowSampleRateDoesNotCrash() {
        let analyzer = SpectrumAnalyzer()
        var samples = [Float](repeating: 0, count: 8192)
        for i in samples.indices { samples[i] = sin(Float(i) * 0.3) * 0.5 }
        let bands = samples.withUnsafeBufferPointer { buf in
            analyzer.bands(left: buf.baseAddress!, right: buf.baseAddress!, frames: buf.count, sampleRate: 8000)
        }
        XCTAssertEqual(bands?.count, Equalizer.frequencies.count)
        XCTAssertEqual(bands?.last, -120, "16 kHz band is above Nyquist at 8 kHz")
    }

    func testFullScaleSineReadsZeroDBFS() {
        let analyzer = SpectrumAnalyzer()
        let rate = 48000.0
        var samples = [Float](repeating: 0, count: 8192)
        for i in samples.indices { samples[i] = sin(2 * .pi * 1000 * Float(i) / Float(rate)) }
        let bands = samples.withUnsafeBufferPointer { buf in
            analyzer.bands(left: buf.baseAddress!, right: buf.baseAddress!, frames: buf.count, sampleRate: rate)
        }!
        XCTAssertEqual(bands[5], 0, accuracy: 0.5, "1 kHz band")
        XCTAssertLessThan(bands[0], -40, "31 Hz band far from the tone")
    }
}
