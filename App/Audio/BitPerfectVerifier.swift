import AVFoundation

/// Sample-by-sample proof that the app hands Core Audio exactly the decoded file.
///
/// The file is decoded once as the reference, then rendered offline through the same units
/// as playback (player node → EQ/ReplayGain unit → mixer) configured by the same
/// `SignalPath`. Both are converted back to the source's integer scale and compared exactly.
/// What happens after Core Audio (driver, DAC) is outside the app and not covered.
enum BitPerfectVerifier {
    struct Report: Equatable {
        var frames: Int
        var channels: Int
        var sourceBits: Int
        var sampleRate: Double
        /// Samples whose integer value differs from the source.
        var differingSamples: Int
        /// Largest difference, in dB relative to full scale (nil when identical).
        var maxErrorDBFS: Double?

        var isIdentical: Bool { differingSamples == 0 && frames > 0 }
    }

    enum Failure: Error, LocalizedError {
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let reason): reason
            }
        }
    }

    /// Verifies up to `seconds` of `url` from its start through `path`.
    static func verify(url: URL, path: SignalPath, seconds: Double = 10) throws -> Report {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(min(Double(file.length), seconds * format.sampleRate))
        guard frames > 0, let reference = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw Failure.unsupported("Empty file")
        }
        try file.read(into: reference, frameCount: frames)
        guard let bits = sourceBits(of: file) else {
            throw Failure.unsupported("Lossy or unknown source format: there is no exact reference to compare with")
        }
        // The reference itself is decoded to float32, which holds 24 bits: a 32-bit file has
        // already lost its low bits before any comparison, so "identical" would prove nothing.
        guard bits <= 24 else {
            throw Failure.unsupported("This file has \(bits)-bit samples. The engine works in 32-bit float, which carries 24 bits, so exactness beyond 24 bits can be neither delivered nor proven.")
        }
        return try verify(reference: reference, sourceBits: bits, path: path)
    }

    /// Renders `reference` through `path` and compares it at `sourceBits` precision.
    static func verify(reference: AVAudioPCMBuffer, sourceBits: Int, path: SignalPath) throws -> Report {
        let rendered = try render(reference, path: path)
        let format = reference.format
        let channels = Int(format.channelCount)
        let n = Int(reference.frameLength)
        let scale = pow(2.0, Double(sourceBits - 1))
        var differing = 0
        var maxError = 0.0
        for ch in 0..<channels {
            let a = reference.floatChannelData![ch]
            let b = rendered.floatChannelData![ch]
            for i in 0..<n where (Double(a[i]) * scale).rounded() != (Double(b[i]) * scale).rounded() || !b[i].isFinite {
                differing += 1
                maxError = max(maxError, abs(Double(a[i]) - Double(b[i])))
            }
        }
        return Report(frames: n, channels: channels, sourceBits: sourceBits, sampleRate: format.sampleRate,
                      differingSamples: differing,
                      maxErrorDBFS: differing > 0 ? 20 * log10(max(maxError, 1e-12)) : nil)
    }

    /// Offline render through the playback chain.
    static func render(_ input: AVAudioPCMBuffer, path: SignalPath) throws -> AVAudioPCMBuffer {
        let format = input.format
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let (eq, eqUnit) = ParametricEQUnit.make()
        engine.attach(node)
        engine.attach(eq)
        engine.connect(node, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        path.configure(eqUnit)
        engine.mainMixerNode.outputVolume = path.mixerVolume
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        node.scheduleBuffer(input)
        try engine.start()
        node.play()
        defer { engine.stop() }

        guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: input.frameLength),
              let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            throw Failure.unsupported("Cannot allocate render buffers")
        }
        let channels = Int(format.channelCount)
        while output.frameLength < input.frameLength {
            let want = min(4096, input.frameLength - output.frameLength)
            guard try engine.renderOffline(want, to: chunk) == .success else { break }
            for ch in 0..<channels {
                (output.floatChannelData![ch] + Int(output.frameLength))
                    .update(from: chunk.floatChannelData![ch], count: Int(chunk.frameLength))
            }
            output.frameLength += chunk.frameLength
        }
        return output
    }

    /// Bit depth of a lossless source (FLAC, ALAC, integer PCM), nil for lossy formats.
    static func sourceBits(of file: AVAudioFile) -> Int? {
        let asbd = file.fileFormat.streamDescription.pointee
        switch asbd.mFormatID {
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            return [1: 16, 2: 20, 3: 24, 4: 32][asbd.mFormatFlags]
        case kAudioFormatLinearPCM:
            // Float sources compare at 24-bit precision, the float32 mantissa.
            return asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? 24 : Int(asbd.mBitsPerChannel)
        default:
            return nil
        }
    }
}
