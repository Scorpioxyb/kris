import ActivityKit
import Foundation

struct WorkoutActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var sessionID: String?
        var planTitle: String
        var planRevision: Int
        var startedAt: Date?
        var lifecycle: String
        var exerciseName: String
        var setNumber: Int
        var completedSets: Int
        var totalSets: Int
        var activeDurationSeconds: TimeInterval
        var updatedAt: Date
        var isRunning: Bool
        var restUntil: Date?
    }

    var activityID: String
}
