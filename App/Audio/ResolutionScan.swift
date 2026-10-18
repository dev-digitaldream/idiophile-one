import Accelerate
import AVFoundation

/// What a file really contains, as opposed to what its header claims.
struct ResolutionReport: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        /// Content reaches (almost) the Nyquist frequency.
        case fullBand
        /// Content stops near a standard CD-era band edge inside a higher-rate file.
        case upsampled(fromHz: Double)
        /// Steep low-pass in the range typical of lossy encoders.
        case lossySignature(cutoffHz: Double)
        /// Content ends well below Nyquist, which a recording may do honestly.
        case limited(cutoffHz: Double)
        /// Nothing to measure (silence).
        case silent
    }

    let sampleRate: Double
    let claimedBits: Int?
    /// Frequency above which the content falls to the noise floor, nil if none was found.
    let cutoffHz: Double?
    /// Bits actually used by the samples (a 16-bit master in a 24-bit container reads 16).
    let effectiveBits: Int?
    let verdict: Verdict
    let windowsMeasured: Int

    var nyquist: Double { sampleRate / 2 }

    /// The claimed depth is not backed by the samples.
    var depthIsPadded: Bool {
        guard let claimed = claimedBits, let used = effectiveBits else { return false }
        return used < claimed
    }
}

/// Averages the spectrum over windows spread across the file and looks for the knee where
/// the content stops. A signature, not a proof: some recordings are honestly band-limited.
enum ResolutionScanner {
    static let fftSize = 8192
    static let bandWidthHz = 500.0

    static func scan(url: URL, claimedBits: Int?) -> ResolutionReport? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        let n = fftSize
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        let windows = 48
        var analyzer = SpectrumAverager(sampleRate: format.sampleRate)
        var usedBits: Int32 = 0
        var measured = 0
        let usable = max(file.length - AVAudioFramePosition(n), 1)

        for w in 0..<windows {
            // Skip the very start and end (fades, silence) by spreading windows over 5…95 %.
            let position = AVAudioFramePosition(Double(usable) * (0.05 + 0.9 * Double(w) / Double(windows - 1)))
            file.framePosition = max(0, min(position, file.length - 1))
            guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(n))) != nil,
                  buffer.frameLength == AVAudioFrameCount(n), let data = buffer.floatChannelData else { continue }
            let channels = Int(format.channelCount)
            // Each channel is analysed on its own and their powers are averaged: summing the
            // channels would cancel a signal that is out of phase between left and right.
            var heard = false
            for c in 0..<min(channels, 2) {
                let channel = Array(UnsafeBufferPointer(start: data[c], count: n))
                var energy: Float = 0
                vDSP_svesq(channel, 1, &energy, vDSP_Length(n))
                guard energy / Float(n) > 1e-10 else { continue }   // digital silence
                analyzer.add(channel)
                heard = true
            }
            guard heard else { continue }
            measured += 1

            // Depth: OR of the samples at 24-bit scale; trailing zero bits are unused bits.
            for c in 0..<min(channels, 2) {
                for i in 0..<n { usedBits |= Int32((data[c][i] * 8_388_608).rounded()) }
            }
        }
        guard measured > 0 else {
            return ResolutionReport(sampleRate: format.sampleRate, claimedBits: claimedBits, cutoffHz: nil,
                                    effectiveBits: nil, verdict: .silent, windowsMeasured: 0)
        }
        let cutoff = analyzer.cutoffHz()
        let effective = usedBits == 0 ? nil : 24 - usedBits.trailingZeroBitCount
        return ResolutionReport(sampleRate: format.sampleRate, claimedBits: claimedBits, cutoffHz: cutoff,
                                effectiveBits: effective.map { max($0, 1) },
                                verdict: verdict(sampleRate: format.sampleRate, cutoff: cutoff), windowsMeasured: measured)
    }

    /// Interprets a cutoff frequency for a file of this sample rate.
    static func verdict(sampleRate: Double, cutoff: Double?) -> ResolutionReport.Verdict {
        let nyquist = sampleRate / 2
        guard let cutoff else { return .fullBand }
        if sampleRate > 48_000 {
            if cutoff <= 24_000 { return .upsampled(fromHz: cutoff > 22_500 ? 48_000 : 44_100) }
            return cutoff >= 0.9 * nyquist ? .fullBand : .limited(cutoffHz: cutoff)
        }
        if cutoff >= 0.9 * nyquist { return .fullBand }
        // Encoders low-pass between ~11 kHz (low bitrates) and ~20 kHz; recordings rarely stop sharply there.
        return cutoff >= 10_000 && cutoff <= 20_500 ? .lossySignature(cutoffHz: cutoff) : .limited(cutoffHz: cutoff)
    }
}

/// Running average of the power spectrum of equal-sized windows, summarised in 500 Hz bands.
struct SpectrumAverager {
    private let sampleRate: Double
    private let n = ResolutionScanner.fftSize
    private let log2n = vDSP_Length(log2(Double(ResolutionScanner.fftSize)))
    private let setup: FFTSetup
    private var window: [Float]
    private var power: [Double]
    private var count = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(ResolutionScanner.fftSize))), FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: ResolutionScanner.fftSize)
        vDSP_hann_window(&window, vDSP_Length(ResolutionScanner.fftSize), Int32(vDSP_HANN_NORM))
        power = [Double](repeating: 0, count: ResolutionScanner.fftSize / 2)
    }

    mutating func add(_ samples: [Float]) {
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        for i in 0..<n / 2 { power[i] += Double(mags[i]) }
        count += 1
    }

    /// Average level per 500 Hz band in dB (arbitrary but consistent reference).
    func bandLevels() -> [Double] {
        let binWidth = sampleRate / Double(n)
        let perBand = max(1, Int((ResolutionScanner.bandWidthHz / binWidth).rounded()))
        var levels: [Double] = []
        var i = 1
        while i + perBand <= n / 2 {
            let mean = power[i..<i + perBand].reduce(0, +) / Double(perBand * max(count, 1))
            levels.append(10 * log10(max(mean, 1e-30)))
            i += perBand
        }
        return levels
    }

    /// Frequency of the knee above which the spectrum stays far below the music, or nil.
    func cutoffHz() -> Double? {
        let levels = bandLevels()
        let bandHz = ResolutionScanner.bandWidthHz
        let firstBand = Int(8_000 / bandHz)            // look for knees above 8 kHz
        guard levels.count > firstBand + 6 else { return nil }
        var best: (band: Int, drop: Double)?
        for k in firstBand..<(levels.count - 3) {
            let before = levels[(k - 3)..<k].reduce(0, +) / 3
            let tail = levels[k...]
            // Everything above the knee must stay far below the content before it.
            guard let loudestAbove = tail.max(), before - loudestAbove >= 30 else { continue }
            let drop = before - (tail.prefix(3).reduce(0, +) / 3)
            if best == nil || drop > best!.drop { best = (k, drop) }
        }
        return best.map { Double($0.band) * bandHz }
    }
}
