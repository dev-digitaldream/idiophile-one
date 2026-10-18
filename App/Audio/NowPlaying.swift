import AppKit
import MediaPlayer

/// Publishes the current track to macOS (Control Center, lock screen) and receives the
/// keyboard media keys and headset buttons through the remote command center.
@MainActor
final class NowPlaying {
    private weak var player: PlayerEngine?

    init(player: PlayerEngine) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in self?.handle { $0.resume() } ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.handle { $0.pause() } ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.handle { $0.togglePlay() } ?? .commandFailed }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.handle { $0.next() } ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.handle { $0.previous() } ?? .commandFailed }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.handle { $0.seek(to: event.positionTime) } ?? .commandFailed
        }
    }

    /// Remote commands arrive on the main thread.
    private nonisolated func handle(_ action: @MainActor (PlayerEngine) -> Void) -> MPRemoteCommandHandlerStatus {
        MainActor.assumeIsolated {
            guard let player, !player.queue.isEmpty || player.isRadio else { return .noActionableNowPlayingItem }
            action(player)
            return .success
        }
    }

    /// Call on every track, play-state or position change.
    func update() {
        let info = MPNowPlayingInfoCenter.default()
        guard let player, let track = player.nowPlaying else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        var values: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyIsLiveStream: player.isRadio,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime(),
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist = track.artist { values[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { values[MPMediaItemPropertyAlbumTitle] = album }
        if let art = track.artwork {
            values[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        info.nowPlayingInfo = values
        info.playbackState = player.isPlaying ? .playing : .paused
    }
}
