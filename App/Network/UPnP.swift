import Darwin
import Foundation

// MARK: - Minimal XML tree

/// Small DOM built with XMLParser; enough for UPnP device descriptions, SOAP and DIDL-Lite.
final class UPnPXML {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [UPnPXML] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Name without namespace prefix ("dc:title" → "title").
    var localName: Substring { name.split(separator: ":").last ?? Substring(name) }

    func child(_ local: String) -> UPnPXML? { children.first { $0.localName == local } }
    func children(_ local: String) -> [UPnPXML] { children.filter { $0.localName == local } }
    func value(_ local: String) -> String? { child(local)?.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }

    /// First descendant with this local name, depth first.
    func find(_ local: String) -> UPnPXML? {
        for child in children {
            if child.localName == local { return child }
            if let found = child.find(local) { return found }
        }
        return nil
    }

    static func parse(_ data: Data) -> UPnPXML? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: UPnPXML?
        var stack: [UPnPXML] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let element = UPnPXML(name: name, attributes: attributes)
            stack.last?.children.append(element)
            if root == nil { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}

// MARK: - Discovery

/// SSDP (UPnP discovery): multicast M-SEARCH, unicast replies carry the device description URL.
enum SSDP {
    static func discoverMediaServers(timeout: TimeInterval = 3) async -> [URL] {
        await Task.detached(priority: .userInitiated) { search(timeout: timeout) }.value
    }

    private static func search(timeout: TimeInterval) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var wait = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        destination.sin_addr.s_addr = inet_addr("239.255.255.250")

        for target in ["urn:schemas-upnp-org:device:MediaServer:1", "urn:schemas-upnp-org:service:ContentDirectory:1"] {
            let message = """
                M-SEARCH * HTTP/1.1\r
                HOST: 239.255.255.250:1900\r
                MAN: "ssdp:discover"\r
                MX: 2\r
                ST: \(target)\r
                USER-AGENT: macOS UPnP/1.1 IdiophileOne/0.1\r
                \r

                """
            _ = message.withCString { text in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, text, strlen(text), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var locations: [URL] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0, let reply = String(bytes: buffer[0..<n], encoding: .utf8) else { continue }
            for line in reply.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: value), !locations.contains(url) { locations.append(url) }
            }
        }
        return locations
    }
}

// MARK: - Media servers

struct MediaServer: Identifiable, Hashable, Sendable {
    let id: String          // UDN
    let name: String
    let model: String?
    let iconURL: URL?
    let controlURL: URL     // ContentDirectory control endpoint
    /// The server answered but refuses this Mac (e.g. QNAP's media receiver allow list).
    var accessDenied = false

    /// Reads a device description and keeps it if it offers a ContentDirectory.
    static func load(from location: URL) async -> MediaServer? {
        guard let (data, response) = try? await URLSession.shared.data(from: location),
              let root = UPnPXML.parse(data) else { return nil }
        if (response as? HTTPURLResponse)?.statusCode != 200 || root.find("Fault") != nil {
            let denied = root.find("errorCode")?.text == "401" || (response as? HTTPURLResponse)?.statusCode == 401
            guard denied else { return nil }
            return MediaServer(id: location.absoluteString, name: location.host ?? "Media server", model: nil,
                               iconURL: nil, controlURL: location, accessDenied: true)
        }
        guard let device = root.find("device") else { return nil }
        let base = root.value("URLBase").flatMap(URL.init(string:)) ?? location
        let services = device.find("serviceList")?.children("service") ?? []
        guard let directory = services.first(where: { ($0.value("serviceType") ?? "").contains("ContentDirectory") }),
              let control = directory.value("controlURL"), let controlURL = URL(string: control, relativeTo: base)?.absoluteURL
        else { return nil }
        let icon = device.find("iconList")?.children("icon")
            .max { Int($0.value("width") ?? "0") ?? 0 < Int($1.value("width") ?? "0") ?? 0 }?
            .value("url").flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        var server = MediaServer(id: device.value("UDN") ?? location.absoluteString,
                                 name: device.value("friendlyName") ?? location.host ?? "Media Server",
                                 model: [device.value("manufacturer"), device.value("modelName")].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
                                 iconURL: icon, controlURL: controlURL)
        // Some devices advertise a ContentDirectory that does not work (QNAP's QTS UPnP
        // service answers 404): keep only servers that can browse, flag those that refuse us.
        switch await ContentDirectory.probe(server) {
        case .ok: return server
        case .denied:
            server.accessDenied = true
            return server
        case .broken: return nil
        }
    }

    /// Description URLs used by common servers, tried for an address typed by the user.
    static func candidateLocations(for input: String) -> [URL] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://"), let url = URL(string: text), url.path.count > 1 { return [url] }
        let host = text.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
            .split(separator: "/").first.map(String.init) ?? text
        let hasPort = host.contains(":") && !host.contains("]")
        let paths = [
            ":8200/rootDesc.xml",               // QNAP DLNA Media Server, MiniDLNA / ReadyMedia
            ":9000/dev0/desc.xml",              // Twonky
            ":50001/desc/device.xml",           // Synology Media Server
            ":32469/DeviceDescription.xml",     // Plex
            ":8096/dlna/description.xml",       // Jellyfin
            ":49152/description.xml",           // Asset UPnP and others
        ]
        if hasPort {
            return ["/rootDesc.xml", "/description.xml", "/DeviceDescription.xml", "/desc/device.xml"]
                .compactMap { URL(string: "http://\(host)\($0)") }
        }
        return paths.compactMap { URL(string: "http://\(host)\($0)") }
    }
}

/// A folder on a media server.
struct NetworkFolder: Identifiable, Hashable, Sendable {
    let server: MediaServer
    let id: String          // UPnP object ID ("0" is the root)
    let title: String
    let childCount: Int?
    let artURL: URL?
}

/// A playable item on a media server.
struct NetworkTrack: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let trackNumber: Int?
    let artURL: URL?
    let resource: URL
    let mimeType: String
    let duration: Double?
    let sampleRate: Double?
    let bits: Int?
    let size: Int64?

    var fileExtension: String {
        let ext = resource.pathExtension.lowercased()
        if ["flac", "wav", "aif", "aiff", "m4a", "mp3", "aac", "alac"].contains(ext) { return ext }
        switch mimeType {
        case let m where m.contains("flac"): return "flac"
        case let m where m.contains("wav"): return "wav"
        case let m where m.contains("aiff"): return "aiff"
        case let m where m.contains("mp4"), let m where m.contains("m4a"): return "m4a"
        case let m where m.contains("mpeg"): return "mp3"
        default: return ext.isEmpty ? "audio" : ext
        }
    }

    var formatLabel: String {
        let codec = fileExtension.uppercased()
        guard let rate = sampleRate, rate > 0 else { return codec }
        let khz = rate.truncatingRemainder(dividingBy: 1000) == 0 ? String(format: "%.0f", rate / 1000) : String(format: "%.1f", rate / 1000)
        return bits.map { "\(codec) \($0)/\(khz)" } ?? "\(codec) \(khz)k"
    }
}

/// ContentDirectory:1 Browse over SOAP.
enum ContentDirectory {
    enum ProbeResult { case ok, denied, broken }

    /// One-item browse of the root, to tell working servers from stubs and refusals.
    static func probe(_ server: MediaServer) async -> ProbeResult {
        var request = soapRequest(server, objectID: "0", start: 0, count: 1)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .broken }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let root = UPnPXML.parse(data)
        if status == 401 || root?.find("errorCode")?.text == "401" { return .denied }
        return status == 200 && root?.find("Result") != nil ? .ok : .broken
    }

    private static func soapRequest(_ server: MediaServer, objectID: String, start: Int, count: Int) -> URLRequest {
        let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
            <ObjectID>\(escape(objectID))</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter>
            <StartingIndex>\(start)</StartingIndex><RequestedCount>\(count)</RequestedCount><SortCriteria></SortCriteria>
            </u:Browse></s:Body></s:Envelope>
            """
        var request = URLRequest(url: server.controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 15
        return request
    }

    static func browse(_ folder: NetworkFolder, limit: Int = 2000) async throws -> (folders: [NetworkFolder], tracks: [NetworkTrack]) {
        var folders: [NetworkFolder] = [], tracks: [NetworkTrack] = []
        var start = 0
        while start < limit {
            let page = try await browsePage(folder, start: start, count: 200)
            folders += page.folders
            tracks += page.tracks
            start += page.returned
            if page.returned == 0 || start >= page.total { break }
        }
        return (folders, tracks)
    }

    private static func browsePage(_ folder: NetworkFolder, start: Int, count: Int) async throws
        -> (folders: [NetworkFolder], tracks: [NetworkTrack], returned: Int, total: Int) {
        let request = soapRequest(folder.server, objectID: folder.id, start: start, count: count)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let envelope = UPnPXML.parse(data), let result = envelope.find("Result")?.text,
              let didl = UPnPXML.parse(Data(result.utf8)) else {
            throw URLError(.cannotParseResponse)
        }
        let returned = Int(envelope.find("NumberReturned")?.text ?? "") ?? 0
        let total = Int(envelope.find("TotalMatches")?.text ?? "") ?? returned

        let folders = didl.children("container").compactMap { c -> NetworkFolder? in
            guard let id = c.attributes["id"] else { return nil }
            return NetworkFolder(server: folder.server, id: id, title: c.value("title") ?? id,
                                 childCount: c.attributes["childCount"].flatMap(Int.init),
                                 artURL: c.value("albumArtURI").flatMap(URL.init(string:)))
        }
        let tracks = didl.children("item").compactMap { item -> NetworkTrack? in
            let resources = item.children("res").filter { ($0.attributes["protocolInfo"] ?? "").contains("audio") }
            // Prefer lossless, then the largest file (original over transcodes).
            guard let res = resources.max(by: { rank($0) < rank($1) }),
                  let url = URL(string: res.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            let mime = (res.attributes["protocolInfo"] ?? "").split(separator: ":").dropFirst(2).first.map(String.init) ?? ""
            return NetworkTrack(
                id: item.attributes["id"] ?? url.absoluteString,
                title: item.value("title") ?? url.lastPathComponent,
                artist: item.value("artist") ?? item.value("creator"),
                album: item.value("album"),
                trackNumber: item.value("originalTrackNumber").flatMap(Int.init),
                artURL: item.value("albumArtURI").flatMap(URL.init(string:)),
                resource: url, mimeType: mime.lowercased(),
                duration: res.attributes["duration"].flatMap(seconds),
                sampleRate: res.attributes["sampleFrequency"].flatMap(Double.init),
                bits: res.attributes["bitsPerSample"].flatMap(Int.init),
                size: res.attributes["size"].flatMap(Int64.init))
        }
        return (folders, tracks.sorted { ($0.trackNumber ?? .max, $0.title) < ($1.trackNumber ?? .max, $1.title) },
                returned, total)
    }

    private static func rank(_ res: UPnPXML) -> Int64 {
        let info = (res.attributes["protocolInfo"] ?? "").lowercased()
        let lossless = ["flac", "wav", "aiff", "alac", "l16"].contains { info.contains($0) }
        return (lossless ? 1 << 40 : 0) + (Int64(res.attributes["size"] ?? "") ?? 0)
    }

    /// "0:03:45.120" → 225.12
    private static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
