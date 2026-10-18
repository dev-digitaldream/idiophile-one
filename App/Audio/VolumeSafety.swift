import Foundation

/// Pure rules that keep the output level at or below what the user asked for.
enum VolumeSafety {
    /// Digital attenuation to add after the device volume so that device + trim never
    /// exceeds `target`. When the device level is unknown, all attenuation is digital.
    static func digitalTrim(target: Float, deviceActual: Float?) -> Float {
        guard target.isFinite else { return 0 }
        guard let actual = deviceActual else { return min(0, target) }
        return min(0, target - actual)
    }

    /// Knob position when taking over a device: never above the knob, the device's current
    /// level, or the limit. A muted knob stays muted.
    static func adoptedPosition(knob: Double, deviceDB: Float?, limit: Double) -> Double {
        guard knob > 0.001 else { return knob }
        var position = min(knob, limit)
        if let deviceDB { position = min(position, PlayerEngine.knobPosition(forDB: deviceDB)) }
        return position
    }

    /// A device the knob has never driven starts no louder than this (−30 dB), so plugging
    /// headphones into a new output can never surprise.
    static let newDeviceCeiling: Double = PlayerEngine.knobPosition(forDB: -30)

    /// Knob position when a device becomes the output. A device with a saved profile gets
    /// its own volume back; an unknown one starts quiet. Never above the device's current
    /// level or the limit; mute stays mute.
    static func startPosition(stored: Double?, current: Double, limit: Double, deviceDB: Float?) -> Double {
        let base = stored ?? min(current, newDeviceCeiling)
        return adoptedPosition(knob: base, deviceDB: deviceDB, limit: limit)
    }

    /// Largest increase one volume-key press can cause (a key step is ~1/16 of the range,
    /// about 3.5 dB on a 55 dB device). Anything bigger is not a key.
    static let maxKeyStepUpDB: Float = 4

    /// A notification that merely reports the level the app itself just set (or read back after
    /// setting): not a user action, and acting on it would undo the digital complement.
    static func isOwnWrite(actualDB: Float, expectedDB: Float?) -> Bool {
        guard let expectedDB else { return false }
        return abs(actualDB - expectedDB) < 0.3
    }

    /// Whether a device volume change should be followed. Decreases always are. An increase
    /// is followed only if it is key-sized: a USB DAC that re-enumerates resets its volume
    /// to a default, often loud, and that must be pushed back down, never adopted.
    static func shouldFollowDeviceChange(fromDB old: Float, toDB new: Float) -> Bool {
        new <= old + maxKeyStepUpDB
    }
}
