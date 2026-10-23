import Foundation

struct ContinuousSessionClock: SessionClock {
    private let origin = ContinuousClock.now

    func now() async -> MonotonicInstant {
        let elapsed = origin.duration(to: .now)
        let components = elapsed.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return try! MonotonicInstant(seconds: max(0, seconds))
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        let current = await now()
        let remaining = max(0, deadline.seconds - current.seconds)
        try await Task.sleep(for: .seconds(remaining))
    }
}
