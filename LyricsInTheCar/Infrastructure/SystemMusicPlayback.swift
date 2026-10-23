import Foundation
import MediaPlayer

@MainActor
final class SystemMusicPlayback: PlaybackFollowing {
    private let player: MPMusicPlayerController
    private var continuation: AsyncStream<PlaybackInvalidation>.Continuation?
    private lazy var stream = AsyncStream<PlaybackInvalidation>(bufferingPolicy: .bufferingNewest(1)) { continuation in
        self.continuation = continuation
    }
    private var notificationTokens: [NSObjectProtocol] = []

    init(player: MPMusicPlayerController = .systemMusicPlayer) {
        self.player = player
    }

    func requestAccess() async -> Result<Void, MusicAccessFailure> {
        let status = MPMediaLibrary.authorizationStatus()
        let resolved: MPMediaLibraryAuthorizationStatus
        if status == .notDetermined {
            resolved = await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else {
            resolved = status
        }
        switch resolved {
        case .authorized:
            beginNotifications()
            return .success(())
        case .denied:
            return .failure(.denied)
        case .restricted:
            return .failure(.restricted)
        case .notDetermined:
            return .failure(.unavailable)
        @unknown default:
            return .failure(.unavailable)
        }
    }

    func events() -> AsyncStream<PlaybackInvalidation> {
        stream
    }

    func sample() -> PlaybackObservation {
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            return .accessBlocked(.denied)
        }
        guard let item = player.nowPlayingItem else { return .noCurrentItem }
        guard let descriptor = descriptor(for: item) else { return .unidentifiedCurrentItem }
        let time = player.currentPlaybackTime
        let reason: PlaybackFreezeReason
        switch player.playbackState {
        case .paused: reason = .paused
        case .stopped: reason = .stopped
        case .interrupted: reason = .interrupted
        default: reason = .unknown
        }
        guard time.isFinite, time >= 0, let position = try? PlaybackPosition(seconds: time) else {
            return .current(track: descriptor, timing: .positionUnavailable(reason: reason))
        }
        if player.playbackState == .playing {
            return .current(track: descriptor, timing: .advancing(from: position))
        }
        return .current(track: descriptor, timing: .frozen(at: position, reason: reason))
    }

    private func beginNotifications() {
        guard notificationTokens.isEmpty else { return }
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
                object: player,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { _ = self.continuation?.yield(.itemChanged) }
                }
            },
            center.addObserver(
                forName: .MPMusicPlayerControllerPlaybackStateDidChange,
                object: player,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { _ = self.continuation?.yield(.playbackStateChanged) }
                }
            },
        ]
    }

    private func descriptor(for item: MPMediaItem) -> TrackDescriptor? {
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        let storeID = item.playbackStoreID.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity: RecordingIdentity
        if !storeID.isEmpty, let id = try? RecordingID.store(validated: storeID) {
            identity = .identified(id)
        } else if item.persistentID != 0 {
            identity = .identified(.library(item.persistentID))
        } else {
            identity = .unavailable
        }

        let tokenSource = !storeID.isEmpty
            ? "store:\(storeID)"
            : "item:\(item.persistentID):\(title):\(artist):\(item.playbackDuration)"
        guard let token = try? TrackChangeToken(validated: tokenSource) else { return nil }
        let duration = try? TrackDuration(seconds: item.playbackDuration)
        return try? TrackDescriptor(
            changeToken: token,
            recordingIdentity: identity,
            title: title,
            artist: artist,
            album: item.albumTitle,
            duration: duration
        )
    }
}
