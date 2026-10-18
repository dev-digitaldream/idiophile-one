import Foundation

/// Moving-coil needle modelled as a damped mass-spring system.
///
/// ζ = 0.81 and ωn = 13.4 rad/s give a 99 % rise in 300 ms and 1.3 % overshoot,
/// matching the IEC 60268-17 VU meter ballistics.
struct NeedleBallistics {
    static let damping = 0.81
    static let naturalFrequency = 13.4
    /// Mechanical stops, in scale units (1.0 = +3 VU, full scale).
    static let restStop = -0.025
    static let pinStop = 1.07

    var position: Double = restStop
    var velocity: Double = 0

    mutating func step(toward target: Double, dt: Double,
                       naturalFrequency w: Double = Self.naturalFrequency, damping z: Double = Self.damping) {
        // Fixed 1 ms sub-steps keep the integration stable at any frame rate.
        var remaining = min(dt, 0.1)
        while remaining > 0 {
            let h = min(remaining, 0.001)
            let accel = w * w * (target - position) - 2 * z * w * velocity
            velocity += accel * h
            position += velocity * h
            if position > Self.pinStop {
                position = Self.pinStop
                velocity = -velocity * 0.15
            } else if position < Self.restStop {
                position = Self.restStop
                velocity = -velocity * 0.15
            }
            remaining -= h
        }
    }
}

/// VU scale mapping. Needle deflection is linear in voltage; +3 VU is full scale.
enum VUScale {
    /// Digital level that reads 0 VU. −14 dBFS keeps modern masters off the pin.
    static let referenceDBFS: Float = -14
    static let fullScale = pow(10.0, 3.0 / 20.0)

    static func position(forDB db: Double) -> Double {
        pow(10, db / 20) / fullScale
    }

    static func position(forLinear level: Float) -> Double {
        let ref = pow(10, referenceDBFS / 20)
        return Double(level / ref) / fullScale
    }

    /// PEAK mode: sample peaks with 0 dBFS at full scale (+3).
    static let peakReferenceDBFS: Float = -3

    static func position(forPeak level: Float) -> Double {
        let ref = pow(10, peakReferenceDBFS / 20)
        return Double(level / ref) / fullScale
    }
}

/// Meter movement: classic VU (300 ms integration) or fast PEAK with slow fall-back.
enum MeterMode: String, CaseIterable {
    case vu, peak

    var label: String { self == .vu ? "VU" : "PEAK" }
}
