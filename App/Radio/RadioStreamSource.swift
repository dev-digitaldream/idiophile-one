import AudioToolbox
import AVFoundation

/// Decodes an internet radio stream (MP3 or AAC over HTTP/Icecast/Shoutcast) into PCM so it
/// can play through the same engine as files: meters, equalizer, device rate, volume.
///
/// Bytes arrive from URLSession; ICY metadata blocks are removed (and their StreamTitle
/// reported); AudioFileStream splits packets; AVAudioConverter decodes them. Everything runs
/// on the main queue: decoding a radio stream costs well under a millisecond per chunk.
@MainActor
final class RadioStreamSource: NSObject, URLSessionDataDelegate {
    enum Failure: Error, LocalizedError {
        case unsupported(String), network(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let type): "Unsupported stream type (\(type))"
            case .network(let message): message
            }
        }
    }

    /// PCM format of the decoded stream, reported once before the first buffer.
    var onFormat: ((AVAudioFormat) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onTitle: ((String) -> Void)?
    /// Called when the stream cannot be played this way (fallback) or fails.
    var onFailure: ((Failure) -> Void)?

    private var session: URLSession?
    private var fileStream: AudioFileStreamID?
    private var sourceFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var cookie: Data?

    // ICY metadata demultiplexing.
    private var metaInterval = 0
    private var audioBytesUntilMeta = 0
    private var metaLength = -1
    private var metaBytes = Data()

    func start(_ url: URL) {
        stop()
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("IdiophileOne/0.1", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        session?.dataTask(with: request).resume()
    }

    func stop() {
        session?.invalidateAndCancel()
        session = nil
        if let fileStream { AudioFileStreamClose(fileStream) }
        fileStream = nil
        sourceFormat = nil
        pcmFormat = nil
        converter = nil
        cookie = nil
        metaInterval = 0
        metaLength = -1
        metaBytes = Data()
    }

    // MARK: URLSession

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        MainActor.assumeIsolated {
            let http = response as? HTTPURLResponse
            let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType ?? "").lowercased()
            let hint: AudioFileTypeID
            if type.contains("mpeg") && !type.contains("mpegurl") {
                hint = kAudioFileMP3Type
            } else if type.contains("aac") || type.contains("mp4") {
                hint = kAudioFileAAC_ADTSType
            } else {
                completionHandler(.cancel)
                onFailure?(.unsupported(type.isEmpty ? "unknown" : type))
                return
            }
            metaInterval = Int(http?.value(forHTTPHeaderField: "icy-metaint") ?? "") ?? 0
            audioBytesUntilMeta = metaInterval
            openParser(hint: hint)
            completionHandler(.allow)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated { demultiplex(data) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard self.session === session else { return }
            let message = error.map { ($0 as NSError).code == NSURLErrorCancelled ? nil : $0.localizedDescription } ?? "Stream ended"
            if let message { onFailure?(.network(message)) }
        }
    }

    // MARK: ICY metadata

    /// Splits audio bytes from the metadata blocks inserted every `icy-metaint` bytes.
    private func demultiplex(_ data: Data) {
        guard metaInterval > 0 else { return parse(data) }
        var index = data.startIndex
        while index < data.endIndex {
            if metaLength < 0, audioBytesUntilMeta > 0 {
                let n = min(audioBytesUntilMeta, data.endIndex - index)
                parse(data[index..<index + n])
                audioBytesUntilMeta -= n
                index += n
            } else if metaLength < 0 {
                metaLength = Int(data[index]) * 16   // length byte, in 16-byte units
                index += 1
                metaBytes.removeAll(keepingCapacity: true)
                if metaLength == 0 { finishMetadata() }
            } else {
                let n = min(metaLength - metaBytes.count, data.endIndex - index)
                metaBytes.append(data[index..<index + n])
                index += n
                if metaBytes.count == metaLength { finishMetadata() }
            }
        }
    }

    private func finishMetadata() {
        if let text = String(data: metaBytes, encoding: .utf8) ?? String(data: metaBytes, encoding: .isoLatin1),
           let start = text.range(of: "StreamTitle='"),
           let end = text.range(of: "';", range: start.upperBound..<text.endIndex) {
            let title = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { onTitle?(title) }
        }
        metaLength = -1
        audioBytesUntilMeta = metaInterval
    }

    // MARK: Parsing and decoding

    private func openParser(hint: AudioFileTypeID) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(me, { client, stream, property, _ in
            let source = Unmanaged<RadioStreamSource>.fromOpaque(client).takeUnretainedValue()
            MainActor.assumeIsolated { source.propertyChanged(stream, property) }
        }, { client, bytes, packets, data, descriptions in
            let source = Unmanaged<RadioStreamSource>.fromOpaque(client).takeUnretainedValue()
            MainActor.assumeIsolated { source.received(bytes: bytes, packets: packets, data: data, descriptions: descriptions) }
        }, hint, &fileStream)
    }

    private func parse(_ data: Data) {
        guard let fileStream, !data.isEmpty else { return }
        let status = data.withUnsafeBytes { AudioFileStreamParseBytes(fileStream, UInt32($0.count), $0.baseAddress, []) }
        if status != noErr, sourceFormat == nil { onFailure?(.unsupported("unparseable audio")) }
    }

    private func propertyChanged(_ stream: AudioFileStreamID, _ property: AudioFileStreamPropertyID) {
        switch property {
        case kAudioFileStreamProperty_MagicCookieData:
            var size: UInt32 = 0
            guard AudioFileStreamGetPropertyInfo(stream, property, &size, nil) == noErr, size > 0 else { return }
            var bytes = [UInt8](repeating: 0, count: Int(size))
            if AudioFileStreamGetProperty(stream, property, &size, &bytes) == noErr { cookie = Data(bytes) }
        case kAudioFileStreamProperty_ReadyToProducePackets:
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr,
                  let source = AVAudioFormat(streamDescription: &asbd),
                  let pcm = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: max(1, asbd.mChannelsPerFrame)),
                  let converter = AVAudioConverter(from: source, to: pcm) else {
                onFailure?(.unsupported("audio format"))
                return
            }
            if let cookie { converter.magicCookie = cookie }
            sourceFormat = source
            pcmFormat = pcm
            self.converter = converter
            onFormat?(pcm)
        default:
            break
        }
    }

    private func received(bytes: UInt32, packets: UInt32, data: UnsafeRawPointer,
                          descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let sourceFormat, let pcmFormat, let converter, packets > 0 else { return }
        // One compressed buffer per packet: an AAC decoder takes a single packet per input
        // request, so handing it the whole batch at once silently dropped all but the first.
        var buffers: [AVAudioCompressedBuffer] = []
        buffers.reserveCapacity(Int(packets))
        let evenSize = Int(bytes) / Int(packets)
        for i in 0..<Int(packets) {
            let offset = descriptions.map { Int($0[i].mStartOffset) } ?? i * evenSize
            let size = descriptions.map { Int($0[i].mDataByteSize) } ?? evenSize
            guard size > 0, offset + size <= Int(bytes) else { continue }
            let one = AVAudioCompressedBuffer(format: sourceFormat, packetCapacity: 1, maximumPacketSize: size)
            one.data.copyMemory(from: data + offset, byteCount: size)
            one.byteLength = UInt32(size)
            one.packetCount = 1
            one.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: descriptions?[i].mVariableFramesInPacket ?? 0, mDataByteSize: UInt32(size))
            buffers.append(one)
        }

        let framesPerPacket = max(sourceFormat.streamDescription.pointee.mFramesPerPacket, 1152)
        guard !buffers.isEmpty,
              let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(buffers.count + 2) * framesPerPacket)
        else { return }
        var next = 0
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard next < buffers.count else {
                status.pointee = .noDataNow
                return nil
            }
            defer { next += 1 }
            status.pointee = .haveData
            return buffers[next]
        }
        if output.frameLength > 0 { onBuffer?(output) }
    }
}
