import AVFoundation
import AudioToolbox
import os

/// A real-time effect Audio Unit: a cascade of biquad filters, a gain, and an exact bypass.
///
/// It replaces `AVAudioUnitEQ`, which cannot reproduce arbitrary correction curves (fixed filter
/// types and slopes, a limited gain range). Filters are the RBJ cookbook biquads of `EQBand`,
/// run in double precision. The render path takes no lock it could wait on: a new setting is
/// picked up with a try-lock, and an unavailable lock simply means "next buffer".
final class ParametricEQUnit: AUAudioUnit {
    static let maxSections = EQProfile.maxBands
    static let maxChannels = 8

    private static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x6964_4551 /* 'idEQ' */,
        componentManufacturer: 0x4964_6F70 /* 'Idop' */, componentFlags: 0, componentFlagsMask: 0)

    /// Registers the unit with the system once for this process.
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(ParametricEQUnit.self, as: description, name: "Idiophile One: Parametric EQ", version: 1)
    }()

    /// A node for AVAudioEngine and the unit behind it.
    static func make() -> (effect: AVAudioUnitEffect, unit: ParametricEQUnit) {
        _ = registration
        let effect = AVAudioUnitEffect(audioComponentDescription: description)
        return (effect, effect.auAudioUnit as! ParametricEQUnit)
    }

    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    // Settings written from the main thread, read by the render thread under a try-lock.
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>
    private var desiredProfile = EQProfile()
    private var desiredGain: Float = 1
    private var desiredBypass = true
    private var sampleRate = 48_000.0
    private var dirty = true

    // Render-thread copies.
    private let coefficients: UnsafeMutablePointer<Double>
    private let state: UnsafeMutablePointer<Double>
    private var sections = 0
    private var gain: Float = 1
    private var appliedGain: Float = 1   // gain reached at the end of the last buffer
    private var bypass = true

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        coefficients = .allocate(capacity: Self.maxSections * 5)
        coefficients.initialize(repeating: 0, count: Self.maxSections * 5)
        state = .allocate(capacity: Self.maxChannels * Self.maxSections * 2)
        state.initialize(repeating: 0, count: Self.maxChannels * Self.maxSections * 2)
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    deinit {
        lock.deallocate()
        coefficients.deallocate()
        state.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        os_unfair_lock_lock(lock)
        sampleRate = outputBus.format.sampleRate
        state.update(repeating: 0, count: Self.maxChannels * Self.maxSections * 2)
        dirty = true
        os_unfair_lock_unlock(lock)
    }

    override var shouldBypassEffect: Bool {
        get { desiredBypass }
        set { setBypass(newValue) }
    }

    // MARK: Settings (main thread)

    /// Sets the filters, the extra gain (dB: preamp, headroom, ReplayGain) and the bypass.
    /// With `bypass` the samples are copied untouched.
    func configure(profile: EQProfile, gainDB: Double, bypass: Bool) {
        os_unfair_lock_lock(lock)
        desiredProfile = profile
        desiredGain = Float(pow(10, gainDB / 20))
        desiredBypass = bypass
        dirty = true
        os_unfair_lock_unlock(lock)
    }

    private func setBypass(_ bypass: Bool) {
        os_unfair_lock_lock(lock)
        desiredBypass = bypass
        dirty = true
        os_unfair_lock_unlock(lock)
    }

    /// Whether the unit currently copies samples without touching them.
    var isBypassed: Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return desiredBypass
    }

    // MARK: Render (real-time thread)

    override var internalRenderBlock: AUInternalRenderBlock {
        { [unowned self] flags, timestamp, frames, bus, output, events, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            let status = pull(flags, timestamp, frames, 0, output)
            guard status == noErr else { return status }

            if os_unfair_lock_trylock(self.lock) {
                if self.dirty {
                    let list = self.desiredProfile.activeSections(sampleRate: self.sampleRate)
                    self.sections = min(list.count, Self.maxSections)
                    for (i, c) in list.prefix(Self.maxSections).enumerated() {
                        let p = self.coefficients + i * 5
                        p[0] = c.b0; p[1] = c.b1; p[2] = c.b2; p[3] = c.a1; p[4] = c.a2
                    }
                    self.gain = self.desiredGain
                    self.bypass = self.desiredBypass
                    self.dirty = false
                }
                os_unfair_lock_unlock(self.lock)
            }
            if self.bypass { self.appliedGain = 1; return noErr }
            let sections = self.sections, gain = self.gain
            if sections == 0 && gain == 1 && self.appliedGain == 1 { return noErr }
            // A gain change (preset switch, A/B level match) is ramped over the buffer: no click.
            let from = self.appliedGain
            let step = frames > 0 ? (gain - from) / Float(frames) : 0
            self.appliedGain = gain

            let buffers = UnsafeMutableAudioBufferListPointer(output)
            for (channel, buffer) in buffers.enumerated() where channel < Self.maxChannels {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let z = self.state + channel * Self.maxSections * 2
                for i in 0..<Int(frames) {
                    var x = Double(samples[i])
                    for s in 0..<sections {
                        let c = self.coefficients + s * 5
                        let y = c[0] * x + z[2 * s]
                        z[2 * s] = c[1] * x - c[3] * y + z[2 * s + 1]
                        z[2 * s + 1] = c[2] * x - c[4] * y
                        x = y
                    }
                    samples[i] = Float(x) * (from + step * Float(i))
                }
            }
            return noErr
        }
    }
}
