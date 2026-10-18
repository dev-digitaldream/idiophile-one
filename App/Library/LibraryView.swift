import SwiftUI

/// The library window: a calm, dark browser for large collections.
struct LibraryView: View {
    @Environment(AmpModel.self) private var amp
    @Environment(LibraryModel.self) private var library

    enum Section: Hashable {
        case albums, artists, composers, genres, recent, songs, radio, network
    }

    @State private var section: Section? = .albums
    @State private var path = NavigationPath()
    @State private var search = ""
    @AppStorage("albumSort") private var sort: AlbumSort = .artist

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            NavigationStack(path: $path) {
                content
                    .navigationDestination(for: LibraryAlbum.self) { AlbumDetailView(album: $0) }
                    .navigationDestination(for: NetworkFolder.self) { NetworkFolderView(folder: $0) }
                    .navigationDestination(for: GroupDestination.self) { group in
                        AlbumGrid(filter: group.filter, sort: sort, title: group.name)
                    }
            }
        }
        .searchable(text: $search, placement: .toolbar,
                    prompt: section == .radio ? "Stations" : "Albums, artists, songs, composers")
        .toolbar {
            if section == .albums || section == .recent {
                Picker("Sort", selection: $sort) {
                    ForEach(AlbumSort.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Button { library.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(library.isScanning || library.roots.isEmpty)
        }
        .onChange(of: section) { path = NavigationPath() }
        .onChange(of: amp.libraryTarget, initial: true) { _, target in
            guard let target else { return }
            amp.libraryTarget = nil
            switch target {
            case "radio": section = .radio
            case "network": section = .network
            default: section = .albums
            }
        }
        .tint(amp.finish.palette.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 520)
    }

    private var sidebar: some View {
        List(selection: $section) {
            SwiftUI.Section("Library") {
                Label("Albums", systemImage: "square.grid.2x2").tag(Section.albums)
                Label("Artists", systemImage: "music.mic").tag(Section.artists)
                Label("Composers", systemImage: "music.quarternote.3").tag(Section.composers)
                Label("Genres", systemImage: "guitars").tag(Section.genres)
                Label("Recently Added", systemImage: "clock").tag(Section.recent)
                Label("Songs", systemImage: "music.note.list").tag(Section.songs)
            }
            SwiftUI.Section("Sources") {
                Label("Internet Radio", systemImage: "antenna.radiowaves.left.and.right").tag(Section.radio)
                Label("Network", systemImage: "network").tag(Section.network)
            }
            SwiftUI.Section("Folders") {
                ForEach(library.roots, id: \.self) { root in
                    Label(root.lastPathComponent, systemImage: "folder")
                        .help(root.path)
                        .contextMenu { Button("Remove from Library") { library.removeFolder(root) } }
                }
                Button { library.addFolders() } label: { Label("Add Folder…", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        }
        .safeAreaInset(edge: .bottom) { status.padding(10) }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if library.isScanning {
                ProgressView(value: Double(library.progress.done), total: Double(max(library.progress.total, 1)))
                Text("Scanning \(library.progress.done) of \(library.progress.total)…")
            } else if library.isAnalyzing {
                ProgressView(value: Double(library.analysisProgress.done), total: Double(max(library.analysisProgress.total, 1)))
                Text("Measuring loudness: album \(library.analysisProgress.done) of \(library.analysisProgress.total)…")
            } else {
                Text("\(library.counts.albums) albums · \(library.counts.tracks) tracks")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if section == .radio {
            RadioView(search: search)
        } else if section == .network {
            NetworkView()
        } else if library.roots.isEmpty {
            EmptyLibraryView()
        } else if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsView(text: search)
        } else {
            switch section ?? .albums {
            case .albums: AlbumGrid(filter: .all, sort: sort, title: "Albums")
            case .recent: AlbumGrid(filter: .all, sort: .added, title: "Recently Added", limit: 120)
            case .artists: GroupList(column: "artist", title: "Artists") { .artist($0) }
            case .composers: GroupList(column: "composer", title: "Composers") { .composer($0) }
            case .genres: GroupList(column: "genre", title: "Genres") { .genre($0) }
            case .songs: SongsView()
            case .radio: RadioView(search: search)
            case .network: NetworkView()
            }
        }
    }
}

struct GroupDestination: Hashable {
    let name: String
    let filter: AlbumFilter
}

// MARK: - Albums

struct AlbumGrid: View {
    @Environment(LibraryModel.self) private var library
    var filter: AlbumFilter
    var sort: AlbumSort
    var title: String
    var limit: Int?

    @State private var albums: [LibraryAlbum] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 22)], alignment: .leading, spacing: 26) {
                ForEach(albums) { album in
                    NavigationLink(value: album) { AlbumTile(album: album) }
                        .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .navigationTitle(title)
        .navigationSubtitle("\(albums.count) albums")
        .task(id: "\(library.revision)|\(filter)|\(sort.rawValue)") {
            albums = (try? await library.database?.albums(filter: filter, sort: sort, limit: limit)) ?? []
        }
    }
}

struct AlbumTile: View {
    @Environment(AmpModel.self) private var amp
    @Environment(LibraryModel.self) private var library
    let album: LibraryAlbum
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtwork(album: album)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if hovering {
                        Button { Task { await play() } } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 38, height: 38)
                                .background(.tint, in: Circle())
                                .foregroundStyle(.black)
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .transition(.opacity)
                    }
                }
            Text(album.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Text(album.artist).lineLimit(1)
                if album.isHighResolution { HiResBadge() }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu {
            Button("Play") { Task { await play() } }
            Button("Play Next") { Task { await tracks().map(amp.playNext) } }
            Button("Add to Queue") { Task { await tracks().map(amp.enqueue) } }
        }
    }

    private func tracks() async -> [LibraryTrack]? { try? await library.database?.tracks(albumKey: album.key) }

    private func play() async {
        if let tracks = await tracks() { amp.play(tracks) }
    }
}

struct AlbumArtwork: View {
    let key: String
    let samplePath: String
    var cornerRadius: CGFloat = 6
    @State private var image: NSImage?

    init(album: LibraryAlbum, cornerRadius: CGFloat = 6) {
        key = album.key
        samplePath = album.samplePath
        self.cornerRadius = cornerRadius
        _image = State(initialValue: ArtworkCache.shared.cached(album.key))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
        .task(id: key) {
            if image == nil { image = await ArtworkCache.shared.image(albumKey: key, samplePath: samplePath) }
        }
    }
}

struct HiResBadge: View {
    var body: some View {
        Text("HI-RES")
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(0.5)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .foregroundStyle(.black)
            .background(Color(red: 0.95, green: 0.75, blue: 0.35), in: RoundedRectangle(cornerRadius: 2.5))
    }
}

// MARK: - Album detail

struct AlbumDetailView: View {
    @Environment(AmpModel.self) private var amp
    @Environment(LibraryModel.self) private var library
    let album: LibraryAlbum
    @State private var tracks: [LibraryTrack] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .bottom, spacing: 26) {
                    AlbumArtwork(album: album, cornerRadius: 8).frame(width: 230, height: 230)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ALBUM").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.tint)
                        Text(album.title).font(.system(size: 30, weight: .bold)).lineLimit(2)
                        Text(album.artist).font(.title3).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(summary).font(.callout).foregroundStyle(.secondary)
                            Text(album.formatLabel).font(.caption.weight(.semibold).monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.5)))
                            if album.isHighResolution { HiResBadge() }
                        }
                        HStack(spacing: 10) {
                            Button { amp.play(tracks) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 70) }
                                .buttonStyle(.borderedProminent).foregroundStyle(.black)
                            Button { amp.play(tracks.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                                .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                        .padding(.top, 6)
                        .disabled(tracks.isEmpty)
                    }
                }
                TrackList(tracks: tracks, albumArtist: album.artist)
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle(album.title)
        .task(id: "\(album.key)|\(library.revision)") {
            tracks = (try? await library.database?.tracks(albumKey: album.key)) ?? []
        }
    }

    private var summary: String {
        let minutes = Int(album.duration / 60)
        return [album.year.map(String.init), "\(album.trackCount) tracks", "\(minutes) min"].compactMap { $0 }.joined(separator: " · ")
    }
}

struct TrackList: View {
    @Environment(AmpModel.self) private var amp
    let tracks: [LibraryTrack]
    let albumArtist: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track, number: track.trackNumber ?? i + 1, showArtist: track.artist != albumArtist,
                         playing: amp.player.currentURL?.path == track.path)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { amp.play(tracks, from: i) }
                    .contextMenu {
                        Button("Play from Here") { amp.play(tracks, from: i) }
                        Button("Play Next") { amp.playNext([track]) }
                        Button("Add to Queue") { amp.enqueue([track]) }
                    }
                if i < tracks.count - 1 { Divider().opacity(0.4) }
            }
        }
    }
}

struct TrackRow: View {
    let track: LibraryTrack
    let number: Int
    let showArtist: Bool
    let playing: Bool

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if playing {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                } else {
                    Text("\(number)").foregroundStyle(.secondary)
                }
            }
            .font(.callout.monospacedDigit())
            .frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).foregroundStyle(playing ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)).lineLimit(1)
                if showArtist, let artist = track.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(Self.clock(track.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Groups, songs, search

struct GroupList: View {
    @Environment(LibraryModel.self) private var library
    let column: String
    let title: String
    let filter: (String) -> AlbumFilter
    @State private var groups: [LibraryGroup] = []

    var body: some View {
        List(groups) { group in
            NavigationLink(value: GroupDestination(name: group.name, filter: filter(group.name))) {
                HStack {
                    Text(group.name)
                    Spacer()
                    Text("\(group.albums) albums · \(group.tracks) tracks").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(groups.count)")
        .task(id: "\(library.revision)|\(column)") { groups = (try? await library.database?.groups(column)) ?? [] }
    }
}

struct SongsView: View {
    @Environment(AmpModel.self) private var amp
    @Environment(LibraryModel.self) private var library
    @State private var tracks: [LibraryTrack] = []
    @State private var selection = Set<LibraryTrack.ID>()

    var body: some View {
        Table(tracks, selection: $selection) {
            TableColumn("Title", value: \.title)
            TableColumn("Artist") { Text($0.artist ?? "") }
            TableColumn("Album") { Text($0.album ?? "") }
            TableColumn("Time") { Text(TrackRow.clock($0.duration)).monospacedDigit() }.width(56)
            TableColumn("Format") { t in
                Text(t.bits.map { "\(t.codec) \($0)/\(Int(t.sampleRate / 1000))" } ?? t.codec).font(.caption.monospaced())
            }
            .width(96)
        }
        .contextMenu(forSelectionType: LibraryTrack.ID.self) { ids in
            Button("Play") { play(ids) }
            Button("Play Next") { amp.playNext(tracks.filter { ids.contains($0.id) }) }
            Button("Add to Queue") { amp.enqueue(tracks.filter { ids.contains($0.id) }) }
        } primaryAction: { play($0) }
        .navigationTitle("Songs")
        .navigationSubtitle("\(tracks.count) tracks")
        .task(id: library.revision) { tracks = (try? await library.database?.allTracks()) ?? [] }
    }

    private func play(_ ids: Set<LibraryTrack.ID>) {
        guard let first = tracks.firstIndex(where: { ids.contains($0.id) }) else { return }
        amp.play(tracks, from: first)
    }
}

struct SearchResultsView: View {
    @Environment(AmpModel.self) private var amp
    @Environment(LibraryModel.self) private var library
    let text: String
    @State private var albums: [LibraryAlbum] = []
    @State private var tracks: [LibraryTrack] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !albums.isEmpty {
                    Text("Albums").font(.title2.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 18) {
                            ForEach(albums) { album in
                                NavigationLink(value: album) { AlbumTile(album: album).frame(width: 160) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                if !tracks.isEmpty {
                    Text("Songs").font(.title2.weight(.semibold))
                    TrackList(tracks: tracks, albumArtist: "")
                }
                if albums.isEmpty && tracks.isEmpty {
                    ContentUnavailableView.search(text: text)
                }
            }
            .padding(24)
        }
        .navigationTitle("Search")
        .task(id: "\(text)|\(library.revision)") {
            try? await Task.sleep(for: .milliseconds(150))   // debounce typing
            guard !Task.isCancelled, let result = try? await library.database?.search(text) else { return }
            albums = result.albums
            tracks = result.tracks
        }
    }
}

struct EmptyLibraryView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        ContentUnavailableView {
            Label("Your music library", systemImage: "music.note.house")
        } description: {
            Text("Add the folders that hold your music. Idiophile One reads their tags and covers and keeps them up to date; your files are never modified.")
        } actions: {
            Button("Add Folder…") { library.addFolders() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
        }
    }
}

struct ComingSoonView: View {
    let title: String
    let icon: String
    let text: String

    var body: some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(text + "\nComing next."))
            .navigationTitle(title)
    }
}
