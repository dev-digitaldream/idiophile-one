import CoreAudio
import Foundation

/// One step between the file and the DAC, as observed in the running engine and device.
struct AudioPathStage: Identifiable, Equatable {
    enum State: Equatable {
        /// Verified not to change the samples.
        case transparent
        /// Changes the samples (a deliberate choice or an imposed conversion).
        case alters
        /// Neutral information.
        case info
        /// Could not be determined: never shown as a guarantee.
        case unknown
    }

    let id: String
    let title: String
    let detail: String
    let state: State
}

/// The whole path and its verdict.
struct AudioPathReport: Equatable {
    enum Verdict: Equatable {
        /// Every condition holds and a sample comparison confirmed it for this track.
        case verifiedBitPerfect
        /// Every condition holds; no sample comparison yet for this track and settings.
        case bitPerfectConditions
        case altered([String])
        case notVerifiable(String)
        case idle
    }

    let stages: [AudioPathStage]
    let verdict: Verdict
}

/// Result of the last sample comparison, valid for one track and one processing setting.
struct VerificationRecord: Equatable {
    let url: URL
    let path: SignalPath
    let report: BitPerfectVerifier.Report
    let date: Date
}

extension OutputDevice {
    /// "USB", "Built-in", "HDMI", "Bluetooth"… from the transport type.
    var transportName: String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        switch value {
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "Virtual"
        default: return nil
        }
    }
}

extension PlayerEngine {
    /// Reads the path from the live engine and device. Nothing here is assumed: values come
    /// from the units' current settings and from Core Audio queries made now.
    func audioPath() -> AudioPathReport {
        guard let info = nowPlaying else { return AudioPathReport(stages: [], verdict: .idle) }
        let path = signalPath
        let device = outputDevice
        var stages: [AudioPathStage] = []
        var alterations: [String] = []
        func khz(_ rate: Double) -> String {
            rate.truncatingRemainder(dividingBy: 1000) == 0 ? String(format: "%.0f kHz", rate / 1000) : String(format: "%.1f kHz", rate / 1000)
        }

        // Source and decoding.
        let sourceDetail = isRadio
            ? "\(station?.displayName ?? "Stream") · \(info.codec)"
            : [info.codec, info.bitDepth.map { "\($0)-bit" }, info.sampleRate > 0 ? khz(info.sampleRate) : nil,
               info.channels == 2 ? "stereo" : "\(info.channels) ch"].compactMap { $0 }.joined(separator: " · ")
        stages.append(.init(id: "source", title: isRadio ? "Live stream" : "Source", detail: sourceDetail, state: .info))
        if info.isLossless {
            stages.append(.init(id: "decode", title: "Decoding", detail: "Lossless: decoded samples equal the original", state: .transparent))
        } else {
            stages.append(.init(id: "decode", title: "Decoding", detail: "Lossy codec: the original samples no longer exist", state: .alters))
            alterations.append("lossy source")
        }

        if info.isLossless, let source = info.bitDepth, source > 24 {
            stages.append(.init(id: "precision", title: "Engine precision",
                                detail: "32-bit float carries 24 bits: the \(source)-bit source is rounded to 24", state: .alters))
            alterations.append("\(source)-bit source rounded to 24 bits")
        }

        // Processing.
        if path.eqAltersSignal {
            let active = path.eq.bands.filter { !$0.isNeutral }.count
            let what = eqSetup.useParametric ? "\(path.eq.name): \(active) filters" : "Graphic, \(active) bands"
            stages.append(.init(id: "eq", title: "Equalizer",
                                detail: String(format: "%@, gain %+.1f dB", what, path.eqGainDB), state: .alters))
            alterations.append("equalizer")
        } else if path.bandsActive {
            stages.append(.init(id: "eq", title: "Equalizer", detail: "On but flat: no filter, no gain", state: .transparent))
        } else {
            stages.append(.init(id: "eq", title: "Equalizer", detail: isDirect ? "Out of the path (DIRECT)" : "Bypassed", state: .transparent))
        }
        if let rg = path.replayGainDB {
            stages.append(.init(id: "rg", title: "ReplayGain", detail: String(format: "%+.1f dB (%@)", rg, replayGainMode.name), state: .alters))
            alterations.append("ReplayGain")
        } else {
            let why = replayGainMode == .off ? "Off" : (isDirect ? "Off in DIRECT" : "No loudness data yet: measure the library")
            stages.append(.init(id: "rg", title: "ReplayGain", detail: why, state: .transparent))
        }
        if path.levelMatchDB != 0 {
            stages.append(.init(id: "audition", title: "A/B level match",
                                detail: String(format: "%+.1f dB so the compared profiles are equally loud", path.levelMatchDB), state: .alters))
            alterations.append("A/B level match")
        }
        let mixer = abs(path.mixerVolume)   // the sign is the polarity, shown on its own line
        if isMuted || mixer == 0 {
            stages.append(.init(id: "gain", title: "Digital volume", detail: "Muted", state: .alters))
            alterations.append("muted")
        } else if mixer == 1 {
            let where_ = usesHardwareVolume ? "volume set on the device" : "knob at maximum"
            stages.append(.init(id: "gain", title: "Digital volume", detail: "Unity gain, \(where_)", state: .transparent))
        } else {
            stages.append(.init(id: "gain", title: "Digital volume", detail: String(format: "%.1f dB in software", 20 * log10(mixer)), state: .alters))
            alterations.append("digital volume")
        }

        if path.invertPolarity {
            stages.append(.init(id: "polarity", title: "Polarity",
                                detail: polarityGlobal && !isCurrentTrackInverted ? "Inverted (all tracks)" : "Inverted for this track",
                                state: .alters))
            alterations.append("polarity")
        } else {
            stages.append(.init(id: "polarity", title: "Polarity", detail: "Normal", state: .transparent))
        }

        // Rate, depth, exclusivity, device: queried from Core Audio now.
        if let device {
            let rate = device.nominalSampleRate
            if info.sampleRate <= 0 {
                stages.append(.init(id: "rate", title: "Sample rate", detail: "\(khz(rate)) at the device", state: .unknown))
            } else if rate == info.sampleRate {
                stages.append(.init(id: "rate", title: "Sample rate", detail: "\(khz(rate)): no resampling", state: .transparent))
            } else {
                stages.append(.init(id: "rate", title: "Sample rate",
                                    detail: "Resampled \(khz(info.sampleRate)) → \(khz(rate)): the device cannot play the file's rate",
                                    state: .alters))
                alterations.append("resampling")
            }
            if let bits = device.physicalBits {
                if let source = info.bitDepth, info.isLossless {
                    stages.append(.init(id: "depth", title: "Output format",
                                        detail: bits >= source ? "\(bits)-bit integer: holds all \(source) bits" : "\(bits)-bit: below the file's \(source) bits",
                                        state: bits >= source ? .transparent : .alters))
                    if bits < source { alterations.append("bit depth") }
                } else {
                    stages.append(.init(id: "depth", title: "Output format", detail: "\(bits)-bit integer", state: .info))
                }
            } else {
                stages.append(.init(id: "depth", title: "Output format", detail: "Not reported by the device", state: .unknown))
            }
            if device.isExclusive {
                stages.append(.init(id: "excl", title: "Access", detail: "Exclusive: nothing else is mixed in", state: .transparent))
            } else {
                stages.append(.init(id: "excl", title: "Access", detail: "Shared: system sounds can be mixed in (DIRECT takes exclusive access)", state: .alters))
                alterations.append("shared device")
            }
            let volume = device.hasHardwareVolume ? String(format: " · volume %.1f dB", device.hardwareVolumeDB) : ""
            stages.append(.init(id: "device", title: "Device",
                                detail: device.name + (device.transportName.map { " (\($0))" } ?? "") + volume
                                    + (device.transportName == "Built-in" ? " · applies its own processing" : ""),
                                state: device.transportName == "Built-in" ? .unknown : .info))
        } else if let missing = missingOutputName {
            stages.append(.init(id: "device", title: "Device",
                                detail: "\(missing) is not connected. Output is locked: playback waits for it", state: .alters))
            alterations.append("output missing")
        } else {
            stages.append(.init(id: "device", title: "Device", detail: "No output device", state: .unknown))
        }

        // Verdict.
        let verdict: AudioPathReport.Verdict
        if !alterations.isEmpty {
            verdict = .altered(alterations)
        } else if stages.contains(where: { $0.state == .unknown && $0.id != "device" }) {
            verdict = .notVerifiable("Some steps cannot be read from this device")
        } else if let record = lastVerification, record.url == currentURL, record.path == path, record.report.isIdentical {
            verdict = .verifiedBitPerfect
        } else {
            verdict = .bitPerfectConditions
        }
        return AudioPathReport(stages: stages, verdict: verdict)
    }
}
