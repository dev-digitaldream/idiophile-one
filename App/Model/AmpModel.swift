import AppKit
import Observation
import UniformTypeIdentifiers

/// Front-panel state of the amplifier: power, input selector, volume, dimmer.
@Observable
@MainActor
final class AmpModel {
    enum Input: Int, CaseIterable {
        case library, radio, network

        var label: String {
            switch self {
            case .library: "LIB"
            case .radio: "RADIO"
            case .network: "NET"
            }
        }

        var longLabel: String {
            switch self {
            case .library: "LIBRARY"
            case .radio: "INTERNET RADIO"
            case .network: "NETWORK"
            }
        }
    }

    /// Backlight levels, from full to deeply dimmed. Default is the warm, dimmed middle step.
    static let dimmerLevels: [Double] = [1.0, 0.6, 0.36]

    let player = PlayerEngine()
    let network = NetworkModel()
    /// Copies network tracks in order and feeds them to the queue as they arrive.
    @ObservationIgnored private var networkTask: Task<Void, Never>?

    var isOn = true
    /// False while the window is hidden, minimised or fully covered: animations pause.
    var isVisible = true

    init() {
        protectQueuedFromCachePruning()
        restoreSession()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }
    /// Compact player instead of the rack (for working); remembered across launches.
    var compactMode = UserDefaults.standard.bool(forKey: "compactMode") {
        didSet { UserDefaults.standard.set(compactMode, forKey: "compactMode") }
    }

    /// Units shown above and below the amplifier; hide them to fit smaller screens.
    /// Each unit can be shown or hidden on its own; at least one always stays.
    var showStreamer = UserDefaults.standard.object(forKey: "showStreamer") as? Bool ?? true {
        didSet { unitChanged(\.showStreamer, "showStreamer", showStreamer) }
    }
    var showAmplifier = UserDefaults.standard.object(forKey: "showAmplifier") as? Bool ?? true {
        didSet { unitChanged(\.showAmplifier, "showAmplifier", showAmplifier) }
    }
    var showEqualizer = UserDefaults.standard.object(forKey: "showEqualizer") as? Bool ?? true {
        didSet { unitChanged(\.showEqualizer, "showEqualizer", showEqualizer) }
    }

    private func unitChanged(_ unit: ReferenceWritableKeyPath<AmpModel, Bool>, _ key: String, _ value: Bool) {
        if !showStreamer && !showAmplifier && !showEqualizer {
            self[keyPath: unit] = true   // refuse to hide the last unit
            return
        }
        UserDefaults.standard.set(value, forKey: key)
    }

    func showRack(streamer: Bool, equalizer: Bool, amplifier: Bool = true) {
        showAmplifier = amplifier
        showStreamer = streamer
        showEqualizer = equalizer
    }

    /// Animation of the meters and of the analyser can be cut while the units stay in view
    /// (they fall to rest and draw nothing).
    var metersLive = UserDefaults.standard.object(forKey: "metersLive") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(metersLive, forKey: "metersLive")
            metersFrozen = false
            if !metersLive { freezeLater(\.metersFrozen, after: 2, unless: \.metersLive) }
        }
    }
    var spectrumLive = UserDefaults.standard.object(forKey: "spectrumLive") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(spectrumLive, forKey: "spectrumLive")
            spectrumFrozen = false
            if !spectrumLive { freezeLater(\.spectrumFrozen, after: 4, unless: \.spectrumLive) }   // the bars fall 30 dB/s
        }
    }
    /// Set a moment after an animation is cut, once everything has come to rest; kept here
    /// rather than in the views so that hiding and showing a unit does not restart it.
    private(set) var metersFrozen = !(UserDefaults.standard.object(forKey: "metersLive") as? Bool ?? true)
    private(set) var spectrumFrozen = !(UserDefaults.standard.object(forKey: "spectrumLive") as? Bool ?? true)

    private func freezeLater(_ flag: ReferenceWritableKeyPath<AmpModel, Bool>, after seconds: Double,
                             unless live: KeyPath<AmpModel, Bool>) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !self[keyPath: live] { self[keyPath: flag] = true }
        }
    }
    var meterMode: MeterMode = MeterMode(rawValue: UserDefaults.standard.string(forKey: "meterMode") ?? "") ?? .vu {
        didSet { UserDefaults.standard.set(meterMode.rawValue, forKey: "meterMode") }
    }
    var finish: Finish = Finish(rawValue: UserDefaults.standard.string(forKey: "finish") ?? "") ?? .champagne {
        didSet { UserDefaults.standard.set(finish.rawValue, forKey: "finish") }
    }
    var input: Input = .library
    var dimmerIndex = 1
    /// Volume knob position, 0…1.
    /// Volume knob position, 0…1. Mirrors the device volume when the DAC has one.
    var volume: Double {
        get { player.volumePosition }
        set { player.setVolume(newValue) }
    }

    var dimmer: Double { Self.dimmerLevels[dimmerIndex] }

    var volumeDB: Float { PlayerEngine.knobGainDB(volume) }

    /// True when the knob drives the DAC's own volume control.
    var isHardwareVolume: Bool { player.usesHardwareVolume }

    func toggleDirect() {
        guard isOn else { return }
        player.setDirect(!player.isDirect)
    }

    /// Power off works like the real thing: lamps and displays fade out, then the app quits.
    /// The play queue keeps its cached network copies.
    func protectQueuedFromCachePruning() {
        network.protectedPaths = { [weak self] in Set(self?.player.queue.map(\.path) ?? []) }
    }

    func togglePower() {
        guard isOn else { isOn = true; return }
        player.setDirect(false)   // release exclusive access
        player.pause()
        isOn = false
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            NSApp.terminate(nil)
        }
    }

    /// Play/pause only. With nothing loaded it opens the library; ⏏ is the key that opens files.
    func togglePlay() {
        guard isOn else { return }
        if player.station != nil || !player.queue.isEmpty {
            player.togglePlay()
        } else {
            libraryRequested = true
        }
    }

    /// Set to ask the window to open the library (models cannot open windows themselves).
    var libraryRequested = false

    // MARK: Session

    private struct Session: Codable {
        var paths: [String]
        var index: Int
        var position: Double
        var station: RadioStation?
    }

    /// Remembers what was playing so the next launch is ready to resume.
    func saveSession() {
        let session = Session(paths: player.queue.map(\.path), index: player.index,
                              position: player.currentTime(), station: player.station)
        UserDefaults.standard.set(try? JSONEncoder().encode(session), forKey: "session")
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: "session"),
              let session = try? JSONDecoder().decode(Session.self, from: data) else { return }
        if let station = session.station {
            player.restore(station: station)
            input = .radio
        } else {
            let urls = session.paths.map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return }
            let index = urls.firstIndex { $0.path == session.paths[safe: session.index] } ?? 0
            player.restore(urls, index: index, position: urls[index].path == session.paths[safe: session.index] ? session.position : 0)
        }
    }

    // MARK: Library playback

    func play(_ tracks: [LibraryTrack], from start: Int = 0) {
        guard !tracks.isEmpty else { return }
        networkTask?.cancel()
        isOn = true
        input = .library
        player.load(tracks.map(\.url), startAt: start)
    }

    /// Network tracks play from local copies: the first starts as soon as it is copied, the
    /// rest join the queue while it plays.
    func play(network tracks: [NetworkTrack], from start: Int) {
        guard tracks.indices.contains(start) else { return }
        isOn = true
        input = .network
        networkTask?.cancel()
        networkTask = Task {
            var started = false
            for track in tracks[start...] {
                guard !Task.isCancelled else { return }
                do {
                    let url = try await network.localCopy(of: track)
                    guard !Task.isCancelled else { return }
                    if started { player.enqueue([url]) } else { player.load([url]); started = true }
                } catch {
                    player.reportError("\(track.title): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Plays a station; with auto-best on, its best-quality stream is looked up first.
    func play(station: RadioStation) {
        networkTask?.cancel()
        isOn = true
        input = .radio
        radioRequest += 1
        let request = radioRequest
        Task {
            let stream = await RadioResolver.shared.playable(station)
            // Answers can arrive out of order: only the latest choice may start, and not after
            // the user left radio.
            guard request == radioRequest, input == .radio else { return }
            player.play(station: stream)
        }
    }

    @ObservationIgnored private var radioRequest = 0

    /// Plays exactly this stream (the user picked it from the list of sources).
    func play(exactStation station: RadioStation) {
        networkTask?.cancel()
        isOn = true
        input = .radio
        radioRequest += 1   // supersedes a lookup still in flight
        player.play(station: station)
    }

    func playNext(_ tracks: [LibraryTrack]) { player.playNext(tracks.map(\.url)) }

    func enqueue(_ tracks: [LibraryTrack]) { player.enqueue(tracks.map(\.url)) }

    func cycleInput() {
        select(Input(rawValue: (input.rawValue + 1) % Input.allCases.count) ?? .library)
    }

    /// Section of the library window to show when it opens ("radio", "network", "albums").
    var libraryTarget: String?

    /// Choosing a source does what it says: LIB returns to the library queue, RADIO plays the
    /// last station (or opens the station browser), NET opens the servers. Playback that was
    /// running keeps running on the new source; a paused player stays paused, ready.
    func select(_ source: Input) {
        guard source != input, isOn else { return }
        let wasPlaying = player.isPlaying
        switch source {
        case .library:
            if player.returnToLibrary() {
                input = .library
                if wasPlaying { player.resume() }
            } else {
                openLibrary(at: "albums")
            }
        case .radio:
            if let station = player.lastStation ?? RadioFavorites.load().first {
                input = .radio
                if wasPlaying { play(station: station) } else { player.restore(station: station) }
            } else {
                // Nothing to play yet: the input changes when a station is chosen.
                openLibrary(at: "radio")
            }
        case .network:
            // Same: the input changes when a track is chosen on a server.
            openLibrary(at: "network")
        }
    }

    private func openLibrary(at section: String) {
        libraryTarget = section
        libraryRequested = true
    }

    /// Result of the true-resolution scan for one file.
    struct ResolutionRecord {
        let url: URL
        let report: ResolutionReport
    }
    private(set) var resolutionRecord: ResolutionRecord?
    private(set) var isScanningResolution = false

    /// Looks at what the current file really contains (bandwidth and bits actually used).
    func scanResolution() {
        guard let url = player.currentURL, !player.isRadio, !isScanningResolution else { return }
        audioPathRequested = true
        isScanningResolution = true
        let claimed = player.nowPlaying?.bitDepth
        Task {
            let report = await Task.detached(priority: .userInitiated) { ResolutionScanner.scan(url: url, claimedBits: claimed) }.value
            if let report { resolutionRecord = ResolutionRecord(url: url, report: report) }
            isScanningResolution = false
        }
    }

    private(set) var isVerifying = false
    private(set) var verificationError: String?
    /// Set to ask the window to open the audio path panel.
    var audioPathRequested = false
    /// Set to ask the window to open the equalizer editor.
    var eqEditorRequested = false

    /// Renders the start of the current track through the current settings and compares it
    /// with the decoded file, sample by sample. The result appears in the audio path panel.
    func verifyBitPerfect() {
        guard let url = player.currentURL, !player.isRadio, !isVerifying else { return }
        audioPathRequested = true
        isVerifying = true
        verificationError = nil
        let path = player.signalPath
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BitPerfectVerifier.verify(url: url, path: path) }
            }.value
            switch result {
            case .success(let report):
                player.lastVerification = VerificationRecord(url: url, path: path, report: report, date: Date())
            case .failure(let error):
                verificationError = error.localizedDescription
            }
            isVerifying = false
        }
    }

    func cycleMeterMode() {
        meterMode = meterMode == .vu ? .peak : .vu
    }

    func cycleDimmer() {
        dimmerIndex = (dimmerIndex + 1) % Self.dimmerLevels.count
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .folder]
        guard panel.runModal() == .OK else { return }
        load(panel.urls)
    }

    func load(_ urls: [URL]) {
        let tracks = Self.expandAudioFiles(urls)
        guard !tracks.isEmpty else { return }
        isOn = true
        input = .library
        player.load(tracks)
    }

    /// Expands folders recursively into a sorted list of playable audio files.
    static func expandAudioFiles(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = fm.enumerator(at: url, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL } ?? []
                result += items.filter(isAudio).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if isAudio(url) {
                result.append(url)
            }
        }
        return result
    }

    private static func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
