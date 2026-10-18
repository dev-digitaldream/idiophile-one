import AVFoundation

/// Processing settings between the decoder and Core Audio, shared by the player and by the
/// bit-perfect verifier so both configure exactly the same units.
struct SignalPath: Equatable {
    /// The equalizer filters (a graphic setting is ten peaking filters).
    var eq: EQProfile
    /// EQ filters in the path (not bypassed, not DIRECT).
    var bandsActive: Bool
    var replayGainDB: Float?
    /// Total digital volume in dB (trim + mute), −∞ for silence.
    var digitalGainDB: Float
    /// Absolute polarity inverted (every sample negated; the mixer accepts a negative gain).
    var invertPolarity = false
    /// Attenuation (≤ 0 dB) that levels the profile being auditioned with the others, so the
    /// comparison is not decided by loudness. Zero outside the A/B comparison.
    var levelMatchDB = 0.0

    /// The EQ changes the signal: it is in the path and its filters or preamp do something.
    var eqAltersSignal: Bool { bandsActive && !eq.isFlat }

    /// Preamp plus the headroom that keeps the loudest point of the response from clipping.
    var eqGainDB: Double { eqAltersSignal ? eq.preampDB + eq.headroomDB() : 0 }

    /// True when no unit can change a sample.
    var isTransparent: Bool { !eqAltersSignal && replayGainDB == nil && digitalGainDB == 0 && !invertPolarity && levelMatchDB == 0 }

    /// The EQ unit also carries ReplayGain as its gain; it is bypassed (samples copied
    /// untouched) when neither is in use.
    func configure(_ unit: ParametricEQUnit) {
        let gain = eqGainDB + Double(replayGainDB ?? 0) + levelMatchDB
        unit.configure(profile: eqAltersSignal ? eq : EQProfile(),
                       gainDB: min(max(gain, -96), 24),
                       bypass: !eqAltersSignal && replayGainDB == nil && levelMatchDB == 0)
    }

    /// Linear output gain of the main mixer: negative when the polarity is inverted.
    var mixerVolume: Float {
        let magnitude: Float = digitalGainDB.isFinite ? min(1, pow(10, digitalGainDB / 20)) : 0
        return invertPolarity ? -magnitude : magnitude
    }
}
