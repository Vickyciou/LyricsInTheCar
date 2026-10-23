import Foundation

nonisolated struct TimedLyricSpan: Hashable, Sendable {
    let interval: Range<PlaybackPosition>
    let text: String
}

nonisolated struct TimedLyricLine: Hashable, Sendable {
    let interval: Range<PlaybackPosition>
    let text: String
    let spans: [TimedLyricSpan]
}

nonisolated struct LyricTimeline: Hashable, Sendable {
    private let lines: [TimedLyricLine]

    init(validating document: RawTimedLyrics) throws {
        guard !document.cues.isEmpty else { throw LyricValidationFailure.empty }
        let sorted = document.cues.enumerated().sorted { lhs, rhs in
            lhs.element.startSeconds < rhs.element.startSeconds
        }
        var validated: [TimedLyricLine] = []

        for (sortedIndex, pair) in sorted.enumerated() {
            let sourceIndex = pair.offset
            let cue = pair.element
            guard cue.startSeconds.isFinite,
                  cue.endSeconds?.isFinite ?? true else {
                throw LyricValidationFailure.nonFiniteTimestamp(cue: sourceIndex)
            }
            guard cue.startSeconds >= 0,
                  (cue.endSeconds ?? 0) >= 0 else {
                throw LyricValidationFailure.negativeTimestamp(cue: sourceIndex)
            }
            let endSeconds: Double
            if let explicitEnd = cue.endSeconds {
                endSeconds = explicitEnd
            } else if sortedIndex + 1 < sorted.count {
                endSeconds = sorted[sortedIndex + 1].element.startSeconds
            } else {
                throw LyricValidationFailure.missingFinalEnd
            }
            guard endSeconds > cue.startSeconds else {
                throw LyricValidationFailure.nonPositiveRange(cue: sourceIndex)
            }
            if let previous = validated.last,
               previous.interval.upperBound.seconds > cue.startSeconds {
                throw LyricValidationFailure.overlap(previous: sorted[sortedIndex - 1].offset, next: sourceIndex)
            }

            let start = try PlaybackPosition(seconds: cue.startSeconds)
            let end = try PlaybackPosition(seconds: endSeconds)
            var spans: [TimedLyricSpan] = []
            for (spanIndex, span) in cue.spans.enumerated() {
                guard span.startSeconds.isFinite,
                      span.endSeconds.isFinite,
                      span.startSeconds >= cue.startSeconds,
                      span.endSeconds <= endSeconds,
                      span.endSeconds > span.startSeconds else {
                    throw LyricValidationFailure.invalidSpan(cue: sourceIndex, span: spanIndex)
                }
                spans.append(TimedLyricSpan(
                    interval: try PlaybackPosition(seconds: span.startSeconds)..<PlaybackPosition(seconds: span.endSeconds),
                    text: span.text
                ))
            }
            validated.append(TimedLyricLine(interval: start..<end, text: cue.text, spans: spans))
        }
        lines = validated
    }

    func line(at position: PlaybackPosition) -> TimedLyricLine? {
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lines[middle].interval.lowerBound <= position {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        let candidate = lines[lower - 1]
        return candidate.interval.contains(position) ? candidate : nil
    }

    func context(at position: PlaybackPosition) -> LyricContext {
        guard let index = lines.lastIndex(where: { $0.interval.lowerBound <= position }),
              lines[index].interval.contains(position) else {
            return LyricContext(previous: nil, active: nil, next: nil)
        }
        return LyricContext(
            previous: index > 0 ? lines[index - 1].text : nil,
            active: lines[index].text,
            next: index + 1 < lines.count ? lines[index + 1].text : nil
        )
    }

    func nextBoundary(after position: PlaybackPosition) -> PlaybackPosition? {
        lines.lazy
            .flatMap { [$0.interval.lowerBound, $0.interval.upperBound] }
            .filter { $0 > position }
            .min()
    }
}
