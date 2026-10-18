import SwiftUI

/// Internet radio browser inside the library window.
struct RadioView: View {
    @Environment(AmpModel.self) private var amp
    /// The window's search text: searches stations while this view is shown.
    let search: String

    enum Tab: Hashable {
        case favorites, popular, local, genre(String)
    }

    static let genres = ["jazz", "classical", "rock", "pop", "electronic", "ambient", "news",
                         "chillout", "blues", "soul", "arabic", "rai", "world", "talk"]

    @State private var tab: Tab = RadioFavorites.load().isEmpty ? .popular : .favorites
    @State private var stations: [RadioStation] = []
    @State private var favorites: [RadioStation] = RadioFavorites.load()
    @State private var loading = false
    @State private var error: String?
    @State private var preference = RadioQuality.preference
    @State private var autoBest = RadioQuality.autoBest

    private var countryCode: String { Locale.current.region?.identifier ?? "US" }
    private var countryName: String { Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode }

    /// One row per station, the best stream first; duplicates of a station are folded into it.
    private var rows: [[RadioStation]] {
        tab == .favorites && search.isEmpty
            ? favorites.map { [$0] }
            : RadioQuality.groups(stations, preference: preference)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .navigationTitle("Internet Radio")
        .navigationSubtitle("radio-browser.info")
        .task(id: "\(tab)|\(search)") { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                chip("Favorites", systemImage: "star.fill", tab: .favorites)
                chip("Popular", systemImage: "flame.fill", tab: .popular)
                chip(countryName, systemImage: "location.fill", tab: .local)
                Spacer()
                qualityMenu
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.genres, id: \.self) { genre in
                        chip(genre.capitalized, systemImage: nil, tab: .genre(genre))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Which stream to play when a station offers several.
    private var qualityMenu: some View {
        Menu {
            Toggle("Pick the best stream automatically", isOn: $autoBest)
            Divider()
            Picker("Preferred quality", selection: $preference) {
                ForEach(RadioQuality.Preference.allCases) { Text($0.name).tag($0) }
            }
            .disabled(!autoBest)
        } label: {
            Label(autoBest ? preference.name.components(separatedBy: " (").first ?? "" : "Manual", systemImage: "waveform.badge.magnifyingglass")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("When a station has several streams, Idiophile One plays the best one for your preference")
        .onChange(of: autoBest) { _, new in RadioQuality.autoBest = new }
        .onChange(of: preference) { _, new in RadioQuality.preference = new }
    }

    private func chip(_ title: String, systemImage: String?, tab value: Tab) -> some View {
        let selected = search.isEmpty && tab == value
        return Button {
            tab = value
        } label: {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.caption) }
                Text(title)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
            .foregroundStyle(selected ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var list: some View {
        if loading && stations.isEmpty && !(tab == .favorites && search.isEmpty) {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView("Directory unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
        } else if rows.isEmpty {
            ContentUnavailableView(tab == .favorites && search.isEmpty ? "No favourites yet" : "No stations",
                                   systemImage: "antenna.radiowaves.left.and.right",
                                   description: Text(tab == .favorites && search.isEmpty
                                                     ? "Star a station to keep it here." : "Try another search or genre."))
        } else {
            let onFavorites = tab == .favorites && search.isEmpty
            List {
                ForEach(rows, id: \.first!.id) { group in
                    let station = group[0]
                    StationRow(station: station, alternatives: group.dropFirst().map { $0 },
                               playing: amp.player.station.map { RadioQuality.groupKey($0) == RadioQuality.groupKey(station) } ?? false,
                               favorite: isFavorite(station),
                               toggleFavorite: { toggleFavorite(station) },
                               play: { amp.play(station: station) },
                               playSource: { amp.play(exactStation: $0) })
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { amp.play(station: station) }
                        .contextMenu {
                            Button("Play Best Stream") { amp.play(station: station) }
                            Button(isFavorite(station) ? "Remove from Favorites" : "Add to Favorites") { toggleFavorite(station) }
                            if let home = station.homepage.flatMap(URL.init(string:)) {
                                Button("Open Website") { NSWorkspace.shared.open(home) }
                            }
                        }
                }
                .onMove(perform: onFavorites ? { from, to in
                    favorites.move(fromOffsets: from, toOffset: to)
                    RadioFavorites.save(favorites)
                } : nil)
            }
            .listStyle(.inset)
        }
    }

    private func isFavorite(_ station: RadioStation) -> Bool {
        let key = RadioQuality.groupKey(station)
        return favorites.contains { RadioQuality.groupKey($0) == key }
    }

    private func load() async {
        error = nil
        let text = search.trimmingCharacters(in: .whitespaces)
        if text.isEmpty, tab == .favorites {
            stations = favorites
            return
        }
        if !text.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }   // debounce typing
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        do {
            let result: [RadioStation]
            if !text.isEmpty {
                result = try await RadioBrowser.shared.search(text, limit: 200)
            } else {
                switch tab {
                case .favorites: result = favorites
                case .popular: result = try await RadioBrowser.shared.popular(limit: 200)
                case .local: result = try await RadioBrowser.shared.local(countryCode: countryCode, limit: 200)
                case .genre(let tag): result = try await RadioBrowser.shared.byTag(tag, limit: 200)
                }
            }
            guard !Task.isCancelled else { return }
            stations = result
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A favourite is a station, not one stream of it: the best stream is chosen when it plays.
    private func toggleFavorite(_ station: RadioStation) {
        let key = RadioQuality.groupKey(station)
        if let i = favorites.firstIndex(where: { RadioQuality.groupKey($0) == key }) { favorites.remove(at: i) } else { favorites.append(station) }
        RadioFavorites.save(favorites)
        if tab == .favorites && search.isEmpty { stations = favorites }
    }
}

struct StationRow: View {
    let station: RadioStation
    let alternatives: [RadioStation]
    let playing: Bool
    let favorite: Bool
    let toggleFavorite: () -> Void
    let play: () -> Void
    let playSource: (RadioStation) -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: station.faviconURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "radio").font(.title3).foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 40)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if playing { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).font(.caption) }
                    Text(station.displayName).font(.body.weight(.medium))
                        .foregroundStyle(playing ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)).lineLimit(1)
                }
                Text(station.tagList.prefix(4).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let country = station.countrycode, !country.isEmpty {
                Text(country).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if !alternatives.isEmpty { sourcesMenu }
            qualityChip(station)
            Button(action: toggleFavorite) {
                Image(systemName: favorite ? "star.fill" : "star")
                    .foregroundStyle(favorite ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(favorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.vertical, 4)
    }

    /// Other streams of the same station: pick one by hand.
    private var sourcesMenu: some View {
        Menu {
            Button { play() } label: { Label("Best: \(station.qualityLabel)", systemImage: "star.circle") }
            Divider()
            ForEach(alternatives) { alt in
                Button("\(alt.qualityLabel)\(alt.hls == 1 ? " · HLS" : "")\(alt.lastcheckok == 1 ? "" : " · unchecked")") { playSource(alt) }
            }
        } label: {
            Text("\(alternatives.count + 1) streams").font(.caption).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("This station has several streams; the best one plays by default")
    }

    @ViewBuilder private func qualityChip(_ s: RadioStation) -> some View {
        if !s.qualityLabel.isEmpty {
            let kbps = s.bitrate ?? 0
            let codec = (s.codec ?? "").uppercased()
            let high = codec.contains("FLAC") || kbps >= 192 || (codec.contains("AAC") && kbps >= 128)
            Text(s.qualityLabel).font(.caption2.weight(.semibold).monospaced())
                .padding(.horizontal, 5).padding(.vertical, 2)
                .foregroundStyle(high ? AnyShapeStyle(.black) : AnyShapeStyle(.secondary))
                .background(high ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(high ? 0 : 0.5)))
        }
    }
}
