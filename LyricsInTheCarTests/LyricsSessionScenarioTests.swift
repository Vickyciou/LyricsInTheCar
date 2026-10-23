import XCTest
@testable import LyricsInTheCar

@MainActor
final class LyricsSessionScenarioTests: XCTestCase {
    func testAuthorizationIsVisibleBeforeSystemRequestReturns() async throws {
        let playback = DeferredAccessPlayback(observation: .noCurrentItem)
        let session = LyricsSession(dependencies: LyricsSessionDependencies(
            playback: playback,
            lyrics: ScriptedLyricsSource(result: .document(.threeLines)),
            clock: ManualSessionClock(),
            activity: RecordingActivityPublisher()
        ))
        let start = Task { await session.send(.startFollowing) }
        await settle()

        XCTAssertEqual(session.presentation, .requestingAccess(.init(timingOffset: .zero)))

        playback.resolveAccess(.success(()))
        await start.value
        XCTAssertEqual(session.presentation.followingContent, .noPlayback)
    }

    func testStartingWithKnownTrackSelectsFixtureLine() async throws {
        let rig = try SessionTestRig(
            observation: .current(
                track: .fixture,
                timing: .advancing(from: PlaybackPosition(seconds: 4))
            ),
            lyrics: .document(.threeLines)
        )

        await rig.session.send(.startFollowing)
        await rig.settle()

        XCTAssertEqual(rig.session.presentation.activeLyricText, "Window light")
    }

    func testMonotonicAdvanceCrossesBoundaryWithoutPlayerSample() async throws {
        let rig = try SessionTestRig(
            observation: .current(track: .fixture, timing: .advancing(from: PlaybackPosition(seconds: 4))),
            lyrics: .document(.threeLines)
        )
        await rig.session.send(.startFollowing)
        await rig.settle()

        await rig.clock.advance(by: 2)
        await rig.settle()

        XCTAssertEqual(rig.session.presentation.activeLyricText, "Open road")
    }

    func testPauseFreezesAndResumeUsesFreshSample() async throws {
        let rig = try SessionTestRig(
            observation: .current(track: .fixture, timing: .advancing(from: PlaybackPosition(seconds: 4))),
            lyrics: .document(.threeLines)
        )
        await rig.session.send(.startFollowing)
        await rig.settle()
        rig.playback.replace(with: .current(
            track: .fixture,
            timing: .frozen(at: try PlaybackPosition(seconds: 4), reason: .paused)
        ), event: .playbackStateChanged)
        await rig.settle()
        await rig.clock.advance(by: 8)
        await rig.settle()

        XCTAssertEqual(rig.session.presentation.activeLyricText, "Window light")
        XCTAssertEqual(rig.session.presentation.playback, .paused)

        rig.playback.replace(with: .current(
            track: .fixture,
            timing: .advancing(from: try PlaybackPosition(seconds: 6))
        ), event: .playbackStateChanged)
        await rig.settle()

        XCTAssertEqual(rig.session.presentation.activeLyricText, "Open road")
        XCTAssertEqual(rig.session.presentation.playback, .playing)
    }

    func testAuthoritativeForwardAndBackwardSeeksReplaceEstimate() async throws {
        let rig = try SessionTestRig(
            observation: .current(track: .fixture, timing: .advancing(from: PlaybackPosition(seconds: 2))),
            lyrics: .document(.threeLines)
        )
        await rig.session.send(.startFollowing)
        await rig.settle()

        rig.playback.replace(with: .current(
            track: .fixture,
            timing: .advancing(from: try PlaybackPosition(seconds: 11))
        ), event: .playbackStateChanged)
        await rig.settle()
        XCTAssertEqual(rig.session.presentation.activeLyricText, "Quiet mile")

        rig.playback.replace(with: .current(
            track: .fixture,
            timing: .advancing(from: try PlaybackPosition(seconds: 2))
        ), event: .playbackStateChanged)
        await rig.settle()
        XCTAssertEqual(rig.session.presentation.activeLyricText, "Window light")
    }

    func testTrackChangeClearsOldTextAndRejectsLateLookup() async throws {
        let playback = ScriptedPlayback(observation: .current(
            track: .fixture,
            timing: .advancing(from: try PlaybackPosition(seconds: 2))
        ))
        let lyrics = DeferredLyricsSource()
        let clock = ManualSessionClock()
        let session = LyricsSession(dependencies: LyricsSessionDependencies(
            playback: playback,
            lyrics: lyrics,
            clock: clock,
            activity: RecordingActivityPublisher()
        ))
        await session.send(.startFollowing)
        await waitUntil { await lyrics.requestCount == 1 }

        playback.replace(with: .current(
            track: .alternate,
            timing: .advancing(from: try PlaybackPosition(seconds: 2))
        ))
        await waitUntil { await lyrics.requestCount == 2 }
        XCTAssertEqual(session.presentation.lyrics, .loading)

        await lyrics.complete(index: 1, with: .document(.alternateLines))
        await settle()
        await lyrics.complete(index: 0, with: .document(.threeLines))
        await settle()

        XCTAssertEqual(session.presentation.trackTitle, "Alternate Song")
        XCTAssertEqual(session.presentation.activeLyricText, "Alternate first")
    }

    func testOldRunCannotReplaceRestartedSessionOnSameTrack() async throws {
        let playback = ScriptedPlayback(observation: .current(
            track: .fixture,
            timing: .advancing(from: try PlaybackPosition(seconds: 2))
        ))
        let lyrics = DeferredLyricsSource()
        let session = LyricsSession(dependencies: LyricsSessionDependencies(
            playback: playback,
            lyrics: lyrics,
            clock: ManualSessionClock(),
            activity: RecordingActivityPublisher()
        ))
        await session.send(.startFollowing)
        await waitUntil { await lyrics.requestCount == 1 }
        await session.send(.stopFollowing)
        await session.send(.startFollowing)
        await waitUntil { await lyrics.requestCount == 2 }

        await lyrics.complete(index: 0, with: .document(.alternateLines))
        await settle()
        XCTAssertEqual(session.presentation.lyrics, .loading)

        await lyrics.complete(index: 1, with: .document(.threeLines))
        await settle()
        XCTAssertEqual(session.presentation.activeLyricText, "Window light")
    }

    func testStopNoPlaybackDeniedAndUnavailablePositionAreDistinct() async throws {
        let noPlayback = try SessionTestRig(observation: .noCurrentItem, lyrics: .document(.threeLines))
        await noPlayback.session.send(.startFollowing)
        XCTAssertEqual(noPlayback.session.presentation.followingContent, .noPlayback)

        let unidentified = try SessionTestRig(
            observation: .unidentifiedCurrentItem,
            lyrics: .document(.threeLines)
        )
        await unidentified.session.send(.startFollowing)
        XCTAssertEqual(unidentified.session.presentation.followingContent, .unidentifiedTrack)

        let denied = try SessionTestRig(observation: .noCurrentItem, lyrics: .document(.threeLines))
        denied.playback.access = .failure(.denied)
        await denied.session.send(.startFollowing)
        XCTAssertEqual(denied.session.presentation.followingContent, .blocked(.denied))

        let unavailable = try SessionTestRig(
            observation: .current(track: .fixture, timing: .positionUnavailable(reason: .unknown)),
            lyrics: .document(.threeLines)
        )
        await unavailable.session.send(.startFollowing)
        await unavailable.settle()
        XCTAssertEqual(unavailable.session.presentation.playback, .positionUnavailable)
        XCTAssertNil(unavailable.session.presentation.activeLyricText)

        await unavailable.session.send(.stopFollowing)
        XCTAssertEqual(unavailable.session.presentation, .stopped(.init(
            timingOffset: .zero,
            activity: .notRequested
        )))
    }

    func testInvalidEmptyAndOverlappingTimelinesStayUnavailable() async throws {
        let empty = try SessionTestRig(
            observation: .current(track: .fixture, timing: .advancing(from: PlaybackPosition(seconds: 1))),
            lyrics: .document(RawTimedLyrics(cues: []))
        )
        await empty.session.send(.startFollowing)
        await empty.settle()
        XCTAssertEqual(empty.session.presentation.lyrics, .unavailable(.invalidTiming(.empty)))

        let overlapping = RawTimedLyrics(cues: [
            RawLyricCue(startSeconds: 0, endSeconds: 5, text: "First"),
            RawLyricCue(startSeconds: 4, endSeconds: 6, text: "Second"),
        ])
        let overlap = try SessionTestRig(
            observation: .current(track: .fixture, timing: .advancing(from: PlaybackPosition(seconds: 1))),
            lyrics: .document(overlapping)
        )
        await overlap.session.send(.startFollowing)
        await overlap.settle()
        XCTAssertEqual(overlap.session.presentation.lyrics, .unavailable(.invalidTiming(.overlap(previous: 0, next: 1))))
    }

    func testExactBoundariesGapsFractionalTimesAndFinalEnd() async throws {
        let lyrics = RawTimedLyrics(cues: [
            RawLyricCue(startSeconds: 0.5, endSeconds: 2.25, text: "Fraction"),
            RawLyricCue(startSeconds: 3, endSeconds: 4, text: "After gap"),
        ])
        let rig = try SessionTestRig(
            observation: .current(track: .fixture, timing: .frozen(at: PlaybackPosition(seconds: 0.5), reason: .paused)),
            lyrics: .document(lyrics)
        )
        await rig.session.send(.startFollowing)
        await rig.settle()
        XCTAssertEqual(rig.session.presentation.activeLyricText, "Fraction")

        rig.playback.replace(with: .current(
            track: .fixture,
            timing: .frozen(at: try PlaybackPosition(seconds: 2.25), reason: .paused)
        ))
        await rig.settle()
        XCTAssertNil(rig.session.presentation.activeLyricText)

        rig.playback.replace(with: .current(
            track: .fixture,
            timing: .frozen(at: try PlaybackPosition(seconds: 3), reason: .paused)
        ))
        await rig.settle()
        XCTAssertEqual(rig.session.presentation.activeLyricText, "After gap")

        rig.playback.replace(with: .current(
            track: .fixture,
            timing: .frozen(at: try PlaybackPosition(seconds: 4), reason: .paused)
        ))
        await rig.settle()
        XCTAssertNil(rig.session.presentation.activeLyricText)
    }

    func testPositiveAndNegativeOffsetsChangeSelectionOnly() async throws {
        let rig = try SessionTestRig(
            observation: .current(track: .fixture, timing: .frozen(at: PlaybackPosition(seconds: 4.5), reason: .paused)),
            lyrics: .document(.threeLines)
        )
        await rig.session.send(.startFollowing)
        await rig.settle()

        await rig.session.send(.setTimingOffset(try TimingOffset(seconds: 0.5)))
        XCTAssertEqual(rig.session.presentation.activeLyricText, "Open road")
        XCTAssertEqual(rig.session.presentation.playback, .paused)

        await rig.session.send(.setTimingOffset(try TimingOffset(seconds: -0.5)))
        XCTAssertEqual(rig.session.presentation.activeLyricText, "Window light")
        XCTAssertEqual(rig.session.presentation.timingOffset, try TimingOffset(seconds: -0.5))
    }

    func testForegroundReconciliationReplacesInterruptedEstimate() async throws {
        let rig = try SessionTestRig(
            observation: .current(track: .fixture, timing: .advancing(from: PlaybackPosition(seconds: 9))),
            lyrics: .document(.threeLines)
        )
        await rig.session.send(.startFollowing)
        await rig.settle()
        rig.playback.observation = .current(
            track: .fixture,
            timing: .frozen(at: try PlaybackPosition(seconds: 2), reason: .interrupted)
        )

        await rig.session.send(.reconcilePlayback)

        XCTAssertEqual(rig.session.presentation.playback, .interrupted)
        XCTAssertEqual(rig.session.presentation.activeLyricText, "Window light")
    }

    func testSourceFailuresRemainExplicit() async throws {
        let ambiguous = try SessionTestRig(
            observation: .current(track: .fixture, timing: .advancing(from: PlaybackPosition(seconds: 2))),
            lyrics: .unavailable(.ambiguousMatch)
        )
        await ambiguous.session.send(.startFollowing)
        await ambiguous.settle()
        XCTAssertEqual(ambiguous.session.presentation.lyrics, .unavailable(.ambiguousMatch))

        let failed = try SessionTestRig(
            observation: .current(track: .fixture, timing: .advancing(from: PlaybackPosition(seconds: 2))),
            lyrics: .unavailable(.sourceFailed)
        )
        await failed.session.send(.startFollowing)
        await failed.settle()
        XCTAssertEqual(failed.session.presentation.lyrics, .unavailable(.sourceFailed))
    }

    func testFixtureSourceTreatsDuplicateMetadataMatchAsAmbiguous() async throws {
        let data = Data(fixtureManifestWithDuplicateMetadata.utf8)
        let track = try TrackDescriptor(
            changeToken: TrackChangeToken(validated: "unidentified"),
            recordingIdentity: .unavailable,
            title: "Fixture Song",
            artist: "Studio Placeholder",
            album: nil,
            duration: TrackDuration(seconds: 30)
        )
        let playback = ScriptedPlayback(observation: .current(
            track: track,
            timing: .advancing(from: try PlaybackPosition(seconds: 2))
        ))
        let session = LyricsSession(dependencies: LyricsSessionDependencies(
            playback: playback,
            lyrics: FixtureLyricsSource(data: data),
            clock: ManualSessionClock(),
            activity: RecordingActivityPublisher()
        ))

        await session.send(.startFollowing)
        await settle()

        XCTAssertEqual(session.presentation.lyrics, .unavailable(.ambiguousMatch))
    }

    func testLiveActivityRequiresExplicitStartAndPreservesEndFailure() async throws {
        let rig = try SessionTestRig(
            observation: .current(track: .fixture, timing: .advancing(from: PlaybackPosition(seconds: 2))),
            lyrics: .document(.threeLines)
        )
        await rig.session.send(.startFollowing)
        await rig.settle()
        let submissionsBeforeStart = await rig.activity.recordedSubmissions()
        XCTAssertEqual(submissionsBeforeStart, [])

        await rig.session.send(.startLiveActivity)
        XCTAssertEqual(rig.session.presentation.activity, .active)
        let submissionsAfterStart = await rig.activity.recordedSubmissions()
        XCTAssertEqual(submissionsAfterStart.count, 1)

        await rig.clock.advance(by: 2)
        await rig.settle()
        let submissionsAfterUnchangedResample = await rig.activity.recordedSubmissions()
        XCTAssertEqual(submissionsAfterUnchangedResample.count, 1)

        await rig.activity.setNextResult(.unavailable(.endFailed))
        await rig.session.send(.stopFollowing)
        XCTAssertEqual(rig.session.presentation, .stopped(.init(
            timingOffset: .zero,
            activity: .unavailable(.endFailed)
        )))
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private var fixtureManifestWithDuplicateMetadata: String {
        """
        {
          "schemaVersion": 1,
          "recordings": [
            {
              "storeID": "one",
              "title": "Fixture Song",
              "artist": "Studio Placeholder",
              "durationSeconds": 30,
              "durationToleranceSeconds": 1,
              "lyrics": { "cues": [{ "startSeconds": 0, "endSeconds": 5, "text": "One", "spans": [] }] }
            },
            {
              "storeID": "two",
              "title": "Fixture Song",
              "artist": "Studio Placeholder",
              "durationSeconds": 30,
              "durationToleranceSeconds": 1,
              "lyrics": { "cues": [{ "startSeconds": 0, "endSeconds": 5, "text": "Two", "spans": [] }] }
            }
          ]
        }
        """
    }
}
