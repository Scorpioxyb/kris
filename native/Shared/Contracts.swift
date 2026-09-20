import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum ContractCoding {
    static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.keyEncodingStrategy = .convertToSnakeCase
        value.outputFormatting = [.sortedKeys]
        return value
    }()

    static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }()
}

enum HealthMetric: String, Codable, CaseIterable, Sendable {
    case sleep
    case hrvSdnn = "hrv_sdnn"
    case restingHeartRate = "resting_heart_rate"
    case stepCount = "step_count"
    case activeEnergy = "active_energy"
    case basalEnergy = "basal_energy"
    case bodyMass = "body_mass"
    case bodyFatPercentage = "body_fat_percentage"
    case leanBodyMass = "lean_body_mass"
    case bmi
    case vo2Max = "vo2_max"
    case workout
}

enum CoverageStatus: String, Codable, Sendable {
    case complete, partial, denied, unavailable
}

struct HealthSampleContract: Codable, Hashable, Sendable {
    var sampleUuid: String
    var metric: HealthMetric
    var startAt: String
    var endAt: String
    var value: Double
    var unit: String
    var source: String
    var metadata: [String: JSONValue]?
}

struct MetricCoverage: Codable, Hashable, Sendable {
    var date: String
    var metric: String
    var status: CoverageStatus
    var reason: String?
}

struct HealthBatch: Codable, Hashable, Sendable {
    var schemaVersion = "HealthBatch.v1"
    var batchId: UUID
    var deviceId: String
    var createdAt: String
    var anchor: String?
    var samples: [HealthSampleContract]
    var coverage: [MetricCoverage]
}

extension HealthBatch {
    static let uploadSampleLimit = 2_000

    func chunked(maxSamples: Int = uploadSampleLimit) -> [HealthBatch] {
        precondition(maxSamples > 0)
        guard samples.count > maxSamples else { return [self] }
        return stride(from: 0, to: samples.count, by: maxSamples).map { start in
            let rows = Array(samples[start..<min(start + maxSamples, samples.count)])
            let dates = Set(rows.map { String($0.startAt.prefix(10)) })
            let scopedCoverage = coverage.filter { dates.contains($0.date) }
            return HealthBatch(
                batchId: UUID(), deviceId: deviceId, createdAt: createdAt,
                anchor: anchor, samples: rows,
                coverage: scopedCoverage.isEmpty ? coverage : scopedCoverage
            )
        }
    }
}

struct ExercisePlan: Codable, Hashable, Identifiable, Sendable {
    var exerciseId: UUID
    var order: Int
    var name: String
    var equipmentVariant: String
    var targetWeightKg: Double?
    var sets: Int
    var targetReps: Int
    var restSeconds: Int
    var notes: [String]?
    var alternative: String?

    var id: UUID { exerciseId }
}

struct TrainingPlan: Codable, Hashable, Identifiable, Sendable {
    var schemaVersion = "TrainingPlan.v1"
    var planId: UUID
    var revision: Int
    var date: String
    var title: String
    var estimatedMinutes: Int
    var goal: String?
    var safetyGates: [String]
    var exercises: [ExercisePlan]
    var publishedAt: String?

    var id: UUID { planId }
}

enum TrainingPlanCandidateStatus: String, Codable, Sendable {
    case draft
    case awaitingConfirmation = "awaiting_confirmation"
    case published
    case rejected
}

/// A candidate is reviewable data, never an implicit replacement for the
/// currently published plan. Publishing requires an explicit confirmation.
struct TrainingPlanCandidate: Codable, Hashable, Identifiable, Sendable {
    var schemaVersion = "TrainingPlanCandidate.v1"
    var candidateId: UUID
    var plan: TrainingPlan
    var status: TrainingPlanCandidateStatus
    var createdAt: String
    var source: String
    var decisionRuleVersion: String?

    var id: UUID { candidateId }
}

enum TrainingPlanCandidateValidation {
    static func errors(_ candidate: TrainingPlanCandidate) -> [String] {
        var result: [String] = []
        guard candidate.schemaVersion == "TrainingPlanCandidate.v1" else {
            result.append("候选计划契约版本不支持")
            return result
        }
        if candidate.plan.schemaVersion != "TrainingPlan.v1" {
            result.append("训练计划契约版本不支持")
        }
        if candidate.plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append("计划标题不能为空")
        }
        if candidate.plan.exercises.isEmpty {
            result.append("计划至少需要一个动作")
        }
        if candidate.plan.estimatedMinutes <= 0 {
            result.append("预计时长必须大于零")
        }
        for exercise in candidate.plan.exercises {
            if exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append("动作名称不能为空")
            }
            if exercise.sets <= 0 || exercise.targetReps <= 0 {
                result.append("动作组数和次数必须大于零")
            }
            if exercise.restSeconds < 0 {
                result.append("组间休息不能为负数")
            }
        }
        return result
    }

    static func canPublish(_ candidate: TrainingPlanCandidate) -> Bool {
        // V1 candidates are compatibility records only. They lack the V2
        // context, evidence and accept-time validation required for adoption.
        false
    }
}

enum TrainingPlanComparison {
    static func changes(from previous: TrainingPlan, to current: TrainingPlan) -> [String] {
        var result: [String] = []
        if previous.estimatedMinutes != current.estimatedMinutes {
            result.append("预计时长：\(previous.estimatedMinutes) → \(current.estimatedMinutes) 分钟")
        }

        let previousByKey = Dictionary(
            previous.exercises.map { (key($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentByKey = Dictionary(
            current.exercises.map { (key($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for exercise in current.exercises.sorted(by: { $0.order < $1.order }) {
            guard let old = previousByKey[key(exercise)] else {
                result.append("新增：\(exercise.name) · \(prescription(exercise))")
                continue
            }
            if old.targetWeightKg != exercise.targetWeightKg
                || old.sets != exercise.sets
                || old.targetReps != exercise.targetReps
                || old.restSeconds != exercise.restSeconds {
                result.append("\(exercise.name)：\(prescription(old)) → \(prescription(exercise))")
            }
        }
        for exercise in previous.exercises.sorted(by: { $0.order < $1.order })
            where currentByKey[key(exercise)] == nil {
            result.append("移除：\(exercise.name)")
        }
        if previous.safetyGates != current.safetyGates {
            result.append("安全门槛已更新")
        }
        return result
    }

    private static func key(_ exercise: ExercisePlan) -> String {
        "\(exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(exercise.equipmentVariant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func prescription(_ exercise: ExercisePlan) -> String {
        let load = exercise.targetWeightKg.map {
            "\($0.formatted(.number.precision(.fractionLength(0...1)))) kg"
        } ?? "自重/按难度"
        return "\(load) · \(exercise.sets)×\(exercise.targetReps) · 休 \(exercise.restSeconds)秒"
    }
}

enum LastSetFeeling: String, Codable, CaseIterable, Sendable {
    case easy
    case appropriate
    case veryHard = "very_hard"
    case formBreakdown = "form_breakdown"

    var label: String {
        switch self {
        case .easy: "轻松"
        case .appropriate: "合适"
        case .veryHard: "很吃力"
        case .formBreakdown: "动作变形"
        }
    }
}

struct CompletedSet: Codable, Hashable, Identifiable, Sendable {
    var setId: UUID
    var setNumber: Int
    var weightKg: Double?
    var reps: Int
    var completedAt: String
    var lastSetFeeling: LastSetFeeling?

    var id: UUID { setId }
}

struct PlannedExerciseReference: Codable, Hashable, Sendable {
    var exerciseId: UUID
    var name: String
    var equipmentVariant: String
    var targetWeightKg: Double?
    var sets: Int
    var targetReps: Int
    var restSeconds: Int
}

struct ExerciseResult: Codable, Hashable, Identifiable, Sendable {
    var exerciseId: UUID
    var name: String
    var equipmentVariant: String
    var sets: [CompletedSet]
    var planned: PlannedExerciseReference? = nil

    var id: UUID { exerciseId }
}

enum TrainingSessionStatus: String, Codable, Sendable {
    case completed
    case stoppedEarly = "stopped_early"
    case cancelled
}

enum SessionEnergy: String, Codable, CaseIterable, Sendable {
    case good, normal
    case slightlyTired = "slightly_tired"
    case exhausted
    case notRecorded = "not_recorded"
}

enum MuscleResponse: String, Codable, CaseIterable, Sendable {
    case good, weak
    case notRecorded = "not_recorded"
}

struct SessionFeedback: Codable, Hashable, Sendable {
    var energy: SessionEnergy
    var targetMuscleResponse: MuscleResponse
    var symptoms: String
    var notes: String
}

struct WorkoutSummary: Codable, Hashable, Sendable {
    var durationSeconds: Double
    var activeKcal: Double?
    var averageHeartRate: Double?
    var maximumHeartRate: Double?
}

struct TrainingSessionContract: Codable, Hashable, Identifiable, Sendable {
    var schemaVersion = "TrainingSession.v1"
    var sessionId: UUID
    var planId: UUID
    var planRevision: Int
    var startedAt: String
    var endedAt: String
    var status: TrainingSessionStatus
    var exerciseResults: [ExerciseResult]
    var feedback: SessionFeedback
    var watchWorkoutUuid: String?
    var workout: WorkoutSummary?

    var id: UUID { sessionId }
}

struct SnapshotReadiness: Codable, Hashable, Sendable {
    var score: Double?
    var state: String
    var label: String
    var confidence: String
    var safetyGate: String
    var components: [String: Double?]?
}

struct ReadinessEvidence: Codable, Hashable, Sendable {
    var signal: String
    var value: Double?
    var unit: String?
    var baseline: Double?
    var delta: Double?
    var deltaPct: Double?
    var impact: String?
    var confidence: String?
}

struct SnapshotReadinessPoint: Codable, Hashable, Identifiable, Sendable {
    var date: String
    var score: Double
    var state: String
    var confidence: String
    var source: String?

    var id: String { date }
}

struct SnapshotDecisionTrace: Codable, Hashable, Sendable {
    var asOf: String?
    var summary: String
    var actions: [String]
    var planBasis: String?
    var adjustmentNote: String?
}

struct SnapshotTrends: Codable, Hashable, Sendable {
    struct Point: Codable, Hashable, Identifiable, Sendable {
        var date: String
        var value: Double
        var id: String { date }
    }
    var latestBody: [String: JSONValue]?
    var latestCompleteHealthDay: [String: JSONValue]?
    var recovery: [String: JSONValue]?
    var fatLoss: [String: JSONValue]?
    var weight: [Point]?
    var bodyFat: [Point]?
    var sleep: [Point]?
    var hrv: [Point]? = nil
    var restingHeartRate: [Point]? = nil
    var steps: [Point]? = nil
    var activeEnergy: [Point]? = nil
    var basalEnergy: [Point]? = nil
    var totalEnergy: [Point]? = nil
    var vo2Max: [Point]? = nil
    var trainingLoad7D: [Point]? = nil
    var trainingLoad42D: [Point]? = nil
    var readiness: [SnapshotReadinessPoint]? = nil
}

struct SnapshotTrainingSummary: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var date: String
    var title: String
    var durationMinutes: Double?
    var activeKcal: Double?
    var averageHeartRate: Double?
    var maximumHeartRate: Double?
    var exerciseCount: Int?
    var completedSetCount: Int?
    var status: String
    var source: String
    var syncedToMac: Bool?
    var workoutDetails: HealthWorkoutDetails? = nil
}

struct HealthWorkoutDetails: Codable, Hashable, Sendable {
    var activityTypeCode: Int?
    var startAt: String
    var endAt: String
    var sourceName: String
    var deviceName: String?
    var indoor: Bool?
    var distanceKilometers: Double?
}

struct CoachSnapshot: Codable, Hashable, Sendable {
    var schemaVersion: String
    var version: Int
    var generatedAt: String
    var readiness: SnapshotReadiness
    var evidence: [ReadinessEvidence]
    var dataGaps: [String]
    var trainingLoad: [String: JSONValue]
    var progression: [JSONValue]
    var trends: SnapshotTrends
    var recentTraining: [SnapshotTrainingSummary]? = nil
    var decisionTrace: SnapshotDecisionTrace? = nil
    var currentPlan: TrainingPlan?
}

struct PairResponse: Codable, Sendable {
    var deviceToken: String
    var snapshotVersion: Int
    var schemaVersion: String
}

struct ChangesResponse: Codable, Sendable {
    struct Change: Codable, Sendable {
        var version: Int
        var kind: String
        var objectId: String
        var createdAt: String
        var payload: JSONValue
    }
    var after: Int
    var currentVersion: Int
    var changes: [Change]
}

struct PairingDescriptor: Hashable, Sendable {
    var host: String
    var port: Int
    var fingerprint: String
    var token: String

    init(uri: String) throws {
        guard let components = URLComponents(string: uri), components.scheme == "kriscoach", components.host == "pair" else {
            throw URLError(.badURL)
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { throw URLError(.badURL) }
            values[item.name] = item.value ?? ""
        }
        guard let host = values["host"], let port = Int(values["port"] ?? ""),
              let fingerprint = values["fingerprint"], let token = values["token"],
              !host.isEmpty, !fingerprint.isEmpty, !token.isEmpty else {
            throw URLError(.badURL)
        }
        self.host = host
        self.port = port
        self.fingerprint = fingerprint.uppercased()
        self.token = token
    }

    var baseURL: URL { URL(string: "https://\(host):\(port)")! }
}

enum WorkoutLifecycleState: String, Codable, CaseIterable, Sendable {
    case preparing
    case running
    case paused
    case stopped
    case finalizing
    case completed
    case failed

    var isTerminal: Bool {
        self == .completed || self == .failed
    }

    func canTransition(to next: WorkoutLifecycleState) -> Bool {
        guard self != next else { return true }
        return switch (self, next) {
        case (.preparing, .running), (.preparing, .stopped), (.preparing, .failed),
             (.running, .paused), (.running, .stopped), (.running, .finalizing), (.running, .failed),
             (.paused, .running), (.paused, .stopped), (.paused, .finalizing), (.paused, .failed),
             (.stopped, .finalizing), (.stopped, .completed), (.stopped, .failed),
             (.finalizing, .completed), (.finalizing, .failed):
            true
        default:
            false
        }
    }
}

struct WorkoutLifecycleSnapshot: Codable, Hashable, Sendable {
    var state: WorkoutLifecycleState
    var sequence: Int
    var startedAt: String
    var transitionAt: String
    var activeDurationSeconds: TimeInterval
    var elapsedDurationSeconds: TimeInterval

    func activeDuration(at date: Date = Date()) -> TimeInterval {
        let stored = max(0, activeDurationSeconds)
        guard state == .running, let transition = DateFormatting.parse(transitionAt) else {
            return stored
        }
        return stored + max(0, date.timeIntervalSince(transition))
    }

    func elapsedDuration(at date: Date = Date()) -> TimeInterval {
        let stored = max(0, elapsedDurationSeconds)
        guard !state.isTerminal, state != .stopped, state != .finalizing,
              let transition = DateFormatting.parse(transitionAt) else {
            return stored
        }
        return stored + max(0, date.timeIntervalSince(transition))
    }
}

struct WorkoutCommand: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case pause
        case resume
        case stop
    }

    var commandId: UUID
    var sessionId: UUID
    var kind: Kind
    var createdAt: String

    var id: UUID { commandId }
}

struct WatchEvent: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case sessionStarted
        case sessionPaused
        case sessionResumed
        case sessionStopped
        case setCompleted
        case feelingUpdated
        case restUpdated
        case sessionCompleted
        case sessionFailed
    }
    var eventId: UUID
    var sessionId: UUID
    var kind: Kind
    var planId: UUID? = nil
    var planRevision: Int? = nil
    var exerciseId: UUID?
    var setNumber: Int?
    var reps: Int?
    var weightKg: Double?
    var feeling: LastSetFeeling?
    var createdAt: String
    var workoutUuid: String?
    var workout: WorkoutSummary?
    var lifecycle: WorkoutLifecycleSnapshot? = nil
    var restUntil: Date? = nil
    var restRevision: Int? = nil

    var id: UUID { eventId }
}

struct WorkoutMirrorEnvelope: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case event
        case command
    }

    static let currentSchemaVersion = "WorkoutMirror.v1"

    var schemaVersion: String
    var messageId: UUID
    var kind: Kind
    var event: WatchEvent?
    var command: WorkoutCommand?

    init(event: WatchEvent) {
        schemaVersion = Self.currentSchemaVersion
        messageId = event.eventId
        kind = .event
        self.event = event
        command = nil
    }

    init(command: WorkoutCommand) {
        schemaVersion = Self.currentSchemaVersion
        messageId = command.commandId
        kind = .command
        event = nil
        self.command = command
    }

    var validatedEvent: WatchEvent? {
        guard schemaVersion == Self.currentSchemaVersion,
              kind == .event,
              event?.eventId == messageId,
              command == nil else { return nil }
        return event
    }

    var validatedCommand: WorkoutCommand? {
        guard schemaVersion == Self.currentSchemaVersion,
              kind == .command,
              command?.commandId == messageId,
              event == nil else { return nil }
        return command
    }
}

enum DateFormatting {
    static func iso(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func parse(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
