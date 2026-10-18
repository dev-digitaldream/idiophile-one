import Accelerate
import AVFoundation

/// Integrated loudness per ITU-R BS.1770 / EBU R128: K-weighting, 400 ms blocks every
/// 100 ms, absolute gate at −70 LUFS and relative gate 10 LU below the gated mean.
/// Written from the published standard; see `LoudnessTests` for the reference signals.
final class LoudnessMeter {
    /// ReplayGain 2.0 reference level.
    static let replayGainReferenceLUFS = -18.0

    private let sampleRate: Double
    private var setups: [vDSP.Biquad<Double>]
    private let channels: Int
    private let hop: Int
    private var hopFill = 0
    private var hopEnergy = 0.0
    /// Mean-square energy (summed over channels) of each completed 100 ms hop.
    private(set) var hops: [Double] = []
    private(set) var samplePeak: Float = 0

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = min(max(channels, 1), 2)
        hop = Int((sampleRate * 0.1).rounded())
        setups = (0..<self.channels).map { _ in
            vDSP.Biquad(coefficients: Self.kWeighting(sampleRate: sampleRate), channelCount: 1, sectionCount: 2,
                        ofType: Double.self)!
        }
    }

    /// The two K-weighting stages as vDSP coefficients [b0 b1 b2 a1 a2] × 2.
    static func kWeighting(sampleRate fs: Double) -> [Double] {
        // Stage 1: high-shelf modelling the head, +4 dB above ~1.7 kHz.
        let f1 = 1681.974450955533, g = 3.999843853973347, q1 = 0.7071752369554196
        let k1 = tan(.pi * f1 / fs)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k1 / q1 + k1 * k1
        let shelf = [(vh + vb * k1 / q1 + k1 * k1) / a0, 2 * (k1 * k1 - vh) / a0, (vh - vb * k1 / q1 + k1 * k1) / a0,
                     2 * (k1 * k1 - 1) / a0, (1 - k1 / q1 + k1 * k1) / a0]
        // Stage 2: revised low-frequency B-weighting (high-pass near 38 Hz).
        let f2 = 38.13547087602444, q2 = 0.5003270373238773
        let k2 = tan(.pi * f2 / fs)
        let b0 = 1 + k2 / q2 + k2 * k2
        let highpass = [1.0, -2.0, 1.0, 2 * (k2 * k2 - 1) / b0, (1 - k2 / q2 + k2 * k2) / b0]
        return shelf + highpass
    }

    /// Feeds planar float samples (one buffer's worth) through the filters.
    func process(_ channelData: [UnsafePointer<Float>], frames: Int) {
        guard frames > 0 else { return }
        var weighted: [[Double]] = []
        for c in 0..<channels {
            let source = channelData[min(c, channelData.count - 1)]
            var peak: Float = 0
            vDSP_maxmgv(source, 1, &peak, vDSP_Length(frames))
            samplePeak = max(samplePeak, peak)
            let input = (0..<frames).map { Double(source[$0]) }
            weighted.append(setups[c].apply(input: input))
        }
        var i = 0
        while i < frames {
            let n = min(hop - hopFill, frames - i)
            for c in 0..<channels {
                hopEnergy += weighted[c][i..<i + n].reduce(0) { $0 + $1 * $1 }
            }
            hopFill += n
            i += n
            if hopFill == hop {
                // Mono is measured as a single front channel; stereo as two (equal weights).
                hops.append(hopEnergy / Double(hop))
                hopEnergy = 0
                hopFill = 0
            }
        }
    }

    /// 400 ms blocks (four hops, 75 % overlap).
    var blocks: [Double] { Self.blocks(from: hops) }

    static func blocks(from hops: [Double]) -> [Double] {
        guard hops.count >= 4 else { return [] }
        return (0...(hops.count - 4)).map { (hops[$0] + hops[$0 + 1] + hops[$0 + 2] + hops[$0 + 3]) / 4 }
    }

    var integratedLUFS: Double? { Self.integratedLUFS(blocks: blocks) }

    /// Gated loudness of a set of 400 ms block energies (a track, or all tracks of an album).
    static func integratedLUFS(blocks: [Double]) -> Double? {
        func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(e) }
        let aboveAbsolute = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return nil }
        let relativeThreshold = lufs(aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) - 10
        let gated = aboveAbsolute.filter { lufs($0) > relativeThreshold }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

/// What the library stores about one track's loudness.
struct TrackLoudness: Sendable {
    var lufs: Double?
    var samplePeak: Float
    /// 400 ms block energies, kept to compute the album figure without decoding again.
    var blocks: [Double]
}

enum LoudnessAnalyzer {
    /// Decodes the file in one pass and measures it. Runs off the main thread.
    static func analyze(url: URL) -> TrackLoudness? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { return nil }
        let meter = LoudnessMeter(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch { return nil }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let planes = (0..<Int(format.channelCount)).map { UnsafePointer<Float>(data[$0]) }
            meter.process(planes, frames: Int(buffer.frameLength))
        }
        return TrackLoudness(lufs: meter.integratedLUFS, samplePeak: meter.samplePeak, blocks: meter.blocks)
    }

    /// ReplayGain 2.0 gain in dB for a measured loudness.
    static func gain(forLUFS lufs: Double) -> Float { Float(LoudnessMeter.replayGainReferenceLUFS - lufs) }
}
