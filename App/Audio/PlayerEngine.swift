import AVFoundation
import AppKit
import CoreAudio
import Accelerate
import Observation
import os

/// Level analysis published by the tap and read by the meters every frame.
///
/// The tap delivers buffers ahead of the speaker and in large blocks (often ~100 ms), so
/// levels are measured in 256-frame chunks stamped with the host time at which each chunk
/// leaves the DAC. The meters then read exactly what is being heard.
final class LevelTap: @unchecked Sendable {
    struct Levels {
        /// Sine-calibrated average-rectified level (what a VU movement responds to), linear.
        var average: (left: Float, right: Float) = (0, 0)
        /// Sample peak, linear.
        var peak: (left: Float, right: Float) = (0, 0)
        /// Octave-band levels in dBFS (sine-referenced), one per `Equalizer.frequencies` entry.
        var spectrum: [Float] = Array(repeating: -120, count: Equalizer.frequencies.count)
    }

    private struct Chunk {
        var time: Double = 0
        var average: (Float, Float) = (0, 0)
        var peak: (Float, Float) = (0, 0)
    }

    private struct State {
        var ring = [Chunk](repeating: Chunk(), count: LevelTap.capacity)
        var head = 0
        var count = 0
        var spectrum = Array(repeating: Float(-120), count: Equalizer.frequencies.count)
        var outputLatency: Double = 0
    }

    static let chunkFrames = 256
    static let capacity = 4096

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Only touched from the tap's serial thread.
    private let analyzer = SpectrumAnalyzer()

    /// Host clock in seconds, the time base of chunk stamps.
    static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    /// The spectrum is computed only while an analyser is on screen.
    private let spectrumOn = OSAllocatedUnfairLock(initialState: true)
    func setSpectrumEnabled(_ on: Bool) { spectrumOn.withLock { $0 = on } }

    /// Device + stream latency between the render clock and the analogue output.
    func setOutputLatency(_ seconds: Double) { state.withLock { $0.outputLatency = seconds } }

    func reset() {
        state.withLock {
            $0.count = 0
            $0.spectrum = Array(repeating: -120, count: Equalizer.frequencies.count)
        }
    }

    /// Aggregates the chunks heard during (`from`, `to`]: mean of averages, max of peaks.
    /// When no chunk falls in the window, returns the latest chunk already heard.
    func read(from: Double, to: Double) -> Levels {
        state.withLock { st in
            var levels = Levels(spectrum: st.spectrum)
            var sum: (Float, Float) = (0, 0)
            var n: Float = 0
            var latest: Chunk?
            for k in 0..<st.count {
                let c = st.ring[(st.head - 1 - k + LevelTap.capacity) % LevelTap.capacity]
                guard c.time <= to else { continue }
                if latest == nil { latest = c }
                guard c.time > from else { break }
                sum.0 += c.average.0; sum.1 += c.average.1
                levels.peak.left = max(levels.peak.left, c.peak.0)
                levels.peak.right = max(levels.peak.right, c.peak.1)
                n += 1
            }
            if n > 0 {
                levels.average = (sum.0 / n, sum.1 / n)
            } else if let latest {
                levels.average = latest.average
                levels.peak = latest.peak
            }
            return levels
        }
    }

    func analyze(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        let right = channels > 1 ? data[1] : data[0]
        let start = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : Self.now()

        var chunks: [Chunk] = []
        chunks.reserveCapacity(frames / Self.chunkFrames + 1)
        var offset = 0
        while offset < frames {
            let n = vDSP_Length(min(Self.chunkFrames, frames - offset))
            var c = Chunk(time: start + Double(offset) / rate)
            var mean: Float = 0, peak: Float = 0
            vDSP_meamgv(data[0] + offset, 1, &mean, n); vDSP_maxmgv(data[0] + offset, 1, &peak, n)
            // Average-rectified × π/(2√2) reads RMS for a sine, as a real VU meter is calibrated.
            c.average.0 = mean * 1.1107; c.peak.0 = peak
            vDSP_meamgv(right + offset, 1, &mean, n); vDSP_maxmgv(right + offset, 1, &peak, n)
            c.average.1 = mean * 1.1107; c.peak.1 = peak
            chunks.append(c)
            offset += Int(n)
        }
        let bands = spectrumOn.withLock { $0 }
            ? analyzer.bands(left: data[0], right: right, frames: frames, sampleRate: rate) : nil
        let measured = chunks

        state.withLock { st in
            for var c in measured {
                c.time += st.outputLatency
                st.ring[st.head] = c
                st.head = (st.head + 1) % LevelTap.capacity
                st.count = min(st.count + 1, LevelTap.capacity)
            }
            if let bands { st.spectrum = bands }
        }
    }
}

/// Octave-band analyser: Hann-windowed 4096-point real FFT of the mono sum.
final class SpectrumAnalyzer {
    static let log2n: vDSP_Length = 12
    static let size = 1 << Int(log2n)

    private let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    private var window = [Float](repeating: 0, count: size)
    private var samples = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imag = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func bands(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double) -> [Float]? {
        let n = Self.size
        guard frames > 0 else { return nil }
        // Slide the newest frames into the analysis window.
        let count = min(frames, n)
        samples.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            if count < n { memmove(base, base + count, (n - count) * MemoryLayout<Float>.size) }
            let dst = base + (n - count)
            let srcL = left + (frames - count)
            let srcR = right + (frames - count)
            vDSP_vadd(srcL, 1, srcR, 1, dst, 1, vDSP_Length(count))
            var half: Float = 0.5
            vDSP_vsmul(dst, 1, &half, dst, 1, vDSP_Length(count))
        }

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }

        // Power of a full-scale sine summed over its Hann main lobe, after zrip scaling and the
        // normalised window; calibrated by test (testFullScaleSineReadsZeroDBFS).
        let reference = Float(n / 2) * Float(n / 2) * 4
        let binWidth = sampleRate / Double(n)
        return Equalizer.frequencies.map { fc in
            let lo = max(1, Int((Double(fc) / 2.0.squareRoot()) / binWidth))
            // Bands above Nyquist (low sample-rate files) have no bins.
            guard lo <= n / 2 - 1 else { return -120 }
            let hi = min(n / 2 - 1, max(lo, Int((Double(fc) * 2.0.squareRoot()) / binWidth)))
            var sum: Float = 0
            for k in lo...hi { sum += power[k] }
            return 10 * log10(max(sum / reference, 1e-12))
        }
    }
}

struct TrackInfo: Equatable {
    var title: String
    var artist: String?
    var album: String?
    var artwork: NSImage?
    var codec: String
    var bitDepth: Int?
    var sampleRate: Double
    var channels: Int
    var duration: TimeInterval
    /// Decoded samples equal the original ones (no lossy codec in between).
    var isLossless: Bool
    /// Live stream: the label shows codec and bitrate rather than a file format.
    var isStream = false

    var formatLabel: String {
        guard sampleRate > 0, !isStream else { return codec }   // radio: codec and bitrate only
        let khz = sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? String(format: "%.0f", sampleRate / 1000)
            : String(format: "%.1f", sampleRate / 1000)
        if let bits = bitDepth { return "\(codec) · \(bits) / \(khz) kHz" }
        return "\(codec) · \(khz) kHz"
    }
}

/// Provisional playback engine built on AVAudioEngine.
/// Not bit-perfect: it goes through the system mixer. The real engine (CoreAudio HAL,
/// hog mode, rate switching, DoP) replaces it in a later milestone; see docs/PLAN.md.
@Observable
@MainActor
final class PlayerEngine {
    private(set) var queue: [URL] = []
    private(set) var index = 0
    private(set) var isPlaying = false {
        didSet {
            remote?.update()
            guard oldValue, !isPlaying else { return }
            // Keep the meters animating while the needles fall back to rest.
            needlesSettling = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                if !isPlaying { needlesSettling = false }
            }
        }
    }
    private(set) var needlesSettling = false
    private(set) var nowPlaying: TrackInfo? {
        didSet { remote?.update() }
    }
    private(set) var lastError: String?
    /// Media keys and Control Center.
    @ObservationIgnored private var remote: NowPlaying?

    // MARK: Radio

    /// The station playing, nil when playing files.
    private(set) var station: RadioStation?
    var isRadio: Bool { station != nil }
    @ObservationIgnored private var stream: StreamPlayer!

    /// Radio decoded by `RadioStreamSource` and played through the engine; AVPlayer is the
    /// fallback for stream types it cannot parse (HLS, Ogg).
    @ObservationIgnored private var radioSource: RadioStreamSource!
    @ObservationIgnored private var radioBufferedFrames: AVAudioFramePosition = 0
    @ObservationIgnored private var radioStarted = false
    private(set) var radioUsesFallback = false

    /// Where the library was when a station took over, so LIB can come back to it.
    @ObservationIgnored private var libraryPosition: TimeInterval = 0

    /// The station played last, restored by the RADIO source.
    var lastStation: RadioStation? {
        UserDefaults.standard.data(forKey: "lastStation").flatMap { try? JSONDecoder().decode(RadioStation.self, from: $0) }
    }

    func play(station: RadioStation) {
        guard let url = station.streamURL, !refuseIfOutputMissing() else { return }
        if file != nil { libraryPosition = currentTime() }
        UserDefaults.standard.set(try? JSONEncoder().encode(station), forKey: "lastStation")
        stopRadio()
        stopFiles()
        self.station = station
        nowPlaying = TrackInfo(title: station.displayName, artist: nil, album: [station.country, station.tagList.prefix(3).joined(separator: ", ")]
                                   .compactMap { $0?.nilIfEmpty }.joined(separator: " · ").nilIfEmpty,
                               artwork: nil, codec: station.qualityLabel.nilIfEmpty ?? "STREAM", bitDepth: nil,
                               sampleRate: 0, channels: 2, duration: 0, isLossless: false, isStream: true)
        lastError = nil
        radioBufferedFrames = 0
        radioStarted = false
        isPlaying = true
        radioSource.start(url)
        let uuid = station.stationuuid
        Task {
            await RadioBrowser.shared.reportClick(station)
            if let icon = station.faviconURL, let (data, _) = try? await URLSession.shared.data(from: icon),
               let image = NSImage(data: data), self.station?.stationuuid == uuid {
                nowPlaying?.artwork = image
            }
        }
    }

    /// First decoded format: build the graph at the stream's rate (the DAC follows it).
    private func radioFormatReady(_ pcm: AVAudioFormat) {
        do {
            prepareOutput(for: pcm.sampleRate)
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(eq)
            engine.connect(node, to: eq, format: pcm)
            engine.connect(eq, to: engine.mainMixerNode, format: pcm)
            let tap = levels
            eq.removeTap(onBus: 0)
            eq.installTap(onBus: 0, bufferSize: 1024, format: pcm) { buffer, when in tap.analyze(buffer, when: when) }
            replayGainTags = nil
            applyEqualizer()
            if !engine.isRunning { try engine.start() }
            levels.setOutputLatency(engine.outputNode.presentationLatency)
            nowPlaying?.sampleRate = pcm.sampleRate   // decoded rate, compared with the device rate
        } catch {
            lastError = error.localizedDescription
            isPlaying = false
        }
    }

    /// Decoded audio: queue it; start once a second is buffered to ride out network jitter.
    private func radioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard station != nil, isPlaying, engine.isRunning else { return }
        node.scheduleBuffer(buffer)
        radioBufferedFrames += AVAudioFramePosition(buffer.frameLength)
        if !radioStarted, Double(radioBufferedFrames) >= buffer.format.sampleRate {
            radioStarted = true
            _ = startNode()
        }
    }

    private func radioFailed(_ failure: RadioStreamSource.Failure) {
        guard let station, isPlaying else { return }
        if case .unsupported = failure, !radioUsesFallback, let url = station.streamURL {
            radioUsesFallback = true
            radioSource.stop()
            stream.play(url, deviceUID: outputDevice?.uid, volume: abs(signalPath.mixerVolume))
        } else {
            lastError = failure.localizedDescription
            isPlaying = false
        }
    }

    private func stopRadio() {
        guard station != nil else { return }
        radioSource.stop()
        stream.stop()
        if !radioUsesFallback { node.stop() }
        radioUsesFallback = false
        station = nil
    }

    /// Stops file playback and releases the engine (radio uses its own player).
    private func stopFiles() {
        generation += 1
        queued = nil
        node.stop()
        if engine.isRunning { engine.stop() }
        file = nil
        levels.reset()
    }

    @ObservationIgnored let levels = LevelTap()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let eqParts = ParametricEQUnit.make()
    /// The equalizer node in the engine graph and the unit behind it.
    private var eq: AVAudioUnitEffect { eqParts.effect }
    private var eqUnit: ParametricEQUnit { eqParts.unit }
    @ObservationIgnored private var file: AVAudioFile?
    /// Bumped on every schedule so completion handlers of stopped files are ignored.
    @ObservationIgnored private var generation = 0
    /// Node time (seconds) at which the current track's position 0 lies. Negative when
    /// playback started mid-track; advanced by each gapless transition.
    @ObservationIgnored private var segmentBase: TimeInterval = 0
    @ObservationIgnored private var lastPosition: TimeInterval = 0
    /// The node lost its schedule while paused (device or format change): resume re-schedules.
    @ObservationIgnored private var needsReschedule = false
    /// Next track already scheduled on the node for a gapless transition.
    @ObservationIgnored private var queued: (index: Int, file: AVAudioFile, meta: FLACMetadata?)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: Output

    private(set) var outputDevices: [OutputDevice] = OutputDevice.all()
    /// `nil` follows the system default output.
    private(set) var chosenDevice: OutputDevice?
    /// Current hardware clock of the output device.
    private(set) var deviceRate: Double = 0
    /// Bits per sample of the device's physical stream format.
    private(set) var deviceBits: Int?
    private(set) var isExclusive = false
    @ObservationIgnored private var hoggedDevice: OutputDevice?

    /// The output the user chose, by stable identifier (names can repeat or change).
    @ObservationIgnored private var savedOutputUID: String? = UserDefaults.standard.string(forKey: "outputDeviceUID")
    @ObservationIgnored private var savedOutputName = UserDefaults.standard.string(forKey: "outputDeviceName")
    /// With the lock on, losing the chosen output stops playback instead of falling back to
    /// another output such as the built-in speakers.
    var lockOutput: Bool = UserDefaults.standard.object(forKey: "lockOutput") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(lockOutput, forKey: "lockOutput")
            if lockOutput, chosenDevice == nil, let current = OutputDevice.systemDefault() { chooseDevice(current) }
        }
    }
    /// Name of the locked output that is not connected; playback is blocked until it returns.
    private(set) var missingOutputName: String?
    @ObservationIgnored private var missingOutputUID: String?

    /// nil while the chosen output is missing, so nothing can start on the wrong device.
    var outputDevice: OutputDevice? {
        missingOutputUID != nil ? nil : (chosenDevice ?? OutputDevice.systemDefault())
    }

    /// Playback is refused while the locked output is absent.
    private func refuseIfOutputMissing() -> Bool {
        guard let name = missingOutputName else { return false }
        lastError = "\(name) is not connected: playback waits for it"
        isPlaying = false
        return true
    }

    // MARK: Per-device profiles

    private struct DeviceProfile: Codable {
        var volume: Double
        var limitDB: Float
    }
    @ObservationIgnored private var profiles: [String: DeviceProfile] = {
        UserDefaults.standard.data(forKey: "deviceProfiles").flatMap { try? JSONDecoder().decode([String: DeviceProfile].self, from: $0) } ?? [:]
    }()
    /// While a profile is being loaded the limit's own side effects stay off.
    @ObservationIgnored private var loadingProfile = false

    private func saveProfile() {
        guard let uid = outputDevice?.uid else { return }
        profiles[uid] = DeviceProfile(volume: volumePosition, limitDB: volumeLimitDB)
        UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: "deviceProfiles")
    }

    /// Loads the volume and limit remembered for the current output, never louder than it was.
    private func loadProfile() {
        loadEQSetup()
        guard let device = outputDevice, let uid = device.uid else { return }
        let profile = profiles[uid]
        loadingProfile = true
        volumeLimitDB = profile?.limitDB ?? 0
        loadingProfile = false
        volumePosition = VolumeSafety.startPosition(stored: profile?.volume, current: volumePosition, limit: limitPosition,
                                                    deviceDB: device.hasHardwareVolume ? device.loudestHardwareVolumeDB : nil)
    }

    /// At launch: use the remembered output; if it is missing and locked, wait for it
    /// rather than start on another device.
    private func restoreChosenOutput() {
        if let uid = savedOutputUID {
            if let device = outputDevices.first(where: { $0.uid == uid }) {
                selectDevice(device)
                return
            }
            if let device = sameDeviceWithNewIdentifier(named: savedOutputName) {
                adopt(device, replacing: uid)
                selectDevice(device)
                return
            }
            if lockOutput {
                missingOutputUID = uid
                missingOutputName = savedOutputName ?? "The chosen output"
                lastError = "\(missingOutputName ?? "The chosen output") is not connected"
                return
            }
        }
        loadProfile()
        attachVolume()
    }

    /// A USB DAC's identifier carries its port, so the same DAC on another port (or behind a
    /// hub) has a new one. A single connected device with the remembered name is that DAC.
    private func sameDeviceWithNewIdentifier(named name: String?) -> OutputDevice? {
        guard let name else { return nil }
        let matches = outputDevices.filter { $0.name == name }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Carries the saved choice and profile over to the DAC's new identifier.
    private func adopt(_ device: OutputDevice, replacing oldUID: String?) {
        if let oldUID, let newUID = device.uid, oldUID != newUID {
            if let profile = profiles[oldUID], profiles[newUID] == nil { profiles[newUID] = profile }
            profiles[oldUID] = nil
            UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: "deviceProfiles")
        }
        savedOutputUID = device.uid
        savedOutputName = device.name
        UserDefaults.standard.set(savedOutputUID, forKey: "outputDeviceUID")
        UserDefaults.standard.set(savedOutputName, forKey: "outputDeviceName")
    }

    /// The user picks an output (nil = follow the system). Remembered across launches.
    func chooseDevice(_ device: OutputDevice?) {
        savedOutputUID = device?.uid
        savedOutputName = device?.name
        UserDefaults.standard.set(savedOutputUID, forKey: "outputDeviceUID")
        UserDefaults.standard.set(savedOutputName, forKey: "outputDeviceName")
        missingOutputUID = nil
        missingOutputName = nil
        selectDevice(device)
    }

    /// DIRECT: no EQ, no ReplayGain, exclusive access.
    private(set) var isDirect = false

    /// True when the samples reach the device untouched: same rate and depth, no DSP,
    /// no digital gain, nothing else mixed in.
    /// Every condition must be known and verified; anything unknown reads as not bit-perfect.
    var isBitPerfect: Bool {
        guard isDirect, !isMuted, let info = nowPlaying, info.isLossless,
              let source = info.bitDepth, source <= 24, let bits = deviceBits, bits >= source,
              deviceRate == info.sampleRate, info.channels == 2,
              let device = outputDevice, device.isExclusive,
              signalPath.isTransparent,
              engine.mainMixerNode.outputVolume == 1 else { return false }
        return true
    }

    // MARK: Volume

    /// Volume knob position, 0…1 (linear in dB from −60 to 0 dB).
    private(set) var volumePosition: Double = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.75
    /// Silence that nothing but the user can lift (device notifications never unmute).
    private(set) var isMuted = false
    /// Loudest level the knob may reach, in dB (headphone safety). 0 = no limit.
    var volumeLimitDB: Float = UserDefaults.standard.object(forKey: "volumeLimitDB") as? Float ?? 0 {
        didSet {
            guard !loadingProfile else { return }
            UserDefaults.standard.set(volumeLimitDB, forKey: "volumeLimitDB")
            setVolume(volumePosition)
        }
    }
    /// Digital attenuation currently applied on top of the device volume, in dB (≤ 0).
    private(set) var digitalTrimDB: Float = 0
    @ObservationIgnored private var volumeObserver: VolumeObserver?

    /// The knob drives the device's own volume control when it has one: the signal stays
    /// untouched and the keyboard volume keys turn the knob.
    var usesHardwareVolume: Bool { outputDevice?.hasHardwareVolume == true }

    /// Total digital gain in dB, including mute.
    var gainDB: Float { isMuted || volumePosition <= 0.001 ? -.infinity : digitalTrimDB }

    nonisolated static func knobGainDB(_ position: Double) -> Float {
        position <= 0.001 ? -.infinity : Float(-60 * (1 - position))
    }

    nonisolated static func knobPosition(forDB db: Float) -> Double {
        db.isFinite ? min(max(1 + Double(db) / 60, 0), 1) : 0
    }

    private var limitPosition: Double { Self.knobPosition(forDB: volumeLimitDB) }

    func setVolume(_ position: Double) {
        volumePosition = min(max(position, 0), limitPosition)
        UserDefaults.standard.set(volumePosition, forKey: "volume")
        saveProfile()
        applyVolume()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyVolume()
    }

    /// Applies the knob: on the device when possible, with a digital trim for whatever the
    /// device could not do. The trim is computed from the level read back from the device,
    /// so a failed or partial write leaves the output at or below the requested level.
    /// The device level the app last set and read back, to recognise its own echo.
    @ObservationIgnored private var expectedDeviceDB: Float?

    private func applyVolume() {
        let target = Self.knobGainDB(volumePosition)
        if let device = outputDevice, device.hasHardwareVolume, target.isFinite {
            device.setHardwareVolumeDB(target)
            let actual = device.loudestHardwareVolumeDB
            expectedDeviceDB = actual
            digitalTrimDB = VolumeSafety.digitalTrim(target: target, deviceActual: actual)
        } else {
            expectedDeviceDB = nil
            digitalTrimDB = target.isFinite ? target : 0
        }
        engine.mainMixerNode.outputVolume = signalPath.mixerVolume
        stream?.setVolume(abs(signalPath.mixerVolume))
    }

    /// Takes over the device volume without ever getting louder than the knob was.
    private func attachVolume() {
        volumeObserver = nil
        if let device = outputDevice, device.hasHardwareVolume {
            volumePosition = VolumeSafety.adoptedPosition(knob: volumePosition, deviceDB: device.loudestHardwareVolumeDB,
                                                          limit: limitPosition)
        }
        applyVolume()
        if let device = outputDevice, device.hasHardwareVolume {
            volumeObserver = VolumeObserver(device: device) { [weak self] in self?.deviceVolumeChanged() }
        }
    }

    /// Volume keys or menu bar changed the device: follow it, within the limit. Mute stays.
    private func deviceVolumeChanged() {
        guard let device = outputDevice, device.hasHardwareVolume, let actual = device.loudestHardwareVolumeDB else { return }
        // The echo of our own write (the DAC clamped our request, e.g. −55 dB for −58 dB asked,
        // and the digital complement makes up the difference) is not a volume key.
        if VolumeSafety.isOwnWrite(actualDB: actual, expectedDB: expectedDeviceDB) { return }
        let position = Self.knobPosition(forDB: actual)
        if position > limitPosition + 0.002 {
            setVolume(limitPosition)   // pushes the device back down
            return
        }
        guard abs(position - volumePosition) > 0.002 else { return }
        // A jump up is a device reset, not a volume key: restore the knob's level on the device.
        if volumePosition > 0.001,
           !VolumeSafety.shouldFollowDeviceChange(fromDB: expectedDeviceDB ?? Self.knobGainDB(volumePosition), toDB: actual) {
            setVolume(volumePosition)
            return
        }
        expectedDeviceDB = actual
        volumePosition = position
        UserDefaults.standard.set(position, forKey: "volume")
        saveProfile()
        digitalTrimDB = VolumeSafety.digitalTrim(target: Self.knobGainDB(position), deviceActual: actual)
        engine.mainMixerNode.outputVolume = signalPath.mixerVolume
        stream?.setVolume(abs(signalPath.mixerVolume))
    }

    // MARK: DIRECT and devices

    /// Set when DIRECT pinned the system output to keep exclusive access across the default
    /// output change that macOS makes when a device is taken exclusively.
    @ObservationIgnored private var pinnedForDirect = false

    func setDirect(_ on: Bool) {
        guard on != isDirect else { return }
        isDirect = on
        if on {
            if chosenDevice == nil, let device = outputDevice, !device.isBuiltIn {
                // Taking the system output exclusively makes macOS switch its default to
                // another device: stay on this one.
                chosenDevice = device
                pinnedForDirect = true
                bindEngine(to: device)
            }
            if let device = outputDevice, !device.isBuiltIn, device.setExclusive(true), device.isExclusive {
                hoggedDevice = device
                isExclusive = true
            }
        } else {
            hoggedDevice?.setExclusive(false)
            hoggedDevice = nil
            isExclusive = false
            if pinnedForDirect {
                pinnedForDirect = false
                if OutputDevice.systemDefault()?.id != chosenDevice?.id {
                    selectDevice(nil)
                } else {
                    chosenDevice = nil
                }
            }
        }
        applyEqualizer()
    }

    /// Points the engine's output unit at `device` when it is not already there.
    private func bindEngine(to device: OutputDevice) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
        guard current != device.id else { return }
        var id = device.id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    func selectDevice(_ device: OutputDevice?) {
        let resumeAt = isPlaying ? currentTime() : nil
        node.stop()
        engine.stop()
        hoggedDevice?.setExclusive(false)
        hoggedDevice = nil
        isExclusive = false
        pinnedForDirect = false
        chosenDevice = device
        if let id = device?.id ?? OutputDevice.systemDefault()?.id, let unit = engine.outputNode.audioUnit {
            var deviceID = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if isDirect, let now = outputDevice, !now.isBuiltIn, now.setExclusive(true) {
            hoggedDevice = now
            isExclusive = true
        }
        loadProfile()
        attachVolume()
        stream?.setDevice(uid: outputDevice?.uid)
        if let station, isPlaying, !radioUsesFallback {
            play(station: station)
        } else if let resumeAt, !isRadio {
            play(at: index, from: resumeAt)
        } else if file != nil, !isRadio {
            needsReschedule = true
        }
    }

    @ObservationIgnored private var deviceUpdate: Task<Void, Never>?
    @ObservationIgnored private var lastDefaultID: AudioDeviceID?

    private func scheduleDeviceUpdate() {
        deviceUpdate?.cancel()
        deviceUpdate = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            applyDeviceChanges()
        }
    }

    /// One reconciliation after a burst of device events.
    private func applyDeviceChanges() {
        refreshDevices()
        let defaultID = OutputDevice.systemDefault()?.id
        if defaultID != lastDefaultID {
            lastDefaultID = defaultID
            defaultDeviceChanged()
        }
        // The engine stopped by itself (format or device change) and nothing above restarted it.
        guard !engine.isRunning, missingOutputUID == nil else { return }
        if let station {
            if isPlaying && !radioUsesFallback { play(station: station) }
        } else if file != nil {
            if isPlaying { play(at: index, from: currentTime()) } else { needsReschedule = true }
        }
    }

    private func refreshDevices() {
        outputDevices = OutputDevice.all()
        // A locked output that came back: reconnect, paused, at its own remembered volume.
        if let uid = missingOutputUID,
           let device = outputDevices.first(where: { $0.uid == uid || "name:\($0.name)" == uid })
               ?? sameDeviceWithNewIdentifier(named: missingOutputName) {
            if device.uid != uid { adopt(device, replacing: uid) }
            missingOutputUID = nil
            missingOutputName = nil
            lastError = nil
            // Back, but never resumed on its own: the user restarts playback.
            isPlaying = false
            selectDevice(device)
            needsReschedule = file != nil
            return
        }
        if let chosen = chosenDevice, !outputDevices.contains(chosen) {
            if lockOutput {
                // Do not fall back to another output: stop and wait for this one. The identifier
                // was read while the device existed; if it never had one, wait by name.
                let uid = chosen.uid ?? "name:\(chosen.name)"
                let position = isPlaying ? currentTime() : lastPosition
                node.stop()
                stream.stop()
                engine.stop()
                hoggedDevice = nil
                isExclusive = false
                chosenDevice = nil
                volumeObserver = nil
                missingOutputUID = uid
                missingOutputName = chosen.name
                isPlaying = false
                lastPosition = position
                needsReschedule = file != nil
                lastError = "\(chosen.name) was disconnected: playback is paused until it returns"
            } else {
                selectDevice(nil)   // fall back to the system output
            }
        }
    }

    /// The system output changed (DAC plugged in, menu bar choice) while following it.
    private func defaultDeviceChanged() {
        // Ignored while a device is chosen or held exclusively (taking it exclusively is what
        // makes macOS move its default elsewhere).
        guard chosenDevice == nil, hoggedDevice == nil, missingOutputUID == nil else { return }
        selectDevice(nil)
    }

    /// Matches the hardware clock to the source so no sample-rate conversion happens.
    /// Returns true when the device clock had to change (the DAC then needs a moment to re-lock).
    @discardableResult
    private func prepareOutput(for sourceRate: Double) -> Bool {
        guard let device = outputDevice else { return false }
        let target = device.preferredRate(for: sourceRate)
        let changed = device.nominalSampleRate != target
        if changed {
            if engine.isRunning { engine.stop() }
            device.setNominalSampleRate(target)
        }
        deviceRate = device.nominalSampleRate
        deviceBits = device.setBestPhysicalFormat(rate: deviceRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: deviceRate, channels: 2)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        return changed
    }

    /// Pause after a sample-rate change before the first sample, in seconds. A DAC that is
    /// still re-locking its clock can swallow the start of the track.
    var rateSettleDelay: Double = UserDefaults.standard.object(forKey: "rateSettleDelay") as? Double ?? 0.3 {
        didSet { UserDefaults.standard.set(rateSettleDelay, forKey: "rateSettleDelay") }
    }

    // MARK: Equalizer and ReplayGain

    /// The equalizer setting of the current output device (graphic faders and/or a parametric
    /// profile). Each device keeps its own: headphones and speakers want different curves.
    var eqSetup = EQSetup() {
        didSet {
            applyEqualizer()
            if !loadingEQ { saveEQSetup() }
        }
    }
    @ObservationIgnored private var loadingEQ = false

    /// Graphic equalizer gains in dB, one per `Equalizer.frequencies` band. Touching a fader
    /// returns to the faders; the parametric profile is kept.
    var eqGains: [Float] {
        get { eqSetup.graphic }
        set {
            eqSetup.graphic = newValue
            eqSetup.useParametric = false
        }
    }

    var eqBypassed = false {
        didSet { applyEqualizer() }
    }

    /// Preamp plus headroom applied by the equalizer, in dB.
    var eqHeadroomDB: Float { Float(signalPath.eqGainDB) }

    private static let eqSetupsKey = "eqSetups"

    private var eqSetups: [String: EQSetup] {
        get {
            UserDefaults.standard.data(forKey: Self.eqSetupsKey)
                .flatMap { try? JSONDecoder().decode([String: EQSetup].self, from: $0) } ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.eqSetupsKey) }
    }

    private func saveEQSetup() {
        eqSetups[outputDevice?.uid ?? "default"] = eqSetup
    }

    /// Loads the equalizer setting remembered for this device. The faders of earlier versions
    /// (one global set) go to the first device that comes up; a new device starts flat.
    private func loadEQSetup() {
        let key = outputDevice?.uid ?? "default"
        var setups = eqSetups
        loadingEQ = true
        defer { loadingEQ = false }
        if let saved = setups[key] {
            eqSetup = saved
        } else if setups.isEmpty, let legacy = UserDefaults.standard.array(forKey: "equalizer.gains") as? [Float],
                  legacy.count == Equalizer.frequencies.count {
            eqSetup = EQSetup(graphic: legacy)
            setups[key] = eqSetup
            eqSetups = setups
            UserDefaults.standard.removeObject(forKey: "equalizer.gains")
        } else {
            eqSetup = EQSetup()
        }
    }

    /// Applies a parametric profile to the current device (from the editor or an import).
    func useParametricProfile(_ profile: EQProfile) {
        eqSetup.parametric = profile
        eqSetup.useParametric = true
    }

    var replayGainMode: ReplayGainMode = ReplayGainMode(rawValue: UserDefaults.standard.string(forKey: "replayGain") ?? "") ?? .off {
        didSet {
            UserDefaults.standard.set(replayGainMode.rawValue, forKey: "replayGain")
            applyEqualizer()
        }
    }
    private(set) var replayGainTags: ReplayGainTags?

    /// ReplayGain applied to the current track, in dB (never in DIRECT).
    var replayGainDB: Float? { isDirect ? nil : replayGainMode.gain(for: replayGainTags) }

    /// The EQ unit also carries ReplayGain as its global gain; it leaves the path entirely
    /// when neither is in use, so the samples pass untouched.
    /// Current processing settings, as applied to the units.
    var signalPath: SignalPath {
        SignalPath(eq: eqSetup.profile, bandsActive: !eqBypassed && !isDirect,
                   replayGainDB: replayGainDB, digitalGainDB: gainDB, invertPolarity: isPolarityInverted,
                   levelMatchDB: auditionSlot != nil && auditionLevelMatch && !isDirect ? auditionMatchDB : 0)
    }

    // MARK: A/B audition

    /// What the A/B comparison is playing: one of two profiles, or the equalizer off.
    enum AuditionSlot: String { case a, b, off }

    /// The slot being heard; nil when no comparison is running.
    private(set) var auditionSlot: AuditionSlot?
    private(set) var auditionA: EQProfile?
    private(set) var auditionB: EQProfile?
    /// Level the slots to the quietest one (attenuation only, so nothing can clip).
    var auditionLevelMatch = true {
        didSet { updateAuditionMatch(); applyEqualizer() }
    }
    @ObservationIgnored private var auditionMatchDB = 0.0

    /// Loads a profile into slot A or B; the comparison switches to it at once.
    func setAudition(_ slot: AuditionSlot, profile: EQProfile) {
        if slot == .a { auditionA = profile } else if slot == .b { auditionB = profile }
        listen(to: slot)
    }

    /// Switches what is heard without interrupting playback.
    func listen(to slot: AuditionSlot) {
        auditionSlot = slot
        switch slot {
        case .a: if let p = auditionA { useParametricProfile(p) }
        case .b: if let p = auditionB { useParametricProfile(p) }
        case .off: break
        }
        eqBypassed = slot == .off
        updateAuditionMatch()
        applyEqualizer()
    }

    /// Ends the comparison; the last profile heard stays, with its own level.
    func endAudition() {
        guard auditionSlot != nil else { return }
        let wasOff = auditionSlot == .off
        auditionSlot = nil
        auditionMatchDB = 0
        if wasOff { eqBypassed = false }
        applyEqualizer()
    }

    private func updateAuditionMatch() {
        guard let slot = auditionSlot else { auditionMatchDB = 0; return }
        // Level of each choice: the profile's average response with its preamp and headroom, 0 for off.
        let a = auditionA?.levelDB() ?? 0, b = auditionB?.levelDB() ?? 0
        let target = min(0, a, b)
        let own: Double
        switch slot {
        case .a: own = a
        case .b: own = b
        case .off: own = 0
        }
        auditionMatchDB = min(0, target - own)
    }

    // MARK: Polarity

    /// Inverts every track (a whole system wired out of phase).
    var polarityGlobal: Bool = UserDefaults.standard.bool(forKey: "polarityGlobal") {
        didSet { UserDefaults.standard.set(polarityGlobal, forKey: "polarityGlobal"); applyVolume() }
    }
    /// Tracks whose recording is out of phase, remembered by file path.
    private(set) var polarityTracks: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "polarityTracks") ?? [])

    var isCurrentTrackInverted: Bool { currentURL.map { polarityTracks.contains($0.path) } ?? false }

    /// The two settings combine: inverting a track on an inverted system restores it.
    var isPolarityInverted: Bool { polarityGlobal != isCurrentTrackInverted }

    func toggleTrackPolarity() {
        guard let path = currentURL?.path else { return }
        if polarityTracks.contains(path) { polarityTracks.remove(path) } else { polarityTracks.insert(path) }
        UserDefaults.standard.set(Array(polarityTracks), forKey: "polarityTracks")
        applyVolume()
    }

    private func applyEqualizer() {
        signalPath.configure(eqUnit)
    }

    init() {
        engine.attach(node)
        engine.attach(eq)
        applyEqualizer()
        engine.connect(node, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)

        // Plugging or unplugging a DAC fires a burst of notifications while Core Audio and the
        // engine are still reconfiguring. Wait until it settles, then act once.
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDeviceUpdate() }
        })
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleDeviceUpdate() }
            }
        }
        stream = StreamPlayer(levels: levels)
        radioSource = RadioStreamSource()
        radioSource.onFormat = { [weak self] in self?.radioFormatReady($0) }
        radioSource.onBuffer = { [weak self] in self?.radioBuffer($0) }
        radioSource.onTitle = { [weak self] title in
            guard let self, let station = self.station else { return }
            self.nowPlaying?.title = title
            self.nowPlaying?.artist = station.displayName
        }
        radioSource.onFailure = { [weak self] in self?.radioFailed($0) }
        stream.onStreamTitle = { [weak self] title in
            guard let self, let station = self.station else { return }
            self.nowPlaying?.title = title
            self.nowPlaying?.artist = station.displayName
        }
        stream.onFailure = { [weak self] message in
            self?.lastError = message
            self?.isPlaying = false
        }
        lastDefaultID = OutputDevice.systemDefault()?.id
        restoreChosenOutput()
        remote = NowPlaying(player: self)
    }

    // MARK: Transport

    func load(_ urls: [URL], startAt start: Int = 0) {
        queue = urls
        play(at: min(max(start, 0), max(urls.count - 1, 0)))
    }

    /// Inserts tracks right after the current one.
    func playNext(_ urls: [URL]) {
        guard !queue.isEmpty else { return load(urls) }
        queue.insert(contentsOf: urls, at: index + 1)
        requeueGapless()
    }

    /// Appends tracks to the end of the queue.
    func enqueue(_ urls: [URL]) {
        guard !queue.isEmpty else { return load(urls) }
        queue.append(contentsOf: urls)
        if queued == nil { queueNextIfGapless() }
    }

    /// The track after the current one changed: drop the pre-scheduled one by restarting
    /// the current track at its position (sample-accurate, inaudible when paused).
    private func requeueGapless() {
        guard queued != nil, file != nil else { return }
        let wasPlaying = isPlaying
        play(at: index, from: currentTime())
        if !wasPlaying { pause() }
    }

    func play(at i: Int, from position: TimeInterval = 0) {
        guard queue.indices.contains(i) else { stop(); return }
        guard !refuseIfOutputMissing() else { return }
        stopRadio()
        index = i
        generation += 1
        queued = nil
        needsReschedule = false
        node.stop()
        let url = queue[i]
        let f: AVAudioFile
        do {
            f = try AVAudioFile(forReading: url)
        } catch {
            lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
            isPlaying = false
            // Skip an unreadable file; give up after a few in a row.
            if skippedInARow < 5, queue.indices.contains(i + 1) {
                skippedInARow += 1
                play(at: i + 1)
            }
            return
        }
        skippedInARow = 0
        do {
            let meta = Self.flacMetadata(url)
            file = f
            let rateChanged = prepareOutput(for: f.processingFormat.sampleRate)
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(eq)
            engine.connect(node, to: eq, format: f.processingFormat)
            engine.connect(eq, to: engine.mainMixerNode, format: f.processingFormat)
            // Meters read the processed signal before the volume control, like a DAC's VU meters.
            let tap = levels
            eq.removeTap(onBus: 0)
            eq.installTap(onBus: 0, bufferSize: 1024, format: f.processingFormat) { buffer, when in
                tap.analyze(buffer, when: when)
            }
            let startFrame = min(AVAudioFramePosition(position * f.processingFormat.sampleRate), f.length)
            segmentBase = -Double(startFrame) / f.processingFormat.sampleRate
            lastPosition = position
            replayGainTags = Self.gainTags(meta, url)
            applyEqualizer()
            applyVolume()   // polarity is per track
            schedule(f, from: startFrame, track: i)
            if !engine.isRunning { try engine.start() }
            levels.setOutputLatency(engine.outputNode.presentationLatency)
            if rateChanged, rateSettleDelay > 0 {
                // Show "playing" now, start the node once the DAC has settled on its new clock.
                isPlaying = true
                let g = generation
                let delay = rateSettleDelay
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    guard generation == g, isPlaying, !node.isPlaying else { return }
                    if !startNode() { isPlaying = false }
                }
            } else {
                guard startNode() else {
                    isPlaying = false
                    nowPlaying = Self.info(for: f, url: url)
                    return
                }
                isPlaying = true
            }
            lastError = nil
            if position == 0 || nowPlaying == nil {
                nowPlaying = Self.info(for: f, url: url)
                loadTags(for: url, meta: meta, generation: generation)
            }
            queueNextIfGapless()
        } catch {
            // Output problem (device busy or gone), not the file: stay on this track.
            lastError = Self.describeOutputError(error, device: outputDevice?.name)
            isPlaying = false
        }
    }

    @ObservationIgnored private var skippedInARow = 0

    private func schedule(_ f: AVAudioFile, from startFrame: AVAudioFramePosition, track: Int) {
        let g = generation
        let frames = AVAudioFrameCount(max(0, f.length - startFrame))
        node.scheduleSegment(f, startingFrame: startFrame, frameCount: frames, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                // Only a real end of track advances: an engine stopped by a device or
                // format change also completes the schedule.
                guard let self, self.generation == g, self.engine.isRunning, self.index == track,
                      self.currentTime() >= (self.nowPlaying?.duration ?? 0) - 1 else { return }
                self.trackFinished()
            }
        }
    }

    private func trackFinished() {
        guard let next = queued, next.index == index + 1, let finished = file else { return play(at: index + 1) }
        // Gapless: the next file is already playing on the node, sample-accurately.
        segmentBase += Double(finished.length) / finished.processingFormat.sampleRate
        index = next.index
        file = next.file
        queued = nil
        replayGainTags = Self.gainTags(next.meta, queue[next.index])
        applyEqualizer()
        applyVolume()
        nowPlaying = Self.info(for: next.file, url: queue[index])
        loadTags(for: queue[index], meta: next.meta, generation: generation)
        queueNextIfGapless()
    }

    /// Schedules the next track right behind the current one when the format is identical,
    /// so there is no gap and no device reconfiguration between them.
    private func queueNextIfGapless() {
        let n = index + 1
        guard queued == nil, queue.indices.contains(n), let current = file,
              let f = try? AVAudioFile(forReading: queue[n]),
              f.processingFormat == current.processingFormat else { return }
        let meta = Self.flacMetadata(queue[n])
        // ReplayGain and polarity live in the mixer and change from the end-of-track callback, not
        // on the exact sample. Pre-scheduling is only honest when nothing changes at the boundary
        // (ReplayGain "Album" mode keeps a whole album gapless; "Track" mode may leave a short gap).
        let nextGain = isDirect ? 0 : (replayGainMode.gain(for: Self.gainTags(meta, queue[n])) ?? 0)
        let nextInverted = polarityGlobal != polarityTracks.contains(queue[n].path)
        guard abs((replayGainDB ?? 0) - nextGain) < 0.05, nextInverted == isPolarityInverted else { return }
        queued = (n, f, meta)
        schedule(f, from: 0, track: n)
    }

    /// File tags when present, otherwise the loudness the library measured.
    private static func gainTags(_ meta: FLACMetadata?, _ url: URL) -> ReplayGainTags? {
        if let tags = meta?.replayGain, tags.trackGain != nil || tags.albumGain != nil { return tags }
        return LoudnessCache.shared.tags(for: url)
    }

    private static func flacMetadata(_ url: URL) -> FLACMetadata? {
        url.pathExtension.lowercased() == "flac" ? FLACMetadata(url: url) : nil
    }

    func togglePlay() {
        if isPlaying { pause() } else { resume() }
    }

    /// Loads a queue paused at `position`, ready for play (session restore).
    func restore(_ urls: [URL], index i: Int, position: TimeInterval) {
        guard urls.indices.contains(i), let f = try? AVAudioFile(forReading: urls[i]) else { return }
        queue = urls
        index = i
        file = f
        lastPosition = position
        needsReschedule = true
        nowPlaying = Self.info(for: f, url: urls[i])
        loadTags(for: urls[i], meta: Self.flacMetadata(urls[i]), generation: generation)
    }

    /// Leaves radio for the library queue, paused at the place it was left (LIB source).
    /// Returns false when there is no library queue to go back to.
    @discardableResult
    func returnToLibrary() -> Bool {
        guard !queue.isEmpty else { return false }
        if station != nil { stopRadio() }
        restore(queue, index: min(index, queue.count - 1), position: libraryPosition)
        return true
    }

    /// Selects a station without connecting, ready for play (session restore).
    func restore(station: RadioStation) {
        if file != nil { libraryPosition = currentTime() }
        stopFiles()
        self.station = station
        nowPlaying = TrackInfo(title: station.displayName, artist: nil, album: station.country, artwork: nil,
                               codec: station.qualityLabel.nilIfEmpty ?? "STREAM", bitDepth: nil, sampleRate: 0,
                               channels: 2, duration: 0, isLossless: false, isStream: true)
    }

    func pause() {
        guard isPlaying else { return }
        if let station {
            // Live radio: pausing stops the stream; resuming rejoins it live.
            stopRadio()
            self.station = station
            isPlaying = false
            levels.reset()
            return
        }
        node.pause()
        isPlaying = false
        levels.reset()
    }

    func resume() {
        guard !refuseIfOutputMissing() else { return }
        if let station {
            play(station: station)
            return
        }
        guard file != nil else { return }
        if needsReschedule { return play(at: index, from: lastPosition) }
        do {
            if !engine.isRunning { try engine.start() }
            guard startNode() else { return }
            isPlaying = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        stopRadio()
        generation += 1
        queued = nil
        node.stop()
        isPlaying = false
        levels.reset()
    }

    func next() {
        guard !isRadio else { return }
        play(at: index + 1)
    }

    func reportError(_ message: String) { lastError = message }

    /// Core Audio error codes are four-character codes: say what they mean for the user.
    private static func describeOutputError(_ error: Error, device: String?) -> String {
        let code = (error as NSError).code
        let name = device ?? "The output"
        switch code {
        case 1937010544:   // 'stop': the device is not running
            return "\(name) cannot start (asleep, in use by another app, or without audio). Choose another output in the Output menu."
        case 560227702:    // '!dev': device not available
            return "\(name) is not available. Choose another output in the Output menu."
        case 1852797029:   // 'nope': hog mode / permission
            return "\(name) is reserved by another app."
        default:
            return "\(name): \(error.localizedDescription) (code \(code))"
        }
    }

    /// Starts the player node, turning the exception AVFAudio raises during a hardware
    /// reconfiguration into an error. Returns false (and asks to retry on resume) if it failed.
    private func startNode() -> Bool {
        guard engine.isRunning else {
            needsReschedule = true
            return false
        }
        if let error = IdiophileTry({ node.play() }) {
            lastError = "Output is changing: \(error.localizedDescription)"
            needsReschedule = true
            return false
        }
        return true
    }

    /// Last sample comparison, shown in the audio path when it matches the current track and settings.
    var lastVerification: VerificationRecord?

    /// URL of the current track.
    var currentURL: URL? { queue.indices.contains(index) ? queue[index] : nil }

    func seek(to position: TimeInterval) {
        guard file != nil else { return }
        play(at: index, from: max(0, position))
        remote?.update()
    }

    func previous() {
        guard !isRadio else { return }
        if currentTime() > 3 { play(at: index) } else { play(at: max(0, index - 1)) }
    }

    /// Playback position in the current track. Survives the engine stopping (device or
    /// format change), when the node no longer reports a render time.
    func currentTime() -> TimeInterval {
        guard let renderTime = node.lastRenderTime, renderTime.isSampleTimeValid,
              let t = node.playerTime(forNodeTime: renderTime) else { return lastPosition }
        lastPosition = max(0, Double(t.sampleTime) / t.sampleRate - segmentBase)
        return lastPosition
    }

    private static func info(for file: AVAudioFile, url: URL) -> TrackInfo {
        let asbd = file.fileFormat.streamDescription.pointee
        let codec: String
        var bits: Int? = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
        switch asbd.mFormatID {
        case kAudioFormatFLAC:
            codec = "FLAC"
            bits = losslessSourceBits(asbd.mFormatFlags)
        case kAudioFormatAppleLossless:
            codec = "ALAC"
            bits = losslessSourceBits(asbd.mFormatFlags)
        case kAudioFormatMPEGLayer3: codec = "MP3"
        case kAudioFormatMPEG4AAC: codec = "AAC"
        case kAudioFormatOpus: codec = "OPUS"
        case kAudioFormatLinearPCM: codec = url.pathExtension.uppercased()
        default: codec = url.pathExtension.uppercased()
        }
        return TrackInfo(
            title: url.deletingPathExtension().lastPathComponent,
            artist: nil,
            album: nil,
            artwork: nil,
            codec: codec,
            bitDepth: bits,
            sampleRate: file.fileFormat.sampleRate,
            channels: Int(file.fileFormat.channelCount),
            duration: Double(file.length) / file.fileFormat.sampleRate,
            isLossless: [kAudioFormatFLAC, kAudioFormatAppleLossless, kAudioFormatLinearPCM].contains(asbd.mFormatID)
        )
    }

    /// FLAC and ALAC encode the source bit depth in the format flags (1 = 16 … 4 = 32).
    private static func losslessSourceBits(_ flags: AudioFormatFlags) -> Int? {
        switch flags {
        case 1: 16
        case 2: 20
        case 3: 24
        case 4: 32
        default: nil
        }
    }

    /// Display names of the next tracks in the queue.
    func upcoming(_ count: Int) -> [String] {
        queue.dropFirst(index + 1).prefix(count).map { $0.deletingPathExtension().lastPathComponent }
    }

    private func loadTags(for url: URL, meta flac: FLACMetadata?, generation g: Int) {
        Task {
            let asset = AVURLAsset(url: url)
            let items = (try? await asset.load(.commonMetadata)) ?? []
            func string(_ id: AVMetadataIdentifier) async -> String? {
                let value = try? await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first?.load(.stringValue)
                return value?.isEmpty == false ? value : nil
            }
            let title = await string(.commonIdentifierTitle) ?? flac?.title
            let artist = await string(.commonIdentifierArtist) ?? flac?.artist
            let album = await string(.commonIdentifierAlbumName) ?? flac?.album
            let artData = try? await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork)
                .first?.load(.dataValue)
            let artwork = (artData ?? flac?.picture).flatMap { NSImage(data: $0) } ?? Self.folderArtwork(for: url)
            // Drop results for a track that is no longer the current one.
            guard generation == g, queue.indices.contains(index), queue[index] == url else { return }
            if let title { nowPlaying?.title = title }
            if let artist { nowPlaying?.artist = artist }
            nowPlaying?.album = album
            nowPlaying?.artwork = artwork
        }
    }

    /// Conventional cover files next to the audio file (cover.jpg, folder.png, …).
    private static func folderArtwork(for url: URL) -> NSImage? {
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let stems = ["cover", "folder", "front", "albumart"]
        let match = names.first { name in
            let lower = name.lowercased()
            return stems.contains { lower.hasPrefix($0) } && ["jpg", "jpeg", "png"].contains((lower as NSString).pathExtension)
        }
        return match.flatMap { NSImage(contentsOf: dir.appendingPathComponent($0)) }
    }
}
