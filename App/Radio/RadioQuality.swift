import Foundation

/// How good a station's stream is, and which of several streams of the same station to play.
enum RadioQuality {
    /// What the user wants when a station offers several streams.
    enum Preference: String, CaseIterable, Identifiable {
        case best, balanced, light

        var id: String { rawValue }
        var name: String {
            switch self {
            case .best: "Best quality"
            case .balanced: "Balanced (up to 128 kbps)"
            case .light: "Light (up to 64 kbps)"
            }
        }
        /// Streams above this bitrate are used only if nothing lighter exists.
        var maxKbps: Int? {
            switch self {
            case .best: nil
            case .balanced: 128
            case .light: 64
            }
        }
    }

    static var preference: Preference {
        get { Preference(rawValue: UserDefaults.standard.string(forKey: "radioQuality") ?? "") ?? .best }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "radioQuality") }
    }

    /// Play the best source of a station automatically instead of the stored one.
    static var autoBest: Bool {
        get { UserDefaults.standard.object(forKey: "radioAutoBest") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "radioAutoBest") }
    }

    // MARK: Scoring

    /// Perceptual weight of a codec against MP3 at the same bitrate.
    private static func codecFactor(_ codec: String) -> Double {
        let c = codec.uppercased()
        if c.contains("FLAC") { return 6 }
        if c.contains("OPUS") { return 1.9 }
        if c.contains("AAC+") || c.contains("AACP") || c.contains("HE-AAC") { return 1.8 }
        if c.contains("AAC") { return 1.4 }
        if c.contains("OGG") || c.contains("VORBIS") { return 1.3 }
        if c.contains("MP3") || c.contains("MPEG") { return 1 }
        return 0.8
    }

    /// Whether the in-app decoder (and so the meters, EQ and device matching) handles the stream.
    static func isNativelyDecodable(_ station: RadioStation) -> Bool {
        if station.hls == 1 { return false }
        let c = (station.codec ?? "").uppercased()
        return c.contains("MP3") || c.contains("AAC") || c.contains("MPEG") || c.isEmpty
    }

    /// Higher is better. Reliability dominates, then codec-weighted bitrate, then how well the
    /// stream plays here, then popularity as a tie-break.
    static func score(_ station: RadioStation, preference: Preference = .best) -> Double {
        let kbps = Double(station.bitrate ?? 0)
        let codec = (station.codec ?? "").uppercased()
        let effective = codec.contains("FLAC") ? 900 : (kbps > 0 ? kbps : 48)
        var value = effective * codecFactor(codec)
        if let cap = preference.maxKbps, kbps > Double(cap) { value *= 0.2 }
        if station.lastcheckok != 1 { value *= 0.05 }
        if !isNativelyDecodable(station) { value *= 0.7 }
        if station.ssl_error == 1 { value *= 0.5 }
        if station.url_resolved.lowercased().hasPrefix("https") { value *= 1.02 }   // wins ties against plain http
        value += log(Double((station.votes ?? 0) + 1)) * 0.01
        return value
    }

    static func ranked(_ stations: [RadioStation], preference: Preference = .best) -> [RadioStation] {
        // The directory often lists the very same URL several times.
        var seen = Set<String>()
        let unique = stations.filter { seen.insert($0.url_resolved).inserted }
        return unique.sorted { score($0, preference: preference) > score($1, preference: preference) }
    }

    static func best(_ stations: [RadioStation], preference: Preference = .best) -> RadioStation? {
        ranked(stations, preference: preference).first
    }

    // MARK: Grouping

    /// Name stripped of quality words and punctuation, so "RTL", "RTL 128k MP3" and
    /// "Rtl (HQ)" are one station.
    static func normalizedName(_ name: String) -> String {
        var text = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        text = text.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b\d{2,3}\s?(k|kbps|kbit|kb)\b"#, with: " ", options: .regularExpression)
        let noise: Set<String> = ["mp3", "aac", "aacp", "flac", "ogg", "opus", "hq", "hd", "lq", "stream", "128", "64", "96", "192",
                                  "256", "320", "32", "48", "high", "quality", "live", "direct"]
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !noise.contains($0) }
        return words.joined(separator: " ")
    }

    static func groupKey(_ station: RadioStation) -> String {
        normalizedName(station.displayName) + "|" + (station.countrycode ?? "").lowercased()
    }

    /// Streams of the same station gathered, each group ranked best first; groups keep the
    /// order in which their first stream appeared.
    static func groups(_ stations: [RadioStation], preference: Preference = .best) -> [[RadioStation]] {
        var order: [String] = []
        var buckets: [String: [RadioStation]] = [:]
        for station in stations {
            let key = groupKey(station)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(station)
        }
        return order.map { ranked(buckets[$0]!, preference: preference) }
    }
}

/// Finds every stream of a station in the directory and picks the best one.
@MainActor
final class RadioResolver {
    static let shared = RadioResolver()
    private var cache: [String: (sources: [RadioStation], date: Date)] = [:]

    /// All known streams of the station, best first (the given one is always included).
    func sources(for station: RadioStation) async -> [RadioStation] {
        let key = RadioQuality.groupKey(station)
        if let hit = cache[key], Date().timeIntervalSince(hit.date) < 3600 { return hit.sources }
        var found = [station]
        if let more = try? await RadioBrowser.shared.search(station.displayName, limit: 80, countryCode: station.countrycode) {
            found += more.filter { RadioQuality.groupKey($0) == key && $0.id != station.id }
        }
        let ranked = RadioQuality.ranked(found, preference: RadioQuality.preference)
        cache[key] = (ranked, Date())
        return ranked
    }

    /// The stream to play for a station: its best source when auto-best is on (waiting at
    /// most `timeout` seconds for the directory), otherwise the station as given.
    func playable(_ station: RadioStation, timeout: Double = 2.5) async -> RadioStation {
        guard RadioQuality.autoBest else { return station }
        let sources = await withTaskGroup(of: [RadioStation]?.self) { group -> [RadioStation] in
            group.addTask { await self.sources(for: station) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            for await result in group {
                group.cancelAll()
                if let result { return result }
                return [station]
            }
            return [station]
        }
        return RadioQuality.best(sources, preference: RadioQuality.preference) ?? station
    }
}
