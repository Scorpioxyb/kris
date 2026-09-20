import Foundation
import HealthKit
import Observation

@MainActor
@Observable
final class WorkoutManager: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    private(set) var lifecycle: WorkoutLifecycleSnapshot?
    private(set) var heartRate: Double = 0
    private(set) var averageHeartRate: Double?
    private(set) var maximumHeartRate: Double?
    private(set) var activeEnergy: Double = 0
    private(set) var workoutUUID: String?
    private(set) var errorMessage: String?
    private(set) var mirroringActive = false
    private(set) var mirroringMessage: String?
    private(set) var isStarting = false
    private(set) var isRecovering = false

    @ObservationIgnored
    var onLifecycleChange: ((WorkoutLifecycleSnapshot) -> Void)?

    @ObservationIgnored
    var onRemoteCommand: ((WorkoutCommand) -> Void)?

    @ObservationIgnored
    var onMirroringReady: (() -> Void)?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var collectionBegan = false
    private var activityStartRequested = false
    private var stopRequested = false
    private var finalizationStarted = false
    private var builderFinished = false
    private var healthKitEnded = false
    private var finalizationTask: Task<Void, Never>?
    private var executionID: UUID?
    private var mirroringStartInFlight = false
    private var mirroringRetryCount = 0
    private var mirroringRetryTask: Task<Void, Never>?
    nonisolated private static let maximumMirrorPayloadBytes = 90_000

    private enum SubmissionPhase: String, Codable {
        case collecting
        case submitting
        case submitted
    }

    private struct SubmissionRecord: Codable {
        var executionID: UUID
        var phase: SubmissionPhase
        var workoutUUID: UUID?
        var startDate: Date
    }

    private let submissionRecordKey = "kriscoach.watch.workout-submission-record.v2"
    private let executionMetadataKey = "com.albertdaisy.kriscoach.execution-id"

    var running: Bool { lifecycle?.state == .running }
    var elapsed: TimeInterval { activeDuration(at: Date()) }
    var totalElapsed: TimeInterval { elapsedDuration(at: Date()) }

    func activeDuration(at date: Date) -> TimeInterval {
        lifecycle?.activeDuration(at: date) ?? 0
    }

    func elapsedDuration(at date: Date) -> TimeInterval {
        lifecycle?.elapsedDuration(at: date) ?? 0
    }

    func requestAuthorization() async throws {
        let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)!
        let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
        let workout = HKObjectType.workoutType()
        try await store.requestAuthorization(toShare: [workout, activeEnergy], read: [heartRate, activeEnergy, workout])
    }

    func start(executionID: UUID) async {
        guard !isRecovering, !isStarting, lifecycle?.state.isTerminal != false else { return }
        resetForNewWorkout()
        self.executionID = executionID
        isStarting = true
        let startedAt = Date()
        transition(to: .preparing, at: startedAt)

        do {
            try await requestAuthorization()
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .traditionalStrengthTraining
            configuration.locationType = .indoor
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            try await builder.addMetadata([executionMetadataKey: executionID.uuidString])
            saveSubmissionRecord(.init(
                executionID: executionID, phase: .collecting,
                workoutUUID: nil, startDate: startedAt
            ))
            session.prepare()
        } catch {
            fail(with: error.localizedDescription, at: Date())
        }
    }

    func recover(executionID: UUID, from previousLifecycle: WorkoutLifecycleSnapshot?) async {
        guard session == nil, !isStarting else { return }
        isRecovering = true
        defer { isRecovering = false }
        resetForNewWorkout()
        self.executionID = executionID
        lifecycle = previousLifecycle
        isStarting = true
        if lifecycle == nil { transition(to: .preparing, at: Date()) }

        let recovered: HKWorkoutSession
        do {
            guard let session = try await store.recoverActiveWorkoutSession() else {
                await reconcileDetachedSubmission(executionID: executionID)
                return
            }
            recovered = session
        } catch {
            fail(with: "恢复 HealthKit 训练失败：\(error.localizedDescription)", at: Date())
            return
        }

        let builder = recovered.associatedWorkoutBuilder()
        recovered.delegate = self
        builder.delegate = self
        session = recovered
        self.builder = builder
        collectionBegan = builder.startDate != nil
        activityStartRequested = recovered.state != .notStarted && recovered.state != .prepared

        let transitionDate = recovered.endDate ?? Date()
        switch recovered.state {
        case .prepared:
            recoverTransition(to: .preparing, at: transitionDate)
            await beginPreparedWorkout()
        case .running:
            isStarting = false
            recoverTransition(to: .running, at: transitionDate)
            await startMirroringIfNeeded()
        case .paused:
            isStarting = false
            recoverTransition(to: .paused, at: transitionDate)
            await startMirroringIfNeeded()
        case .stopped:
            isStarting = false
            recoverTransition(to: .stopped, at: transitionDate)
            await resumeFinalization(executionID: executionID, at: transitionDate, shouldEndSession: true)
        case .notStarted:
            fail(with: "HealthKit 训练尚未开始，无法恢复", at: transitionDate)
            recovered.end()
        case .ended:
            healthKitEnded = true
            recoverTransition(to: .stopped, at: transitionDate)
            recoverTransition(to: .finalizing, at: transitionDate)
            await resumeFinalization(executionID: executionID, at: transitionDate, shouldEndSession: false)
        @unknown default:
            fail(with: "HealthKit 返回了未知恢复状态", at: transitionDate)
        }
    }

    /// An ended session is no longer recoverable even while its saved workout
    /// still needs to be reconciled. Verify by execution metadata rather than
    /// treating the missing active session as a failed workout.
    private func reconcileDetachedSubmission(executionID: UUID) async {
        guard let record = submissionRecord(for: executionID),
              record.phase == .submitting || record.phase == .submitted else {
            fail(with: "未找到可恢复的 HealthKit 训练", at: Date())
            return
        }
        do {
            let matches = try await workouts(executionID: executionID, startDate: record.startDate)
            guard matches.count == 1 else {
                if matches.isEmpty {
                    markReconciliationPending(
                        "HealthKit 尚未返回已提交的训练，请稍后重试",
                        at: Date()
                    )
                } else {
                    fail(with: "HealthKit 中找到多条同一训练记录，已停止自动归档", at: Date())
                }
                return
            }
            let workout = matches[0]
            var verified = record
            verified.phase = .submitted
            verified.workoutUUID = workout.uuid
            saveSubmissionRecord(verified)
            workoutUUID = workout.uuid.uuidString
            builderFinished = true
            healthKitEnded = true
            let endedAt = workout.endDate
            recoverTransition(to: .stopped, at: endedAt)
            recoverTransition(to: .finalizing, at: endedAt)
            completeIfReady(at: endedAt)
        } catch {
            markReconciliationPending(
                "核验 HealthKit 训练失败：\(error.localizedDescription)",
                at: Date()
            )
        }
    }

    func pause() {
        guard lifecycle?.state == .running else { return }
        session?.pause()
    }

    func resume() {
        guard lifecycle?.state == .paused else { return }
        session?.resume()
    }

    func stop() {
        guard !stopRequested,
              lifecycle?.state == .running || lifecycle?.state == .paused else { return }
        stopRequested = true
        session?.stopActivity(with: Date())
    }

    func send(event: WatchEvent) {
        guard mirroringActive,
              let session,
              let data = try? ContractCoding.encoder.encode(
                WorkoutMirrorEnvelope(event: event)
              ),
              data.count <= Self.maximumMirrorPayloadBytes else { return }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session, self.session === session,
                  self.mirroringActive else { return }
            do {
                try await session.sendToRemoteWorkoutSession(data: data)
            } catch {
                guard self.session === session else { return }
                self.mirroringMessage = "手机实时显示暂不可用，训练仍会正常保存。"
            }
        }
    }

    private func resetForNewWorkout() {
        lifecycle = nil
        heartRate = 0
        averageHeartRate = nil
        maximumHeartRate = nil
        activeEnergy = 0
        workoutUUID = nil
        errorMessage = nil
        mirroringActive = false
        mirroringMessage = nil
        mirroringStartInFlight = false
        mirroringRetryCount = 0
        mirroringRetryTask?.cancel()
        mirroringRetryTask = nil
        session = nil
        builder = nil
        collectionBegan = false
        activityStartRequested = false
        stopRequested = false
        finalizationStarted = false
        builderFinished = false
        healthKitEnded = false
        finalizationTask = nil
        executionID = nil
    }

    private func beginPreparedWorkout() async {
        guard !activityStartRequested, let session, let builder else { return }
        activityStartRequested = true
        let start = Date()
        session.startActivity(with: start)
        do {
            try await builder.beginCollection(at: start)
            collectionBegan = true
        } catch {
            fail(with: error.localizedDescription, at: Date())
            session.end()
        }
    }

    private func startMirroringIfNeeded() async {
        guard let session,
              session.type == .primary,
              session.state == .running || session.state == .paused,
              !mirroringActive,
              !mirroringStartInFlight else { return }
        mirroringStartInFlight = true
        defer { mirroringStartInFlight = false }
        do {
            try await session.startMirroringToCompanionDevice()
            guard self.session === session,
                  session.state == .running || session.state == .paused else { return }
            mirroringRetryTask?.cancel()
            mirroringRetryTask = nil
            mirroringRetryCount = 0
            mirroringActive = true
            mirroringMessage = nil
            onMirroringReady?()
        } catch {
            guard self.session === session,
                  session.state == .running || session.state == .paused else { return }
            mirroringActive = false
            mirroringMessage = "手机实时显示暂不可用，正在后台重试。"
            scheduleMirroringRetry()
        }
    }

    private func scheduleMirroringRetry() {
        guard mirroringRetryTask == nil, mirroringRetryCount < 3 else { return }
        let delays: [UInt64] = [2, 5, 10]
        let delay = delays[mirroringRetryCount]
        mirroringRetryCount += 1
        mirroringRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.mirroringRetryTask = nil
            await self.startMirroringIfNeeded()
        }
    }

    private func scheduleFinalization(at date: Date, shouldEndSession: Bool) {
        guard finalizationTask == nil else { return }
        finalizationTask = Task { [weak self] in
            await self?.finalize(at: date, shouldEndSession: shouldEndSession)
        }
    }

    private func finalize(at date: Date, shouldEndSession: Bool) async {
        guard !finalizationStarted else { return }
        finalizationStarted = true
        transition(to: .finalizing, at: date)

        guard let session, let builder, collectionBegan else {
            fail(with: "HealthKit 训练未完整启动", at: date)
            self.session?.end()
            return
        }

        do {
            if builder.endDate == nil {
                try await builder.endCollection(at: date)
            }
            // Write-ahead marker: if watchOS suspends us while HealthKit saves,
            // recovery must not issue a second finishWorkout call.
            guard let executionID else {
                fail(with: "训练标识缺失，无法安全保存", at: Date())
                return
            }
            var record = submissionRecord(for: executionID) ?? SubmissionRecord(
                executionID: executionID, phase: .collecting,
                workoutUUID: nil, startDate: session.startDate ?? date
            )
            record.phase = .submitting
            saveSubmissionRecord(record)
            let workout = try await builder.finishWorkout()
            record.phase = .submitted
            record.workoutUUID = workout?.uuid
            saveSubmissionRecord(record)
            if shouldEndSession { session.end() }
            if let workout {
                workoutUUID = workout.uuid.uuidString
                builderFinished = true
                completeIfReady(at: date)
            } else {
                // A locked device may return nil without an error even after
                // HealthKit accepted the workout. Verify the saved sample by
                // execution metadata; never infer completion from nil.
                await reconcileSubmittedRecord(record, at: date)
            }
        } catch {
            // Keep the execution non-terminal. A relaunch can recover the
            // associated builder and reconcile the write-ahead marker.
            errorMessage = "训练正在等待 HealthKit 确认：\(error.localizedDescription)"
            isStarting = false
        }
    }

    private func markReconciliationPending(_ message: String, at date: Date) {
        errorMessage = message
        isStarting = false
        if lifecycle?.state != .finalizing {
            recoverTransition(to: .stopped, at: date)
            recoverTransition(to: .finalizing, at: date)
        }
    }

    private func resumeFinalization(
        executionID: UUID,
        at date: Date,
        shouldEndSession: Bool
    ) async {
        guard let record = submissionRecord(for: executionID) else {
            scheduleFinalization(at: date, shouldEndSession: shouldEndSession)
            return
        }
        if record.phase == .submitted, let workoutUUID = record.workoutUUID {
            self.workoutUUID = workoutUUID.uuidString
            builderFinished = true
            if shouldEndSession { session?.end() }
            completeIfReady(at: date)
            return
        }
        if record.phase == .submitted {
            if shouldEndSession { session?.end() }
            await reconcileSubmittedRecord(record, at: date)
            return
        }
        guard record.phase == .submitting else {
            scheduleFinalization(at: date, shouldEndSession: shouldEndSession)
            return
        }

        do {
            let matches = try await workouts(executionID: executionID, startDate: record.startDate)
            switch matches.count {
            case 0:
                scheduleFinalization(at: date, shouldEndSession: shouldEndSession)
            case 1:
                var verified = record
                verified.phase = .submitted
                verified.workoutUUID = matches[0].uuid
                saveSubmissionRecord(verified)
                workoutUUID = matches[0].uuid.uuidString
                builderFinished = true
                if shouldEndSession { session?.end() }
                completeIfReady(at: date)
            default:
                fail(with: "HealthKit 中找到多条同一训练记录，已停止自动归档", at: date)
            }
        } catch {
            markReconciliationPending(
                "核验 HealthKit 训练失败：\(error.localizedDescription)",
                at: date
            )
        }
    }

    private func reconcileSubmittedRecord(_ record: SubmissionRecord, at date: Date) async {
        do {
            let matches = try await workouts(
                executionID: record.executionID,
                startDate: record.startDate
            )
            switch matches.count {
            case 0:
                markReconciliationPending(
                    "HealthKit 正在保存训练，尚未完成核验",
                    at: date
                )
            case 1:
                var verified = record
                verified.workoutUUID = matches[0].uuid
                saveSubmissionRecord(verified)
                workoutUUID = matches[0].uuid.uuidString
                builderFinished = true
                completeIfReady(at: date)
            default:
                fail(with: "HealthKit 中找到多条同一训练记录，已停止自动归档", at: date)
            }
        } catch {
            markReconciliationPending(
                "核验 HealthKit 训练失败：\(error.localizedDescription)",
                at: date
            )
        }
    }

    private func submissionRecord(for executionID: UUID) -> SubmissionRecord? {
        guard let data = UserDefaults.standard.data(forKey: submissionRecordKey),
              let record = try? JSONDecoder().decode(SubmissionRecord.self, from: data),
              record.executionID == executionID else { return nil }
        return record
    }

    private func saveSubmissionRecord(_ record: SubmissionRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: submissionRecordKey)
    }

    private func workouts(executionID: UUID, startDate: Date) async throws -> [HKWorkout] {
        let metadata = HKQuery.predicateForObjects(
            withMetadataKey: executionMetadataKey,
            allowedValues: [executionID.uuidString]
        )
        let interval = HKQuery.predicateForSamples(
            withStart: startDate.addingTimeInterval(-60),
            end: Date().addingTimeInterval(60),
            options: []
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [metadata, interval])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(), predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (samples as? [HKWorkout]) ?? []) }
            }
            store.execute(query)
        }
    }

    private func completeIfReady(at date: Date) {
        guard builderFinished, healthKitEnded, lifecycle?.state == .finalizing else { return }
        isStarting = false
        transition(to: .completed, at: date)
    }

    private func fail(with message: String, at date: Date) {
        guard lifecycle?.state != .failed, lifecycle?.state != .completed else { return }
        errorMessage = message
        isStarting = false
        transition(to: .failed, at: date)
    }

    private func transition(to state: WorkoutLifecycleState, at date: Date) {
        if let current = lifecycle {
            guard current.state != state, current.state.canTransition(to: state) else { return }
            var active = current.activeDuration(at: date)
            var elapsed = current.elapsedDuration(at: date)
            var startedAt = current.startedAt
            if current.state == .preparing, state == .running {
                active = 0
                elapsed = 0
                startedAt = DateFormatting.iso(date)
            }
            let snapshot = WorkoutLifecycleSnapshot(
                state: state,
                sequence: current.sequence + 1,
                startedAt: startedAt,
                transitionAt: DateFormatting.iso(date),
                activeDurationSeconds: active,
                elapsedDurationSeconds: elapsed
            )
            lifecycle = snapshot
            onLifecycleChange?(snapshot)
            return
        }

        let snapshot = WorkoutLifecycleSnapshot(
            state: state,
            sequence: 1,
            startedAt: DateFormatting.iso(date),
            transitionAt: DateFormatting.iso(date),
            activeDurationSeconds: 0,
            elapsedDurationSeconds: 0
        )
        lifecycle = snapshot
        onLifecycleChange?(snapshot)
    }

    private func recoverTransition(to state: WorkoutLifecycleState, at date: Date) {
        let previous = lifecycle
        let startDate = session?.startDate
            ?? previous.flatMap { DateFormatting.parse($0.startedAt) }
            ?? date
        let active = builder?.elapsedTime(at: date)
            ?? previous?.activeDuration(at: date)
            ?? 0
        let elapsed = max(0, date.timeIntervalSince(startDate))
        let snapshot = WorkoutLifecycleSnapshot(
            state: state,
            sequence: (previous?.sequence ?? 0) + 1,
            startedAt: DateFormatting.iso(startDate),
            transitionAt: DateFormatting.iso(date),
            activeDurationSeconds: max(0, active),
            elapsedDurationSeconds: elapsed
        )
        lifecycle = snapshot
        onLifecycleChange?(snapshot)
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            switch toState {
            case .prepared:
                self.transition(to: .preparing, at: date)
                await self.beginPreparedWorkout()
            case .running:
                self.isStarting = false
                self.transition(to: .running, at: date)
                await self.startMirroringIfNeeded()
            case .paused:
                self.transition(to: .paused, at: date)
                await self.startMirroringIfNeeded()
            case .stopped:
                self.mirroringRetryTask?.cancel()
                self.mirroringRetryTask = nil
                self.transition(to: .stopped, at: date)
                self.scheduleFinalization(at: date, shouldEndSession: true)
            case .ended:
                self.healthKitEnded = true
                if self.lifecycle?.state == .failed || self.lifecycle?.state == .completed { return }
                if !self.finalizationStarted {
                    self.scheduleFinalization(at: date, shouldEndSession: false)
                }
                self.completeIfReady(at: date)
            case .notStarted:
                break
            @unknown default:
                self.fail(with: "HealthKit 返回了未知训练状态", at: date)
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.fail(with: message, at: Date()) }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        let commands = data.compactMap { item -> WorkoutCommand? in
            guard item.count <= Self.maximumMirrorPayloadBytes,
                  let envelope = try? ContractCoding.decoder.decode(
                    WorkoutMirrorEnvelope.self, from: item
                  ) else { return nil }
            return envelope.validatedCommand
        }
        guard !commands.isEmpty else { return }
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            for command in commands { self.onRemoteCommand?(command) }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.mirroringActive = false
            if workoutSession.state == .running || workoutSession.state == .paused {
                self.mirroringMessage = "手机实时连接已中断，训练仍会正常保存。"
                self.scheduleMirroringRetry()
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            for type in collectedTypes {
                guard let quantity = type as? HKQuantityType,
                      let statistics = workoutBuilder.statistics(for: quantity) else { continue }
                if quantity == HKQuantityType.quantityType(forIdentifier: .heartRate),
                   let value = statistics.mostRecentQuantity() {
                    let unit = HKUnit.count().unitDivided(by: .minute())
                    self.heartRate = value.doubleValue(for: unit)
                    self.averageHeartRate = statistics.averageQuantity()?.doubleValue(for: unit)
                    self.maximumHeartRate = statistics.maximumQuantity()?.doubleValue(for: unit)
                } else if quantity == HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                          let value = statistics.sumQuantity() {
                    self.activeEnergy = value.doubleValue(for: .kilocalorie())
                }
            }
        }
    }
}
