import Foundation

/// A station from the radio-browser.info community directory.
struct RadioStation: Codable, Identifiable, Hashable, Sendable {
    let stationuuid: String
    let name: String
    let url_resolved: String
    let favicon: String?
    let tags: String?
    let country: String?
    let countrycode: String?
    let codec: String?
    let bitrate: Int?
    let homepage: String?
    /// 1 when the directory's last probe could play the stream.
    let lastcheckok: Int?
    let hls: Int?
    let ssl_error: Int?
    let votes: Int?
    let clickcount: Int?

    var id: String { stationuuid }
    var streamURL: URL? { URL(string: url_resolved) }
    var faviconURL: URL? { favicon.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var tagList: [String] {
        (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var qualityLabel: String {
        let codecName = (codec ?? "").uppercased()
        guard let bitrate, bitrate > 0 else { return codecName }
        return "\(codecName) \(bitrate)k".trimmingCharacters(in: .whitespaces)
    }
}

/// Client for the radio-browser.info API (open, no key). Follows the API's etiquette:
/// a descriptive User-Agent and a click report when a station starts playing.
actor RadioBrowser {
    static let shared = RadioBrowser()

    private var server: URL?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "IdiophileOne/0.1 (+https://github.com/dev-digitaldream/idiophile-one)"]
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config)
    }()

    func popular(limit: Int = 100) async throws -> [RadioStation] {
        try await stations("json/stations/topclick/\(limit)", query: ["hidebroken": "true"])
    }

    func local(countryCode: String, limit: Int = 100) async throws -> [RadioStation] {
        try await stations("json/stations/bycountrycodeexact/\(countryCode)",
                           query: ["order": "clickcount", "reverse": "true", "hidebroken": "true", "limit": "\(limit)"])
    }

    func search(_ text: String, limit: Int = 100, countryCode: String? = nil) async throws -> [RadioStation] {
        var query = ["name": text, "order": "clickcount", "reverse": "true", "hidebroken": "true", "limit": "\(limit)"]
        if let countryCode, !countryCode.isEmpty { query["countrycode"] = countryCode }
        return try await stations("json/stations/search", query: query)
    }

    func byTag(_ tag: String, limit: Int = 100) async throws -> [RadioStation] {
        try await stations("json/stations/bytagexact/\(tag)",
                           query: ["order": "clickcount", "reverse": "true", "hidebroken": "true", "limit": "\(limit)"])
    }

    /// Tells the directory a station was played (keeps its popularity ranking honest).
    func reportClick(_ station: RadioStation) async {
        guard let base = try? await baseURL() else { return }
        _ = try? await session.data(from: base.appendingPathComponent("json/url/\(station.stationuuid)"))
    }

    private func stations(_ path: String, query: [String: String]) async throws -> [RadioStation] {
        var components = URLComponents(url: try await baseURL().appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, _) = try await session.data(from: components.url!)
        return try JSONDecoder().decode([RadioStation].self, from: data)
            .filter { $0.streamURL != nil && !$0.displayName.isEmpty }
    }

    /// Picks one of the mirrors listed by the directory, falling back to a known one.
    private func baseURL() async throws -> URL {
        if let server { return server }
        struct Mirror: Decodable { let name: String }
        let fallback = URL(string: "https://de1.api.radio-browser.info")!
        if let (data, _) = try? await session.data(from: URL(string: "https://all.api.radio-browser.info/json/servers")!),
           let mirrors = try? JSONDecoder().decode([Mirror].self, from: data),
           let pick = mirrors.randomElement(), let url = URL(string: "https://\(pick.name)") {
            server = url
        } else {
            server = fallback
        }
        return server!
    }
}

/// Favourite stations, kept locally.
enum RadioFavorites {
    private static let key = "radioFavorites"

    static func load() -> [RadioStation] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RadioStation].self, from: data)) ?? []
    }

    static func save(_ stations: [RadioStation]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(stations), forKey: key)
    }
}
