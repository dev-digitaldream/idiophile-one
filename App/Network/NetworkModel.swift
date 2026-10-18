import Foundation
import Observation

/// Media servers found on the local network, and the local copies used for playback.
@Observable
@MainActor
final class NetworkModel {
    private(set) var servers: [MediaServer] = []
    private(set) var isSearching = false
    /// Tracks being copied from a server: id → fraction done.
    private(set) var downloads: [String: Double] = [:]

    /// Description URLs of servers added by hand (VPN such as Tailscale, other subnets).
    private(set) var manualLocations: [URL] = (UserDefaults.standard.stringArray(forKey: "manualServers") ?? []).compactMap(URL.init(string:)) {
        didSet { UserDefaults.standard.set(manualLocations.map(\.absoluteString), forKey: "manualServers") }
    }
    private(set) var addError: String?

    /// Adds a server by address ("nas.tailnet.ts.net", "100.64.0.10", "host:port" or a full
    /// description URL), trying the description paths of common servers.
    func addServer(_ address: String) async -> Bool {
        addError = nil
        for location in MediaServer.candidateLocations(for: address) {
            if let server = await MediaServer.load(from: location) {
                if !manualLocations.contains(location) { manualLocations.append(location) }
                servers.removeAll { $0.id == server.id }
                servers.append(server)
                return true
            }
        }
        addError = "No media server answered at \(address). Check the address and that the server's DLNA / UPnP service is on."
        return false
    }

    func removeManual(_ server: MediaServer) {
        manualLocations.removeAll { $0.host == server.controlURL.host }
        servers.removeAll { $0.id == server.id }
    }

    func discover() {
        guard !isSearching else { return }
        isSearching = true
        Task {
            let locations = await SSDP.discoverMediaServers() + manualLocations
            var found: [MediaServer] = []
            await withTaskGroup(of: MediaServer?.self) { group in
                for location in locations { group.addTask { await MediaServer.load(from: location) } }
                for await server in group { if let server, !found.contains(where: { $0.id == server.id }) { found.append(server) } }
            }
            servers = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            isSearching = false
        }
    }

    // MARK: Local copies

    /// Network files play from a local copy, so the engine reads them exactly like library
    /// files (bit-perfect, gapless, seekable). Copies are cached and pruned beyond 4 GB.
    private nonisolated static let cacheLimit: Int64 = 4 << 30
    private let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Idiophile One/Network", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func localCopy(of track: NetworkTrack) async throws -> URL {
        let folder = directory.appendingPathComponent(Self.hash(track.resource.absoluteString), isDirectory: true)
        let name = Self.safeName([track.artist, track.title].compactMap { $0 }.joined(separator: " - "))
        let file = folder.appendingPathComponent(name).appendingPathExtension(track.fileExtension)
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { return file }

        downloads[track.id] = 0
        defer { downloads[track.id] = nil }
        let (temporary, response) = try await URLSession.shared.download(from: track.resource)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            throw URLError(.badServerResponse)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
        let keep = protectedPaths()
        Task.detached(priority: .background) { [directory] in Self.prune(directory, keeping: keep) }
        return file
    }

    /// Paths that must survive pruning (the tracks in the play queue), supplied by the player.
    var protectedPaths: () -> Set<String> = { [] }

    private nonisolated static func prune(_ directory: URL, keeping protected: Set<String>) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(URL, Int64, Date)] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files.append((url, Int64(v.fileSize ?? 0), v.contentAccessDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.1 }
        for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) where total > cacheLimit && !protected.contains(url.path) {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    private nonisolated static func safeName(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: " ")
        return String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "track"
    }

    private nonisolated static func hash(_ key: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
