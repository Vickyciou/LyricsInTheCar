import Foundation

actor LRCLIBLyricsSource: TimedLyricsLoading {
    typealias Request = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct Response: Decodable {
        let trackName: String
        let artistName: String
        let albumName: String?
        let duration: Double
        let syncedLyrics: String?
    }

    private struct Marker {
        let seconds: Double
        let text: String?
        let order: Int
    }

    private let endpoint: URL
    private let userAgent: String
    private let now: @Sendable () -> Date
    private let request: Request
    private var retryNotBefore: Date?

    init(
        endpoint: URL,
        userAgent: String,
        now: @escaping @Sendable () -> Date,
        request: @escaping Request
    ) {
        self.endpoint = endpoint
        self.userAgent = userAgent
        self.now = now
        self.request = request
    }

    nonisolated static func live() -> LRCLIBLyricsSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return LRCLIBLyricsSource(
            endpoint: URL(string: "https://lrclib.net/api/get")!,
            userAgent: "LyricsInTheCar/\(version) (https://github.com/Vickyciou/LyricsInTheCar)",
            now: Date.init,
            request: { request in try await session.data(for: request) }
        )
    }

    func lyrics(for track: TrackDescriptor) async -> LyricLookupResult {
        guard let duration = track.duration else {
            return .unavailable(.unidentifiedRecording)
        }

        let requestDate = now()
        if let retryNotBefore, requestDate < retryNotBefore {
            return .unavailable(.sourceFailed)
        }
        retryNotBefore = nil

        guard let urlRequest = makeRequest(for: track, duration: duration) else {
            return .unavailable(.sourceFailed)
        }

        do {
            let (data, response) = try await request(urlRequest)
            guard !Task.isCancelled else {
                return .unavailable(.sourceFailed)
            }
            guard let response = response as? HTTPURLResponse else {
                return .unavailable(.sourceFailed)
            }

            switch response.statusCode {
            case 200:
                return decode(data, for: track, duration: duration)
            case 404:
                return .unavailable(.noSynchronizedLyrics)
            case 429:
                recordRetryDelay(response.value(forHTTPHeaderField: "Retry-After"), from: requestDate)
                return .unavailable(.sourceFailed)
            default:
                return .unavailable(.sourceFailed)
            }
        } catch {
            return .unavailable(.sourceFailed)
        }
    }

    private func makeRequest(for track: TrackDescriptor, duration: TrackDuration) -> URLRequest? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
        ]
        if let album = nonblank(track.album) {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration.seconds.rounded()))))
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func decode(
        _ data: Data,
        for track: TrackDescriptor,
        duration: TrackDuration
    ) -> LyricLookupResult {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return .unavailable(.sourceFailed)
        }
        guard matches(response, track: track, duration: duration) else {
            return .unavailable(.recordingMismatch)
        }
        guard let synchronized = nonblank(response.syncedLyrics) else {
            return .unavailable(.noSynchronizedLyrics)
        }
        guard let lyrics = parse(synchronized, trackDuration: duration.seconds) else {
            return .unavailable(.sourceFailed)
        }
        return .document(lyrics)
    }

    private func matches(
        _ response: Response,
        track: TrackDescriptor,
        duration: TrackDuration
    ) -> Bool {
        guard normalized(response.trackName) == normalized(track.title),
              normalized(response.artistName) == normalized(track.artist),
              response.duration.isFinite,
              Int(response.duration.rounded()) == Int(duration.seconds.rounded()) else {
            return false
        }
        if let album = nonblank(track.album) {
            return normalized(response.albumName ?? "") == normalized(album)
        }
        return true
    }

    private func parse(_ lrc: String, trackDuration: Double) -> RawTimedLyrics? {
        var markers: [Marker] = []
        var order = 0

        for line in lrc.components(separatedBy: .newlines) {
            var remainder = line[line.startIndex...]
            var timestamps: [Double] = []

            while remainder.first == "[", let closing = remainder.firstIndex(of: "]") {
                let tagStart = remainder.index(after: remainder.startIndex)
                let tag = String(remainder[tagStart..<closing])
                guard let timestamp = timestamp(from: tag) else { break }
                timestamps.append(timestamp)
                remainder = remainder[remainder.index(after: closing)...]
            }

            guard !timestamps.isEmpty else { continue }
            let text = nonblank(String(remainder))
            for timestamp in timestamps {
                markers.append(Marker(seconds: timestamp, text: text, order: order))
                order += 1
            }
        }

        let sorted = markers.sorted {
            $0.seconds == $1.seconds ? $0.order < $1.order : $0.seconds < $1.seconds
        }
        var grouped: [Marker] = []

        for marker in sorted {
            if let last = grouped.last, last.seconds == marker.seconds {
                let texts = [last.text, marker.text]
                    .compactMap { $0 }
                    .reduce(into: [String]()) { result, text in
                        if !result.contains(text) { result.append(text) }
                    }
                grouped[grouped.count - 1] = Marker(
                    seconds: marker.seconds,
                    text: texts.isEmpty ? nil : texts.joined(separator: "\n"),
                    order: last.order
                )
            } else {
                grouped.append(marker)
            }
        }

        let cues = grouped.enumerated().compactMap { index, marker -> RawLyricCue? in
            guard let text = marker.text else { return nil }
            let end = index + 1 < grouped.count ? grouped[index + 1].seconds : trackDuration
            guard marker.seconds >= 0, marker.seconds < end, end <= trackDuration else { return nil }
            return RawLyricCue(startSeconds: marker.seconds, endSeconds: end, text: text)
        }
        return cues.isEmpty ? nil : RawTimedLyrics(cues: cues)
    }

    private func timestamp(from tag: String) -> Double? {
        let parts = tag.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]),
              minutes.isFinite,
              seconds.isFinite,
              minutes >= 0,
              seconds >= 0,
              seconds < 60 else {
            return nil
        }
        return minutes * 60 + seconds
    }

    private func recordRetryDelay(_ value: String?, from requestDate: Date) {
        guard let value,
              let seconds = TimeInterval(value),
              seconds.isFinite,
              seconds > 0 else {
            return
        }
        retryNotBefore = requestDate.addingTimeInterval(seconds)
    }

    private func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
