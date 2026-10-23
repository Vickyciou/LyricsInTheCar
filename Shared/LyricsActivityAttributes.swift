import ActivityKit

nonisolated struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        struct TrackSnippet: Codable, Hashable, Sendable {
            let title: String
            let artist: String
        }

        enum Display: Codable, Hashable, Sendable {
            case lyric(text: String, isPaused: Bool)
            case noActiveLine(isPaused: Bool)
            case noPlayback
            case unavailable(UnavailableReason)
        }

        enum UnavailableReason: String, Codable, Hashable, Sendable {
            case permission
            case position
            case lyrics
        }

        let track: TrackSnippet?
        let display: Display
        let revision: UInt64
    }

    let schemaVersion: UInt8
}
