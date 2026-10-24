import Foundation

nonisolated enum DomainValueError: Error, Equatable {
    case emptyIdentifier
    case nonFiniteNumber
    case negativePosition
    case nonPositiveDuration
}

nonisolated struct SessionRunID: Hashable, Sendable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

nonisolated struct TrackGeneration: Hashable, Sendable {
    let ordinal: UInt64
}

nonisolated struct TrackChangeToken: Hashable, Sendable {
    let rawValue: String

    init(validated rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValueError.emptyIdentifier
        }
        self.rawValue = rawValue
    }
}

nonisolated struct RecordingID: Hashable, Sendable {
    enum Authority: String, Hashable, Sendable {
        case store
        case library
    }

    let authority: Authority
    let rawValue: String

    static func store(validated rawValue: String) throws -> RecordingID {
        try RecordingID(authority: .store, validated: rawValue)
    }

    static func library(_ persistentID: UInt64) -> RecordingID {
        RecordingID(authority: .library, rawValue: String(persistentID))
    }

    private init(authority: Authority, validated rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValueError.emptyIdentifier
        }
        self.authority = authority
        self.rawValue = rawValue
    }

    private init(authority: Authority, rawValue: String) {
        self.authority = authority
        self.rawValue = rawValue
    }
}

nonisolated enum RecordingIdentity: Hashable, Sendable {
    case identified(RecordingID)
    case unavailable
}

nonisolated struct PlaybackPosition: Hashable, Comparable, Sendable {
    let seconds: Double

    init(seconds: Double) throws {
        guard seconds.isFinite else { throw DomainValueError.nonFiniteNumber }
        guard seconds >= 0 else { throw DomainValueError.negativePosition }
        self.seconds = seconds
    }

    static func < (lhs: PlaybackPosition, rhs: PlaybackPosition) -> Bool {
        lhs.seconds < rhs.seconds
    }

    func applying(_ offset: TimingOffset) -> PlaybackPosition {
        try! PlaybackPosition(seconds: max(0, seconds + offset.seconds))
    }
}

nonisolated struct TrackDuration: Hashable, Sendable {
    let seconds: Double

    init(seconds: Double) throws {
        guard seconds.isFinite else { throw DomainValueError.nonFiniteNumber }
        guard seconds > 0 else { throw DomainValueError.nonPositiveDuration }
        self.seconds = seconds
    }
}

nonisolated struct TimingOffset: Hashable, Sendable {
    let seconds: Double

    static let zero = try! TimingOffset(seconds: 0)

    init(seconds: Double) throws {
        guard seconds.isFinite else { throw DomainValueError.nonFiniteNumber }
        self.seconds = seconds
    }
}

nonisolated struct MonotonicInstant: Hashable, Comparable, Sendable {
    let seconds: Double

    init(seconds: Double) throws {
        guard seconds.isFinite else { throw DomainValueError.nonFiniteNumber }
        guard seconds >= 0 else { throw DomainValueError.negativePosition }
        self.seconds = seconds
    }

    static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.seconds < rhs.seconds
    }

    func advanced(by seconds: Double) -> MonotonicInstant {
        try! MonotonicInstant(seconds: self.seconds + max(0, seconds))
    }
}

nonisolated struct TrackDescriptor: Hashable, Sendable {
    let changeToken: TrackChangeToken
    let recordingIdentity: RecordingIdentity
    let title: String
    let artist: String
    let album: String?
    let duration: TrackDuration?

    init(
        changeToken: TrackChangeToken,
        recordingIdentity: RecordingIdentity,
        title: String,
        artist: String,
        album: String?,
        duration: TrackDuration?
    ) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValueError.emptyIdentifier
        }
        self.changeToken = changeToken
        self.recordingIdentity = recordingIdentity
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

nonisolated enum PlaybackFreezeReason: Hashable, Sendable {
    case paused
    case stopped
    case interrupted
    case unknown
}

nonisolated enum SampledPlaybackTiming: Hashable, Sendable {
    case advancing(from: PlaybackPosition)
    case frozen(at: PlaybackPosition, reason: PlaybackFreezeReason)
    case positionUnavailable(reason: PlaybackFreezeReason)
}

nonisolated enum MusicAccessFailure: Error, Hashable, Sendable {
    case denied
    case restricted
    case unavailable
}

nonisolated enum PlaybackObservation: Hashable, Sendable {
    case accessBlocked(MusicAccessFailure)
    case noCurrentItem
    case unidentifiedCurrentItem
    case current(track: TrackDescriptor, timing: SampledPlaybackTiming)
}

nonisolated struct PlaybackAnchor: Hashable, Sendable {
    let sampledPosition: PlaybackPosition
    let sampledAt: MonotonicInstant
    let trackDuration: TrackDuration?

    func estimate(at now: MonotonicInstant) -> PlaybackPosition {
        let elapsed = max(0, now.seconds - sampledAt.seconds)
        let estimated = sampledPosition.seconds + elapsed
        let bounded = min(estimated, trackDuration?.seconds ?? estimated)
        return try! PlaybackPosition(seconds: bounded)
    }
}

nonisolated enum PlaybackCursor: Hashable, Sendable {
    case advancing(PlaybackAnchor)
    case frozen(PlaybackPosition, PlaybackFreezeReason)
    case unavailable(PlaybackFreezeReason)

    func position(at now: MonotonicInstant) -> PlaybackPosition? {
        switch self {
        case .advancing(let anchor):
            anchor.estimate(at: now)
        case .frozen(let position, _):
            position
        case .unavailable:
            nil
        }
    }
}

nonisolated struct RawLyricSpan: Hashable, Sendable, Codable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

nonisolated struct RawLyricCue: Hashable, Sendable, Codable {
    let startSeconds: Double
    let endSeconds: Double?
    let text: String
    let spans: [RawLyricSpan]

    init(startSeconds: Double, endSeconds: Double?, text: String, spans: [RawLyricSpan] = []) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.spans = spans
    }
}

nonisolated struct RawTimedLyrics: Hashable, Sendable, Codable {
    let cues: [RawLyricCue]
}

nonisolated enum LyricValidationFailure: Error, Hashable, Sendable {
    case empty
    case nonFiniteTimestamp(cue: Int)
    case negativeTimestamp(cue: Int)
    case missingFinalEnd
    case nonPositiveRange(cue: Int)
    case overlap(previous: Int, next: Int)
    case invalidSpan(cue: Int, span: Int)
}

nonisolated enum LyricUnavailable: Hashable, Sendable {
    case noFixture
    case noSynchronizedLyrics
    case unidentifiedRecording
    case recordingMismatch
    case ambiguousMatch
    case sourceFailed
    case invalidTiming(LyricValidationFailure)
}

nonisolated enum LyricLookupResult: Sendable {
    case document(RawTimedLyrics)
    case unavailable(LyricUnavailable)
}

nonisolated enum LyricsPresentation: Equatable, Sendable {
    case stopped(StoppedPresentation)
    case requestingAccess(RequestingAccessPresentation)
    case following(FollowingPresentation)
}

nonisolated struct StoppedPresentation: Equatable, Sendable {
    let timingOffset: TimingOffset
    let activity: LiveActivityPresentation
}

nonisolated struct RequestingAccessPresentation: Equatable, Sendable {
    let timingOffset: TimingOffset
}

nonisolated struct FollowingPresentation: Equatable, Sendable {
    let content: FollowingContent
    let timingOffset: TimingOffset
    let activity: LiveActivityPresentation
}

nonisolated enum FollowingContent: Equatable, Sendable {
    case blocked(MusicAccessFailure)
    case noPlayback
    case unidentifiedTrack
    case track(TrackPresentation)
}

nonisolated struct TrackPresentation: Equatable, Sendable {
    let track: TrackSummary
    let playback: PlaybackPresentation
    let lyrics: TrackLyricsPresentation
}

nonisolated struct TrackSummary: Equatable, Sendable {
    let changeToken: TrackChangeToken
    let title: String
    let artist: String
}

nonisolated enum PlaybackPresentation: Equatable, Sendable {
    case playing
    case paused
    case stopped
    case interrupted
    case positionUnavailable
}

nonisolated enum TrackLyricsPresentation: Equatable, Sendable {
    case loading
    case ready(LyricContext)
    case unavailable(LyricUnavailable)
}

nonisolated struct LyricContext: Equatable, Sendable {
    let previous: String?
    let active: String?
    let next: String?
}

nonisolated enum LiveActivityPresentation: Equatable, Sendable {
    case notRequested
    case starting
    case active
    case ending
    case unavailable(LiveActivityFailure)
}

nonisolated enum LiveActivityFailure: Equatable, Sendable {
    case disabled
    case startFailed
    case updateFailed
    case endFailed
}

nonisolated enum PlaybackInvalidation: Sendable {
    case itemChanged
    case playbackStateChanged
}

struct LyricsSessionDependencies {
    let playback: any PlaybackFollowing
    let lyrics: any TimedLyricsLoading
    let clock: any SessionClock
    let activity: any LyricsActivityPublishing
}

@MainActor
protocol PlaybackFollowing: AnyObject {
    func requestAccess() async -> Result<Void, MusicAccessFailure>
    func events() -> AsyncStream<PlaybackInvalidation>
    func sample() -> PlaybackObservation
}

nonisolated protocol TimedLyricsLoading: Sendable {
    func lyrics(for track: TrackDescriptor) async -> LyricLookupResult
}

protocol SessionClock: Sendable {
    func now() async -> MonotonicInstant
    func sleep(until deadline: MonotonicInstant) async throws
}

nonisolated enum DesiredActivity: Sendable, Equatable {
    case ended
    case visible(LyricsActivityAttributes.ContentState)
}

protocol LyricsActivityPublishing: Sendable {
    func reconcile(to desired: DesiredActivity) async -> LiveActivityPresentation
}
