import Foundation
import Observation
import WatchConnectivity

@MainActor
@Observable
final class WatchAppModel: NSObject, WCSessionDelegate, @unchecked Sendable {
    private(set) var plan: TrainingPlan?
    private(set) var sessionID: UUID?
    private(set) var exerciseIndex = 0
    private(set) var setNumber = 1
    private(set) var completedSets = 0
    private(set) var isActive = false
    private(set) var isComplete = false
    private(set) var needsFailureRecovery = false
    private(set) var completedWithWorkoutFailure = false
    private(set) var executionRecoveryError: String?
    private var pendingSessionID: UUID?
    private var processedCommandIDs: Set<UUID> = []
    private var lastLifecycleSequence = 0
    private var hasPublishedStart = false
    private var isRestoringExecution = false
    private var persistedLifecycle: WorkoutLifecycleSnapshot?
    private var pendingEvents: [WatchEvent] = []
    var reps = 10 { didSet { persistExecution() } }
    var feeling: LastSetFeeling = .appropriate { didSet { persistExecution() } }
    var restUntil: Date?
    var restRevision: Int?

    let workout = WorkoutManager()
    private let queue = WatchEventQueue()
    private let executionStore = WatchExecutionStore()
    private let planURL: URL

    var currentExercise: ExercisePlan? {
        guard let plan, plan.exercises.indices.contains(exerciseIndex) else { return nil }
        return plan.exercises[exerciseIndex]
    }

    var totalSets: Int { plan?.exercises.reduce(0) { $0 + $1.sets } ?? 0 }

    override init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        planURL = directory.appendingPathComponent("current-plan.json")
        super.init()
        workout.onLifecycleChange = { [weak self] snapshot in
            self?.handleLifecycle(snapshot)
        }
        workout.onRemoteCommand = { [weak self] command in
            self?.apply(command)
        }
        workout.onMirroringReady = { [weak self] in
            self?.publishCurrentExecutionState()
        }
        if let data = try? Data(contentsOf: planURL) { plan = try? ContractCoding.decoder.decode(TrainingPlan.self, from: data) }
        switch executionStore.load() {
        case .missing:
            break
        case .valid(let restored):
            switch restored.lifecycle?.state {
            case .completed:
                restoreExecution(restored)
                isActive = false
                isComplete = true
                replayPendingEvents()
            case .failed:
                restoreExecution(restored)
                isActive = false
                needsFailureRecovery = true
                replayPendingEvents()
            default:
                restoreExecution(restored)
                replayPendingEvents()
                Task {
                    await workout.recover(
                        executionID: restored.sessionId,
                        from: restored.lifecycle
                    )
                }
            }
        case .corrupt:
            executionRecoveryError = "训练恢复文件损坏，无法安全读取。"
        case .unsupported(let version):
            executionRecoveryError = "训练记录来自更高版本（v\(version)），请先更新 App。"
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func start() {
        guard executionRecoveryError == nil, !needsFailureRecovery, !isActive,
              let plan, let exercise = plan.exercises.first else { return }
        let executionID = pendingSessionID ?? UUID()
        sessionID = executionID
        pendingSessionID = nil
        exerciseIndex = 0
        setNumber = 1
        completedSets = 0
        reps = exercise.targetReps
        restUntil = nil
        restRevision = nil
        isActive = true
        isComplete = false
        processedCommandIDs.removeAll()
        lastLifecycleSequence = 0
        hasPublishedStart = false
        persistedLifecycle = nil
        pendingEvents.removeAll()
        guard persistExecution() else {
            isActive = false
            executionRecoveryError = "无法建立训练恢复记录，请释放存储空间后重试。"
            return
        }
        Task { await workout.start(executionID: executionID) }
    }

    func dismissCompletion() {
        sessionID = nil
        pendingSessionID = nil
        completedWithWorkoutFailure = false
        resetExecution(for: plan)
    }

    func keepFailedExecution() async {
        guard needsFailureRecovery else { return }
        for event in pendingEvents {
            guard await queue.enqueue(event) else { return }
        }
        guard executionStore.clear() else { return }
        pendingEvents.removeAll()
        needsFailureRecovery = false
        completedWithWorkoutFailure = true
        isComplete = true
    }

    func discardFailedExecution() {
        guard needsFailureRecovery else { return }
        pendingEvents.removeAll()
        needsFailureRecovery = false
        sessionID = nil
        completedWithWorkoutFailure = false
        resetExecution(for: plan)
    }

    func discardUnreadableExecution() {
        guard executionRecoveryError != nil else { return }
        guard executionStore.clear() else { return }
        executionRecoveryError = nil
    }

    func completeCurrentSet() {
        guard workout.lifecycle?.state == .running,
              let sessionID, let exercise = currentExercise else { return }
        let completedSetNumber = setNumber
        let completedReps = reps
        let last = completedSetNumber == exercise.sets
        isRestoringExecution = true
        var shouldFinish = false
        completedSets += 1
        if last {
            if let plan, exerciseIndex + 1 < plan.exercises.count {
                exerciseIndex += 1
                setNumber = 1
                reps = plan.exercises[exerciseIndex].targetReps
            } else {
                shouldFinish = true
            }
        } else {
            setNumber += 1
            reps = exercise.targetReps
        }
        // A completed set always publishes the current absolute rest state. The
        // final set clears any stale deadline instead of starting an unusable rest.
        restUntil = shouldFinish
            ? nil
            : Date().addingTimeInterval(TimeInterval(exercise.restSeconds))
        restRevision = (restRevision ?? 0) + 1
        let event = WatchEvent(
            eventId: UUID(), sessionId: sessionID, kind: .setCompleted,
            exerciseId: exercise.exerciseId, setNumber: completedSetNumber, reps: completedReps,
            weightKg: exercise.targetWeightKg, feeling: last ? feeling : nil,
            createdAt: DateFormatting.iso(), workoutUuid: nil, workout: nil,
            lifecycle: workout.lifecycle,
            restUntil: restUntil, restRevision: restRevision
        )
        isRestoringExecution = false
        stageEvent(event)
        if shouldFinish { Task { await finish() } }
    }

    func extendRest(by seconds: TimeInterval) {
        guard isActive, workout.lifecycle?.state == .running else { return }
        restUntil = max(restUntil ?? Date(), Date()).addingTimeInterval(seconds)
        restRevision = (restRevision ?? 0) + 1
        if let event = restEvent() { stageEvent(event) }
    }

    func skipRest() {
        guard isActive, workout.lifecycle?.state == .running else { return }
        restUntil = nil
        restRevision = (restRevision ?? 0) + 1
        if let event = restEvent() { stageEvent(event) }
    }

    func finish() async {
        guard sessionID != nil else { return }
        workout.stop()
    }

    func pause() { workout.pause() }

    func resume() { workout.resume() }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { await queue.flush() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) { Task { await queue.flush() } }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveCommand(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receiveCommand(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["plan"] as? Data,
              let plan = try? ContractCoding.decoder.decode(TrainingPlan.self, from: data) else { return }
        let sessionID = (applicationContext["session_id"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            guard self.executionRecoveryError == nil, !self.needsFailureRecovery else { return }
            if self.isComplete, sessionID == self.sessionID { return }
            if self.isActive {
                guard sessionID == self.sessionID,
                      self.plan?.planId == plan.planId,
                      self.plan?.revision == plan.revision else { return }
                self.applyExecutionPlanUpdate(plan, payload: data)
                return
            }
            if let current = self.plan,
               current.planId == plan.planId,
               current.revision > plan.revision { return }
            let isNewPlan = self.plan?.planId != plan.planId || self.plan?.revision != plan.revision
            guard isNewPlan || sessionID != nil else { return }
            self.plan = plan
            self.pendingSessionID = sessionID
            self.sessionID = nil
            self.resetExecution(for: plan)
            try? data.write(to: self.planURL, options: [.atomic, .completeFileProtection])
        }
    }

    private nonisolated func receiveCommand(_ payload: [String: Any]) {
        let data = payload["workout_command"] as? Data ?? payload["command"] as? Data
        guard let data,
              let command = try? ContractCoding.decoder.decode(WorkoutCommand.self, from: data) else { return }
        Task { @MainActor in self.apply(command) }
    }

    private func apply(_ command: WorkoutCommand) {
        guard command.sessionId == sessionID,
              processedCommandIDs.insert(command.commandId).inserted else { return }
        persistExecution()
        switch command.kind {
        case .pause: workout.pause()
        case .resume: workout.resume()
        case .stop: workout.stop()
        }
    }

    private func handleLifecycle(_ snapshot: WorkoutLifecycleSnapshot) {
        guard snapshot.sequence > lastLifecycleSequence, let sessionID else { return }
        lastLifecycleSequence = snapshot.sequence
        persistedLifecycle = snapshot

        switch snapshot.state {
        case .preparing:
            isActive = true
            isComplete = false
            persistExecution()
        case .running:
            isActive = true
            isComplete = false
            let kind: WatchEvent.Kind = hasPublishedStart ? .sessionResumed : .sessionStarted
            hasPublishedStart = true
            publishLifecycle(kind, sessionID: sessionID, snapshot: snapshot)
        case .paused:
            isActive = true
            publishLifecycle(.sessionPaused, sessionID: sessionID, snapshot: snapshot)
        case .stopped:
            isActive = true
            // A stopped execution must not resurrect an obsolete rest timer if
            // the terminal HealthKit callback is delivered after relaunch.
            restUntil = nil
            publishLifecycle(.sessionStopped, sessionID: sessionID, snapshot: snapshot)
        case .finalizing:
            isActive = true
            persistExecution()
        case .completed:
            restUntil = nil
            let event = lifecycleEvent(.sessionCompleted, sessionID: sessionID, snapshot: snapshot)
            stageEvent(event)
            isActive = false
            isComplete = true
        case .failed:
            restUntil = nil
            let event = lifecycleEvent(.sessionFailed, sessionID: sessionID, snapshot: snapshot)
            stageEvent(event)
            isActive = false
            isComplete = false
            needsFailureRecovery = true
        }
    }

    private func publishLifecycle(
        _ kind: WatchEvent.Kind,
        sessionID: UUID,
        snapshot: WorkoutLifecycleSnapshot
    ) {
        let event = lifecycleEvent(kind, sessionID: sessionID, snapshot: snapshot)
        stageEvent(event)
    }

    private func lifecycleEvent(
        _ kind: WatchEvent.Kind,
        sessionID: UUID,
        snapshot: WorkoutLifecycleSnapshot
    ) -> WatchEvent {
        let completed = kind == .sessionCompleted
        return WatchEvent(
            eventId: UUID(), sessionId: sessionID, kind: kind,
            planId: plan?.planId, planRevision: plan?.revision,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil,
            feeling: nil, createdAt: snapshot.transitionAt,
            workoutUuid: completed ? workout.workoutUUID : nil,
            workout: completed
                ? WorkoutSummary(
                    durationSeconds: snapshot.activeDurationSeconds,
                    activeKcal: workout.activeEnergy,
                    averageHeartRate: workout.averageHeartRate,
                    maximumHeartRate: workout.maximumHeartRate
                )
                : nil,
            lifecycle: snapshot
        )
    }

    private func restEvent() -> WatchEvent? {
        guard let sessionID else { return nil }
        return WatchEvent(
            eventId: UUID(), sessionId: sessionID, kind: .restUpdated,
            planId: plan?.planId, planRevision: plan?.revision,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil,
            feeling: nil, createdAt: DateFormatting.iso(), workoutUuid: nil,
            workout: nil, lifecycle: workout.lifecycle,
            restUntil: restUntil, restRevision: restRevision
        )
    }

    private func stageEvent(_ event: WatchEvent) {
        if !pendingEvents.contains(where: { $0.eventId == event.eventId }) {
            pendingEvents.append(event)
            guard persistExecution() else { return }
        }
        workout.send(event: event)
        enqueueStagedEvent(event)
    }

    private func publishCurrentExecutionState() {
        guard let sessionID, let snapshot = workout.lifecycle,
              snapshot.state == .running || snapshot.state == .paused else { return }
        let event = lifecycleEvent(.sessionStarted, sessionID: sessionID, snapshot: snapshot)
        stageEvent(event)
    }

    private func enqueueStagedEvent(_ event: WatchEvent) {
        Task { [weak self] in
            guard let self, await queue.enqueue(event) else { return }
            guard pendingEvents.contains(where: { $0.eventId == event.eventId }) else { return }
            pendingEvents.removeAll { $0.eventId == event.eventId }
            if persistedLifecycle?.state == .completed, pendingEvents.isEmpty {
                executionStore.clear()
            } else {
                persistExecution()
            }
        }
    }

    private func replayPendingEvents() {
        for event in pendingEvents {
            enqueueStagedEvent(event)
        }
    }

    private func applyExecutionPlanUpdate(_ updated: TrainingPlan, payload: Data) {
        let currentID = currentExercise?.exerciseId
        plan = updated
        if let currentID,
           let updatedIndex = updated.exercises.firstIndex(where: { $0.exerciseId == currentID }) {
            exerciseIndex = updatedIndex
            let exercise = updated.exercises[updatedIndex]
            setNumber = min(max(1, setNumber), max(1, exercise.sets))
            reps = exercise.targetReps
        }
        try? payload.write(to: planURL, options: [.atomic, .completeFileProtection])
        persistExecution()
    }

    private func restoreExecution(_ snapshot: WatchExecutionSnapshot) {
        isRestoringExecution = true
        defer { isRestoringExecution = false }
        plan = snapshot.plan
        sessionID = snapshot.sessionId
        pendingSessionID = nil
        exerciseIndex = WatchExecutionRecovery.exerciseIndex(for: snapshot)
        let exerciseSets = currentExercise?.sets ?? 1
        setNumber = min(max(1, snapshot.setNumber), max(1, exerciseSets))
        completedSets = max(0, snapshot.completedSets)
        reps = max(0, snapshot.reps)
        feeling = snapshot.feeling
        restUntil = snapshot.restUntil
        restRevision = snapshot.restRevision
        processedCommandIDs = Set(snapshot.processedCommandIds)
        lastLifecycleSequence = max(snapshot.lastLifecycleSequence, snapshot.lifecycle?.sequence ?? 0)
        hasPublishedStart = snapshot.hasPublishedStart
        persistedLifecycle = snapshot.lifecycle
        pendingEvents = snapshot.pendingEvents ?? []
        isActive = true
        isComplete = false
    }

    @discardableResult
    private func persistExecution() -> Bool {
        guard !isRestoringExecution, let sessionID, let plan,
              isActive || persistedLifecycle?.state.isTerminal == true else { return false }
        return executionStore.save(WatchExecutionSnapshot(
            sessionId: sessionID,
            plan: plan,
            currentExerciseId: currentExercise?.exerciseId,
            exerciseIndex: exerciseIndex,
            setNumber: setNumber,
            completedSets: completedSets,
            reps: reps,
            feeling: feeling,
            restUntil: restUntil,
            restRevision: restRevision,
            processedCommandIds: processedCommandIDs.sorted { $0.uuidString < $1.uuidString },
            lastLifecycleSequence: lastLifecycleSequence,
            hasPublishedStart: hasPublishedStart,
            lifecycle: persistedLifecycle,
            pendingEvents: pendingEvents
        ))
    }

    private func resetExecution(for plan: TrainingPlan?) {
        exerciseIndex = 0
        setNumber = 1
        completedSets = 0
        reps = plan?.exercises.first?.targetReps ?? 10
        feeling = .appropriate
        restUntil = nil
        restRevision = nil
        isActive = false
        isComplete = false
        needsFailureRecovery = false
        persistedLifecycle = nil
        pendingEvents.removeAll()
        executionStore.clear()
    }
}
