import Foundation
import UniformTypeIdentifiers

struct LibraryTrack: Identifiable, Hashable, Sendable {
    let id: Int64
    let path: String
    let title: String
    let artist: String?
    let album: String?
    let composer: String?
    let year: Int?
    let trackNumber: Int?
    let discNumber: Int?
    let duration: Double
    let sampleRate: Double
    let bits: Int?
    let codec: String
    let albumKey: String

    var url: URL { URL(fileURLWithPath: path) }
}

struct LibraryAlbum: Identifiable, Hashable, Sendable {
    let key: String
    let title: String
    let artist: String
    let year: Int?
    let trackCount: Int
    let duration: Double
    let sampleRate: Double
    let bits: Int?
    let codec: String
    /// A file of the album, used to find its artwork.
    let samplePath: String
    let added: Double

    var id: String { key }

    var formatLabel: String {
        let khz = sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? String(format: "%.0f", sampleRate / 1000) : String(format: "%.1f", sampleRate / 1000)
        return bits.map { "\(codec) \($0)/\(khz)" } ?? "\(codec) \(khz)k"
    }

    var isHighResolution: Bool { sampleRate > 48000 || (bits ?? 0) > 16 }
}

/// A name with counts: artist, composer or genre.
struct LibraryGroup: Identifiable, Hashable, Sendable {
    let name: String
    let albums: Int
    let tracks: Int
    var id: String { name }
}

enum AlbumSort: String, CaseIterable, Identifiable, Sendable {
    case artist, title, year, added
    var id: String { rawValue }
    var name: String {
        switch self {
        case .artist: "Artist"
        case .title: "Title"
        case .year: "Year"
        case .added: "Recently Added"
        }
    }
}

enum AlbumFilter: Hashable, Sendable {
    case all, artist(String), composer(String), genre(String)
}

/// The music library database. All SQLite access happens on this actor.
actor LibraryDatabase {
    private let db: SQLiteDatabase

    init(url: URL) throws {
        db = try SQLiteDatabase(path: url.path)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS tracks(
                id INTEGER PRIMARY KEY,
                path TEXT UNIQUE NOT NULL, modified REAL, size INTEGER,
                title TEXT NOT NULL, artist TEXT, album_artist TEXT, album TEXT, composer TEXT, genre TEXT,
                year INTEGER, track_no INTEGER, disc_no INTEGER,
                duration REAL, sample_rate REAL, bits INTEGER, channels INTEGER, codec TEXT, lossless INTEGER,
                rg_track REAL, rg_album REAL, rg_track_peak REAL, rg_album_peak REAL,
                album_key TEXT NOT NULL, added REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS tracks_album ON tracks(album_key);
            CREATE INDEX IF NOT EXISTS tracks_artist ON tracks(COALESCE(album_artist, artist));
            CREATE INDEX IF NOT EXISTS tracks_composer ON tracks(composer);
            CREATE INDEX IF NOT EXISTS tracks_genre ON tracks(genre);
            CREATE TABLE IF NOT EXISTS loudness(
                path TEXT PRIMARY KEY, modified REAL, lufs REAL, peak REAL, album_lufs REAL, album_peak REAL);
            CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5(
                title, artist, album, composer, content='tracks', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS tracks_ai AFTER INSERT ON tracks BEGIN
                INSERT INTO tracks_fts(rowid, title, artist, album, composer) VALUES (new.id, new.title, new.artist, new.album, new.composer);
            END;
            CREATE TRIGGER IF NOT EXISTS tracks_ad AFTER DELETE ON tracks BEGIN
                INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album, composer) VALUES ('delete', old.id, old.title, old.artist, old.album, old.composer);
            END;
            CREATE TRIGGER IF NOT EXISTS tracks_au AFTER UPDATE ON tracks BEGIN
                INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album, composer) VALUES ('delete', old.id, old.title, old.artist, old.album, old.composer);
                INSERT INTO tracks_fts(rowid, title, artist, album, composer) VALUES (new.id, new.title, new.artist, new.album, new.composer);
            END;
            """)
    }

    // MARK: Scanning

    struct ScanResult: Sendable {
        var added = 0, updated = 0, removed = 0, unreadable = 0
    }

    /// Incremental scan: only new or changed files are read; vanished files are removed.
    func scan(roots: [URL], progress: @Sendable (Int, Int) -> Void) throws -> ScanResult {
        var result = ScanResult()
        let known = Dictionary(uniqueKeysWithValues: try db.query("SELECT path, modified, size FROM tracks").compactMap { row in
            row[0].string.map { ($0, (row[1].double ?? 0, row[2].int ?? 0)) }
        })
        let files = roots.flatMap(Self.audioFiles)
        var seen = Set<String>()
        try db.execute("BEGIN")
        for (n, file) in files.enumerated() {
            seen.insert(file.url.path)
            if let previous = known[file.url.path], previous.0 == file.modified, Int64(previous.1) == file.size { continue }
            guard let track = TagReader.read(file.url, modified: file.modified, size: file.size) else {
                result.unreadable += 1
                continue
            }
            try upsert(track)
            if known[file.url.path] == nil { result.added += 1 } else { result.updated += 1 }
            if n % 200 == 0 {
                try db.execute("COMMIT; BEGIN")
                progress(n, files.count)
            }
        }
        // Remove tracks under the roots whose files are gone, and tracks of removed roots.
        let rootPaths = roots.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        for path in known.keys where !seen.contains(path) {
            if !rootPaths.contains(where: path.hasPrefix) || !FileManager.default.fileExists(atPath: path) {
                try db.query("DELETE FROM tracks WHERE path = ?", [.text(path)])
                result.removed += 1
            }
        }
        try db.execute("COMMIT")
        progress(files.count, files.count)
        return result
    }

    private func upsert(_ t: ScannedTrack) throws {
        let groupArtist = (t.albumArtist ?? t.artist ?? "").lowercased()
        let key = t.album.map { "\(groupArtist)|\($0.lowercased())" }
            ?? "folder:" + URL(fileURLWithPath: t.path).deletingLastPathComponent().path
        try db.query("""
            INSERT INTO tracks(path, modified, size, title, artist, album_artist, album, composer, genre, year, track_no, disc_no,
                               duration, sample_rate, bits, channels, codec, lossless, rg_track, rg_album, rg_track_peak, rg_album_peak,
                               album_key, added)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                modified=excluded.modified, size=excluded.size, title=excluded.title, artist=excluded.artist,
                album_artist=excluded.album_artist, album=excluded.album, composer=excluded.composer, genre=excluded.genre,
                year=excluded.year, track_no=excluded.track_no, disc_no=excluded.disc_no, duration=excluded.duration,
                sample_rate=excluded.sample_rate, bits=excluded.bits, channels=excluded.channels, codec=excluded.codec,
                lossless=excluded.lossless, rg_track=excluded.rg_track, rg_album=excluded.rg_album,
                rg_track_peak=excluded.rg_track_peak, rg_album_peak=excluded.rg_album_peak, album_key=excluded.album_key
            """, [
                .text(t.path), .double(t.modified), .int(t.size), .text(t.title), .init(t.artist), .init(t.albumArtist),
                .init(t.album), .init(t.composer), .init(t.genre), .init(t.year), .init(t.trackNumber), .init(t.discNumber),
                .double(t.duration), .double(t.sampleRate), .init(t.bits), .int(Int64(t.channels)), .text(t.codec),
                .int(t.lossless ? 1 : 0), .init(t.replayGain.trackGain), .init(t.replayGain.albumGain),
                .init(t.replayGain.trackPeak), .init(t.replayGain.albumPeak), .text(key), .double(Date().timeIntervalSince1970),
            ])
    }

    private struct FoundFile { let url: URL; let modified: Double; let size: Int64 }

    private static func audioFiles(under root: URL) -> [FoundFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .typeIdentifierKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [FoundFile] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let type = values.typeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .audio) else { continue }
            files.append(FoundFile(url: url, modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                   size: Int64(values.fileSize ?? 0)))
        }
        return files
    }

    // MARK: Queries

    private static let albumColumns = """
        album_key, COALESCE(MAX(album), '(Untitled)'),
        COALESCE(MAX(album_artist), CASE WHEN COUNT(DISTINCT artist) > 1 THEN 'Various Artists' ELSE MAX(artist) END, 'Unknown Artist'),
        MAX(year), COUNT(*), SUM(duration), MAX(sample_rate), MAX(bits), MIN(codec), MIN(path), MAX(added)
        """

    func albums(filter: AlbumFilter = .all, sort: AlbumSort = .artist, limit: Int? = nil) throws -> [LibraryAlbum] {
        var sql = "SELECT \(Self.albumColumns) FROM tracks"
        var values: [SQLiteDatabase.Value] = []
        switch filter {
        case .all: break
        case .artist(let name):
            sql += " WHERE album_key IN (SELECT album_key FROM tracks WHERE COALESCE(album_artist, artist) = ? OR artist = ?)"
            values = [.text(name), .text(name)]
        case .composer(let name):
            sql += " WHERE album_key IN (SELECT album_key FROM tracks WHERE composer = ?)"
            values = [.text(name)]
        case .genre(let name):
            sql += " WHERE album_key IN (SELECT album_key FROM tracks WHERE genre = ?)"
            values = [.text(name)]
        }
        sql += " GROUP BY album_key ORDER BY " + {
            switch sort {
            case .artist: "3 COLLATE NOCASE, 4, 2 COLLATE NOCASE"
            case .title: "2 COLLATE NOCASE"
            case .year: "4 DESC, 3 COLLATE NOCASE"
            case .added: "11 DESC"
            }
        }()
        if let limit { sql += " LIMIT \(limit)" }
        return try db.query(sql, values).map(Self.album)
    }

    func album(key: String) throws -> LibraryAlbum? {
        try db.query("SELECT \(Self.albumColumns) FROM tracks WHERE album_key = ? GROUP BY album_key", [.text(key)]).first.map(Self.album)
    }

    private static let trackColumns = """
        id, path, title, artist, album, composer, year, track_no, disc_no, duration, sample_rate, bits, codec, album_key
        """

    func tracks(albumKey: String) throws -> [LibraryTrack] {
        try db.query("SELECT \(Self.trackColumns) FROM tracks WHERE album_key = ? ORDER BY COALESCE(disc_no, 1), track_no, path",
                     [.text(albumKey)]).map(Self.track)
    }

    func allTracks() throws -> [LibraryTrack] {
        try db.query("""
            SELECT \(Self.trackColumns) FROM tracks
            ORDER BY COALESCE(album_artist, artist) COLLATE NOCASE, album COLLATE NOCASE, COALESCE(disc_no, 1), track_no
            """).map(Self.track)
    }

    func groups(_ column: String) throws -> [LibraryGroup] {
        precondition(["artist", "composer", "genre"].contains(column))
        let expr = column == "artist" ? "COALESCE(album_artist, artist)" : column
        return try db.query("""
            SELECT \(expr) AS name, COUNT(DISTINCT album_key), COUNT(*) FROM tracks
            WHERE name IS NOT NULL AND name != '' GROUP BY name ORDER BY name COLLATE NOCASE
            """).compactMap { row in
            row[0].string.map { LibraryGroup(name: $0, albums: row[1].int ?? 0, tracks: row[2].int ?? 0) }
        }
    }

    /// Full-text search over titles, artists, albums and composers (prefix match per word).
    func search(_ text: String) throws -> (albums: [LibraryAlbum], tracks: [LibraryTrack]) {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
        guard !words.isEmpty else { return ([], []) }
        let match = words.joined(separator: " ")
        let tracks = try db.query("""
            SELECT \(Self.trackColumns.split(separator: ",").map { "t." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
            FROM tracks_fts JOIN tracks t ON t.id = tracks_fts.rowid WHERE tracks_fts MATCH ? ORDER BY rank LIMIT 200
            """, [.text(match)]).map(Self.track)
        let keys = Array(Set(tracks.map(\.albumKey)))
        guard !keys.isEmpty else { return ([], tracks) }
        let albums = try db.query("""
            SELECT \(Self.albumColumns) FROM tracks WHERE album_key IN (\(keys.map { _ in "?" }.joined(separator: ",")))
            GROUP BY album_key ORDER BY 3 COLLATE NOCASE, 2 COLLATE NOCASE
            """, keys.map { .text($0) }).map(Self.album)
        return (albums, tracks)
    }

    // MARK: Loudness

    struct PendingTrack: Sendable {
        let path: String
        let modified: Double
    }

    /// Albums with at least one track that has neither file tags nor an up-to-date analysis.
    func albumsNeedingLoudness() throws -> [(key: String, tracks: [PendingTrack])] {
        let rows = try db.query("""
            SELECT t.album_key, t.path, t.modified FROM tracks t
            WHERE t.album_key IN (
                SELECT t2.album_key FROM tracks t2
                LEFT JOIN loudness l2 ON l2.path = t2.path AND l2.modified = t2.modified
                WHERE l2.path IS NULL AND (t2.rg_track IS NULL OR t2.rg_album IS NULL))
            ORDER BY t.album_key, COALESCE(t.disc_no, 1), t.track_no, t.path
            """)
        var grouped: [(key: String, tracks: [PendingTrack])] = []
        for row in rows {
            guard let key = row[0].string, let path = row[1].string else { continue }
            let track = PendingTrack(path: path, modified: row[2].double ?? 0)
            if grouped.last?.key == key { grouped[grouped.count - 1].tracks.append(track) } else { grouped.append((key, [track])) }
        }
        return grouped
    }

    struct LoudnessResult: Sendable {
        let path: String
        let modified: Double
        let lufs: Double?
        let peak: Double
        let albumLUFS: Double?
        let albumPeak: Double
    }

    func store(_ results: [LoudnessResult]) throws {
        try db.execute("BEGIN")
        for r in results {
            try db.query("INSERT OR REPLACE INTO loudness(path, modified, lufs, peak, album_lufs, album_peak) VALUES (?,?,?,?,?,?)",
                         [.text(r.path), .double(r.modified), r.lufs.map { .double($0) } ?? .null, .double(r.peak),
                          r.albumLUFS.map { .double($0) } ?? .null, .double(r.albumPeak)])
        }
        try db.execute("COMMIT")
    }

    /// Analysed loudness as ReplayGain 2.0 values, keyed by file path.
    func loudnessTags() throws -> [String: ReplayGainTags] {
        var map: [String: ReplayGainTags] = [:]
        let rows = try db.query("""
            SELECT l.path, l.lufs, l.peak, l.album_lufs, l.album_peak FROM loudness l
            JOIN tracks t ON t.path = l.path AND t.modified = l.modified
            """)
        for row in rows {
            guard let path = row[0].string else { continue }
            map[path] = ReplayGainTags(
                trackGain: row[1].double.map { LoudnessAnalyzer.gain(forLUFS: $0) },
                albumGain: row[3].double.map { LoudnessAnalyzer.gain(forLUFS: $0) },
                trackPeak: row[2].double.map { Float($0) }, albumPeak: row[4].double.map { Float($0) })
        }
        return map
    }

    func counts() throws -> (albums: Int, tracks: Int) {
        let row = try db.query("SELECT COUNT(DISTINCT album_key), COUNT(*) FROM tracks").first
        return (row?[0].int ?? 0, row?[1].int ?? 0)
    }

    private static func album(_ r: [SQLiteDatabase.Value]) -> LibraryAlbum {
        LibraryAlbum(key: r[0].string ?? "", title: r[1].string ?? "", artist: r[2].string ?? "", year: r[3].int,
                     trackCount: r[4].int ?? 0, duration: r[5].double ?? 0, sampleRate: r[6].double ?? 0, bits: r[7].int,
                     codec: r[8].string ?? "", samplePath: r[9].string ?? "", added: r[10].double ?? 0)
    }

    private static func track(_ r: [SQLiteDatabase.Value]) -> LibraryTrack {
        LibraryTrack(id: Int64(r[0].int ?? 0), path: r[1].string ?? "", title: r[2].string ?? "", artist: r[3].string,
                     album: r[4].string, composer: r[5].string, year: r[6].int, trackNumber: r[7].int, discNumber: r[8].int,
                     duration: r[9].double ?? 0, sampleRate: r[10].double ?? 0, bits: r[11].int, codec: r[12].string ?? "",
                     albumKey: r[13].string ?? "")
    }
}
