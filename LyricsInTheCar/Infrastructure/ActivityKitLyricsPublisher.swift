import ActivityKit
import Foundation

actor ActivityKitLyricsPublisher: LyricsActivityPublishing {
    private var lastState: LyricsActivityAttributes.ContentState?

    func reconcile(to desired: DesiredActivity) async -> LiveActivityPresentation {
        switch desired {
        case .ended:
            do {
                for activity in Activity<LyricsActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                lastState = nil
                return .notRequested
            }
        case .visible(let state):
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                return .unavailable(.disabled)
            }
            let activities = Activity<LyricsActivityAttributes>.activities
            if let activity = activities.first {
                for duplicate in activities.dropFirst() {
                    await duplicate.end(nil, dismissalPolicy: .immediate)
                }
                guard state != lastState else { return .active }
                await activity.update(ActivityContent(state: state, staleDate: nil))
                lastState = state
                return .active
            }
            do {
                _ = try Activity.request(
                    attributes: LyricsActivityAttributes(schemaVersion: 1),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                lastState = state
                return .active
            } catch {
                return .unavailable(.startFailed)
            }
        }
    }
}
