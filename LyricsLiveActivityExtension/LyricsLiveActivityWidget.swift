import ActivityKit
import SwiftUI
import WidgetKit

struct LyricsLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityView(state: context.state)
                .activityBackgroundTint(.black.opacity(0.86))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.purple)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    playbackIndicator(for: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityLyricText(state: context.state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                playbackIndicator(for: context.state)
            } minimal: {
                Image(systemName: "text.quote")
            }
            .keylineTint(.purple)
        }
        .supplementalActivityFamilies([.small])
    }

    @ViewBuilder
    private func playbackIndicator(for state: LyricsActivityAttributes.ContentState) -> some View {
        switch state.display {
        case .lyric(_, let isPaused), .noActiveLine(let isPaused):
            Image(systemName: isPaused ? "pause.fill" : "waveform")
        case .noPlayback:
            Image(systemName: "stop.fill")
        case .unavailable:
            Image(systemName: "exclamationmark.triangle")
        }
    }
}

struct LyricsActivityView: View {
    @Environment(\.activityFamily) private var family
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        if family == .small {
            SmallCarPlayLyricsView(state: state)
        } else {
            LockScreenLyricsView(state: state)
        }
    }
}

struct LockScreenLyricsView: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let track = state.track {
                Text(track.title)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ActivityLyricText(state: state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

struct SmallCarPlayLyricsView: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let track = state.track {
                Text(track.title)
                    .font(.caption.bold())
                    .lineLimit(1)
            }
            ActivityLyricText(state: state)
                .font(.headline)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

struct ActivityLyricText: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        switch state.display {
        case .lyric(let text, let isPaused):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isPaused { Image(systemName: "pause.fill") }
                Text(text)
            }
        case .noActiveLine:
            Text("Instrumental")
                .foregroundStyle(.secondary)
        case .noPlayback:
            Text("Nothing is playing")
                .foregroundStyle(.secondary)
        case .unavailable(let reason):
            Text(message(for: reason))
                .foregroundStyle(.secondary)
        }
    }

    private func message(for reason: LyricsActivityAttributes.ContentState.UnavailableReason) -> String {
        switch reason {
        case .permission: "Music access required"
        case .position: "Playback position unavailable"
        case .lyrics: "Lyrics unavailable"
        }
    }
}
