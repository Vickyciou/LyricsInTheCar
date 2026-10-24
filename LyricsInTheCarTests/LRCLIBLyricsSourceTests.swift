import XCTest
@testable import LyricsInTheCar

final class LRCLIBLyricsSourceTests: XCTestCase {
    func testSuccessfulResponseSendsIdentifiedExactRequestAndCreatesCueIntervalsAcrossBlankBoundary() async throws {
        let transport = StubLRCLIBTransport(steps: [
            .response(
                statusCode: 200,
                body: responseBody(syncedLyrics: "[00:01.00]First\n[00:04.50]\n[00:06.00]Second")
            ),
        ])
        let source = makeSource(transport: transport)

        let result = await source.lyrics(for: try makeTrack(duration: 30.4))

        XCTAssertEqual(document(from: result), RawTimedLyrics(cues: [
            RawLyricCue(startSeconds: 1, endSeconds: 4.5, text: "First"),
            RawLyricCue(startSeconds: 6, endSeconds: 30.4, text: "Second"),
        ]))

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "User-Agent"), "LyricsInTheCarTests/1")
        XCTAssertEqual(queryValues(in: requests[0]), [
            "track_name": "Song & Rain",
            "artist_name": "Artist",
            "album_name": "Album",
            "duration": "30",
        ])
    }

    func testEqualTimestampLinesCoalesceInSourceOrderAndRemoveExactDuplicates() async throws {
        let transport = StubLRCLIBTransport(steps: [
            .response(
                statusCode: 200,
                body: responseBody(syncedLyrics: "[00:01]First\n[00:01]First\n[00:01]Harmony\n[00:03]Next")
            ),
        ])
        let source = makeSource(transport: transport)

        let result = await source.lyrics(for: try makeTrack(duration: 30.4))

        XCTAssertEqual(document(from: result), RawTimedLyrics(cues: [
            RawLyricCue(startSeconds: 1, endSeconds: 3, text: "First\nHarmony"),
            RawLyricCue(startSeconds: 3, endSeconds: 30.4, text: "Next"),
        ]))
    }

    func testMissingDurationDoesNotMakeARequest() async throws {
        let transport = StubLRCLIBTransport(steps: [])
        let source = makeSource(transport: transport)

        let result = await source.lyrics(for: try makeTrack(duration: nil))

        let requests = await transport.recordedRequests()
        XCTAssertEqual(unavailableReason(from: result), .unidentifiedRecording)
        XCTAssertEqual(requests.count, 0)
    }

    func testMismatchedRecordingIsRejected() async throws {
        let transport = StubLRCLIBTransport(steps: [
            .response(
                statusCode: 200,
                body: responseBody(duration: 42, syncedLyrics: "[00:01]Wrong recording")
            ),
        ])
        let source = makeSource(transport: transport)

        let result = await source.lyrics(for: try makeTrack(duration: 30.4))

        XCTAssertEqual(unavailableReason(from: result), .recordingMismatch)
    }

    func testMissingSynchronizedLyricsHasSpecificUnavailableReason() async throws {
        let transport = StubLRCLIBTransport(steps: [
            .response(statusCode: 200, body: responseBody(syncedLyrics: nil)),
            .response(statusCode: 404, body: Data()),
        ])
        let source = makeSource(transport: transport)
        let track = try makeTrack(duration: 30.4)

        let plainOnly = await source.lyrics(for: track)
        let missing = await source.lyrics(for: track)

        XCTAssertEqual(unavailableReason(from: plainOnly), .noSynchronizedLyrics)
        XCTAssertEqual(unavailableReason(from: missing), .noSynchronizedLyrics)
    }

    func testMalformedPayloadAndNetworkFailureBecomeSourceFailure() async throws {
        let transport = StubLRCLIBTransport(steps: [
            .response(statusCode: 200, body: Data("not-json".utf8)),
            .failure(.notConnectedToInternet),
        ])
        let source = makeSource(transport: transport)
        let track = try makeTrack(duration: 30.4)

        let malformed = await source.lyrics(for: track)
        let disconnected = await source.lyrics(for: track)

        XCTAssertEqual(unavailableReason(from: malformed), .sourceFailed)
        XCTAssertEqual(unavailableReason(from: disconnected), .sourceFailed)
    }

    func testRetryAfterSuppressesRequestsUntilCooldownExpires() async throws {
        let clock = TestDate(Date(timeIntervalSince1970: 1_000))
        let transport = StubLRCLIBTransport(steps: [
            .response(statusCode: 429, body: Data(), headers: ["Retry-After": "10"]),
            .response(statusCode: 200, body: responseBody(syncedLyrics: "[00:01]Ready")),
        ])
        let source = makeSource(transport: transport, now: clock.now)
        let track = try makeTrack(duration: 30.4)

        let first = await source.lyrics(for: track)
        let suppressed = await source.lyrics(for: track)
        let requestsDuringCooldown = await transport.recordedRequests()

        XCTAssertEqual(unavailableReason(from: first), .sourceFailed)
        XCTAssertEqual(unavailableReason(from: suppressed), .sourceFailed)
        XCTAssertEqual(requestsDuringCooldown.count, 1)

        clock.advance(by: 10)

        let recovered = await source.lyrics(for: track)
        let requestsAfterCooldown = await transport.recordedRequests()

        XCTAssertNotNil(document(from: recovered))
        XCTAssertEqual(requestsAfterCooldown.count, 2)
    }

    private func makeSource(
        transport: StubLRCLIBTransport,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000) }
    ) -> LRCLIBLyricsSource {
        LRCLIBLyricsSource(
            endpoint: URL(string: "https://lrclib.test/api/get")!,
            userAgent: "LyricsInTheCarTests/1",
            now: now,
            request: { request in try await transport.response(for: request) }
        )
    }

    private func makeTrack(duration: Double?) throws -> TrackDescriptor {
        try TrackDescriptor(
            changeToken: TrackChangeToken(validated: "test-track"),
            recordingIdentity: .unavailable,
            title: "Song & Rain",
            artist: "Artist",
            album: "Album",
            duration: try duration.map(TrackDuration.init(seconds:))
        )
    }

    private func responseBody(
        trackName: String = "Song & Rain",
        artistName: String = "Artist",
        albumName: String = "Album",
        duration: Double = 30.2,
        syncedLyrics: String?
    ) -> Data {
        let payload: [String: Any] = [
            "trackName": trackName,
            "artistName": artistName,
            "albumName": albumName,
            "duration": duration,
            "syncedLyrics": syncedLyrics ?? NSNull(),
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func document(from result: LyricLookupResult) -> RawTimedLyrics? {
        guard case .document(let document) = result else { return nil }
        return document
    }

    private func unavailableReason(from result: LyricLookupResult) -> LyricUnavailable? {
        guard case .unavailable(let reason) = result else { return nil }
        return reason
    }

    private func queryValues(in request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}

private actor StubLRCLIBTransport {
    enum Step: Sendable {
        case response(statusCode: Int, body: Data, headers: [String: String] = [:])
        case failure(URLError.Code)
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }

        switch steps.removeFirst() {
        case .response(let statusCode, let body, let headers):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            return (body, response)
        case .failure(let code):
            throw URLError(code)
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private final class TestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            value = value.addingTimeInterval(interval)
        }
    }
}
