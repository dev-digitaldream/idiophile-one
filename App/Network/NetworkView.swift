import SwiftUI

/// Media servers on the local network (UPnP / DLNA).
struct NetworkView: View {
    @Environment(AmpModel.self) private var amp
    @State private var adding = false

    var body: some View {
        let network = amp.network
        Group {
            if network.servers.isEmpty {
                if network.isSearching {
                    ProgressView("Searching your network…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("No media server found", systemImage: "network")
                    } description: {
                        Text("Turn on the DLNA / UPnP media server of your NAS (on a QNAP: DLNA Media Server or Multimedia Console) and allow Idiophile One to access the local network in System Settings › Privacy & Security.")
                    } actions: {
                        Button("Search Again") { network.discover() }
                        Button("Add Server…") { adding = true }
                    }
                }
            } else {
                List(network.servers) { server in
                    if server.accessDenied {
                        DeniedServerRow(server: server)
                    } else {
                    NavigationLink(value: NetworkFolder(server: server, id: "0", title: server.name, childCount: nil, artURL: server.iconURL)) {
                        HStack(spacing: 12) {
                            AsyncImage(url: server.iconURL) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                                Image(systemName: "externaldrive.connected.to.line.below").font(.title2).foregroundStyle(.secondary)
                            }
                            .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(.body.weight(.medium))
                                if let model = server.model { Text(model).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    }
                }
            }
        }
        .navigationTitle("Network")
        .navigationSubtitle(network.isSearching ? "Searching…" : "\(network.servers.count) servers")
        .toolbar {
            Button { adding = true } label: { Label("Add Server…", systemImage: "plus") }
            Button { network.discover() } label: { Label("Search Again", systemImage: "dot.radiowaves.left.and.right") }
                .disabled(network.isSearching)
        }
        .sheet(isPresented: $adding) { AddServerSheet() }
        .onAppear { if network.servers.isEmpty { network.discover() } }
    }
}

/// Adds a server by address, for servers discovery cannot reach (Tailscale, other subnets).
private struct AddServerSheet: View {
    @Environment(AmpModel.self) private var amp
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Media Server").font(.title2.weight(.semibold))
            Text("For a server discovery cannot see, such as a NAS reached through Tailscale. Enter its name or address; the usual ports of QNAP, Synology, Twonky, Plex and Jellyfin are tried.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("nas.tailnet.ts.net, 100.64.0.10 or 192.168.0.10:8200", text: $address)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            if let error = amp.network.addError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: add) {
                    if working { ProgressView().controlSize(.small) } else { Text("Add") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func add() {
        working = true
        Task {
            let ok = await amp.network.addServer(address)
            working = false
            if ok { dismiss() }
        }
    }
}

/// A server that refuses this Mac: explain how to allow it.
private struct DeniedServerRow: View {
    let server: MediaServer

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill").font(.title2).foregroundStyle(.orange).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(server.name) refuses access").font(.body.weight(.medium))
                Text("The media server only serves devices it has allowed. On a QNAP, open DLNA Media Server › Media Receivers and allow this Mac (or turn on automatic approval of new receivers), then search again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

/// One folder of a media server: sub-folders, then tracks.
struct NetworkFolderView: View {
    @Environment(AmpModel.self) private var amp
    let folder: NetworkFolder
    @State private var folders: [NetworkFolder] = []
    @State private var tracks: [NetworkTrack] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Cannot open this folder", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if folders.isEmpty && tracks.isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            } else {
                List {
                    if !folders.isEmpty {
                        Section {
                            ForEach(folders) { sub in
                                NavigationLink(value: sub) { FolderRow(folder: sub) }
                            }
                        }
                    }
                    if !tracks.isEmpty {
                        Section("\(tracks.count) tracks") {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                                NetworkTrackRow(track: track, number: track.trackNumber ?? i + 1,
                                                copying: amp.network.downloads[track.id] != nil)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { amp.play(network: tracks, from: i) }
                                    .contextMenu { Button("Play from Here") { amp.play(network: tracks, from: i) } }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(folder.title)
        .toolbar {
            if !tracks.isEmpty {
                Button { amp.play(network: tracks, from: 0) } label: { Label("Play All", systemImage: "play.fill") }
            }
        }
        .task(id: folder) {
            loading = true
            do {
                (folders, tracks) = try await ContentDirectory.browse(folder)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

private struct FolderRow: View {
    let folder: NetworkFolder

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: folder.artURL) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                Image(systemName: "folder.fill").font(.title2).foregroundStyle(.tint)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(folder.title).lineLimit(1)
            Spacer()
            if let count = folder.childCount { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

private struct NetworkTrackRow: View {
    let track: NetworkTrack
    let number: Int
    let copying: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text("\(number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                if let artist = track.artist { Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if copying { ProgressView().controlSize(.small).help("Copying from the server") }
            Text(track.formatLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let duration = track.duration { Text(TrackRow.clock(duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }
}
