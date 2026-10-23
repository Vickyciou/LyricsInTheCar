import Foundation

struct FixtureLyricsSource: TimedLyricsLoading {
    private struct Manifest: Decodable {
        struct Recording: Decodable {
            let storeID: String?
            let title: String
            let artist: String
            let durationSeconds: Double
            let durationToleranceSeconds: Double
            let lyrics: RawTimedLyrics
        }

        let schemaVersion: Int
        let recordings: [Recording]
    }

    private let loadData: @Sendable () throws -> Data

    init(bundle: Bundle = .main) {
        loadData = {
            guard let url = bundle.url(forResource: "known-recording", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try Data(contentsOf: url)
        }
    }

    init(data: Data) {
        loadData = { data }
    }

    func lyrics(for track: TrackDescriptor) async -> LyricLookupResult {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: loadData())
            guard manifest.schemaVersion == 1 else { return .unavailable(.sourceFailed) }
        } catch {
            return .unavailable(.sourceFailed)
        }

        let matches = manifest.recordings.filter { recording in
            if case .identified(let identity) = track.recordingIdentity,
               identity.authority == .store,
               let storeID = recording.storeID {
                return identity.rawValue == storeID
            }
            guard recording.title.caseInsensitiveCompare(track.title) == .orderedSame,
                  recording.artist.caseInsensitiveCompare(track.artist) == .orderedSame,
                  let duration = track.duration else { return false }
            return abs(recording.durationSeconds - duration.seconds) <= recording.durationToleranceSeconds
        }
        guard !matches.isEmpty else {
            if track.recordingIdentity == .unavailable, track.duration == nil {
                return .unavailable(.unidentifiedRecording)
            }
            return .unavailable(.recordingMismatch)
        }
        guard matches.count == 1 else { return .unavailable(.ambiguousMatch) }
        return .document(matches[0].lyrics)
    }
}
