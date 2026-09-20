import Foundation

struct WatchExecutionSnapshot: Codable, Hashable, Sendable {
    var sessionId: UUID
    var plan: TrainingPlan
    var currentExerciseId: UUID?
    var exerciseIndex: Int
    var setNumber: Int
    var completedSets: Int
    var reps: Int
    var feeling: LastSetFeeling
    var restUntil: Date?
    var restRevision: Int? = nil
    var processedCommandIds: [UUID]
    var lastLifecycleSequence: Int
    var hasPublishedStart: Bool
    var lifecycle: WorkoutLifecycleSnapshot?
    var pendingEvents: [WatchEvent]?
}

enum WatchExecutionLoadResult: Sendable {
    case missing
    case valid(WatchExecutionSnapshot)
    case corrupt
    case unsupported(version: Int)
}

enum WatchExecutionPersistenceCodec {
    static let currentSchemaVersion = 1

    private struct VersionHeader: Decodable {
        var schemaVersion: Int
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var snapshot: WatchExecutionSnapshot?
    }

    static func encode(snapshot: WatchExecutionSnapshot?) throws -> Data {
        try ContractCoding.encoder.encode(Envelope(
            schemaVersion: currentSchemaVersion,
            snapshot: snapshot
        ))
    }

    static func decode(_ data: Data?) -> WatchExecutionLoadResult {
        guard let data else { return .missing }
        guard let header = try? ContractCoding.decoder.decode(VersionHeader.self, from: data) else {
            return .corrupt
        }
        guard header.schemaVersion == currentSchemaVersion else {
            return .unsupported(version: header.schemaVersion)
        }
        guard let envelope = try? ContractCoding.decoder.decode(Envelope.self, from: data) else {
            return .corrupt
        }
        guard let snapshot = envelope.snapshot else { return .missing }
        return .valid(snapshot)
    }
}

enum WatchExecutionRecovery {
    static func exerciseIndex(for snapshot: WatchExecutionSnapshot) -> Int {
        guard !snapshot.plan.exercises.isEmpty else { return 0 }
        if let exerciseID = snapshot.currentExerciseId,
           let index = snapshot.plan.exercises.firstIndex(where: { $0.exerciseId == exerciseID }) {
            return index
        }
        return min(max(0, snapshot.exerciseIndex), snapshot.plan.exercises.count - 1)
    }
}
