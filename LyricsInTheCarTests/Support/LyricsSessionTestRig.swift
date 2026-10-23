import Foundation
@testable import LyricsInTheCar

@MainActor
final class SessionTestRig {
    let session: LyricsSession
    let playback: ScriptedPlayback
    let clock: ManualSessionClock
    let lyrics: ScriptedLyricsSource
    let activity: RecordingActivityPublisher

    init(observation: PlaybackObservation, lyrics: LyricLookupResult) throws {
        playback = ScriptedPlayback(observation: observation)
        clock = ManualSessionClock()
        self.lyrics = ScriptedLyricsSource(result: lyrics)
        activity = RecordingActivityPublisher()
        session = LyricsSession(dependencies: LyricsSessionDependencies(
            playback: playback,
            lyrics: self.lyrics,
            clock: clock,
            activity: activity
        ))
    }

    func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

@MainActor
final class ScriptedPlayback: PlaybackFollowing {
    var access: Result<Void, MusicAccessFailure> = .success(())
    var observation: PlaybackObservation
    private var continuation: AsyncStream<PlaybackInvalidation>.Continuation?
    private lazy var stream = AsyncStream<PlaybackInvalidation> { continuation in
        self.continuation = continuation
    }

    init(observation: PlaybackObservation) {
        self.observation = observation
    }

    func requestAccess() async -> Result<Void, MusicAccessFailure> { access }
    func events() -> AsyncStream<PlaybackInvalidation> { stream }
    func sample() -> PlaybackObservation { observation }

    func replace(with observation: PlaybackObservation, event: PlaybackInvalidation = .itemChanged) {
        self.observation = observation
        continuation?.yield(event)
    }
}

@MainActor
final class DeferredAccessPlayback: PlaybackFollowing {
    private let observation: PlaybackObservation
    private var continuation: CheckedContinuation<Result<Void, MusicAccessFailure>, Never>?

    init(observation: PlaybackObservation) {
        self.observation = observation
    }

    func requestAccess() async -> Result<Void, MusicAccessFailure> {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolveAccess(_ result: Result<Void, MusicAccessFailure>) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func events() -> AsyncStream<PlaybackInvalidation> {
        AsyncStream { $0.finish() }
    }

    func sample() -> PlaybackObservation { observation }
}

actor ManualSessionClock: SessionClock {
    private struct Sleeper {
        let deadline: MonotonicInstant
        let continuation: CheckedContinuation<Void, Error>
    }

    private var seconds: Double = 0
    private var sleepers: [UUID: Sleeper] = [:]

    func now() -> MonotonicInstant {
        try! MonotonicInstant(seconds: seconds)
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        if deadline.seconds <= seconds { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelSleep(id: id) }
        }
    }

    func advance(by delta: Double) {
        seconds += delta
        let ready = sleepers.filter { $0.value.deadline.seconds <= seconds }
        ready.keys.forEach { sleepers.removeValue(forKey: $0) }
        ready.values.forEach { $0.continuation.resume() }
    }

    private func cancelSleep(id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

actor ScriptedLyricsSource: TimedLyricsLoading {
    private var result: LyricLookupResult

    init(result: LyricLookupResult) {
        self.result = result
    }

    func lyrics(for track: TrackDescriptor) async -> LyricLookupResult {
        result
    }

    func setResult(_ result: LyricLookupResult) {
        self.result = result
    }
}

actor RecordingActivityPublisher: LyricsActivityPublishing {
    var nextResult: LiveActivityPresentation = .active
    private(set) var submissions: [DesiredActivity] = []

    func reconcile(to desired: DesiredActivity) async -> LiveActivityPresentation {
        submissions.append(desired)
        if desired == .ended, nextResult == .active { return .notRequested }
        return nextResult
    }

    func setNextResult(_ result: LiveActivityPresentation) {
        nextResult = result
    }

    func recordedSubmissions() -> [DesiredActivity] {
        submissions
    }
}

extension TrackDescriptor {
    static let fixture = try! TrackDescriptor(
        changeToken: TrackChangeToken(validated: "fixture"),
        recordingIdentity: .identified(RecordingID.store(validated: "fixture-recording")),
        title: "Fixture Song",
        artist: "Studio Placeholder",
        album: nil,
        duration: TrackDuration(seconds: 30)
    )

    static let alternate = try! TrackDescriptor(
        changeToken: TrackChangeToken(validated: "alternate"),
        recordingIdentity: .identified(RecordingID.store(validated: "alternate-recording")),
        title: "Alternate Song",
        artist: "Studio Placeholder",
        album: nil,
        duration: TrackDuration(seconds: 30)
    )
}

extension RawTimedLyrics {
    static let threeLines = RawTimedLyrics(cues: [
        RawLyricCue(startSeconds: 0, endSeconds: 5, text: "Window light"),
        RawLyricCue(startSeconds: 5, endSeconds: 10, text: "Open road"),
        RawLyricCue(startSeconds: 10, endSeconds: 15, text: "Quiet mile"),
    ])

    static let alternateLines = RawTimedLyrics(cues: [
        RawLyricCue(startSeconds: 0, endSeconds: 5, text: "Alternate first"),
        RawLyricCue(startSeconds: 5, endSeconds: 10, text: "Alternate second"),
    ])
}

actor DeferredLyricsSource: TimedLyricsLoading {
    private struct Request {
        let continuation: CheckedContinuation<LyricLookupResult, Never>
    }

    private var requests: [Request] = []
    var requestCount: Int { requests.count }

    func lyrics(for track: TrackDescriptor) async -> LyricLookupResult {
        await withCheckedContinuation { continuation in
            requests.append(Request(continuation: continuation))
        }
    }

    func complete(index: Int, with result: LyricLookupResult) {
        requests[index].continuation.resume(returning: result)
    }
}

extension LyricsPresentation {
    var activeLyricText: String? {
        guard case .following(let following) = self,
              case .track(let track) = following.content,
              case .ready(let context) = track.lyrics else {
            return nil
        }
        return context.active
    }

    var followingContent: FollowingContent? {
        guard case .following(let following) = self else { return nil }
        return following.content
    }

    var playback: PlaybackPresentation? {
        guard case .following(let following) = self,
              case .track(let track) = following.content else { return nil }
        return track.playback
    }

    var lyrics: TrackLyricsPresentation? {
        guard case .following(let following) = self,
              case .track(let track) = following.content else { return nil }
        return track.lyrics
    }

    var trackTitle: String? {
        guard case .following(let following) = self,
              case .track(let track) = following.content else { return nil }
        return track.track.title
    }

    var timingOffset: TimingOffset? {
        switch self {
        case .stopped(let stopped): stopped.timingOffset
        case .requestingAccess(let requesting): requesting.timingOffset
        case .following(let following): following.timingOffset
        }
    }

    var activity: LiveActivityPresentation? {
        switch self {
        case .stopped(let stopped): stopped.activity
        case .requestingAccess: nil
        case .following(let following): following.activity
        }
    }
}
