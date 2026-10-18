import CoreAudio
import Foundation

/// Thin CoreAudio HAL wrapper for the output device: sample rate, hardware volume, hog mode.
struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    /// Persistent identifier. Read once when the device is listed: a device that has just
    /// been unplugged can no longer be asked, and the lock must still know which one it lost.
    let uid: String?

    init(id: AudioDeviceID, name: String) {
        self.id = id
        self.name = name
        self.uid = Self.readUID(of: id)
    }

    private static func readUID(of id: AudioDeviceID) -> String? {
        var address = Self.address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: Discovery

    static func all() -> [OutputDevice] {
        let ids: [AudioDeviceID] = systemArray(kAudioHardwarePropertyDevices)
        return ids.filter { outputChannels($0) > 0 }.map { OutputDevice(id: $0, name: name(of: $0)) }
    }

    static func systemDefault() -> OutputDevice? {
        let ids: [AudioDeviceID] = systemArray(kAudioHardwarePropertyDefaultOutputDevice)
        return ids.first.map { OutputDevice(id: $0, name: name(of: $0)) }
    }

    // MARK: Sample rate

    var nominalSampleRate: Double {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate
    }

    var supportedSampleRates: [AudioValueRange] {
        var address = Self.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges)
        return ranges
    }

    func supports(_ rate: Double) -> Bool {
        supportedSampleRates.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
    }

    /// Best device rate for a source: the exact rate if supported, otherwise the highest
    /// supported integer multiple, otherwise the highest supported rate.
    func preferredRate(for source: Double) -> Double {
        if supports(source) { return source }
        let multiples = (2...8).map { source * Double($0) }.filter(supports)
        if let best = multiples.max() { return best }
        return supportedSampleRates.map(\.mMaximum).max() ?? nominalSampleRate
    }

    /// Switches the hardware clock and waits for the device to report the new rate.
    @discardableResult
    func setNominalSampleRate(_ rate: Double) -> Bool {
        if nominalSampleRate == rate { return true }
        var value = Float64(rate)
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
        else { return false }
        for _ in 0..<100 where nominalSampleRate != rate { usleep(10_000) }
        return nominalSampleRate == rate
    }

    // MARK: Stream format

    /// Selects the integer PCM physical format with the most bits at `rate`, so the source
    /// reaches the converter without truncation. Returns the bit depth in use.
    @discardableResult
    func setBestPhysicalFormat(rate: Double) -> Int? {
        guard let stream = outputStreams.first else { return nil }
        var address = Self.address(kAudioStreamPropertyAvailablePhysicalFormats)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(stream, &address, 0, nil, &size) == noErr else { return nil }
        var formats = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(),
                                                     count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &formats)

        // A format either names one rate or covers a range (mSampleRate == 0).
        let candidates = formats.filter {
            let f = $0.mFormat
            let rateMatches = f.mSampleRate == rate
                || (f.mSampleRate == 0 && rate >= $0.mSampleRateRange.mMinimum && rate <= $0.mSampleRateRange.mMaximum)
            return f.mFormatID == kAudioFormatLinearPCM && rateMatches && f.mFormatFlags & kAudioFormatFlagIsFloat == 0
        }.map { ranged -> AudioStreamBasicDescription in
            var f = ranged.mFormat
            f.mSampleRate = rate
            return f
        }
        guard var best = candidates.max(by: { $0.mBitsPerChannel < $1.mBitsPerChannel }) else { return physicalBits }
        if physicalBits != Int(best.mBitsPerChannel) {
            var current = Self.address(kAudioStreamPropertyPhysicalFormat)
            AudioObjectSetPropertyData(stream, &current, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &best)
        }
        return physicalBits
    }

    var physicalBits: Int? {
        guard let stream = outputStreams.first else { return nil }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.address(kAudioStreamPropertyPhysicalFormat)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr else { return nil }
        return Int(format.mBitsPerChannel)
    }

    private var outputStreams: [AudioStreamID] {
        var address = Self.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids)
        return ids
    }

    // MARK: Hardware volume

    /// Elements carrying a settable output volume: the main element, else channels 1 and 2.
    var volumeElements: [AudioObjectPropertyElement] {
        let main = kAudioObjectPropertyElementMain
        if isVolumeSettable(main) { return [main] }
        return [1, 2].filter(isVolumeSettable)
    }

    /// Hardware volume usable for DIRECT: settable and calibrated in dB.
    var hasHardwareVolume: Bool { volumeElements.first.map(hasDecibels) ?? false }

    /// Device attenuation in dB (0 = full output).
    var hardwareVolumeDB: Float {
        guard let element = volumeElements.first else { return 0 }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioDevicePropertyVolumeDecibels, scope: kAudioDevicePropertyScopeOutput, element: element)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    var hardwareVolumeRangeDB: ClosedRange<Float> {
        guard let element = volumeElements.first else { return 0...0 }
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var address = Self.address(kAudioDevicePropertyVolumeRangeDecibels, scope: kAudioDevicePropertyScopeOutput, element: element)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &range)
        return Float(range.mMinimum)...Float(max(range.mMinimum, range.mMaximum))
    }

    /// Sets the attenuation on every volume element. Returns false if any write failed;
    /// callers must read `hardwareVolumeDB` back rather than trust the requested value.
    @discardableResult
    func setHardwareVolumeDB(_ db: Float) -> Bool {
        let range = hardwareVolumeRangeDB
        var value = Float32(min(max(db, range.lowerBound), range.upperBound))
        var ok = true
        for element in volumeElements {
            var address = Self.address(kAudioDevicePropertyVolumeDecibels, scope: kAudioDevicePropertyScopeOutput, element: element)
            ok = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr && ok
        }
        return ok
    }

    /// Loudest of the volume elements, so a partial failure is never under-estimated.
    var loudestHardwareVolumeDB: Float? {
        let values: [Float] = volumeElements.compactMap { element in
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            var address = Self.address(kAudioDevicePropertyVolumeDecibels, scope: kAudioDevicePropertyScopeOutput, element: element)
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        return values.count == volumeElements.count ? values.max() : nil
    }

    private func hasDecibels(_ element: AudioObjectPropertyElement) -> Bool {
        var address = Self.address(kAudioDevicePropertyVolumeDecibels, scope: kAudioDevicePropertyScopeOutput, element: element)
        return AudioObjectHasProperty(id, &address)
    }

    private func isVolumeSettable(_ element: AudioObjectPropertyElement) -> Bool {
        var address = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    // MARK: Exclusive access

    /// Takes (or releases) hog mode so no other app or system sound can mix into the stream.
    @discardableResult
    func setExclusive(_ exclusive: Bool) -> Bool {
        var owner: pid_t = exclusive ? getpid() : -1
        let current = hogOwner
        if exclusive ? current == getpid() : current != getpid() { return true }
        var address = Self.address(kAudioDevicePropertyHogMode)
        // Setting hog mode toggles it: the value written back is the new owner.
        guard AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<pid_t>.size), &owner) == noErr
        else { return false }
        return exclusive ? hogOwner == getpid() : hogOwner != getpid()
    }

    var isExclusive: Bool { hogOwner == getpid() }

    private var hogOwner: pid_t {
        var owner: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = Self.address(kAudioDevicePropertyHogMode)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &owner)
        return owner
    }

    // MARK: Helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func systemArray(_ selector: AudioObjectPropertySelector) -> [AudioDeviceID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids
    }

    private static func name(of id: AudioDeviceID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return "Output \(id)" }
        return name.takeRetainedValue() as String
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Calls back on the main thread whenever the device volume changes, e.g. from the
/// keyboard volume keys or the menu bar.
final class VolumeObserver {
    private let device: AudioDeviceID
    private var addresses: [AudioObjectPropertyAddress]
    private let block: AudioObjectPropertyListenerBlock

    init(device: OutputDevice, onChange: @escaping @MainActor () -> Void) {
        self.device = device.id
        block = { _, _ in MainActor.assumeIsolated { onChange() } }
        addresses = device.volumeElements.map {
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioDevicePropertyScopeOutput, mElement: $0)
        }
        for i in addresses.indices { AudioObjectAddPropertyListenerBlock(self.device, &addresses[i], .main, block) }
    }

    deinit {
        for i in addresses.indices { AudioObjectRemovePropertyListenerBlock(device, &addresses[i], .main, block) }
    }
}
