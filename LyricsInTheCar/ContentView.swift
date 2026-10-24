import SwiftUI

struct ContentView: View {
    @Bindable var session: LyricsSession

    var body: some View {
        LyricsScreen(presentation: session.presentation) { command in
            Task { await session.send(command) }
        }
    }
}

struct LyricsScreen: View {
    let presentation: LyricsPresentation
    let send: (LyricsSession.Command) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                statusCard
                offsetCard
                controls
                Text("Foreground synchronization is implemented. Lock-screen, sustained background, and CarPlay timing remain unverified on a real device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("background-status")
            }
            .padding(20)
        }
        .background(
            LinearGradient(
                colors: [Color.indigo.opacity(0.22), Color.black.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lyrics in the Car")
                .font(.largeTitle.bold())
            Text("Follow Apple Music without controlling playback.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch presentation {
            case .stopped(let stopped):
                Label("Following stopped", systemImage: "stop.circle")
                    .font(.title2.bold())
                Text(activityMessage(stopped.activity))
                    .foregroundStyle(stopped.activity == .unavailable(.endFailed) ? .red : .secondary)
            case .requestingAccess:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Requesting Apple Music access")
                        .font(.headline)
                }
            case .following(let following):
                followingContent(following)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityIdentifier("lyrics-status")
    }

    @ViewBuilder
    private func followingContent(_ following: FollowingPresentation) -> some View {
        switch following.content {
        case .blocked(let failure):
            Label(accessFailureTitle(failure), systemImage: "lock.trianglebadge.exclamationmark")
                .font(.title2.bold())
            Text("Open Settings to allow Media & Apple Music access, then retry.")
                .foregroundStyle(.secondary)
        case .noPlayback:
            Label("Nothing is playing", systemImage: "music.note.slash")
                .font(.title2.bold())
            Text("Start a song in Apple Music, then retry here.")
                .foregroundStyle(.secondary)
        case .unidentifiedTrack:
            Label("Current song is unavailable", systemImage: "questionmark.circle")
                .font(.title2.bold())
            Text("Apple Music is playing, but this item does not expose enough metadata to match lyrics.")
                .foregroundStyle(.secondary)
        case .track(let track):
            Text(track.track.title)
                .font(.headline)
            Text(track.track.artist)
                .foregroundStyle(.secondary)
            lyricContent(track.lyrics)
            Label(playbackTitle(track.playback), systemImage: playbackIcon(track.playback))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if case .unavailable(let failure) = following.activity {
            Label(activityFailureTitle(failure), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func lyricContent(_ lyrics: TrackLyricsPresentation) -> some View {
        switch lyrics {
        case .loading:
            HStack {
                ProgressView()
                Text("Resolving lyrics")
            }
        case .ready(let context):
            Text(context.active ?? "Instrumental")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .accessibilityIdentifier("active-lyric")
            if let next = context.next {
                Text(next)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .unavailable(let reason):
            Text(lyricUnavailableTitle(reason))
                .font(.title3.bold())
            Text("No synchronized text is being guessed for this recording.")
                .foregroundStyle(.secondary)
        }
    }

    private var offsetCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Display timing")
                    .font(.headline)
                Text("Positive values show lyrics earlier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                setOffset(currentOffset - 0.1)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("offset-decrease")
            Text(currentOffset, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
                .frame(width: 48)
            Button {
                setOffset(currentOffset + 0.1)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("offset-increase")
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            switch presentation {
            case .stopped(let stopped):
                Button("Start following", systemImage: "play.fill") {
                    send(.startFollowing)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("start-following")
                if stopped.activity == .unavailable(.endFailed) {
                    Button("Retry ending Live Activity", systemImage: "xmark.circle") {
                        send(.endLiveActivity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("retry-end-activity")
                }
            case .requestingAccess:
                Button("Stop", systemImage: "stop.fill") {
                    send(.stopFollowing)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("stop-following")
            case .following(let following):
                HStack {
                    Button("Stop", systemImage: "stop.fill") {
                        send(.stopFollowing)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("stop-following")
                    Button("Retry", systemImage: "arrow.clockwise") {
                        send(.reconcilePlayback)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("retry-following")
                }
                if following.activity == .active || following.activity == .ending {
                    Button("End Live Activity", systemImage: "rectangle.slash") {
                        send(.endLiveActivity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("end-live-activity")
                } else {
                    Button("Start Live Activity", systemImage: "rectangle.inset.filled.and.person.filled") {
                        send(.startLiveActivity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("start-live-activity")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var currentOffset: Double {
        switch presentation {
        case .stopped(let stopped): stopped.timingOffset.seconds
        case .requestingAccess(let requesting): requesting.timingOffset.seconds
        case .following(let following): following.timingOffset.seconds
        }
    }

    private func setOffset(_ value: Double) {
        let clamped = min(3, max(-3, value))
        guard let offset = try? TimingOffset(seconds: clamped) else { return }
        send(.setTimingOffset(offset))
    }

    private func accessFailureTitle(_ failure: MusicAccessFailure) -> String {
        switch failure {
        case .denied: "Music access denied"
        case .restricted: "Music access restricted"
        case .unavailable: "Music access unavailable"
        }
    }

    private func playbackTitle(_ playback: PlaybackPresentation) -> String {
        switch playback {
        case .playing: "Playing"
        case .paused: "Paused"
        case .stopped: "Playback stopped"
        case .interrupted: "Playback interrupted"
        case .positionUnavailable: "Playback position unavailable"
        }
    }

    private func playbackIcon(_ playback: PlaybackPresentation) -> String {
        switch playback {
        case .playing: "waveform"
        case .paused: "pause.fill"
        case .stopped: "stop.fill"
        case .interrupted: "exclamationmark.arrow.triangle.2.circlepath"
        case .positionUnavailable: "questionmark.circle"
        }
    }

    private func lyricUnavailableTitle(_ reason: LyricUnavailable) -> String {
        switch reason {
        case .noFixture: "No fixture lyrics"
        case .noSynchronizedLyrics: "No synchronized lyrics"
        case .unidentifiedRecording: "Recording could not be identified"
        case .recordingMismatch: "Returned recording did not match"
        case .ambiguousMatch: "Recording match is ambiguous"
        case .sourceFailed: "Lyric source failed"
        case .invalidTiming: "Lyric timing is invalid"
        }
    }

    private func activityMessage(_ activity: LiveActivityPresentation) -> String {
        switch activity {
        case .unavailable(.endFailed): "The Live Activity may still be visible. Retry ending it."
        default: "No lyrics are being followed."
        }
    }

    private func activityFailureTitle(_ failure: LiveActivityFailure) -> String {
        switch failure {
        case .disabled: "Live Activities are disabled"
        case .startFailed: "Live Activity could not start"
        case .updateFailed: "Live Activity could not update"
        case .endFailed: "Live Activity could not end"
        }
    }
}

#Preview("Stopped") {
    LyricsScreen(
        presentation: .stopped(.init(timingOffset: .zero, activity: .notRequested)),
        send: { _ in }
    )
}

#Preview("Following") {
    LyricsScreen(
        presentation: .following(.init(
            content: .track(.init(
                track: .init(
                    changeToken: try! TrackChangeToken(validated: "preview"),
                    title: "Fixture Song",
                    artist: "Studio Placeholder"
                ),
                playback: .playing,
                lyrics: .ready(.init(previous: nil, active: "Window light", next: "Open road"))
            )),
            timingOffset: .zero,
            activity: .active
        )),
        send: { _ in }
    )
}
