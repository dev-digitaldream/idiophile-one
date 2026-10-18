import AppKit
import AVFoundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// The library as the UI sees it: folders, scan state, and a revision that changes after
/// every scan so views reload.
@Observable
@MainActor
final class LibraryModel {
    private(set) var roots: [URL] = (UserDefaults.standard.stringArray(forKey: "libraryRoots") ?? []).map {
        URL(fileURLWithPath: $0)
    } {
        didSet { UserDefaults.standard.set(roots.map(\.path), forKey: "libraryRoots") }
    }
    private(set) var isScanning = false
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    private(set) var revision = 0
    private(set) var counts: (albums: Int, tracks: Int) = (0, 0)
    private(set) var lastError: String?
    private(set) var isAnalyzing = false
    private(set) var analysisProgress: (done: Int, total: Int) = (0, 0)
    @ObservationIgnored private var analysisTask: Task<Void, Never>?

    let database: LibraryDatabase?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Idiophile One", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        database = try? LibraryDatabase(url: dir.appendingPathComponent("library.sqlite"))
        if let database { Task { await LoudnessCache.shared.reload(from: database) } }
        if !roots.isEmpty { rescan() }
        Task { await refreshCounts() }
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        guard panel.runModal() == .OK else { return }
        roots = Array(Set(roots + panel.urls)).sorted { $0.path < $1.path }
        rescan()
    }

    func removeFolder(_ url: URL) {
        roots.removeAll { $0 == url }
        rescan()
    }

    func rescan() {
        guard let database, !isScanning else { return }
        isScanning = true
        lastError = nil
        let roots = roots
        Task {
            do {
                _ = try await database.scan(roots: roots) { done, total in
                    Task { @MainActor in self.progress = (done, total) }
                }
            } catch {
                lastError = "\(error)"
            }
            isScanning = false
            await refreshCounts()
            revision += 1
            analyzeLoudness()
        }
    }

    /// Measures the loudness (EBU R128) of tracks that carry no ReplayGain tags, album by
    /// album, at background priority. Results live in the library database, not in the files.
    func analyzeLoudness() {
        guard let database, !isAnalyzing else { return }
        isAnalyzing = true
        analysisTask = Task {
            let pending = (try? await database.albumsNeedingLoudness()) ?? []
            analysisProgress = (0, pending.count)
            for (n, album) in pending.enumerated() {
                if Task.isCancelled { break }
                let results = await Task.detached(priority: .background) { Self.analyze(album.tracks) }.value
                if !results.isEmpty { try? await database.store(results) }
                analysisProgress = (n + 1, pending.count)
            }
            await LoudnessCache.shared.reload(from: database)
            isAnalyzing = false
        }
    }

    func cancelAnalysis() { analysisTask?.cancel() }

    /// One album: every track measured, then the album figure over all their blocks.
    private nonisolated static func analyze(_ tracks: [LibraryDatabase.PendingTrack]) -> [LibraryDatabase.LoudnessResult] {
        let measured = tracks.map { ($0, LoudnessAnalyzer.analyze(url: URL(fileURLWithPath: $0.path))) }
        let albumBlocks = measured.flatMap { $0.1?.blocks ?? [] }
        let albumLUFS = LoudnessMeter.integratedLUFS(blocks: albumBlocks)
        let albumPeak = measured.map { Double($0.1?.samplePeak ?? 0) }.max() ?? 0
        return measured.compactMap { track, loudness in
            loudness.map {
                LibraryDatabase.LoudnessResult(path: track.path, modified: track.modified, lufs: $0.lufs, peak: Double($0.samplePeak),
                                               albumLUFS: albumLUFS, albumPeak: albumPeak)
            }
        }
    }

    private func refreshCounts() async {
        if let counts = try? await database?.counts() { self.counts = counts }
    }
}

/// Album covers: embedded FLAC picture, a cover file in the folder, or AVFoundation
/// metadata; scaled to thumbnails and cached in memory and on disk.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL
    private var missing = Set<String>()

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Idiophile One/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 600
    }

    func cached(_ key: String) -> NSImage? { memory.object(forKey: key as NSString) }

    func image(albumKey key: String, samplePath: String, size: Int = 512) async -> NSImage? {
        if let image = memory.object(forKey: key as NSString) { return image }
        if missing.contains(key) { return nil }
        let file = directory.appendingPathComponent(Self.hash(key) + ".jpg")
        if let image = NSImage(contentsOf: file) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        let url = URL(fileURLWithPath: samplePath)
        var data = await Task.detached(priority: .utility) { Self.localArtwork(for: url) }.value
        if data == nil {
            let asset = AVURLAsset(url: url)
            if let items = try? await asset.load(.commonMetadata) {
                data = try? await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork)
                    .first?.load(.dataValue)
            }
        }
        guard let data, let thumbnail = await Task.detached(priority: .utility, operation: {
            Self.thumbnail(data, size: size, writeTo: file)
        }).value else {
            missing.insert(key)
            return nil
        }
        memory.setObject(thumbnail, forKey: key as NSString)
        return thumbnail
    }

    private nonisolated static func localArtwork(for url: URL) -> Data? {
        if url.pathExtension.lowercased() == "flac", let picture = FLACMetadata(url: url)?.picture { return picture }
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let match = names.first { name in
            let lower = name.lowercased()
            return ["cover", "folder", "front", "albumart"].contains(where: lower.hasPrefix)
                && ["jpg", "jpeg", "png"].contains((lower as NSString).pathExtension)
        }
        return match.flatMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
    }

    private nonisolated static func thumbnail(_ data: Data, size: Int, writeTo file: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: size,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Stable file name for a key (FNV-1a 64).
    private nonisolated static func hash(_ key: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// Analysed loudness by file path, read by the player when a file carries no tags.
@MainActor
final class LoudnessCache {
    static let shared = LoudnessCache()
    private var tags: [String: ReplayGainTags] = [:]

    func tags(for url: URL) -> ReplayGainTags? { tags[url.path] }

    func reload(from database: LibraryDatabase) async {
        tags = (try? await database.loudnessTags()) ?? tags
    }
}
