import Foundation

/// Minimal reader for FLAC metadata blocks: Vorbis comments and embedded pictures.
/// AVFoundation decodes FLAC audio but exposes none of these tags.
struct FLACMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var picture: Data?
    var replayGain = ReplayGainTags()
    var albumArtist: String?
    var composer: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?

    private static let vorbisComment: UInt8 = 4
    private static let pictureBlock: UInt8 = 6
    private static let frontCover: UInt32 = 3

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }

        var fallbackPicture: Data?
        var isLast = false
        while !isLast {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])

            switch type {
            case Self.vorbisComment:
                guard let block = try? handle.read(upToCount: length) else { return }
                parseComments(block)
            case Self.pictureBlock:
                guard let block = try? handle.read(upToCount: length),
                      let (kind, data) = Self.parsePicture(block) else { continue }
                if kind == Self.frontCover { picture = data } else if fallbackPicture == nil { fallbackPicture = data }
            default:
                guard (try? handle.seek(toOffset: handle.offsetInFile + UInt64(length))) != nil else { return }
            }
        }
        if picture == nil { picture = fallbackPicture }
    }

    private mutating func parseComments(_ block: Data) {
        var reader = ByteReader(data: block)
        guard let vendorLength = reader.uint32LE(), reader.skip(Int(vendorLength)),
              let count = reader.uint32LE() else { return }
        var artists: [String] = []
        for _ in 0..<count {
            guard let length = reader.uint32LE(), let bytes = reader.bytes(Int(length)),
                  let entry = String(data: bytes, encoding: .utf8),
                  let eq = entry.firstIndex(of: "=") else { return }
            let key = entry[..<eq].uppercased()
            let value = String(entry[entry.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "TITLE": title = title ?? value
            case "ARTIST": artists.append(value)
            case "ALBUM": album = album ?? value
            case "ALBUMARTIST", "ALBUM ARTIST": albumArtist = albumArtist ?? value
            case "COMPOSER": composer = composer ?? value
            case "GENRE": genre = genre ?? value
            case "DATE", "YEAR": year = year ?? Int(value.prefix(4))
            case "TRACKNUMBER": trackNumber = trackNumber ?? Self.leadingInt(value)
            case "DISCNUMBER": discNumber = discNumber ?? Self.leadingInt(value)
            case "REPLAYGAIN_TRACK_GAIN": replayGain.trackGain = Self.number(value)
            case "REPLAYGAIN_ALBUM_GAIN": replayGain.albumGain = Self.number(value)
            case "REPLAYGAIN_TRACK_PEAK": replayGain.trackPeak = Self.number(value)
            case "REPLAYGAIN_ALBUM_PEAK": replayGain.albumPeak = Self.number(value)
            default: break
            }
        }
        if !artists.isEmpty { artist = artists.joined(separator: ", ") }
    }

    /// "3/12" → 3.
    static func leadingInt(_ value: String) -> Int? {
        Int(value.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? value)
    }

    /// Leading number of a tag value such as "-6.54 dB".
    private static func number(_ value: String) -> Float? {
        Float(value.split(separator: " ").first.map(String.init) ?? value)
    }

    private static func parsePicture(_ block: Data) -> (UInt32, Data)? {
        var reader = ByteReader(data: block)
        guard let kind = reader.uint32BE(),
              let mimeLength = reader.uint32BE(), reader.skip(Int(mimeLength)),
              let descLength = reader.uint32BE(), reader.skip(Int(descLength)),
              reader.skip(16), // width, height, depth, colours
              let dataLength = reader.uint32BE(),
              let data = reader.bytes(Int(dataLength)) else { return nil }
        return (kind, data)
    }
}

/// ReplayGain 2.0 values from the file tags.
struct ReplayGainTags: Equatable {
    var trackGain: Float?
    var albumGain: Float?
    var trackPeak: Float?
    var albumPeak: Float?
}

/// Loudness normalisation: off, per track, or per album (keeps an album's dynamics).
enum ReplayGainMode: String, CaseIterable, Identifiable {
    case off, track, album

    var id: String { rawValue }
    var name: String {
        switch self {
        case .off: "Off"
        case .track: "Track"
        case .album: "Album"
        }
    }

    /// Gain to apply in dB, limited so the tagged peak never exceeds full scale.
    func gain(for tags: ReplayGainTags?) -> Float? {
        guard self != .off, let tags else { return nil }
        let album = self == .album
        guard var gain = album ? (tags.albumGain ?? tags.trackGain) : (tags.trackGain ?? tags.albumGain) else { return nil }
        if let peak = album ? (tags.albumPeak ?? tags.trackPeak) : (tags.trackPeak ?? tags.albumPeak), peak > 0 {
            gain = min(gain, -20 * log10(peak))
        }
        return gain
    }
}

private struct ByteReader {
    let data: Data
    var offset = 0

    init(data: Data) { self.data = Data(data) }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func skip(_ count: Int) -> Bool { bytes(count) != nil }

    mutating func uint32LE() -> UInt32? {
        bytes(4).map { $0.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
    }

    mutating func uint32BE() -> UInt32? {
        bytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
    }
}
