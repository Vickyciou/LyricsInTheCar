import Foundation
import Observation

@MainActor
@Observable
final class LyricsSession {
    enum Command: Sendable {
        case startFollowing
        case stopFollowing
        case setTimingOffset(TimingOffset)
        case startLiveActivity
        case endLiveActivity
        case reconcilePlayback
    }

    private struct Settings {
        var timingOffset: TimingOffset
    }

    private enum TrackLyrics {
        case loading
        case timeline(LyricTimeline)
        case unavailable(LyricUnavailable)
    }

    private struct CurrentTrack {
        let generation: TrackGeneration
        var descriptor: TrackDescriptor
        var cursor: PlaybackCursor
        var lyrics: TrackLyrics
        var context: LyricContext?
    }

    private struct FollowingState {
        let runID: SessionRunID
        var settings: Settings
        var content: Content
        var activity: LiveActivityPresentation
        var wantsActivity: Bool
        var activityRevision: UInt64
        var lastActivityState: LyricsActivityAttributes.ContentState?

        enum Content {
            case blocked(MusicAccessFailure)
            case noPlayback
            case unidentifiedTrack
            case track(CurrentTrack)
        }
    }

    private enum MachineState {
        case stopped(Settings, LiveActivityPresentation)
        case requestingAccess(SessionRunID, Settings)
        case following(FollowingState)
    }

    private enum WakePurpose {
        case lyricBoundary
        case playbackResample
    }

    private let dependencies: LyricsSessionDependencies
    private var state: MachineState
    private var nextGeneration: UInt64 = 0
    private var eventTask: Task<Void, Never>?
    private var lyricTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?

    private(set) var presentation: LyricsPresentation

    init(dependencies: LyricsSessionDependencies) {
        self.dependencies = dependencies
        let settings = Settings(timingOffset: .zero)
        state = .stopped(settings, .notRequested)
        presentation = .stopped(StoppedPresentation(timingOffset: .zero, activity: .notRequested))
    }

    static func live() -> LyricsSession {
        LyricsSession(dependencies: LyricsSessionDependencies(
            playback: SystemMusicPlayback(),
            lyrics: LRCLIBLyricsSource.live(),
            clock: ContinuousSessionClock(),
            activity: ActivityKitLyricsPublisher()
        ))
    }

    func send(_ command: Command) async {
        switch command {
        case .startFollowing:
            await startFollowing()
        case .stopFollowing:
            await stopFollowing()
        case .setTimingOffset(let offset):
            await setTimingOffset(offset)
        case .startLiveActivity:
            await startLiveActivity()
        case .endLiveActivity:
            await endLiveActivity()
        case .reconcilePlayback:
            await reconcilePlayback()
        }
    }

    private func startFollowing() async {
        switch state {
        case .requestingAccess, .following:
            return
        case .stopped(let settings, _):
            let runID = SessionRunID()
            state = .requestingAccess(runID, settings)
            publish()
            let access = await dependencies.playback.requestAccess()
            guard case .requestingAccess(let currentRun, let currentSettings) = state,
                  currentRun == runID else { return }
            switch access {
            case .failure(let failure):
                state = .following(FollowingState(
                    runID: runID,
                    settings: currentSettings,
                    content: .blocked(failure),
                    activity: .notRequested,
                    wantsActivity: false,
                    activityRevision: 0,
                    lastActivityState: nil
                ))
                publish()
            case .success:
                state = .following(FollowingState(
                    runID: runID,
                    settings: currentSettings,
                    content: .noPlayback,
                    activity: .notRequested,
                    wantsActivity: false,
                    activityRevision: 0,
                    lastActivityState: nil
                ))
                publish()
                startObservingPlayback(runID: runID)
                await reconcilePlayback(runID: runID)
            }
        }
    }

    private func stopFollowing() async {
        let settings: Settings
        switch state {
        case .stopped:
            return
        case .requestingAccess(_, let currentSettings):
            settings = currentSettings
        case .following(let following):
            settings = following.settings
        }
        eventTask?.cancel()
        lyricTask?.cancel()
        wakeTask?.cancel()
        eventTask = nil
        lyricTask = nil
        wakeTask = nil
        state = .stopped(settings, .ending)
        publish()
        let activity = await dependencies.activity.reconcile(to: .ended)
        guard case .stopped(let currentSettings, .ending) = state else { return }
        state = .stopped(currentSettings, activity)
        publish()
    }

    private func setTimingOffset(_ offset: TimingOffset) async {
        switch state {
        case .stopped(var settings, let activity):
            settings.timingOffset = offset
            state = .stopped(settings, activity)
        case .requestingAccess(let runID, var settings):
            settings.timingOffset = offset
            state = .requestingAccess(runID, settings)
        case .following(var following):
            following.settings.timingOffset = offset
            state = .following(following)
            await refreshPresentation(runID: following.runID)
            return
        }
        publish()
    }

    private func startLiveActivity() async {
        guard case .following(var following) = state else { return }
        if following.wantsActivity, following.activity == .active { return }
        following.wantsActivity = true
        following.activity = .starting
        let runID = following.runID
        state = .following(following)
        publish()
        let activityState = makeActivityState(
            from: presentation,
            revision: following.activityRevision + 1
        )
        let result = await dependencies.activity.reconcile(to: .visible(activityState))
        guard case .following(var current) = state,
              current.runID == runID,
              current.wantsActivity,
              current.activity == .starting else { return }
        current.activity = result
        if result == .active {
            current.activityRevision += 1
            current.lastActivityState = activityState
        }
        state = .following(current)
        publish()
    }

    private func endLiveActivity() async {
        guard case .following(var following) = state else {
            if case .stopped(let settings, .unavailable(.endFailed)) = state {
                state = .stopped(settings, .ending)
                publish()
                let result = await dependencies.activity.reconcile(to: .ended)
                guard case .stopped(let currentSettings, .ending) = state else { return }
                state = .stopped(currentSettings, result)
                publish()
            }
            return
        }
        following.wantsActivity = false
        following.activity = .ending
        let runID = following.runID
        state = .following(following)
        publish()
        let result = await dependencies.activity.reconcile(to: .ended)
        guard case .following(var current) = state,
              current.runID == runID,
              !current.wantsActivity,
              current.activity == .ending else { return }
        current.activity = result
        state = .following(current)
        publish()
    }

    private func reconcilePlayback() async {
        guard case .following(let following) = state else { return }
        await reconcilePlayback(runID: following.runID)
    }

    private func reconcilePlayback(runID: SessionRunID) async {
        guard case .following(let following) = state, following.runID == runID else { return }
        let observation = dependencies.playback.sample()
        let now = await dependencies.clock.now()
        guard case .following(var current) = state, current.runID == runID else { return }

        switch observation {
        case .accessBlocked(let failure):
            lyricTask?.cancel()
            wakeTask?.cancel()
            current.content = .blocked(failure)
            state = .following(current)
            publish()
        case .noCurrentItem:
            lyricTask?.cancel()
            wakeTask?.cancel()
            current.content = .noPlayback
            state = .following(current)
            publish()
        case .unidentifiedCurrentItem:
            lyricTask?.cancel()
            wakeTask?.cancel()
            current.content = .unidentifiedTrack
            state = .following(current)
            publish()
        case .current(let descriptor, let timing):
            if case .track(var existing) = current.content,
               existing.descriptor.changeToken == descriptor.changeToken {
                existing.descriptor = descriptor
                existing.cursor = cursor(for: timing, descriptor: descriptor, sampledAt: now)
                current.content = .track(existing)
                state = .following(current)
                await refreshPresentation(runID: runID)
                return
            } else {
                nextGeneration &+= 1
                let generation = TrackGeneration(ordinal: nextGeneration)
                let track = CurrentTrack(
                    generation: generation,
                    descriptor: descriptor,
                    cursor: cursor(for: timing, descriptor: descriptor, sampledAt: now),
                    lyrics: .loading,
                    context: nil
                )
                lyricTask?.cancel()
                wakeTask?.cancel()
                current.content = .track(track)
                state = .following(current)
                publish()
                scheduleWake(for: current, now: now)
                startLyricsLookup(runID: runID, generation: generation, descriptor: descriptor)
            }
        }
        await reconcileVisibleActivity(runID: runID)
    }

    private func startObservingPlayback(runID: SessionRunID) {
        eventTask?.cancel()
        let stream = dependencies.playback.events()
        eventTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.reconcilePlayback(runID: runID)
            }
        }
    }

    private func startLyricsLookup(
        runID: SessionRunID,
        generation: TrackGeneration,
        descriptor: TrackDescriptor
    ) {
        lyricTask = Task { [weak self, lyrics = dependencies.lyrics] in
            let result = await lyrics.lyrics(for: descriptor)
            guard !Task.isCancelled else { return }
            await self?.receiveLyrics(result, runID: runID, generation: generation)
        }
    }

    private func receiveLyrics(
        _ result: LyricLookupResult,
        runID: SessionRunID,
        generation: TrackGeneration
    ) async {
        guard case .following(var following) = state,
              following.runID == runID,
              case .track(var track) = following.content,
              track.generation == generation else { return }

        switch result {
        case .unavailable(let reason):
            track.lyrics = .unavailable(reason)
        case .document(let document):
            do {
                track.lyrics = .timeline(try LyricTimeline(validating: document))
            } catch let failure as LyricValidationFailure {
                track.lyrics = .unavailable(.invalidTiming(failure))
            } catch {
                track.lyrics = .unavailable(.sourceFailed)
            }
        }
        following.content = .track(track)
        state = .following(following)
        await refreshPresentation(runID: runID)
    }

    private func refreshPresentation(runID: SessionRunID) async {
        guard case .following(let following) = state, following.runID == runID else { return }
        let now = await dependencies.clock.now()
        guard case .following(var current) = state, current.runID == runID else { return }
        if case .track(var track) = current.content,
           case .timeline(let timeline) = track.lyrics {
            if let position = track.cursor.position(at: now) {
                track.context = timeline.context(at: position.applying(current.settings.timingOffset))
            } else {
                track.context = LyricContext(previous: nil, active: nil, next: nil)
            }
            current.content = .track(track)
            state = .following(current)
        }
        presentation = makePresentation(from: current)
        scheduleWake(for: current, now: now)
        await reconcileVisibleActivity(runID: runID)
    }

    private func scheduleWake(for following: FollowingState, now: MonotonicInstant) {
        wakeTask?.cancel()
        guard case .track(let track) = following.content,
              case .advancing = track.cursor,
              let position = track.cursor.position(at: now) else { return }
        let resampleDeadline = now.advanced(by: 2)
        let lyricDeadline: MonotonicInstant?
        if case .timeline(let timeline) = track.lyrics {
            let selection = position.applying(following.settings.timingOffset)
            lyricDeadline = timeline.nextBoundary(after: selection).map {
                now.advanced(by: $0.seconds - selection.seconds)
            }
        } else {
            lyricDeadline = nil
        }
        let deadline: MonotonicInstant
        let purpose: WakePurpose
        if let lyricDeadline, lyricDeadline <= resampleDeadline {
            deadline = lyricDeadline
            purpose = .lyricBoundary
        } else {
            deadline = resampleDeadline
            purpose = .playbackResample
        }
        let runID = following.runID
        let generation = track.generation
        wakeTask = Task { [weak self, clock = dependencies.clock] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.handleWake(runID: runID, generation: generation, purpose: purpose)
        }
    }

    private func handleWake(
        runID: SessionRunID,
        generation: TrackGeneration,
        purpose: WakePurpose
    ) async {
        guard case .following(let following) = state,
              following.runID == runID,
              case .track(let track) = following.content,
              track.generation == generation else { return }
        switch purpose {
        case .lyricBoundary:
            await refreshPresentation(runID: runID)
        case .playbackResample:
            await reconcilePlayback(runID: runID)
        }
    }

    private func reconcileVisibleActivity(runID: SessionRunID) async {
        guard case .following(let following) = state,
              following.runID == runID,
              following.wantsActivity,
              following.activity == .active else { return }
        let nextRevision = following.activityRevision + 1
        let activityState = makeActivityState(from: presentation, revision: nextRevision)
        if let previous = following.lastActivityState,
           previous.track == activityState.track,
           previous.display == activityState.display {
            return
        }
        let result = await dependencies.activity.reconcile(to: .visible(activityState))
        guard case .following(var current) = state,
              current.runID == runID,
              current.wantsActivity,
              current.activity != .ending else { return }
        current.activity = result
        if result == .active {
            current.activityRevision = nextRevision
            current.lastActivityState = activityState
        }
        state = .following(current)
        publish()
    }

    private func cursor(
        for timing: SampledPlaybackTiming,
        descriptor: TrackDescriptor,
        sampledAt: MonotonicInstant
    ) -> PlaybackCursor {
        switch timing {
        case .advancing(let position):
            .advancing(PlaybackAnchor(
                sampledPosition: position,
                sampledAt: sampledAt,
                trackDuration: descriptor.duration
            ))
        case .frozen(let position, let reason):
            .frozen(position, reason)
        case .positionUnavailable(let reason):
            .unavailable(reason)
        }
    }

    private func publish() {
        switch state {
        case .stopped(let settings, let activity):
            presentation = .stopped(StoppedPresentation(
                timingOffset: settings.timingOffset,
                activity: activity
            ))
        case .requestingAccess(_, let settings):
            presentation = .requestingAccess(RequestingAccessPresentation(
                timingOffset: settings.timingOffset
            ))
        case .following(let following):
            presentation = makePresentation(from: following)
        }
    }

    private func makePresentation(from following: FollowingState) -> LyricsPresentation {
        let content: FollowingContent
        switch following.content {
        case .blocked(let failure):
            content = .blocked(failure)
        case .noPlayback:
            content = .noPlayback
        case .unidentifiedTrack:
            content = .unidentifiedTrack
        case .track(let track):
            let playback: PlaybackPresentation
            switch track.cursor {
            case .advancing:
                playback = .playing
            case .frozen(_, let reason):
                switch reason {
                case .paused: playback = .paused
                case .stopped: playback = .stopped
                case .interrupted: playback = .interrupted
                case .unknown: playback = .positionUnavailable
                }
            case .unavailable:
                playback = .positionUnavailable
            }

            let lyrics: TrackLyricsPresentation
            switch track.lyrics {
            case .loading:
                lyrics = .loading
            case .unavailable(let reason):
                lyrics = .unavailable(reason)
            case .timeline:
                lyrics = .ready(track.context ?? LyricContext(previous: nil, active: nil, next: nil))
            }
            content = .track(TrackPresentation(
                track: TrackSummary(
                    changeToken: track.descriptor.changeToken,
                    title: track.descriptor.title,
                    artist: track.descriptor.artist
                ),
                playback: playback,
                lyrics: lyrics
            ))
        }
        return .following(FollowingPresentation(
            content: content,
            timingOffset: following.settings.timingOffset,
            activity: following.activity
        ))
    }

    private func makeActivityState(
        from presentation: LyricsPresentation,
        revision: UInt64
    ) -> LyricsActivityAttributes.ContentState {
        guard case .following(let following) = presentation else {
            return .init(track: nil, display: .noPlayback, revision: revision)
        }
        let track: LyricsActivityAttributes.ContentState.TrackSnippet?
        let display: LyricsActivityAttributes.ContentState.Display
        switch following.content {
        case .blocked:
            track = nil
            display = .unavailable(.permission)
        case .noPlayback:
            track = nil
            display = .noPlayback
        case .unidentifiedTrack:
            track = nil
            display = .unavailable(.lyrics)
        case .track(let presentation):
            track = .init(title: presentation.track.title, artist: presentation.track.artist)
            let paused = presentation.playback != .playing
            switch presentation.lyrics {
            case .loading, .unavailable:
                display = .unavailable(.lyrics)
            case .ready(let context):
                if presentation.playback == .positionUnavailable {
                    display = .unavailable(.position)
                } else if let active = context.active {
                    display = .lyric(text: active, next: context.next, isPaused: paused)
                } else {
                    display = .noActiveLine(isPaused: paused)
                }
            }
        }
        return .init(track: track, display: display, revision: revision)
    }
}
