import AudioToolbox
import Foundation

/// Everything the library stores about one file.
struct ScannedTrack: Sendable {
    var path: String
    var modified: Double
    var size: Int64
    var title: String
    var artist: String?
    var albumArtist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: Double
    var sampleRate: Double
    var bits: Int?
    var channels: Int
    var codec: String
    var lossless: Bool
    var replayGain: ReplayGainTags
}

/// Fast, synchronous tag and format reader for the scanner: FLAC Vorbis comments through
/// `FLACMetadata`, everything else through the AudioFile info dictionary (no AVAsset load).
enum TagReader {
    static func read(_ url: URL, modified: Double, size: Int64) -> ScannedTrack? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return nil }
        defer { AudioFileClose(fileID) }

        var asbd = AudioStreamBasicDescription()
        var size32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &size32, &asbd) == noErr, asbd.mSampleRate > 0
        else { return nil }

        var duration: Float64 = 0
        size32 = UInt32(MemoryLayout<Float64>.size)
        AudioFileGetProperty(fileID, kAudioFilePropertyEstimatedDuration, &size32, &duration)

        var info: Unmanaged<CFDictionary>?
        size32 = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        AudioFileGetProperty(fileID, kAudioFilePropertyInfoDictionary, &size32, &info)
        let dict = (info?.takeRetainedValue() as? [String: Any]) ?? [:]
        func tag(_ key: String) -> String? {
            (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        let (codec, lossless, bits) = format(asbd, ext: url.pathExtension)
        var track = ScannedTrack(
            path: url.path, modified: modified, size: size,
            title: tag(kAFInfoDictionary_Title) ?? url.deletingPathExtension().lastPathComponent,
            artist: tag(kAFInfoDictionary_Artist), albumArtist: nil, album: tag(kAFInfoDictionary_Album),
            composer: tag(kAFInfoDictionary_Composer), genre: tag(kAFInfoDictionary_Genre),
            year: tag(kAFInfoDictionary_Year).flatMap { Int($0.prefix(4)) },
            trackNumber: tag(kAFInfoDictionary_TrackNumber).flatMap(FLACMetadata.leadingInt),
            discNumber: nil,
            duration: duration, sampleRate: asbd.mSampleRate, bits: bits, channels: Int(asbd.mChannelsPerFrame),
            codec: codec, lossless: lossless, replayGain: ReplayGainTags())

        if asbd.mFormatID == kAudioFormatFLAC, let flac = FLACMetadata(url: url) {
            track.title = flac.title ?? track.title
            track.artist = flac.artist ?? track.artist
            track.albumArtist = flac.albumArtist
            track.album = flac.album ?? track.album
            track.composer = flac.composer ?? track.composer
            track.genre = flac.genre ?? track.genre
            track.year = flac.year ?? track.year
            track.trackNumber = flac.trackNumber ?? track.trackNumber
            track.discNumber = flac.discNumber
            track.replayGain = flac.replayGain
        }
        return track
    }

    private static func format(_ asbd: AudioStreamBasicDescription, ext: String) -> (String, Bool, Int?) {
        let lossless = { (flags: AudioFormatFlags) in [1: 16, 2: 20, 3: 24, 4: 32][flags] }
        switch asbd.mFormatID {
        case kAudioFormatFLAC: return ("FLAC", true, lossless(asbd.mFormatFlags))
        case kAudioFormatAppleLossless: return ("ALAC", true, lossless(asbd.mFormatFlags))
        case kAudioFormatLinearPCM: return (ext.uppercased(), true, Int(asbd.mBitsPerChannel))
        case kAudioFormatMPEGLayer3: return ("MP3", false, nil)
        case kAudioFormatMPEG4AAC: return ("AAC", false, nil)
        case kAudioFormatOpus: return ("OPUS", false, nil)
        default: return (ext.uppercased(), false, nil)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
