import Foundation
import Observation
import SwiftData
import UIKit

enum ExerciseAdjustmentKind: String, Codable, Sendable {
    case equipmentChange = "equipment_change"
    case plannedAlternative = "planned_alternative"
    case custom
}

struct ExerciseExecutionOverride: Codable, Hashable, Sendable {
    var plannedExerciseId: UUID
    var name: String
    var equipmentVariant: String
    var targetWeightKg: Double?
    var sets: Int
    var targetReps: Int
    var restSeconds: Int
    var kind: ExerciseAdjustmentKind
}

struct RecordedExerciseIdentity: Codable, Hashable, Sendable {
    var name: String
    var equipmentVariant: String
}

struct TrainingDraft: Codable, Sendable {
    var sessionId: UUID
    var plan: TrainingPlan
    var startedAt: String
    var completedSets: [UUID: [CompletedSet]]
    var watchWorkoutUuid: String?
    var workout: WorkoutSummary?
    var exerciseOverrides: [UUID: ExerciseExecutionOverride]? = nil
    var recordedSetExercises: [String: RecordedExerciseIdentity]? = nil
    var lifecycle: WorkoutLifecycleSnapshot? = nil
    var workoutManagedByWatch: Bool? = nil
    var restUntil: Date? = nil
    var restRevision: Int? = nil

    var lifecycleState: WorkoutLifecycleState {
        lifecycle?.state ?? .running
    }

    func activeDuration(at date: Date = Date()) -> TimeInterval {
        lifecycleSnapshot.activeDuration(at: date)
    }

    func elapsedDuration(at date: Date = Date()) -> TimeInterval {
        lifecycleSnapshot.elapsedDuration(at: date)
    }

    var executionExercises: [ExercisePlan] {
        plan.exercises.map(executionExercise)
    }

    func executionExercise(for plannedExerciseId: UUID) -> ExercisePlan? {
        plan.exercises.first(where: { $0.exerciseId == plannedExerciseId }).map(executionExercise)
    }

    func override(for plannedExerciseId: UUID) -> ExerciseExecutionOverride? {
        exerciseOverrides?[plannedExerciseId]
    }

    mutating func updateExecution(
        plannedExerciseId: UUID,
        name: String,
        equipmentVariant: String,
        targetWeightKg: Double?,
        sets: Int,
        targetReps: Int,
        restSeconds: Int,
        kind: ExerciseAdjustmentKind
    ) {
        guard let planned = plan.exercises.first(where: { $0.exerciseId == plannedExerciseId }) else { return }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEquipment = equipmentVariant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, !normalizedEquipment.isEmpty else { return }
        let highestRecordedSet = completedSets[plannedExerciseId]?.map(\.setNumber).max() ?? 0
        let updated = ExerciseExecutionOverride(
            plannedExerciseId: plannedExerciseId,
            name: String(normalizedName.prefix(100)),
            equipmentVariant: String(normalizedEquipment.prefix(120)),
            targetWeightKg: targetWeightKg.map { min(max($0, 0), 1_000) },
            sets: min(max(sets, max(1, highestRecordedSet)), 20),
            targetReps: min(max(targetReps, 0), 500),
            restSeconds: min(max(restSeconds, 0), 600),
            kind: kind
        )
        if updated.name == planned.name,
           updated.equipmentVariant == planned.equipmentVariant,
           updated.targetWeightKg == planned.targetWeightKg,
           updated.sets == planned.sets,
           updated.targetReps == planned.targetReps,
           updated.restSeconds == planned.restSeconds {
            exerciseOverrides?.removeValue(forKey: plannedExerciseId)
        } else {
            if exerciseOverrides == nil { exerciseOverrides = [:] }
            exerciseOverrides?[plannedExerciseId] = updated
        }
    }

    mutating func resetExecution(plannedExerciseId: UUID) {
        exerciseOverrides?.removeValue(forKey: plannedExerciseId)
    }

    mutating func record(exercise: ExercisePlan, setNumber: Int, weight: Double?, reps: Int, feeling: LastSetFeeling?) {
        var sets = completedSets[exercise.exerciseId, default: []]
        sets.removeAll { $0.setNumber == setNumber }
        sets.append(
            CompletedSet(
                setId: UUID(), setNumber: setNumber, weightKg: weight, reps: reps,
                completedAt: DateFormatting.iso(), lastSetFeeling: feeling
            )
        )
        completedSets[exercise.exerciseId] = sets.sorted { $0.setNumber < $1.setNumber }
        let identityKey = setIdentityKey(exercise.exerciseId, setNumber)
        var identities = recordedSetExercises ?? [:]
        if identities[identityKey] == nil {
            identities[identityKey] = RecordedExerciseIdentity(
                name: exercise.name, equipmentVariant: exercise.equipmentVariant
            )
        }
        recordedSetExercises = identities
    }

    mutating func remove(exerciseID: UUID, setNumber: Int) {
        completedSets[exerciseID]?.removeAll { $0.setNumber == setNumber }
        if completedSets[exerciseID]?.isEmpty == true { completedSets.removeValue(forKey: exerciseID) }
        let identityKey = setIdentityKey(exerciseID, setNumber)
        recordedSetExercises?.removeValue(forKey: identityKey)
    }

    mutating func updateFeeling(exerciseID: UUID, feeling: LastSetFeeling) {
        guard var last = completedSets[exerciseID]?.max(by: { $0.setNumber < $1.setNumber }) else { return }
        last.lastSetFeeling = feeling
        var sets = completedSets[exerciseID] ?? []
        sets.removeAll { $0.setNumber == last.setNumber }
        sets.append(last)
        completedSets[exerciseID] = sets.sorted { $0.setNumber < $1.setNumber }
    }

    mutating func apply(_ event: WatchEvent) {
        if let incoming = event.lifecycle {
            applyWatchLifecycle(incoming)
        } else if let state = event.kind.lifecycleState {
            transitionLocally(to: state, at: DateFormatting.parse(event.createdAt) ?? Date())
            workoutManagedByWatch = true
        }
        if lifecycleState == .stopped || lifecycleState.isTerminal {
            restUntil = nil
        }
        if event.kind == .sessionCompleted {
            watchWorkoutUuid = event.workoutUuid
            workout = event.workout
            return
        }
        if event.kind == .sessionStopped || event.kind == .sessionFailed {
            return
        }
        if event.kind == .restUpdated {
            applyRestUpdate(event)
            return
        }
        guard let exerciseID = event.exerciseId,
              let exercise = executionExercise(for: exerciseID) else { return }
        if event.kind == .setCompleted, let setNumber = event.setNumber, let reps = event.reps {
            record(exercise: exercise, setNumber: setNumber, weight: event.weightKg, reps: reps, feeling: event.feeling)
            if event.restUntil != nil || event.restRevision != nil {
                applyRestUpdate(event)
            } else {
                // Compatibility with events queued by an older Watch build.
                let completedAt = DateFormatting.parse(event.createdAt) ?? Date()
                restUntil = completedAt.addingTimeInterval(TimeInterval(exercise.restSeconds))
            }
        } else if event.kind == .feelingUpdated, let feeling = event.feeling,
                  var last = completedSets[exerciseID]?.max(by: { $0.setNumber < $1.setNumber }) {
            last.lastSetFeeling = feeling
            var sets = completedSets[exerciseID] ?? []
            sets.removeAll { $0.setNumber == last.setNumber }
            sets.append(last)
            completedSets[exerciseID] = sets.sorted { $0.setNumber < $1.setNumber }
        }
    }

    private mutating func applyRestUpdate(_ event: WatchEvent) {
        guard lifecycleState != .stopped, !lifecycleState.isTerminal else {
            restUntil = nil
            return
        }
        if let incomingRevision = event.restRevision {
            guard incomingRevision > (restRevision ?? 0) else { return }
            restRevision = incomingRevision
        } else if restRevision != nil {
            return
        }
        restUntil = event.restUntil
    }

    func exerciseResults() -> [ExerciseResult] {
        var results: [ExerciseResult] = []
        for planned in plan.exercises {
            guard let sets = completedSets[planned.exerciseId], !sets.isEmpty else { continue }
            var groups: [(identity: RecordedExerciseIdentity, sets: [CompletedSet])] = []
            for set in sets.sorted(by: { $0.setNumber < $1.setNumber }) {
                let identity = recordedSetExercises?[setIdentityKey(planned.exerciseId, set.setNumber)]
                    ?? RecordedExerciseIdentity(
                        name: planned.name, equipmentVariant: planned.equipmentVariant
                    )
                if let index = groups.firstIndex(where: { $0.identity == identity }) {
                    groups[index].sets.append(set)
                } else {
                    groups.append((identity, [set]))
                }
            }
            for (index, group) in groups.enumerated() {
                results.append(ExerciseResult(
                    exerciseId: index == 0 ? planned.exerciseId : UUID(),
                    name: group.identity.name,
                    equipmentVariant: group.identity.equipmentVariant,
                    sets: group.sets,
                    planned: PlannedExerciseReference(
                        exerciseId: planned.exerciseId,
                        name: planned.name,
                        equipmentVariant: planned.equipmentVariant,
                        targetWeightKg: planned.targetWeightKg,
                        sets: planned.sets,
                        targetReps: planned.targetReps,
                        restSeconds: planned.restSeconds
                    )
                ))
            }
        }
        return results
    }

    private func executionExercise(_ planned: ExercisePlan) -> ExercisePlan {
        guard let override = exerciseOverrides?[planned.exerciseId] else { return planned }
        var result = planned
        result.name = override.name
        result.equipmentVariant = override.equipmentVariant
        result.targetWeightKg = override.targetWeightKg
        result.sets = override.sets
        result.targetReps = override.targetReps
        result.restSeconds = override.restSeconds
        return result
    }

    private func setIdentityKey(_ exerciseId: UUID, _ setNumber: Int) -> String {
        "\(exerciseId.uuidString):\(setNumber)"
    }

    @discardableResult
    mutating func transitionLocally(
        to state: WorkoutLifecycleState, at date: Date = Date()
    ) -> Bool {
        let current = lifecycleSnapshot
        guard current.state.canTransition(to: state) else { return false }
        lifecycle = WorkoutLifecycleSnapshot(
            state: state,
            sequence: current.sequence + (current.state == state ? 0 : 1),
            startedAt: current.startedAt,
            transitionAt: DateFormatting.iso(date),
            activeDurationSeconds: current.activeDuration(at: date),
            elapsedDurationSeconds: current.elapsedDuration(at: date)
        )
        return true
    }

    private var lifecycleSnapshot: WorkoutLifecycleSnapshot {
        lifecycle ?? WorkoutLifecycleSnapshot(
            state: .running,
            sequence: 0,
            startedAt: startedAt,
            transitionAt: startedAt,
            activeDurationSeconds: 0,
            elapsedDurationSeconds: 0
        )
    }

    private mutating func applyWatchLifecycle(_ incoming: WorkoutLifecycleSnapshot) {
        if workoutManagedByWatch == true, let current = lifecycle {
            guard incoming.sequence > current.sequence else { return }
            guard current.state.canTransition(to: incoming.state) || incoming.state.isTerminal else {
                return
            }
        }
        lifecycle = incoming
        workoutManagedByWatch = true
    }
}

private extension WatchEvent.Kind {
    var lifecycleState: WorkoutLifecycleState? {
        switch self {
        case .sessionStarted: .running
        case .sessionPaused: .paused
        case .sessionResumed: .running
        case .sessionStopped: .stopped
        case .sessionCompleted: .completed
        case .sessionFailed: .failed
        case .setCompleted, .feelingUpdated, .restUpdated: nil
        }
    }
}

struct SyncQueueSummary: Equatable, Sendable {
    var healthBatches = 0
    var trainingSessions = 0
    var retryItems = 0
    var latestError: String?
}

struct DataQualityExplanation: Equatable, Identifiable, Sendable {
    enum Severity: Equatable, Sendable { case information, warning }

    var id: String { rawGap }
    let rawGap: String
    let title: String
    let impact: String
    let nextStep: String
    let severity: Severity
}

struct WeeklyTrainingSummary: Equatable, Sendable {
    let completedSessions: Int
    let completedSets: Int
    let trainingMinutes: Double
    let stoppedEarlySessions: Int

    var hasTraining: Bool { completedSessions > 0 }
}

struct HealthMetricFreshness: Equatable, Identifiable, Sendable {
    let metric: HealthMetric
    let sampleCount: Int
    let latestAt: Date?

    var id: HealthMetric { metric }
}

@ModelActor
actor HealthPersistenceWorker {
    func loadDecisionSamples() throws -> [HealthSampleContract] {
        var samplesByID: [String: HealthSampleContract] = [:]
        let limits: [(HealthMetric, Int)] = [
            (.sleep, 2_000),
            (.hrvSdnn, 2_000),
            (.restingHeartRate, 500),
            (.stepCount, 1_500),
            (.activeEnergy, 3_000),
            (.bodyMass, 120),
            (.bodyFatPercentage, 120),
            (.leanBodyMass, 120),
            (.bmi, 120),
            (.basalEnergy, 3_000),
            (.vo2Max, 120),
            (.workout, 500),
        ]
        for (metric, limit) in limits {
            let rawMetric = metric.rawValue
            var descriptor = FetchDescriptor<CachedHealthSampleRecord>(
                predicate: #Predicate { $0.metric == rawMetric },
                sortBy: [SortDescriptor(\.startAt, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            for record in try modelContext.fetch(descriptor) {
                guard let sample = try? ContractCoding.decoder.decode(
                    HealthSampleContract.self, from: record.payload
                ) else { continue }
                samplesByID[sample.sampleUuid] = sample
            }
        }
        return Array(samplesByID.values)
    }

    func enqueue(
        _ batch: HealthBatch,
        replacing metric: HealthMetric?,
        forceQueue: Bool = false,
        queueForExport: Bool = false
    ) throws {
        if queueForExport, let metric {
            let healthKind = "health"
            let pending = try modelContext.fetch(FetchDescriptor<SyncQueueItem>(
                predicate: #Predicate { $0.kind == healthKind }
            ))
            for item in pending {
                guard let queued = try? ContractCoding.decoder.decode(HealthBatch.self, from: item.payload),
                      queued.samples.contains(where: { $0.metric == metric }) else { continue }
                modelContext.delete(item)
            }
        }

        let incoming = batch.samples
        let incomingIDs = incoming.map(\.sampleUuid)
        var existingIDs = Set<String>()
        var existingRecords: [String: CachedHealthSampleRecord] = [:]
        for start in stride(from: 0, to: incomingIDs.count, by: 400) {
            let ids = Array(incomingIDs[start..<min(start + 400, incomingIDs.count)])
            let descriptor = FetchDescriptor<CachedHealthSampleRecord>(
                predicate: #Predicate { ids.contains($0.sampleUuid) }
            )
            for record in try modelContext.fetch(descriptor) {
                existingIDs.insert(record.sampleUuid)
                existingRecords[record.sampleUuid] = record
            }
        }
        for sample in incoming {
            guard let payload = try? ContractCoding.encoder.encode(sample) else { continue }
            if let record = existingRecords[sample.sampleUuid] {
                guard record.payload != payload else { continue }
                record.metric = sample.metric.rawValue
                record.startAt = sample.startAt
                record.payload = payload
            } else {
                modelContext.insert(CachedHealthSampleRecord(sample: sample, payload: payload))
            }
        }
        guard queueForExport else {
            if modelContext.hasChanges { try modelContext.save() }
            return
        }
        let samplesToQueue = forceQueue
            ? incoming
            : incoming.filter { !existingIDs.contains($0.sampleUuid) }
        guard !samplesToQueue.isEmpty else {
            if modelContext.hasChanges { try modelContext.save() }
            return
        }
        var uploadBatch = batch
        uploadBatch.samples = samplesToQueue
        for chunk in uploadBatch.chunked() {
            guard let data = try? ContractCoding.encoder.encode(chunk) else { continue }
            modelContext.insert(SyncQueueItem(kind: "health", payload: data))
        }
        try modelContext.save()
    }
}

private enum TrainingArchiveError: Error {
    case activeRecordMissing
}

private struct TrainingHistoryRecordSnapshot: Sendable {
    let payload: Data
    let endedAt: Date
    let syncedToMac: Bool
}

private struct TrainingHistoryInput: Sendable {
    let records: [TrainingHistoryRecordSnapshot]
    let planPayloads: [Data]
    let workoutSamples: [HealthSampleContract]
}

private struct TrainingHistoryComputation: Sendable {
    let history: [SnapshotTrainingSummary]
    let intelligence: LocalTrainingIntelligence
}

@MainActor
@Observable
final class AppModel {
    enum SyncState: Equatable { case idle, syncing, success(Date), failed(String) }
    enum AIGenerationState: Equatable {
        case idle
        case generating
        case ready
        case failed(String)
    }

    private enum PersistencePriority {
        case debounced
        case immediate
    }

    let container: ModelContainer
    let health = HealthKitService()
    let watch = PhoneWatchConnectivity()
    let workoutMirror = MirroredWorkoutCoordinator()
    let liveActivity = WorkoutLiveActivityController()
    let bonjour = BonjourBrowser()
    private let aiService = KrisAIGatewayService()
    private let healthPersistence: HealthPersistenceWorker
    private let usesInMemoryPersistence: Bool

    private(set) var snapshot: CoachSnapshot?
    private(set) var currentPlan: TrainingPlan?
    private(set) var planCandidate: TrainingPlanCandidate?
    private(set) var aiRecommendationCandidate: TrainingPlanCandidateV2?
    private(set) var planChanges: [String] = []
    private(set) var localTrainingHistory: [SnapshotTrainingSummary] = []
    private(set) var localTrainingIntelligence = LocalTrainingIntelligence()
    private(set) var activeDraft: TrainingDraft?
    private(set) var lastCompletedSession: TrainingSessionContract?
    private(set) var queueCount = 0
    private(set) var queueSummary = SyncQueueSummary()
    private(set) var syncState: SyncState = .idle
    private(set) var aiGenerationState: AIGenerationState = .idle
    private(set) var aiServiceAvailable = KrisAIGatewayConfiguration.isAvailable
    private(set) var aiPlanRationale: String?
    private(set) var aiPlanCautions: [String] = []
    private(set) var trainingCompletionError: String?
    private(set) var pendingTrainingDiscardSessionID: UUID?
    private(set) var hiddenTrainingHistoryIDs: Set<String> = []
    private(set) var isPaired = false
    private var replacingHealthMetrics: Set<HealthMetric> = []
    private var startedHealthReplacements: Set<HealthMetric> = []
    private var healthCacheRestored = false
    private var isHandlingForegroundActivation = false
    private var isSyncing = false
    private var servicesEnabled = false
    private var pendingPersistenceTask: Task<Void, Never>?
    private var pendingPersistenceDraft: TrainingDraft?
    private var persistenceGeneration = 0
    private var trainingHistoryRefreshTask: Task<Void, Never>?
    private var aiGenerationTask: Task<Void, Never>?
    private var trainingHistoryGeneration = 0
    var trainingArchiveSaveOverride: (() throws -> Void)?
    var aiCandidateSaveOverride: (() throws -> Void)?
    var pairingURI = ""
    var selectedTab = 0

    private var developmentCompanionExportEnabled: Bool {
        defaults.bool(forKey: "development.companionExportEnabled") && makeClient() != nil
    }

    var effectiveReadiness: SnapshotReadiness? {
        // The companion snapshot is a development/archive input. It must not
        // masquerade as today's readiness in the standalone app.
        return health.localReadiness?.readiness
    }

    var usesLocalReadiness: Bool {
        health.localReadiness != nil
    }

    var effectiveEvidence: [ReadinessEvidence] {
        health.localReadiness?.evidence ?? []
    }

    var effectiveDataGaps: [String] {
        if let local = health.localReadiness { return local.dataGaps }
        return ["等待健康数据完成首次计算"]
    }

    /// Only failures that require a user action belong on the daily surface.
    /// A new calendar day commonly has no sleep/HRV/resting-heart-rate sample
    /// yet; that is normal collection latency, not a broken authorization.
    var healthAttentionMessage: String? {
        switch health.state {
        case .unavailable:
            return "当前无法读取 Apple 健康。"
        case .failed, .noData:
            return health.lastError ?? "Apple 健康暂时没有可用数据。"
        case .idle, .authorizing, .importing, .ready:
            return nil
        }
    }

    var readinessSource: String {
        usesLocalReadiness ? "健康分析" : "等待健康数据"
    }

    /// Read-only execution gate for the current cached plan. It deliberately
    /// treats missing symptom feedback as unknown; callers must not use this
    /// value to silently rewrite or publish a plan.
    var localPlanDecision: LocalPlanDecision {
        let local = health.localReadiness
        return LocalPlanEngine.decide(
            readiness: local?.readiness,
            evaluatedAt: local?.generatedAt,
            signalsFresh: local?.dataGaps.isEmpty == true,
            symptoms: .notReported,
            hasPlan: currentPlan != nil,
            now: Date(),
            calendar: .autoupdatingCurrent
        )
    }

    var effectiveDecisionTrace: SnapshotDecisionTrace? {
        guard let readiness = effectiveReadiness else { return nil }
        var actions: [String] = []
        if readiness.safetyGate == "stop_and_seek_care" {
            actions.append("停止训练并优先处理异常信号。")
        } else if readiness.safetyGate == "reduce" || readiness.state == "train_reduce" {
            actions.append("保留训练习惯，减少一组或降低一个最小负重档。")
        } else if readiness.state == "recover_or_light" {
            actions.append("优先恢复，或只进行轻量活动；不进行力竭组。")
        } else {
            actions.append("按已发布计划执行，实际重量以动作质量和安全门槛为准。")
        }
        actions.append(loadAction(localTrainingIntelligence.loadStatus))
        return SnapshotDecisionTrace(
            asOf: String((health.localReadiness?.generatedAt ?? Date()).ISO8601Format().prefix(10)),
            summary: "\(readiness.label) · 已结合近期恢复信号",
            actions: actions,
            planBasis: nil,
            adjustmentNote: nil
        )
    }

    var effectiveProgression: [LocalProgressionDecision] {
        localTrainingIntelligence.progression
    }

    var hasEffectiveProgression: Bool {
        !effectiveProgression.isEmpty || snapshot?.progression.isEmpty == false
    }

    var effectiveLoadRatio: Double? {
        if localTrainingIntelligence.hasLoad { return localTrainingIntelligence.loadRatio }
        return snapshotNumber("load_ratio_7d_to_28d_weekly")
    }

    var effectiveLoadStatus: String? {
        if localTrainingIntelligence.hasLoad { return localTrainingIntelligence.loadStatus }
        guard case .string(let value)? = snapshot?.trainingLoad["load_status"] else { return nil }
        return value
    }

    var effectiveTrends: SnapshotTrends {
        let local = health.localTrends
        let remote = snapshot?.trends
        return SnapshotTrends(
            latestBody: preferred(local.latestBody, remote?.latestBody),
            latestCompleteHealthDay: preferred(
                local.latestCompleteHealthDay, remote?.latestCompleteHealthDay
            ),
            recovery: preferred(local.recovery, remote?.recovery),
            fatLoss: preferred(local.fatLoss, remote?.fatLoss),
            weight: preferred(local.weight, remote?.weight),
            bodyFat: preferred(local.bodyFat, remote?.bodyFat),
            sleep: preferred(local.sleep, remote?.sleep),
            hrv: preferred(local.hrv, remote?.hrv),
            restingHeartRate: preferred(local.restingHeartRate, remote?.restingHeartRate),
            steps: preferred(local.steps, remote?.steps),
            activeEnergy: preferred(local.activeEnergy, remote?.activeEnergy),
            basalEnergy: preferred(local.basalEnergy, remote?.basalEnergy),
            totalEnergy: preferred(local.totalEnergy, remote?.totalEnergy),
            vo2Max: preferred(local.vo2Max, remote?.vo2Max),
            trainingLoad7D: localTrainingIntelligence.hasLoad
                ? localTrainingIntelligence.trainingLoad7D : remote?.trainingLoad7D,
            trainingLoad42D: localTrainingIntelligence.hasLoad
                ? localTrainingIntelligence.trainingLoad42D : remote?.trainingLoad42D,
            readiness: local.readiness?.isEmpty == false ? local.readiness : remote?.readiness
        )
    }

    var effectiveTrainingHistory: [SnapshotTrainingSummary] {
        Self.mergeTrainingHistory(
            local: localTrainingHistory,
            remote: snapshot?.recentTraining ?? []
        ).filter { !hiddenTrainingHistoryIDs.contains($0.id.lowercased()) }
    }

    var isTrainingDiscardPending: Bool {
        guard let pendingTrainingDiscardSessionID else { return false }
        return activeDraft?.sessionId == pendingTrainingDiscardSessionID
    }

    var dataQualityExplanations: [DataQualityExplanation] {
        effectiveDataGaps.map(Self.explainDataGap)
    }

    var weeklyTrainingSummary: WeeklyTrainingSummary {
        Self.summarizeWeeklyTraining(effectiveTrainingHistory)
    }

    var todayFocus: TodayFocus {
        TodayFocus.resolve(
            safetyGate: effectiveReadiness?.safetyGate,
            hasActiveSession: activeDraft != nil
        )
    }

    var homeTrainingPlan: TrainingPlan? {
        if let draft = activeDraft { return draft.plan }
        guard let plan = currentPlan,
              TodayFocus.isPlanScheduledToday(plan.date, now: Date(), calendar: .autoupdatingCurrent) else {
            return nil
        }
        return plan
    }

    nonisolated static func summarizeWeeklyTraining(
        _ history: [SnapshotTrainingSummary],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> WeeklyTrainingSummary {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let items = history.filter { item in
            guard let date = DateFormatting.parse(item.date) else { return false }
            return date >= start && date < tomorrow
        }
        return WeeklyTrainingSummary(
            completedSessions: items.count,
            completedSets: items.compactMap(\.completedSetCount).reduce(0, +),
            trainingMinutes: items.compactMap(\.durationMinutes).reduce(0, +),
            stoppedEarlySessions: items.filter { $0.status == TrainingSessionStatus.stoppedEarly.rawValue }.count
        )
    }

    nonisolated static func explainDataGap(_ gap: String) -> DataQualityExplanation {
        let normalized = gap.lowercased()
        if normalized.contains("尚未结束") || normalized.contains("不用于日结") {
            return DataQualityExplanation(
                rawGap: gap, title: "今日仍在累积",
                impact: "不生成完整日总消耗，相关结论会降低置信度，也不会据此调整饮食。",
                nextStep: "无需处理，次日完整覆盖后自动进入趋势。",
                severity: .information
            )
        }
        if normalized.contains("个人恢复基线") {
            return DataQualityExplanation(
                rawGap: gap, title: "恢复基线建立中",
                impact: "恢复判断的依据会减少，但现有客观数据仍会显示。",
                nextStep: "继续佩戴手表并保留睡眠、HRV 与静息心率记录。",
                severity: .information
            )
        }
        if normalized.contains("训练负荷基线") || normalized.contains("7/42") {
            return DataQualityExplanation(
                rawGap: gap, title: "训练负荷基线建立中",
                impact: "不会仅凭短期训练量开放加重。",
                nextStep: "继续记录实际训练，满 42 天前按基线建立中解释。",
                severity: .information
            )
        }
        if normalized.contains("体测") || normalized.contains("体重")
            || normalized.contains("体脂") || normalized.contains("bmi") {
            return DataQualityExplanation(
                rawGap: gap, title: "晨起体测不完整",
                impact: "单独体重不会覆盖同日完整的米家体测。",
                nextStep: "下次晨起上秤后等待体重、体脂、去脂体重和 BMI 同步。",
                severity: .warning
            )
        }
        if normalized.contains("睡眠") || normalized.contains("hrv")
            || normalized.contains("静息心率") {
            return DataQualityExplanation(
                rawGap: gap, title: "恢复信号缺失",
                impact: "恢复判断的依据不足，缺失值不会被补成正常。",
                nextStep: "确认 Apple 健康权限与手表佩戴；回到 App 后会自动补齐。",
                severity: .warning
            )
        }
        return DataQualityExplanation(
            rawGap: gap, title: "数据覆盖不完整",
            impact: "相关结论会降低置信度，不会伪造正常状态。",
            nextStep: "在数据页检查 Apple 健康权限和最近更新时间。",
            severity: .warning
        )
    }

    nonisolated static func mergeTrainingHistory(
        local: [SnapshotTrainingSummary], remote: [SnapshotTrainingSummary]
    ) -> [SnapshotTrainingSummary] {
        var byID = Dictionary(
            remote.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for item in local { byID[item.id.lowercased()] = item }
        return byID.values.sorted {
            $0.date == $1.date ? $0.title < $1.title : $0.date > $1.date
        }
    }

    private func preferred(
        _ local: [SnapshotTrends.Point]?, _ remote: [SnapshotTrends.Point]?
    ) -> [SnapshotTrends.Point]? {
        local?.isEmpty == false ? local : remote
    }

    private func preferred(
        _ local: [String: JSONValue]?, _ remote: [String: JSONValue]?
    ) -> [String: JSONValue]? {
        local?.isEmpty == false ? local : remote
    }

    private func snapshotNumber(_ key: String) -> Double? {
        guard let value = snapshot?.trainingLoad[key] else { return nil }
        switch value {
        case .number(let number): return number
        case .string(let string): return Double(string)
        default: return nil
        }
    }

    private func loadAction(_ status: String) -> String {
        switch status {
        case "elevated_recent_load": "近期负荷明显高于基线，不追加额外高强度量。"
        case "above_28d_baseline": "近期负荷高于基线，优先完成原定容量。"
        case "within_28d_baseline": "近期负荷接近个人基线，继续观察训练质量和次日恢复。"
        case "below_28d_baseline": "近期训练刺激低于基线，通过稳定完成计划恢复，不盲目跳级。"
        default: "训练负荷基线仍在建立。"
        }
    }

    private var context: ModelContext { container.mainContext }
    private let defaults: UserDefaults
    private let snapshotCacheKey = "kriscoach.coach-snapshot.v1"
    private let hiddenTrainingHistoryKey = "kriscoach.hidden-training-history.v1"
    private let legacyAIEnabledKey = "kriscoach.ai.enabled.v1"
    private let legacyAIModelKey = "kriscoach.ai.model.v1"
    private var legacyAIAPIKeyAccount: String {
        // Construct the one-time migration key at runtime so the retired
        // vendor credential identifier is not embedded in the App binary.
        let retiredCredentialComponent = ["api", "key"].joined(separator: "-")
        return ["ai", "deep", "seek", retiredCredentialComponent, "v1"].joined(separator: ".")
    }

    nonisolated static func allowsBundledSamplePlan(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.albertdaisy.kriscoach.preview"
            && !ProcessInfo.processInfo.arguments.contains("-ui-testing-no-sample-plan")
    }

    init(inMemory: Bool = false, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let createdContainer: ModelContainer
        do {
            createdContainer = try ModelContainer(
                for: SyncQueueItem.self, CachedPlanRecord.self, TrainingPlanCandidateRecord.self, ActiveTrainingRecord.self,
                ArchivedSessionRecord.self, WatchEventRecord.self, HealthAnchorRecord.self,
                CachedHealthSampleRecord.self,
                configurations: configuration
            )
        } catch {
            fatalError("SwiftData initialization failed: \(error)")
        }
        container = createdContainer
        healthPersistence = HealthPersistenceWorker(modelContainer: createdContainer)
        usesInMemoryPersistence = inMemory
        configure(inMemory: inMemory, startServices: !inMemory)
    }

    init(testContainer: ModelContainer) {
        defaults = .standard
        container = testContainer
        healthPersistence = HealthPersistenceWorker(modelContainer: testContainer)
        usesInMemoryPersistence = true
        configure(inMemory: true, startServices: false)
    }

    private func configure(inMemory: Bool, startServices: Bool) {
        servicesEnabled = startServices
        let isUITesting = inMemory && ProcessInfo.processInfo.arguments.contains("-ui-testing")
        if isUITesting { defaults.removeObject(forKey: hiddenTrainingHistoryKey) }
        hiddenTrainingHistoryIDs = Set(
            (defaults.stringArray(forKey: hiddenTrainingHistoryKey) ?? []).map { $0.lowercased() }
        )
        aiServiceAvailable = !isUITesting && KrisAIGatewayConfiguration.isAvailable
        if !inMemory {
            KeychainStore.delete(account: legacyAIAPIKeyAccount)
            defaults.removeObject(forKey: legacyAIEnabledKey)
            defaults.removeObject(forKey: legacyAIModelKey)
        }
        // A valid legacy credential alone must not turn the companion export
        // path back into a product dependency.
        isPaired = !inMemory && developmentCompanionExportEnabled
        if !inMemory,
           let data = defaults.data(forKey: snapshotCacheKey),
           let cached = try? ContractCoding.decoder.decode(CoachSnapshot.self, from: data) {
            snapshot = cached
        }
        health.onBatch = { [weak self] batch in await self?.enqueueHealth(batch) }
        health.onImportFinished = { [weak self] in
            // HealthKit may emit many chunks for one refresh. Rebuild derived
            // workout history once after the whole import. The development
            // export queue is unrelated to HealthKit presentation and should
            // not add work to every foreground refresh.
            self?.refreshTrainingHistory()
        }
        watch.onEvent = { [weak self] event in self?.receiveWatchEvent(event) }
        workoutMirror.onEvent = { [weak self] event in self?.receiveWatchEvent(event) }
        workoutMirror.onSessionAccepted = { [weak self] in
            self?.liveActivity.beginProvisional()
        }
        // Production launch only hydrates the plan and active workout before
        // the first frame. History, diagnostics and HealthKit observation can
        // safely start on the next main-actor turn. Tests keep the fully
        // synchronous path so persistence assertions remain deterministic.
        loadLocalState(includeSecondaryState: !startServices)
        if let marker = ProcessInfo.processInfo.arguments.firstIndex(of: "-selected-tab"),
           ProcessInfo.processInfo.arguments.indices.contains(marker + 1),
           let tab = Int(ProcessInfo.processInfo.arguments[marker + 1]),
           (0...4).contains(tab) {
            selectedTab = tab
        }
        if inMemory, ProcessInfo.processInfo.arguments.contains("-readiness-evidence-fixture") {
            installReadinessEvidenceFixture()
        }
        if inMemory, ProcessInfo.processInfo.arguments.contains("-sync-queue-fixture") {
            installSyncQueueFixture()
        }
        if inMemory, ProcessInfo.processInfo.arguments.contains("-plan-change-fixture") {
            installPlanChangeFixture()
        }
        if inMemory, ProcessInfo.processInfo.arguments.contains("-active-training-fixture") {
            startTraining()
        }
        if inMemory, ProcessInfo.processInfo.arguments.contains("-training-history-fixture") {
            installTrainingHistoryFixture()
        }
        if inMemory, ProcessInfo.processInfo.arguments.contains("-health-workout-history-fixture") {
            installHealthWorkoutHistoryFixture()
        }
        if inMemory, ProcessInfo.processInfo.arguments.contains("-ai-candidate-fixture") {
            installAICandidateFixture()
        }
        guard startServices else { return }
        Task { [weak self] in
            guard let self else { return }
            await Task.yield()
            self.health.beginObservingIfPreviouslyEnabled()
            await self.handleAppBecameActive()
        }
    }

    private func installReadinessEvidenceFixture() {
        let fixture = CoachSnapshot(
            schemaVersion: "CoachSnapshot.v1", version: 1,
            generatedAt: DateFormatting.iso(),
            readiness: SnapshotReadiness(
                score: 57.5, state: "train_reduce", label: "可训练，但降阶（临时）",
                confidence: "medium", safetyGate: "reduce",
                components: ["sleep": 68.8, "hrv": 56.6, "rhr": 14.5, "load": 68]
            ),
            evidence: [
                ReadinessEvidence(
                    signal: "sleep", value: 7.52, unit: "h", baseline: 6.67,
                    delta: 0.85, deltaPct: nil, impact: "中性/支持", confidence: "medium"
                ),
                ReadinessEvidence(
                    signal: "hrv_sdnn", value: 55, unit: "ms", baseline: 49.5,
                    delta: 5.5, deltaPct: 11.1, impact: "中性/支持", confidence: "medium"
                ),
                ReadinessEvidence(
                    signal: "resting_hr", value: 89, unit: "bpm", baseline: 65.3,
                    delta: 23.7, deltaPct: nil, impact: "限制今天的训练负荷", confidence: "medium"
                ),
            ],
            dataGaps: ["今天尚未结束，能量数据不用于日结"],
            trainingLoad: [
                "rolling_7d_load": .string("146.0"),
                "load_ratio_7d_to_28d_weekly": .string("0.68"),
                "load_status": .string("below_28d_baseline"),
            ], progression: [],
            trends: SnapshotTrends(
                latestBody: nil, latestCompleteHealthDay: nil, recovery: nil,
                fatLoss: nil,
                weight: [
                    .init(date: "08/26", value: 85.1), .init(date: "08/27", value: 84.8),
                    .init(date: "08/28", value: 84.9), .init(date: "08/29", value: 84.5),
                    .init(date: "08/30", value: 84.6), .init(date: "08/31", value: 84.4),
                    .init(date: "09/01", value: 84.3),
                ],
                bodyFat: [
                    .init(date: "08/26", value: 26.8), .init(date: "08/27", value: 26.7),
                    .init(date: "08/28", value: 26.9), .init(date: "08/29", value: 26.5),
                    .init(date: "08/30", value: 26.6), .init(date: "08/31", value: 26.5),
                    .init(date: "09/01", value: 26.4),
                ],
                sleep: [
                    .init(date: "08/26", value: 6.7), .init(date: "08/27", value: 7.1),
                    .init(date: "08/28", value: 6.4), .init(date: "08/29", value: 7.8),
                    .init(date: "08/30", value: 7.0), .init(date: "08/31", value: 6.8),
                    .init(date: "09/01", value: 7.5),
                ],
                hrv: [
                    .init(date: "08/26", value: 48), .init(date: "08/27", value: 51),
                    .init(date: "08/28", value: 47), .init(date: "08/29", value: 52),
                    .init(date: "08/30", value: 50), .init(date: "08/31", value: 49),
                    .init(date: "09/01", value: 55),
                ],
                restingHeartRate: [
                    .init(date: "08/26", value: 66), .init(date: "08/27", value: 64),
                    .init(date: "08/28", value: 68), .init(date: "08/29", value: 63),
                    .init(date: "08/30", value: 65), .init(date: "08/31", value: 66),
                    .init(date: "09/01", value: 62),
                ],
                steps: [
                    .init(date: "08/26", value: 7_420), .init(date: "08/27", value: 9_180),
                    .init(date: "08/28", value: 6_340), .init(date: "08/29", value: 10_260),
                    .init(date: "08/30", value: 8_760), .init(date: "08/31", value: 7_950),
                    .init(date: "09/01", value: 4_820),
                ],
                activeEnergy: [
                    .init(date: "08/26", value: 610), .init(date: "08/27", value: 745),
                    .init(date: "08/28", value: 530), .init(date: "08/29", value: 820),
                    .init(date: "08/30", value: 690), .init(date: "08/31", value: 640),
                    .init(date: "09/01", value: 385),
                ],
                totalEnergy: [
                    .init(date: "08/26", value: 2_510), .init(date: "08/27", value: 2_645),
                    .init(date: "08/28", value: 2_430), .init(date: "08/29", value: 2_720),
                    .init(date: "08/30", value: 2_590), .init(date: "08/31", value: 2_540),
                    .init(date: "09/01", value: 2_285),
                ],
                vo2Max: [
                    .init(date: "08/19", value: 42.1),
                    .init(date: "08/25", value: 42.6),
                    .init(date: "09/01", value: 43.0),
                ],
                trainingLoad7D: [
                    .init(date: "08/26", value: 38), .init(date: "08/27", value: 35),
                    .init(date: "08/28", value: 31), .init(date: "08/29", value: 29),
                    .init(date: "08/30", value: 26), .init(date: "08/31", value: 24),
                    .init(date: "09/01", value: 22),
                ],
                trainingLoad42D: [
                    .init(date: "08/26", value: 31), .init(date: "08/27", value: 31),
                    .init(date: "08/28", value: 30), .init(date: "08/29", value: 30),
                    .init(date: "08/30", value: 30), .init(date: "08/31", value: 29),
                    .init(date: "09/01", value: 29),
                ],
                readiness: [
                    .init(date: "08/26", score: 63, state: "train_maintain", confidence: "medium", source: "iphone_healthkit"),
                    .init(date: "08/27", score: 68, state: "train_maintain", confidence: "medium", source: "iphone_healthkit"),
                    .init(date: "08/28", score: 54, state: "train_reduce", confidence: "medium", source: "iphone_healthkit"),
                    .init(date: "08/29", score: 72, state: "train_maintain", confidence: "medium", source: "iphone_healthkit"),
                    .init(date: "08/30", score: 66, state: "train_maintain", confidence: "medium", source: "iphone_healthkit"),
                    .init(date: "08/31", score: 58, state: "train_reduce", confidence: "medium", source: "iphone_healthkit"),
                    .init(date: "09/01", score: 57.5, state: "train_reduce", confidence: "medium", source: "iphone_healthkit"),
                ]
            ),
            recentTraining: [
                SnapshotTrainingSummary(
                    id: "fixture-session-1", date: "2026-08-31T19:10:00+08:00",
                    title: "上肢 A · 回归", durationMinutes: 52, activeKcal: 418,
                    averageHeartRate: 131, maximumHeartRate: 161,
                    exerciseCount: 6, completedSetCount: 16,
                    status: "completed", source: "kris_coach_app", syncedToMac: true
                ),
                SnapshotTrainingSummary(
                    id: "fixture-session-2", date: "2026-08-29",
                    title: "跑步机自由跑", durationMinutes: 35, activeKcal: 356,
                    averageHeartRate: 156, maximumHeartRate: 178,
                    exerciseCount: nil, completedSetCount: nil,
                    status: "archived", source: "obsidian_archive", syncedToMac: true
                ),
            ],
            decisionTrace: SnapshotDecisionTrace(
                asOf: "2026-09-01",
                summary: "恢复信号偏弱，今天保留训练但降低强度或容量。",
                actions: [
                    "保留动作模式，减少一组或降低一个小档；不做力竭和高强度有氧。",
                    "训练前复核腰骶、膝髋状态，异常时按安全门槛降阶。",
                ],
                planBasis: "最近正式下肢训练间隔较长；今天静息心率高于个人基线，因此沿用回归降阶方案。",
                adjustmentNote: "倒蹬首组不足目标次数时立即回退，不追加训练量。"
            ),
            currentPlan: currentPlan
        )
        snapshot = fixture
        health.installReadinessFixture(fixture)
    }

    private func installAICandidateFixture() {
        guard var plan = currentPlan else { return }
        plan.revision += 1
        plan.title = "上肢力量 · 恢复"
        plan.goal = "恢复动作质量，保留一次稳定的上肢刺激"
        plan.estimatedMinutes = 50
        let candidate = TrainingPlanCandidate(
            candidateId: UUID(), plan: plan, status: .awaitingConfirmation,
            createdAt: DateFormatting.iso(),
            source: "kris-ai:managed:\(AIPlanPolicy.promptVersion)",
            decisionRuleVersion: LocalPlanEngine.ruleVersion
        )
        _ = savePlanCandidate(candidate)
        aiPlanRationale = "近期训练频率较低，先保留主要拉、推动作，不安排力竭。"
        aiPlanCautions = ["首组以动作稳定为准校准重量"]
    }

    private func installSyncQueueFixture() {
        context.insert(SyncQueueItem(kind: "health", payload: Data()))
        let retryingHealth = SyncQueueItem(kind: "health", payload: Data())
        retryingHealth.attempts = 2
        retryingHealth.lastError = "后台处理暂时失败，请稍后重试。"
        context.insert(retryingHealth)
        context.insert(SyncQueueItem(kind: "training", payload: Data()))
        try? context.save()
        refreshQueueCount()
    }

    private func installPlanChangeFixture() {
        guard let original = currentPlan else { return }
        savePlan(original)
        var revised = original
        revised.revision += 1
        revised.estimatedMinutes = max(20, original.estimatedMinutes - 5)
        revised.title = "上肢力量 · 调整版"
        if !revised.exercises.isEmpty {
            revised.exercises[0].targetWeightKg = (revised.exercises[0].targetWeightKg ?? 0) + 2.5
        }
        savePlan(revised)
    }

    private func installTrainingHistoryFixture() {
        guard let plan = currentPlan, let exercise = plan.exercises.first else { return }
        startTraining()
        recordSet(
            exercise: exercise, setNumber: 1,
            weight: exercise.targetWeightKg, reps: exercise.targetReps,
            feeling: .appropriate
        )
        finishTraining(
            feedback: SessionFeedback(
                energy: .normal, targetMuscleResponse: .good,
                symptoms: "无不适", notes: "界面验收样本"
            ),
            stoppedEarly: false
        )
        dismissTrainingReceipt()
    }

    func installHealthWorkoutHistoryFixture() {
        // This fixture replaces the asynchronous empty-history refresh started
        // during test setup, so it cannot be overwritten before UI assertions.
        trainingHistoryGeneration &+= 1
        trainingHistoryRefreshTask?.cancel()
        localTrainingHistory = [
            SnapshotTrainingSummary(
                id: "fixture-health-workout", date: "2026-09-01T20:39:58+08:00",
                title: "传统力量训练", durationMinutes: 42.6, activeKcal: 386,
                averageHeartRate: 128, maximumHeartRate: 157,
                exerciseCount: nil, completedSetCount: nil,
                status: "completed", source: "iphone_healthkit", syncedToMac: nil,
                workoutDetails: HealthWorkoutDetails(
                    activityTypeCode: 50,
                    startAt: "2026-09-01T19:57:21+08:00",
                    endAt: "2026-09-01T20:39:58+08:00",
                    sourceName: "Apple Watch",
                    deviceName: "Apple Watch",
                    indoor: true,
                    distanceKilometers: nil
                )
            ),
            SnapshotTrainingSummary(
                id: "fixture-health-run", date: "2026-08-30T18:42:00+08:00",
                title: "跑步", durationMinutes: 31.2, activeKcal: 352,
                averageHeartRate: 154, maximumHeartRate: 177,
                exerciseCount: nil, completedSetCount: nil,
                status: "completed", source: "iphone_healthkit", syncedToMac: nil,
                workoutDetails: HealthWorkoutDetails(
                    activityTypeCode: 37,
                    startAt: "2026-08-30T18:10:48+08:00",
                    endAt: "2026-08-30T18:42:00+08:00",
                    sourceName: "Apple Watch",
                    deviceName: "Apple Watch",
                    indoor: false,
                    distanceKilometers: 4.82
                )
            ),
        ]
    }

    func loadLocalState(includeSecondaryState: Bool = true) {
        do {
            var planDescriptor = FetchDescriptor<CachedPlanRecord>(
                predicate: #Predicate { $0.isActive },
                sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
            )
            planDescriptor.fetchLimit = 1
            if let record = try context.fetch(planDescriptor).first {
                currentPlan = try ContractCoding.decoder.decode(TrainingPlan.self, from: record.payload)
                let history = try context.fetch(FetchDescriptor<CachedPlanRecord>(
                    sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
                ))
                if let previousRecord = history.first(where: {
                    $0.key != record.key && $0.receivedAt < record.receivedAt
                }), let previous = try? ContractCoding.decoder.decode(TrainingPlan.self, from: previousRecord.payload),
                   let currentPlan {
                    planChanges = TrainingPlanComparison.changes(from: previous, to: currentPlan)
                }
            } else if Self.allowsBundledSamplePlan(bundleIdentifier: Bundle.main.bundleIdentifier),
                      let url = Bundle.main.url(forResource: "TrainingPlan.sample", withExtension: "json"),
                      let data = try? Data(contentsOf: url) {
                currentPlan = try? ContractCoding.decoder.decode(TrainingPlan.self, from: data)
            }
            var activeDescriptor = FetchDescriptor<ActiveTrainingRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
            activeDescriptor.fetchLimit = 1
            if let active = try context.fetch(activeDescriptor).first {
                activeDraft = try ContractCoding.decoder.decode(TrainingDraft.self, from: active.draftPayload)
            }
            let candidates = try context.fetch(FetchDescriptor<TrainingPlanCandidateRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            ))
            let pendingCandidates = candidates.filter {
                $0.status == TrainingPlanCandidateStatus.draft.rawValue
                    || $0.status == TrainingPlanCandidateStatus.awaitingConfirmation.rawValue
            }
            for pending in pendingCandidates {
                if aiRecommendationCandidate == nil,
                   let candidate = try? ContractCoding.decoder.decode(
                       TrainingPlanCandidateV2.self, from: pending.payload
                   ) {
                    aiRecommendationCandidate = candidate
                }
                if planCandidate == nil,
                   let candidate = try? ContractCoding.decoder.decode(
                       TrainingPlanCandidate.self, from: pending.payload
                   ) {
                    planCandidate = candidate
                }
            }
            health.setInteractiveTrainingActive(activeDraft != nil)
            if let activeDraft {
                liveActivity.sync(activeDraft)
            } else if !workoutMirror.isConnected {
                liveActivity.endOrphanedActivities()
            }
            if activeDraft == nil, let currentPlan {
                resumePendingWatchSession(for: currentPlan)
            }
            AppPerformanceTrace.mark("cached_dashboard")
            if includeSecondaryState {
                refreshTrainingHistory()
                refreshQueueCount()
            }
        } catch {
            syncState = .failed("数据读取失败：\(error.localizedDescription)")
        }
    }

    private func restoreHealthCache() async {
        do {
            let samples = try await healthPersistence.loadDecisionSamples()
            await health.restoreCachedSamples(samples)
            healthCacheRestored = true
        } catch {
            syncState = .failed("健康缓存恢复失败，原始数据仍已保留：\(error.localizedDescription)")
        }
    }

    func handleAppBecameActive() async {
        guard servicesEnabled, !isHandlingForegroundActivation else { return }
        aiServiceAvailable = KrisAIGatewayConfiguration.isAvailable
        guard Self.shouldRunForegroundMaintenance(hasActiveTraining: activeDraft != nil) else {
            health.setInteractiveTrainingActive(true)
            return
        }
        isHandlingForegroundActivation = true
        defer { isHandlingForegroundActivation = false }
        if !healthCacheRestored { await restoreHealthCache() }
        await health.refreshAutomatically()
        AppPerformanceTrace.mark("health_refresh_complete")
        if isPaired { await syncNow() }
    }

    /// Persist the active workout once at an app lifecycle boundary. This is
    /// intentionally event-driven; it is not a background polling loop.
    func handleAppBecameInactive() {
        guard activeDraft != nil else { return }
        _ = flushPendingPersistence()
        liveActivity.flushPendingState()
    }

    nonisolated static func shouldRunForegroundMaintenance(
        hasActiveTraining: Bool
    ) -> Bool {
        !hasActiveTraining
    }

    func pair(uri: String) async {
        syncState = .syncing
        do {
            let descriptor = try PairingDescriptor(uri: uri.trimmingCharacters(in: .whitespacesAndNewlines))
            let response = try await CompanionClient.pair(
                descriptor: descriptor,
                deviceID: HealthKitService.deviceID,
                deviceName: UIDevice.current.name
            )
            try KeychainStore.save(response.deviceToken, account: CompanionClient.tokenAccount)
            defaults.set(descriptor.baseURL.absoluteString, forKey: "companion.baseURL")
            defaults.set(descriptor.fingerprint, forKey: "companion.fingerprint")
            defaults.set(response.snapshotVersion, forKey: "companion.version")
            defaults.set(true, forKey: "development.companionExportEnabled")
            isPaired = true
            pairingURI = ""
            syncState = .success(Date())
            await syncNow()
        } catch {
            syncState = .failed(Self.presentSyncError(error))
        }
    }

    func unpair() {
        KeychainStore.delete(account: CompanionClient.tokenAccount)
        defaults.removeObject(forKey: "companion.baseURL")
        defaults.removeObject(forKey: "companion.fingerprint")
        defaults.removeObject(forKey: "development.companionExportEnabled")
        isPaired = false
        syncState = .idle
    }

    func syncNow() async {
        guard !isSyncing else { return }
        guard let client = makeClient() else { syncState = .failed("尚未与 Mac 配对"); return }
        isSyncing = true
        defer { isSyncing = false }
        syncState = .syncing
        do {
            let descriptor = FetchDescriptor<SyncQueueItem>(sortBy: [SortDescriptor(\.createdAt)])
            var uploadedHealth: [SyncQueueItem] = []
            for item in try context.fetch(descriptor) {
                do {
                    if item.kind == "health" {
                        try await client.uploadHealth(item.payload)
                        uploadedHealth.append(item)
                    } else if item.kind == "training" {
                        try await client.uploadSession(item.payload)
                        markArchivedSession(from: item.payload)
                        context.delete(item)
                        try context.save()
                    }
                } catch {
                    item.attempts += 1
                    item.lastError = Self.presentSyncError(error)
                    try context.save()
                    throw error
                }
            }
            if !uploadedHealth.isEmpty {
                try await client.refreshDerivedData()
                uploadedHealth.forEach(context.delete)
                try context.save()
            }
            let latest = try await client.snapshot()
            snapshot = latest
            if let data = try? ContractCoding.encoder.encode(latest) {
                defaults.set(data, forKey: snapshotCacheKey)
            }
            defaults.set(latest.version, forKey: "companion.version")
            if let plan = latest.currentPlan { savePlan(plan) }
            refreshQueueCount()
            syncState = .success(Date())
        } catch {
            refreshQueueCount()
            syncState = .failed(Self.presentSyncError(error))
        }
    }

    func startTraining() {
        guard activeDraft == nil, let plan = currentPlan else { return }
        beginTraining(plan: plan, sessionID: UUID(), startedAt: DateFormatting.iso(), sendToWatch: true)
    }

    func sendCurrentPlanToWatch() {
        guard let plan = activeDraft?.plan ?? currentPlan else { return }
        watch.send(plan: plan, sessionID: activeDraft?.sessionId)
    }

    private func beginTraining(
        plan: TrainingPlan, sessionID: UUID, startedAt: String, sendToWatch: Bool
    ) {
        guard activeDraft == nil else { return }
        let startDate = DateFormatting.parse(startedAt) ?? Date()
        let draft = TrainingDraft(
            sessionId: sessionID, plan: plan, startedAt: startedAt, completedSets: [:],
            watchWorkoutUuid: nil, workout: nil,
            exerciseOverrides: nil, recordedSetExercises: nil,
            lifecycle: WorkoutLifecycleSnapshot(
                state: .running, sequence: 0,
                startedAt: DateFormatting.iso(startDate), transitionAt: DateFormatting.iso(startDate),
                activeDurationSeconds: 0, elapsedDurationSeconds: 0
            ),
            workoutManagedByWatch: false
        )
        guard let data = try? ContractCoding.encoder.encode(draft) else { return }
        context.insert(ActiveTrainingRecord(
            sessionId: draft.sessionId, planId: plan.planId, planRevision: plan.revision,
            startedAt: Date(), draftPayload: data
        ))
        try? context.save()
        activeDraft = draft
        pendingPersistenceDraft = nil
        health.setInteractiveTrainingActive(true)
        liveActivity.sync(draft, priority: .immediate)
        if sendToWatch { watch.send(plan: plan, sessionID: draft.sessionId) }
    }

    func recordSet(exercise: ExercisePlan, setNumber: Int, weight: Double?, reps: Int, feeling: LastSetFeeling?) {
        guard var draft = activeDraft else { return }
        guard let actualExercise = draft.executionExercise(for: exercise.exerciseId) else { return }
        draft.record(
            exercise: actualExercise, setNumber: setNumber,
            weight: weight, reps: reps, feeling: feeling
        )
        // Publish the row immediately, then coalesce the disk write. A set is
        // still flushed synchronously at lifecycle boundaries and before
        // archiving, while the tap itself no longer waits on SwiftData.save().
        persist(draft, priority: .debounced)
    }

    func removeSet(exercise: ExercisePlan, setNumber: Int) {
        guard var draft = activeDraft else { return }
        draft.remove(exerciseID: exercise.exerciseId, setNumber: setNumber)
        persist(draft, priority: .debounced)
    }

    func updateLastSetFeeling(exercise: ExercisePlan, feeling: LastSetFeeling) {
        guard var draft = activeDraft else { return }
        draft.updateFeeling(exerciseID: exercise.exerciseId, feeling: feeling)
        persist(draft, priority: .debounced)
    }

    func setRestUntil(_ deadline: Date?) {
        guard var draft = activeDraft else { return }
        draft.restUntil = deadline
        draft.restRevision = (draft.restRevision ?? 0) + 1
        persist(draft, priority: .debounced)
    }

    func updateExerciseExecution(
        plannedExerciseId: UUID,
        name: String,
        equipmentVariant: String,
        targetWeightKg: Double?,
        sets: Int,
        targetReps: Int,
        restSeconds: Int,
        kind: ExerciseAdjustmentKind
    ) {
        guard var draft = activeDraft else { return }
        draft.updateExecution(
            plannedExerciseId: plannedExerciseId,
            name: name,
            equipmentVariant: equipmentVariant,
            targetWeightKg: targetWeightKg,
            sets: sets,
            targetReps: targetReps,
            restSeconds: restSeconds,
            kind: kind
        )
        // Exercise substitutions affect the rendered row, Watch payload, and
        // crash/relaunch recovery. Save the structural edit before returning.
        persist(draft, priority: .immediate)
        sendExecutionPlanToWatch(draft)
    }

    func resetExerciseExecution(plannedExerciseId: UUID) {
        guard var draft = activeDraft else { return }
        draft.resetExecution(plannedExerciseId: plannedExerciseId)
        persist(draft, priority: .immediate)
        sendExecutionPlanToWatch(draft)
    }

    func pauseTraining() {
        guard var draft = activeDraft, draft.lifecycleState == .running else { return }
        if draft.workoutManagedByWatch == true {
            sendWorkoutCommand(.pause, sessionID: draft.sessionId)
            return
        }
        guard draft.transitionLocally(to: .paused) else { return }
        persist(draft, priority: .immediate)
    }

    func resumeTraining() {
        guard var draft = activeDraft, draft.lifecycleState == .paused else { return }
        if draft.workoutManagedByWatch == true {
            sendWorkoutCommand(.resume, sessionID: draft.sessionId)
            return
        }
        guard draft.transitionLocally(to: .running) else { return }
        persist(draft, priority: .immediate)
    }

    func requestStopTraining() {
        guard var draft = activeDraft else { return }
        guard draft.lifecycleState == .running || draft.lifecycleState == .paused
                || draft.lifecycleState == .preparing else { return }
        if draft.workoutManagedByWatch == true {
            sendWorkoutCommand(.stop, sessionID: draft.sessionId)
            return
        }
        guard draft.transitionLocally(to: .stopped) else { return }
        draft.restUntil = nil
        persist(draft, priority: .immediate)
    }

    private func sendWorkoutCommand(_ kind: WorkoutCommand.Kind, sessionID: UUID) {
        let command = WorkoutCommand(
            commandId: UUID(), sessionId: sessionID, kind: kind,
            createdAt: DateFormatting.iso()
        )
        workoutMirror.send(command: command)
        watch.send(command: command)
    }

    var canFinalizeTraining: Bool {
        guard let draft = activeDraft else { return false }
        if draft.workoutManagedByWatch == true {
            return draft.lifecycleState == .completed || draft.lifecycleState == .failed
        }
        return draft.lifecycleState == .stopped || draft.lifecycleState.isTerminal
    }

    var canDiscardTraining: Bool {
        guard let draft = activeDraft else { return false }
        if draft.workoutManagedByWatch == true {
            return draft.lifecycleState == .completed || draft.lifecycleState == .failed
        }
        return true
    }

    /// Abandons the execution draft without creating a training history item.
    /// A Watch-managed workout must reach a terminal state first so HealthKit
    /// is never left with an active workout session behind the UI.
    @discardableResult
    func discardTraining() -> Bool {
        guard var draft = activeDraft else { return false }
        if draft.workoutManagedByWatch == true,
           draft.lifecycleState != .completed,
           draft.lifecycleState != .failed {
            if pendingTrainingDiscardSessionID != draft.sessionId {
                pendingTrainingDiscardSessionID = draft.sessionId
                sendWorkoutCommand(.stop, sessionID: draft.sessionId)
            }
            trainingCompletionError = nil
            return false
        }
        if draft.workoutManagedByWatch != true,
           (draft.lifecycleState == .running || draft.lifecycleState == .paused
                || draft.lifecycleState == .preparing) {
            _ = draft.transitionLocally(to: .stopped)
        }

        cancelPendingPersistence()
        let sessionID = draft.sessionId
        let descriptor = FetchDescriptor<ActiveTrainingRecord>(
            predicate: #Predicate { $0.sessionId == sessionID }
        )
        do {
            for record in try context.fetch(descriptor) { context.delete(record) }
            try context.save()
        } catch {
            context.rollback()
            pendingTrainingDiscardSessionID = nil
            trainingCompletionError = "未能放弃本次训练，请重试。"
            return false
        }

        liveActivity.discard(draft)
        activeDraft = nil
        pendingTrainingDiscardSessionID = nil
        health.setInteractiveTrainingActive(false)
        trainingCompletionError = nil
        activatePendingPlan(receivedAfter: DateFormatting.parse(draft.startedAt) ?? Date())
        return true
    }

    @discardableResult
    func finishTraining(feedback: SessionFeedback, stoppedEarly: Bool) -> Bool {
        guard var draft = activeDraft else { return false }
        guard flushPendingPersistence() else { return false }
        if draft.workoutManagedByWatch == true {
            guard draft.lifecycleState == .completed || draft.lifecycleState == .failed else { return false }
        } else if draft.lifecycleState != .stopped && !draft.lifecycleState.isTerminal {
            guard draft.transitionLocally(to: .stopped) else { return false }
        }
        let endedAt = Date()
        let workout = draft.workout ?? WorkoutSummary(
            durationSeconds: draft.activeDuration(at: endedAt),
            activeKcal: nil, averageHeartRate: nil, maximumHeartRate: nil
        )
        let results = draft.exerciseResults()
        let session = TrainingSessionContract(
            sessionId: draft.sessionId, planId: draft.plan.planId, planRevision: draft.plan.revision,
            startedAt: draft.startedAt, endedAt: DateFormatting.iso(endedAt),
            status: stoppedEarly ? .stoppedEarly : .completed,
            exerciseResults: results, feedback: feedback,
            watchWorkoutUuid: draft.watchWorkoutUuid, workout: workout
        )
        guard let payload = try? ContractCoding.encoder.encode(session) else {
            trainingCompletionError = "训练记录编码失败，已保留当前训练，请重试。"
            return false
        }
        let archived = ArchivedSessionRecord(
            sessionId: session.sessionId, payload: payload, endedAt: endedAt
        )
        context.insert(archived)
        if developmentCompanionExportEnabled {
            context.insert(SyncQueueItem(kind: "training", payload: payload))
        }
        let descriptor = FetchDescriptor<ActiveTrainingRecord>(predicate: #Predicate { $0.sessionId == draft.sessionId })
        do {
            guard let record = try context.fetch(descriptor).first else {
                throw TrainingArchiveError.activeRecordMissing
            }
            context.delete(record)
            if let trainingArchiveSaveOverride {
                try trainingArchiveSaveOverride()
            } else {
                try context.save()
            }
        } catch {
            context.rollback()
            trainingCompletionError = "未能保存本次训练，记录和锁屏训练卡已保留，请重试。"
            return false
        }
        trainingCompletionError = nil
        cancelPendingPersistence()
        liveActivity.end(draft, now: endedAt)
        activeDraft = nil
        health.setInteractiveTrainingActive(false)
        lastCompletedSession = session
        refreshTrainingHistory()
        activatePendingPlan(receivedAfter: DateFormatting.parse(draft.startedAt) ?? Date())
        refreshQueueCount()
        if isPaired { Task { await syncNow() } }
        return true
    }

    private func sendExecutionPlanToWatch(_ draft: TrainingDraft) {
        var executionPlan = draft.plan
        executionPlan.exercises = draft.executionExercises
        watch.send(plan: executionPlan, sessionID: draft.sessionId)
    }

    func dismissTrainingReceipt() {
        lastCompletedSession = nil
    }

    func localSession(id: String) -> TrainingSessionContract? {
        guard let sessionID = UUID(uuidString: id) else { return nil }
        let descriptor = FetchDescriptor<ArchivedSessionRecord>(
            predicate: #Predicate { $0.sessionId == sessionID }
        )
        guard let record = try? context.fetch(descriptor).first else { return nil }
        return try? ContractCoding.decoder.decode(
            TrainingSessionContract.self, from: record.payload
        )
    }

    @discardableResult
    func deleteLocalSession(id: String) -> Bool {
        let normalizedID = id.lowercased()
        guard let sessionID = UUID(uuidString: id) else {
            guard effectiveTrainingHistory.contains(where: { $0.id.lowercased() == normalizedID }) else {
                return false
            }
            hideTrainingHistoryItem(id: normalizedID)
            return true
        }
        let archivedDescriptor = FetchDescriptor<ArchivedSessionRecord>(
            predicate: #Predicate { $0.sessionId == sessionID }
        )
        do {
            if let archived = try context.fetch(archivedDescriptor).first {
                context.delete(archived)
            } else if effectiveTrainingHistory.contains(where: { $0.id.lowercased() == normalizedID }) {
                hideTrainingHistoryItem(id: normalizedID)
                return true
            } else {
                return false
            }

            let trainingKind = "training"
            let queueDescriptor = FetchDescriptor<SyncQueueItem>(
                predicate: #Predicate { $0.kind == trainingKind }
            )
            for item in try context.fetch(queueDescriptor) {
                guard let queued = try? ContractCoding.decoder.decode(
                    TrainingSessionContract.self, from: item.payload
                ), queued.sessionId == sessionID else { continue }
                context.delete(item)
            }
            try context.save()
        } catch {
            context.rollback()
            return false
        }

        if lastCompletedSession?.sessionId == sessionID { lastCompletedSession = nil }
        refreshTrainingHistory()
        refreshQueueCount()
        return true
    }

    private func hideTrainingHistoryItem(id: String) {
        hiddenTrainingHistoryIDs.insert(id.lowercased())
        defaults.set(Array(hiddenTrainingHistoryIDs).sorted(), forKey: hiddenTrainingHistoryKey)
    }

    func planForSession(_ session: TrainingSessionContract) -> TrainingPlan? {
        if let currentPlan,
           currentPlan.planId == session.planId,
           currentPlan.revision == session.planRevision {
            return currentPlan
        }
        let key = "\(session.planId.uuidString):\(session.planRevision)"
        let descriptor = FetchDescriptor<CachedPlanRecord>(
            predicate: #Predicate { $0.key == key }
        )
        guard let record = try? context.fetch(descriptor).first else { return nil }
        return try? ContractCoding.decoder.decode(TrainingPlan.self, from: record.payload)
    }

    func sessionIsArchivedToMac(_ id: UUID) -> Bool {
        let descriptor = FetchDescriptor<ArchivedSessionRecord>(
            predicate: #Predicate { $0.sessionId == id }
        )
        return (try? context.fetch(descriptor).first?.macArchivedAt) != nil
    }

    private func persist(
        _ draft: TrainingDraft,
        priority: PersistencePriority = .debounced
    ) {
        // Keep the UI responsive by publishing the newest draft immediately. The
        // durable record is coalesced for ordinary edits, while lifecycle and set
        // events use the immediate path below.
        activeDraft = draft
        pendingPersistenceDraft = draft
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil

        switch priority {
        case .immediate:
            _ = flushPendingPersistence(generation: generation)
            liveActivity.sync(draft, priority: .immediate)
        case .debounced:
            // Tests model an immediate relaunch against the same in-memory
            // container. Keep that deterministic without changing production
            // tap latency, which still uses the coalesced write below.
            if usesInMemoryPersistence {
                _ = flushPendingPersistence(generation: generation)
                return
            }
            liveActivity.sync(draft)
            pendingPersistenceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self else { return }
                _ = self.flushPendingPersistence(generation: generation)
            }
        }
    }

    @discardableResult
    func flushPendingPersistence() -> Bool {
        flushPendingPersistence(generation: persistenceGeneration)
    }

    @discardableResult
    private func flushPendingPersistence(generation: Int) -> Bool {
        guard generation == persistenceGeneration else { return false }
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        guard let draft = pendingPersistenceDraft ?? activeDraft else { return true }
        guard let payload = try? ContractCoding.encoder.encode(draft) else {
            syncState = .failed("训练状态编码失败，当前训练仍保留在界面中。")
            return false
        }
        let sessionID = draft.sessionId
        let descriptor = FetchDescriptor<ActiveTrainingRecord>(
            predicate: #Predicate { $0.sessionId == sessionID }
        )
        do {
            guard let record = try context.fetch(descriptor).first else {
                syncState = .failed("训练状态记录不存在，当前训练仍保留在界面中。")
                return false
            }
            record.draftPayload = payload
            try context.save()
            pendingPersistenceDraft = nil
            return true
        } catch {
            syncState = .failed("训练状态暂存失败，当前训练仍保留在界面中：\(error.localizedDescription)")
            return false
        }
    }

    private func cancelPendingPersistence() {
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        pendingPersistenceDraft = nil
        persistenceGeneration &+= 1
    }

    private func enqueueHealth(_ batch: HealthBatch) async {
        let metric = batch.samples.first?.metric
        let queueForExport = developmentCompanionExportEnabled
        let forceQueue = queueForExport && (metric.map { replacingHealthMetrics.contains($0) } ?? false)
        let replacement: HealthMetric? = metric.flatMap { value in
            guard forceQueue, startedHealthReplacements.insert(value).inserted else { return nil }
            return value
        }
        do {
            try await healthPersistence.enqueue(
                batch, replacing: replacement, forceQueue: forceQueue,
                queueForExport: queueForExport
            )
        } catch {
            syncState = .failed("健康数据暂存失败，HealthKit 原始数据未受影响：\(error.localizedDescription)")
        }
    }

    func importHealth(forceBackfill: Bool = false) async {
        if forceBackfill {
            replacingHealthMetrics = Set(HealthMetric.allCases)
        }
        await health.requestAuthorizationAndImport(forceBackfill: forceBackfill)
        replacingHealthMetrics.removeAll()
        startedHealthReplacements.removeAll()
        if isPaired { await syncNow() }
    }

    static func mergeHealthBatches(_ batches: [HealthBatch]) -> HealthBatch? {
        guard let latest = batches.last else { return nil }
        var samples: [String: HealthSampleContract] = [:]
        var coverage: [String: MetricCoverage] = [:]
        for batch in batches {
            for sample in batch.samples { samples[sample.sampleUuid] = sample }
            for item in batch.coverage {
                let key = "\(item.date)|\(item.metric)"
                let current = coverage[key]
                if current == nil || (current?.status != .complete && item.status == .complete) {
                    coverage[key] = item
                }
            }
        }
        return HealthBatch(
            batchId: UUID(), deviceId: latest.deviceId, createdAt: DateFormatting.iso(),
            anchor: latest.anchor,
            samples: samples.values.sorted {
                $0.startAt == $1.startAt ? $0.sampleUuid < $1.sampleUuid : $0.startAt < $1.startAt
            },
            coverage: coverage.values.sorted {
                $0.date == $1.date ? $0.metric < $1.metric : $0.date < $1.date
            }
        )
    }

    nonisolated static func presentSyncError(_ error: Error) -> String {
        if let error = error as? CompanionError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .secureConnectionFailed, .clientCertificateRejected:
                return "Mac 身份校验失败，已阻止连接；请在数据页重新扫码配对。"
            case .timedOut:
                return "连接 Mac 超时。确认 companion 正在运行后重试。"
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .dnsLookupFailed:
                return "暂时无法连接 Mac。确认双方在同一局域网且 companion 正在运行。"
            default:
                return "同步失败，队列已保留；请稍后重试。"
            }
        }
        if error is DecodingError {
            return "Mac 返回的数据版本不兼容，请更新 companion 或 App。"
        }
        return "同步失败，队列已保留；请稍后重试。"
    }

    func receiveWatchEvent(_ event: WatchEvent) {
        let eventID = event.eventId
        let descriptor = FetchDescriptor<WatchEventRecord>(predicate: #Predicate { $0.eventId == eventID })
        let record: WatchEventRecord
        if let existing = try? context.fetch(descriptor).first {
            guard existing.appliedAt == nil else { return }
            record = existing
        } else {
            guard let payload = try? ContractCoding.encoder.encode(event) else { return }
            record = WatchEventRecord(eventId: eventID, payload: payload)
            context.insert(record)
        }
        try? context.save()
        if event.kind == .sessionStarted {
            if activeDraft == nil {
                startTrainingFromWatch(event)
            } else if var draft = activeDraft, draft.sessionId == event.sessionId {
                draft.apply(event)
                persist(draft, priority: .immediate)
            }
        }
        replayPendingWatchEvents(sessionID: event.sessionId)
    }

    private func startTrainingFromWatch(_ event: WatchEvent) {
        guard activeDraft == nil, let plan = plan(for: event) else { return }
        beginTraining(
            plan: plan, sessionID: event.sessionId,
            startedAt: event.createdAt, sendToWatch: false
        )
        guard var draft = activeDraft else { return }
        draft.apply(event)
        persist(draft, priority: .immediate)
    }

    private func plan(for event: WatchEvent) -> TrainingPlan? {
        if let currentPlan,
           event.planId == currentPlan.planId,
           event.planRevision == currentPlan.revision { return currentPlan }
        guard let planID = event.planId, let revision = event.planRevision else { return nil }
        let key = "\(planID.uuidString):\(revision)"
        let descriptor = FetchDescriptor<CachedPlanRecord>(predicate: #Predicate { $0.key == key })
        guard let record = try? context.fetch(descriptor).first else { return nil }
        return try? ContractCoding.decoder.decode(TrainingPlan.self, from: record.payload)
    }

    private func replayPendingWatchEvents(sessionID: UUID) {
        guard activeDraft?.sessionId == sessionID else { return }
        let descriptor = FetchDescriptor<WatchEventRecord>(
            predicate: #Predicate { $0.appliedAt == nil },
            sortBy: [SortDescriptor(\.receivedAt)]
        )
        guard let records = try? context.fetch(descriptor) else { return }
        let pending = records.compactMap { record -> (WatchEventRecord, WatchEvent)? in
            guard let payload = record.payload,
                  let event = try? ContractCoding.decoder.decode(WatchEvent.self, from: payload),
                  event.sessionId == sessionID else { return nil }
            return (record, event)
        }
        .sorted { left, right in
            if let leftSequence = left.1.lifecycle?.sequence,
               let rightSequence = right.1.lifecycle?.sequence,
               leftSequence != rightSequence {
                return leftSequence < rightSequence
            }
            return left.1.createdAt < right.1.createdAt
        }
        var latestDraft = activeDraft
        var didApplyDraftChange = false
        for (record, event) in pending {
            if event.kind != .sessionStarted, var draft = activeDraft {
                draft.apply(event)
                latestDraft = draft
                activeDraft = draft
                didApplyDraftChange = true
            }
            record.appliedAt = Date()
        }
        try? context.save()
        if didApplyDraftChange, let latestDraft {
            persist(latestDraft, priority: .immediate)
            if pendingTrainingDiscardSessionID == sessionID,
               latestDraft.lifecycleState.isTerminal {
                _ = discardTraining()
            }
        }
    }

    private func resumePendingWatchSession(for plan: TrainingPlan) {
        guard activeDraft == nil else { return }
        let descriptor = FetchDescriptor<WatchEventRecord>(
            predicate: #Predicate { $0.appliedAt == nil },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        guard let records = try? context.fetch(descriptor),
              let event = records.compactMap({ record -> WatchEvent? in
                  guard let payload = record.payload,
                        let event = try? ContractCoding.decoder.decode(WatchEvent.self, from: payload),
                        event.kind == .sessionStarted,
                        event.planId == plan.planId,
                        event.planRevision == plan.revision else { return nil }
                  return event
              }).first else { return }
        startTrainingFromWatch(event)
        replayPendingWatchEvents(sessionID: event.sessionId)
    }

    func savePlan(_ plan: TrainingPlan) {
        guard let payload = try? ContractCoding.encoder.encode(plan) else { return }
        let shouldActivate = activeDraft == nil
        let previous = currentPlan
        let descriptor = FetchDescriptor<CachedPlanRecord>()
        let records = (try? context.fetch(descriptor)) ?? []
        let currentRevision = currentPlan?.planId == plan.planId ? currentPlan?.revision : nil
        let cachedRevision = records
            .filter { $0.planId == plan.planId }
            .map(\.revision)
            .max()
        if plan.revision < max(currentRevision ?? 0, cachedRevision ?? 0) { return }
        if let currentPlan,
           currentPlan.planId == plan.planId,
           currentPlan.revision == plan.revision,
           currentPlan != plan { return }

        let key = "\(plan.planId.uuidString):\(plan.revision)"
        if let existing = records.first(where: { $0.key == key }) {
            guard existing.payload == payload else { return }
            guard shouldActivate else { return }
            records.forEach { $0.isActive = false }
            existing.isActive = true
            try? context.save()
            currentPlan = plan
            planChanges = previous.map { TrainingPlanComparison.changes(from: $0, to: plan) } ?? []
            resumePendingWatchSession(for: plan)
            watch.send(plan: plan)
            return
        }

        if shouldActivate { records.forEach { $0.isActive = false } }
        let record = CachedPlanRecord(plan: plan, payload: payload)
        record.isActive = shouldActivate
        context.insert(record)
        try? context.save()
        guard shouldActivate else { return }
        currentPlan = plan
        planChanges = previous.map { TrainingPlanComparison.changes(from: $0, to: plan) } ?? []
        resumePendingWatchSession(for: plan)
        watch.send(plan: plan)
    }

    func savePlanCandidate(_ candidate: TrainingPlanCandidate) -> [String] {
        var errors = TrainingPlanCandidateValidation.errors(candidate)
        errors.append(contentsOf: AIPlanPolicy.publicationErrors(
            candidate,
            currentSafetyGate: effectiveReadiness?.safetyGate
        ))
        errors = Array(Set(errors)).sorted()
        guard errors.isEmpty,
              let payload = try? ContractCoding.encoder.encode(candidate) else { return errors }
        let descriptor = FetchDescriptor<TrainingPlanCandidateRecord>(
            predicate: #Predicate { $0.candidateId == candidate.candidateId }
        )
        if let existing = try? context.fetch(descriptor).first {
            guard existing.payload == payload,
                  existing.status == candidate.status.rawValue else {
                return ["旧版候选仅可查看或放弃，不能编辑或确认"]
            }
        } else {
            context.insert(TrainingPlanCandidateRecord(candidate: candidate, payload: payload))
        }
        try? context.save()
        planCandidate = candidate
        return []
    }

    @discardableResult
    func confirmPlanCandidate() -> Bool {
        false
    }

    @discardableResult
    func publishPlanCandidate() -> Bool {
        // V1 candidates remain decodable so users can inspect or reject data
        // created by an older build. They cannot cross the V2 acceptance
        // boundary because they do not carry evidence, restrictions, expiry,
        // or the original context needed for acceptance-time revalidation.
        false
    }

    @discardableResult
    func rejectPlanCandidate() -> Bool {
        guard var candidate = planCandidate else { return false }
        candidate.status = .rejected
        guard let payload = try? ContractCoding.encoder.encode(candidate) else { return false }
        let descriptor = FetchDescriptor<TrainingPlanCandidateRecord>(
            predicate: #Predicate { $0.candidateId == candidate.candidateId }
        )
        do {
            guard let existing = try context.fetch(descriptor).first else { return false }
            existing.payload = payload
            existing.status = candidate.status.rawValue
            try context.save()
        } catch {
            context.rollback()
            return false
        }
        planCandidate = nil
        return true
    }

    func makeAITrainingContext(
        input: AIPlanUserInput,
        now: Date = Date()
    ) -> TrainingContext {
        makeAITrainingContext(input: input, now: now, preservingIntent: nil)
    }

    func canRequestAIRecommendation(context: TrainingContext) -> Bool {
        guard context.schemaVersion == "TrainingContext.v2",
              context.safety.disposition != .block,
              context.safety.disposition != .needsUserInput,
              !context.safety.restrictions.contains(where: {
                  $0.kind == .prohibitTraining || $0.severity == .block
              }) else { return false }
        return true
    }

    func makeAIRecommendationCandidate(
        recommendation: AIRecommendation,
        context: TrainingContext,
        now: Date = Date()
    ) -> TrainingPlanCandidateV2? {
        let metadata = recommendation.inferenceMetadata
        let source = [
            "kris-ai", metadata?.provider ?? "managed",
            metadata?.model ?? "provider-neutral",
            metadata?.promptVersion ?? "training_recommendation.v2",
        ].joined(separator: ":")
        return AIDecisionCandidateFactory.makeCandidate(
            recommendation: recommendation, context: context,
            source: source, now: now
        )
    }

    @discardableResult
    func saveAIRecommendationCandidate(
        _ candidate: TrainingPlanCandidateV2
    ) -> AIDecisionValidationReport {
        let validationDate = DateFormatting.parse(candidate.createdAt) ?? Date()
        let report = AIDecisionPipelineValidator.revalidateForAcceptance(
            candidate: candidate, currentContext: candidate.context, now: validationDate
        )
        guard report.isValid else { return report }

        var persistedCandidate = candidate
        persistedCandidate.validationReport = report
        guard let payload = try? ContractCoding.encoder.encode(persistedCandidate) else {
            return AIDecisionValidationReport(issues: [AIDecisionValidationIssue(
                code: .invalidPlan, path: "candidate",
                message: "Candidate could not be encoded"
            )])
        }
        let descriptor = FetchDescriptor<TrainingPlanCandidateRecord>(
            predicate: #Predicate { $0.candidateId == persistedCandidate.candidateId }
        )
        do {
            if let existing = try context.fetch(descriptor).first {
                existing.payload = payload
                existing.status = persistedCandidate.status.rawValue
            } else {
                context.insert(TrainingPlanCandidateRecord(
                    candidate: persistedCandidate, payload: payload
                ))
            }
            try aiCandidateSaveOverride?()
            try context.save()
        } catch {
            context.rollback()
            return AIDecisionValidationReport(issues: [AIDecisionValidationIssue(
                code: .invalidPlan, path: "persistence",
                message: "Candidate could not be saved"
            )])
        }
        aiRecommendationCandidate = persistedCandidate
        return report
    }

    @discardableResult
    func publishAIRecommendationCandidate(now: Date = Date()) -> Bool {
        guard var candidate = aiRecommendationCandidate,
              candidate.status == .awaitingConfirmation else { return false }

        let currentContext = makeAITrainingContext(
            input: aiInput(from: candidate.context), now: now,
            preservingIntent: candidate.context.intent
        )
        let report = AIDecisionPipelineValidator.revalidateForAcceptance(
            candidate: candidate, currentContext: currentContext, now: now
        )
        guard report.isValid else {
            candidate.validationReport = report
            persistAIRecommendationValidationReport(candidate)
            aiRecommendationCandidate = candidate
            return false
        }

        if candidate.recommendation.kind == .noChange
            || candidate.recommendation.kind == .declineUnsafeRequest {
            guard candidate.plan.planId == currentPlan?.planId,
                  candidate.plan.revision == currentPlan?.revision else { return false }
            candidate.status = .published
            candidate.validationReport = report
            candidate.userDecision = UserDecision(
                recommendationId: candidate.recommendation.recommendationId,
                candidateId: candidate.candidateId, kind: .accepted,
                decidedAt: DateFormatting.iso(now),
                acceptedPlanId: currentPlan?.planId,
                acceptedPlanRevision: currentPlan?.revision,
                edits: [], rejectionReason: nil
            )
            guard let payload = try? ContractCoding.encoder.encode(candidate) else { return false }
            let descriptor = FetchDescriptor<TrainingPlanCandidateRecord>(
                predicate: #Predicate { $0.candidateId == candidate.candidateId }
            )
            do {
                if let existing = try context.fetch(descriptor).first {
                    existing.payload = payload
                    existing.status = candidate.status.rawValue
                } else {
                    context.insert(TrainingPlanCandidateRecord(candidate: candidate, payload: payload))
                }
                try aiCandidateSaveOverride?()
                try context.save()
            } catch {
                context.rollback()
                return false
            }
            aiRecommendationCandidate = nil
            return true
        }

        let previous = currentPlan
        var acceptedPlan = candidate.plan
        acceptedPlan.publishedAt = DateFormatting.iso(now)
        let edits = planEdits(candidate: candidate, acceptedPlan: acceptedPlan)
        candidate.plan = acceptedPlan
        candidate.status = .published
        candidate.validationReport = report
        candidate.userDecision = UserDecision(
            recommendationId: candidate.recommendation.recommendationId,
            candidateId: candidate.candidateId,
            kind: edits.isEmpty ? .accepted : .acceptedWithEdits,
            decidedAt: DateFormatting.iso(now),
            acceptedPlanId: acceptedPlan.planId,
            acceptedPlanRevision: acceptedPlan.revision,
            edits: edits, rejectionReason: nil
        )

        guard let candidatePayload = try? ContractCoding.encoder.encode(candidate),
              let planPayload = try? ContractCoding.encoder.encode(acceptedPlan) else {
            return false
        }
        let candidateDescriptor = FetchDescriptor<TrainingPlanCandidateRecord>(
            predicate: #Predicate { $0.candidateId == candidate.candidateId }
        )
        let planDescriptor = FetchDescriptor<CachedPlanRecord>()
        let shouldActivate = activeDraft == nil
        do {
            let planRecords = try context.fetch(planDescriptor)
            let key = "\(acceptedPlan.planId.uuidString):\(acceptedPlan.revision)"
            if let existing = planRecords.first(where: { $0.key == key }) {
                guard existing.payload == planPayload else { return false }
                if shouldActivate {
                    planRecords.forEach { $0.isActive = false }
                    existing.isActive = true
                }
            } else {
                let record = CachedPlanRecord(plan: acceptedPlan, payload: planPayload)
                record.isActive = shouldActivate
                if shouldActivate { planRecords.forEach { $0.isActive = false } }
                context.insert(record)
            }

            if let existing = try context.fetch(candidateDescriptor).first {
                existing.payload = candidatePayload
                existing.status = candidate.status.rawValue
            } else {
                context.insert(TrainingPlanCandidateRecord(candidate: candidate, payload: candidatePayload))
            }
            try aiCandidateSaveOverride?()
            try context.save()
        } catch {
            context.rollback()
            return false
        }

        aiRecommendationCandidate = nil
        guard shouldActivate else { return true }
        currentPlan = acceptedPlan
        planChanges = previous.map {
            TrainingPlanComparison.changes(from: $0, to: acceptedPlan)
        } ?? []
        resumePendingWatchSession(for: acceptedPlan)
        watch.send(plan: acceptedPlan)
        return true
    }

    @discardableResult
    func rejectAIRecommendationCandidate(reason: String? = nil) -> Bool {
        guard var candidate = aiRecommendationCandidate else { return false }
        candidate.status = .rejected
        candidate.userDecision = UserDecision(
            recommendationId: candidate.recommendation.recommendationId,
            candidateId: candidate.candidateId, kind: .rejected,
            decidedAt: DateFormatting.iso(), acceptedPlanId: nil,
            acceptedPlanRevision: nil, edits: [],
            rejectionReason: reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let payload = try? ContractCoding.encoder.encode(candidate) else { return false }
        let descriptor = FetchDescriptor<TrainingPlanCandidateRecord>(
            predicate: #Predicate { $0.candidateId == candidate.candidateId }
        )
        do {
            if let existing = try context.fetch(descriptor).first {
                existing.payload = payload
                existing.status = candidate.status.rawValue
            } else {
                context.insert(TrainingPlanCandidateRecord(candidate: candidate, payload: payload))
            }
            try aiCandidateSaveOverride?()
            try context.save()
        } catch {
            context.rollback()
            return false
        }
        aiRecommendationCandidate = nil
        return true
    }

    private func persistAIRecommendationValidationReport(
        _ candidate: TrainingPlanCandidateV2
    ) {
        guard let payload = try? ContractCoding.encoder.encode(candidate) else { return }
        let descriptor = FetchDescriptor<TrainingPlanCandidateRecord>(
            predicate: #Predicate { $0.candidateId == candidate.candidateId }
        )
        do {
            guard let existing = try context.fetch(descriptor).first else { return }
            existing.payload = payload
            existing.status = candidate.status.rawValue
            try context.save()
        } catch {
            context.rollback()
        }
    }

    private func makeAITrainingContext(
        input: AIPlanUserInput,
        now: Date,
        preservingIntent: UserIntent?
    ) -> TrainingContext {
        let result = AIDecisionContextBuilder.build(
            input: input, currentPlan: currentPlan,
            health: health.todayMetrics, healthAsOf: health.lastImportAt ?? now,
            dataGaps: effectiveDataGaps,
            trainingHistory: effectiveTrainingHistory,
            confirmedTrainingOutcomes: recentConfirmedTrainingOutcomes(),
            progression: effectiveProgression, now: now,
            preservingIntent: preservingIntent
        )
        return result
    }

    private func recentConfirmedTrainingOutcomes() -> [TrainingSessionContract] {
        var descriptor = FetchDescriptor<ArchivedSessionRecord>(
            sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 12
        guard let records = try? context.fetch(descriptor) else { return [] }
        return Array(records.compactMap { record in
            guard !hiddenTrainingHistoryIDs.contains(record.sessionId.uuidString.lowercased()) else {
                return nil
            }
            return try? ContractCoding.decoder.decode(
                TrainingSessionContract.self, from: record.payload
            )
        }.prefix(4))
    }

    private func aiInput(from context: TrainingContext) -> AIPlanUserInput {
        let symptoms = context.evidence.first {
            $0.provenance == .subjectiveUser && $0.key == "reported_symptoms"
        }.flatMap { evidence -> LocalTrainingSymptoms? in
            guard case .string(let value)? = evidence.value else { return nil }
            return LocalTrainingSymptoms(rawValue: value)
        } ?? .notReported
        let energy = context.evidence.first {
            $0.provenance == .subjectiveUser && $0.key == "user_reported_energy"
        }.flatMap { evidence -> SubjectiveEnergy? in
            guard case .string(let value)? = evidence.value else { return nil }
            return SubjectiveEnergy(rawValue: value)
        }
        return AIPlanUserInput(
            date: context.intent.requestedDate,
            objective: context.intent.objective,
            availableMinutes: context.intent.availableMinutes,
            equipment: context.intent.equipment.map(\.name).joined(separator: "，"),
            notes: context.intent.notes ?? "", symptoms: symptoms,
            reportedEnergy: energy,
            intent: AIPlanIntentInput(
                kind: context.intent.kind, equipment: context.intent.equipment,
                requestedExerciseId: context.intent.requestedExerciseId,
                requestedChanges: context.intent.requestedChanges
            )
        )
    }

    private func planEdits(
        candidate: TrainingPlanCandidateV2,
        acceptedPlan: TrainingPlan
    ) -> [PlanChange] {
        guard let draft = candidate.recommendation.proposedPlan else { return [] }
        var edits: [PlanChange] = []
        func append(_ path: String, _ before: String?, _ after: String?) {
            if before != after {
                edits.append(PlanChange(path: path, before: before, after: after))
            }
        }
        append("title", draft.title, acceptedPlan.title)
        append("estimated_minutes", String(draft.estimatedMinutes), String(acceptedPlan.estimatedMinutes))
        append("goal", draft.goal, acceptedPlan.goal)
        let maximumCount = max(draft.exercises.count, acceptedPlan.exercises.count)
        for index in 0..<maximumCount {
            let proposed = draft.exercises.indices.contains(index) ? draft.exercises[index] : nil
            let accepted = acceptedPlan.exercises.indices.contains(index) ? acceptedPlan.exercises[index] : nil
            let base = "exercises[\(index)]"
            append("\(base).name", proposed?.name, accepted?.name)
            append("\(base).equipment_variant", proposed?.equipmentVariant, accepted?.equipmentVariant)
            let proposedWeight = proposed?.targetWeightKg.map { String($0) }
            let acceptedWeight = accepted?.targetWeightKg.map { String($0) }
            append("\(base).target_weight_kg", proposedWeight, acceptedWeight)
            append("\(base).sets", proposed.map { String($0.sets) }, accepted.map { String($0.sets) })
            append("\(base).target_reps", proposed.map { String($0.targetReps) }, accepted.map { String($0.targetReps) })
            append("\(base).rest_seconds", proposed.map { String($0.restSeconds) }, accepted.map { String($0.restSeconds) })
        }
        return edits
    }

    func makeAIPlanContext(input: AIPlanUserInput) -> AIRedactedPlanContext {
        let readiness = effectiveReadiness.map {
            AIRedactedReadiness(
                score: $0.score, state: $0.state,
                confidence: $0.confidence, safetyGate: $0.safetyGate
            )
        }
        let decision = LocalPlanEngine.decide(
            readiness: effectiveReadiness,
            evaluatedAt: health.localReadiness?.generatedAt,
            signalsFresh: effectiveDataGaps.isEmpty,
            symptoms: input.symptoms,
            hasPlan: true,
            now: Date(), calendar: .autoupdatingCurrent
        )
        let recent = effectiveTrainingHistory.prefix(6).map {
            AIRedactedTrainingSummary(
                date: String($0.date.prefix(10)), title: $0.title,
                durationMinutes: $0.durationMinutes.map { Int($0.rounded()) },
                completedSetCount: $0.completedSetCount,
                status: $0.status
            )
        }
        let plan = currentPlan.map { plan in
            AIRedactedCurrentPlan(
                title: plan.title, date: plan.date, revision: plan.revision,
                exercisePrescriptions: plan.exercises.sorted(by: { $0.order < $1.order }).map { exercise in
                    let load = exercise.targetWeightKg.map {
                        "\($0.formatted(.number.precision(.fractionLength(0...1))))kg"
                    } ?? "未设重量"
                    return "\(exercise.name)|\(exercise.equipmentVariant)|\(load)|\(exercise.sets)x\(exercise.targetReps)|休\(exercise.restSeconds)秒"
                }
            )
        }
        let progression = effectiveProgression.prefix(8).map {
            "\($0.exercise)|\($0.equipmentVariant)|\($0.state)|\($0.nextAction)"
        }
        return AIRedactedPlanContext(
            generatedAt: DateFormatting.iso(), userInput: input,
            readiness: readiness, localDecision: decision,
            recentConfirmedTraining: recent, currentPlan: plan,
            progressionNotes: progression,
            dataGaps: Array(effectiveDataGaps.prefix(8))
        )
    }

    func startAIPlanGeneration(input: AIPlanUserInput) {
        guard aiServiceAvailable else {
            aiGenerationState = .failed(AIServiceError.notConfigured.localizedDescription)
            return
        }
        let context = makeAITrainingContext(input: input)
        guard canRequestAIRecommendation(context: context) else {
            aiGenerationState = .failed(
                context.safety.restrictions.last?.message
                    ?? "需要先完成本地安全确认，才能生成训练建议"
            )
            return
        }
        aiGenerationTask?.cancel()
        aiGenerationState = .generating
        aiPlanRationale = nil
        aiPlanCautions = []
        aiGenerationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await aiService.generateRecommendation(context: context)
                try Task.checkCancellation()
                guard let candidate = makeAIRecommendationCandidate(
                    recommendation: response, context: context
                ) else {
                    aiGenerationState = .failed(AIServiceError.invalidResponse.localizedDescription)
                    return
                }
                let report = saveAIRecommendationCandidate(candidate)
                guard report.isValid else {
                    aiGenerationState = .failed(
                        report.issues.map(\.message).joined(separator: "；")
                    )
                    return
                }
                aiPlanRationale = response.reasons.map(\.explanation).joined(separator: "；")
                aiPlanCautions = response.safetyConsiderations.map(\.explanation)
                aiGenerationState = .ready
            } catch {
                if Task.isCancelled {
                    aiGenerationState = .idle
                } else {
                    aiGenerationState = .failed(
                        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                }
            }
        }
    }

    func cancelAIPlanGeneration() {
        aiGenerationTask?.cancel()
        aiGenerationTask = nil
        if aiGenerationState == .generating { aiGenerationState = .idle }
    }

    private func activatePendingPlan(receivedAfter trainingStartedAt: Date) {
        let descriptor = FetchDescriptor<CachedPlanRecord>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        guard let records = try? context.fetch(descriptor),
              let pending = records.first(where: { !$0.isActive && $0.receivedAt >= trainingStartedAt }),
              let plan = try? ContractCoding.decoder.decode(TrainingPlan.self, from: pending.payload) else { return }
        let previous = currentPlan
        records.forEach { $0.isActive = $0.key == pending.key }
        try? context.save()
        currentPlan = plan
        planChanges = previous.map { TrainingPlanComparison.changes(from: $0, to: plan) } ?? []
        watch.send(plan: plan)
    }

    private func makeClient() -> CompanionClient? {
        guard let base = defaults.string(forKey: "companion.baseURL").flatMap(URL.init(string:)),
              let fingerprint = defaults.string(forKey: "companion.fingerprint"),
              let token = KeychainStore.read(account: CompanionClient.tokenAccount) else { return nil }
        return CompanionClient(baseURL: base, fingerprint: fingerprint, deviceToken: token)
    }

    private func refreshQueueCount() {
        let healthKind = "health"
        let trainingKind = "training"
        let allDescriptor = FetchDescriptor<SyncQueueItem>()
        let healthDescriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.kind == healthKind }
        )
        let trainingDescriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.kind == trainingKind }
        )
        let retryDescriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.attempts > 0 }
        )
        var errorDescriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.lastError != nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        errorDescriptor.fetchLimit = 1
        queueCount = (try? context.fetchCount(allDescriptor)) ?? 0
        queueSummary = SyncQueueSummary(
            healthBatches: (try? context.fetchCount(healthDescriptor)) ?? 0,
            trainingSessions: (try? context.fetchCount(trainingDescriptor)) ?? 0,
            retryItems: (try? context.fetchCount(retryDescriptor)) ?? 0,
            latestError: try? context.fetch(errorDescriptor).first?.lastError
        )
    }

    private func markArchivedSession(from payload: Data) {
        guard let session = try? ContractCoding.decoder.decode(TrainingSessionContract.self, from: payload) else { return }
        let sessionID = session.sessionId
        let descriptor = FetchDescriptor<ArchivedSessionRecord>(predicate: #Predicate { $0.sessionId == sessionID })
        if let record = try? context.fetch(descriptor).first {
            record.macArchivedAt = Date()
            try? context.save()
            refreshTrainingHistory()
        }
    }

    private func refreshTrainingHistory() {
        var descriptor = FetchDescriptor<ArchivedSessionRecord>(
            sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        guard let records = try? context.fetch(descriptor) else { return }
        let planPayloads = ((try? context.fetch(FetchDescriptor<CachedPlanRecord>())) ?? [])
            .map(\.payload)
        let input = TrainingHistoryInput(
            records: records.map {
                TrainingHistoryRecordSnapshot(
                    payload: $0.payload,
                    endedAt: $0.endedAt,
                    syncedToMac: $0.macArchivedAt != nil
                )
            },
            planPayloads: planPayloads,
            workoutSamples: health.localWorkoutSamples
        )
        trainingHistoryGeneration &+= 1
        let generation = trainingHistoryGeneration
        trainingHistoryRefreshTask?.cancel()
        trainingHistoryRefreshTask = Task { [weak self] in
            // Let SwiftUI finish the state change that requested this refresh
            // before doing the detached decode/evaluation pass.
            await Task.yield()
            let result = await Task.detached(priority: .utility) {
                Self.computeTrainingHistory(input)
            }.value
            guard !Task.isCancelled, let self,
                  self.trainingHistoryGeneration == generation else { return }
            self.localTrainingHistory = result.history
            self.localTrainingIntelligence = result.intelligence
            Task { await self.health.updateLocalTrainingLoadRatio(result.intelligence.loadRatio) }
        }
    }

    nonisolated private static func computeTrainingHistory(
        _ input: TrainingHistoryInput
    ) -> TrainingHistoryComputation {
        let planList = input.planPayloads.compactMap {
            try? ContractCoding.decoder.decode(TrainingPlan.self, from: $0)
        }
        let plans = planList.reduce(into: [String: TrainingPlan]()) { result, plan in
            result["\(plan.planId.uuidString):\(plan.revision)"] = plan
        }
        let decodedRecords: [(snapshot: TrainingHistoryRecordSnapshot, session: TrainingSessionContract)] =
            input.records.compactMap { item in
                guard let session = try? ContractCoding.decoder.decode(
                    TrainingSessionContract.self, from: item.payload
                ) else { return nil }
                return (snapshot: item, session: session)
            }
        let sessions = decodedRecords.map(\.session)
        let appHistory = decodedRecords.compactMap { item -> SnapshotTrainingSummary? in
            let session = item.session
            let planKey = "\(session.planId.uuidString):\(session.planRevision)"
            let duration: Double?
            if let workoutDuration = session.workout?.durationSeconds {
                duration = workoutDuration
            } else if let start = DateFormatting.parse(session.startedAt),
                      let end = DateFormatting.parse(session.endedAt) {
                duration = max(0, end.timeIntervalSince(start))
            } else {
                duration = nil
            }
            let fallbackTitle = session.exerciseResults.map(\.name).prefix(2).joined(separator: " · ")
            return SnapshotTrainingSummary(
                id: session.sessionId.uuidString,
                date: session.endedAt,
                title: plans[planKey]?.title ?? (fallbackTitle.isEmpty ? "已完成训练" : fallbackTitle),
                durationMinutes: duration.map { ($0 / 60 * 10).rounded() / 10 },
                activeKcal: session.workout?.activeKcal,
                averageHeartRate: session.workout?.averageHeartRate,
                maximumHeartRate: session.workout?.maximumHeartRate,
                exerciseCount: session.exerciseResults.count,
                completedSetCount: session.exerciseResults.flatMap(\.sets).count,
                status: session.status.rawValue,
                source: "kris_coach_app",
                syncedToMac: item.snapshot.syncedToMac
            )
        }
        let healthHistory = TrainingIntelligence.workoutSummaries(
            samples: input.workoutSamples, excluding: sessions
        )
        return TrainingHistoryComputation(
            history: mergeTrainingHistory(local: appHistory, remote: healthHistory),
            intelligence: TrainingIntelligence.evaluate(
                sessions: sessions, plans: planList,
                workoutSamples: input.workoutSamples
            )
        )
    }
}
