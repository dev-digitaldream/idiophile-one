import AVFoundation
import MediaToolbox

/// Plays internet radio streams with AVPlayer, feeding the meters through an audio
/// processing tap and reporting the stream title (ICY metadata).
///
/// Streams are lossy and decoded by the system: this path is never bit-perfect and skips
/// the equalizer. Output device and volume follow the amplifier.
@MainActor
final class StreamPlayer: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let player = AVPlayer()
    private let levels: LevelTap
    private var statusObservation: NSKeyValueObservation?
    var onStreamTitle: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    init(levels: LevelTap) {
        self.levels = levels
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func play(_ url: URL, deviceUID: String?, volume: Float) {
        stop()
        let item = AVPlayerItem(url: url)
        let metadata = AVPlayerItemMetadataOutput(identifiers: nil)
        metadata.setDelegate(self, queue: .main)
        item.add(metadata)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay: await self.attachTap(to: item)
                case .failed: self.onFailure?(item.error?.localizedDescription ?? "Stream unavailable")
                default: break
                }
            }
        }
        player.audioOutputDeviceUniqueID = deviceUID
        player.volume = volume
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func pause() { player.pause() }
    func resume() { player.play() }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        levels.reset()
    }

    func setVolume(_ volume: Float) { player.volume = volume }

    func setDevice(uid: String?) { player.audioOutputDeviceUniqueID = uid }

    // MARK: Stream title

    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                                    didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                                    from track: AVPlayerItemTrack?) {
        guard let item = groups.flatMap(\.items).first(where: {
            $0.identifier == .icyMetadataStreamTitle || $0.commonKey == .commonKeyTitle
        }) else { return }
        Task { @MainActor in
            if let title = try? await item.load(.stringValue), !title.trimmingCharacters(in: .whitespaces).isEmpty {
                self.onStreamTitle?(title)
            }
        }
    }

    // MARK: Meter tap

    private func attachTap(to item: AVPlayerItem) async {
        guard item.audioMix == nil,
              let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
              let tap = Self.makeTap(levels: levels) else { return }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    private final class TapContext {
        let levels: LevelTap
        var format: AVAudioFormat?
        init(levels: LevelTap) { self.levels = levels }
    }

    private static func makeTap(levels: LevelTap) -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(TapContext(levels: levels))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context.toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, description in
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.format = AVAudioFormat(streamDescription: description)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard let format = context.format, !format.isInterleaved,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil)
                else { return }
                buffer.frameLength = AVAudioFrameCount(framesOut.pointee)
                context.levels.analyze(buffer, when: AVAudioTime(hostTime: mach_absolute_time()))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr
        else {
            context.release()
            return nil
        }
        return tap
    }
}
