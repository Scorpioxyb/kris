@preconcurrency import ActivityKit
import Foundation
import Observation

@MainActor
@Observable
final class WorkoutLiveActivityController {
    enum UpdatePriority {
        case debounced
        case immediate
    }

    /// ActivityKit's reference type is not annotated Sendable in the iOS 26
    /// SDK, although its async lifecycle methods are safe to serialize from
    /// this controller. Keep the unchecked boundary local and single-purpose.
    private final class ActivityReference: @unchecked Sendable {
        let value: Activity<WorkoutActivityAttributes>

        init(_ value: Activity<WorkoutActivityAttributes>) {
            self.value = value
        }
    }

    private(set) var isVisible = false
    private(set) var lastError: String?

    private var activity: Activity<WorkoutActivityAttributes>?
    private var pendingState: WorkoutActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?
    private var activityOperationTask: Task<Void, Never>?
    private var activityOperationID = 0
    private var updateGeneration = 0

    private var isEnabledForCurrentApp: Bool {
        Bundle.main.bundleIdentifier == "com.albertdaisy.kriscoach"
    }

    func beginProvisional() {
        guard isEnabledForCurrentApp,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let current = Activity<WorkoutActivityAttributes>.activities.first(where: {
            $0.activityState == .active || $0.activityState == .stale
        }) {
            activity = current
            isVisible = true
            return
        }
        let state = WorkoutActivityAttributes.ContentState(
            sessionID: nil,
            planTitle: "Apple Watch 训练",
            planRevision: 0,
            startedAt: nil,
            lifecycle: "正在连接",
            exerciseName: "等待训练状态",
            setNumber: 0,
            completedSets: 0,
            totalSets: 0,
            activeDurationSeconds: 0,
            updatedAt: Date(),
            isRunning: false,
            restUntil: nil
        )
        do {
            lastError = nil
            activity = try Activity.request(
                attributes: WorkoutActivityAttributes(activityID: UUID().uuidString),
                content: ActivityContent(state: state, staleDate: nil, relevanceScore: 1),
                pushType: nil
            )
            isVisible = true
        } catch {
            isVisible = false
            lastError = "实时活动不可用，训练记录不受影响。"
        }
    }

    func sync(
        _ draft: TrainingDraft,
        now: Date = Date(),
        priority: UpdatePriority = .debounced
    ) {
        guard isEnabledForCurrentApp,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            isVisible = false
            return
        }
        let state = Self.contentState(for: draft, now: now)
        guard let activity = activity(for: draft, state: state) else { return }
        self.activity = activity
        pendingState = state
        isVisible = true
        scheduleUpdate(priority: priority)
    }

    func end(_ draft: TrainingDraft, now: Date = Date()) {
        guard isEnabledForCurrentApp else { return }
        let state = Self.contentState(for: draft, now: now)
        guard activity != nil || Activity<WorkoutActivityAttributes>.activities.contains(where: {
            $0.content.state.sessionID == draft.sessionId.uuidString
        }) else { return }
        updateTask?.cancel()
        updateTask = nil
        pendingState = nil
        updateGeneration &+= 1
        let generation = updateGeneration
        isVisible = false
        guard let reference = activity.map(ActivityReference.init) ??
                Activity<WorkoutActivityAttributes>.activities.first(
                    where: { $0.content.state.sessionID == draft.sessionId.uuidString }
                ).map(ActivityReference.init) else { return }
        enqueueActivityOperation { [weak self] in
            guard !Task.isCancelled, let self, self.updateGeneration == generation else { return }
            let content = ActivityContent(
                state: state, staleDate: nil, relevanceScore: 0
            )
            await reference.value.end(
                content,
                dismissalPolicy: .after(now.addingTimeInterval(45))
            )
            guard !Task.isCancelled, self.updateGeneration == generation else { return }
            self.activity = nil
        }
    }

    func discard(_ draft: TrainingDraft) {
        guard isEnabledForCurrentApp else { return }
        updateTask?.cancel()
        updateTask = nil
        pendingState = nil
        updateGeneration &+= 1
        let generation = updateGeneration
        isVisible = false
        guard let reference = activity.map(ActivityReference.init) ??
                Activity<WorkoutActivityAttributes>.activities.first(
                    where: { $0.content.state.sessionID == draft.sessionId.uuidString }
                ).map(ActivityReference.init) else { return }
        enqueueActivityOperation { [weak self] in
            guard !Task.isCancelled, let self, self.updateGeneration == generation else { return }
            await reference.value.end(nil, dismissalPolicy: .immediate)
            guard !Task.isCancelled, self.updateGeneration == generation else { return }
            self.activity = nil
        }
    }

    func endOrphanedActivities() {
        guard isEnabledForCurrentApp else { return }
        guard !Activity<WorkoutActivityAttributes>.activities.isEmpty else { return }
        activity = nil
        isVisible = false
        updateTask?.cancel()
        updateTask = nil
        pendingState = nil
        updateGeneration &+= 1
        let generation = updateGeneration
        let references = Activity<WorkoutActivityAttributes>.activities.map(ActivityReference.init)
        enqueueActivityOperation { [weak self] in
            guard !Task.isCancelled, let self, self.updateGeneration == generation else { return }
            for reference in references {
                guard !Task.isCancelled, self.updateGeneration == generation else { return }
                await reference.value.end(nil, dismissalPolicy: .immediate)
                guard !Task.isCancelled, self.updateGeneration == generation else { return }
            }
        }
    }

    static func contentState(
        for draft: TrainingDraft, now: Date = Date()
    ) -> WorkoutActivityAttributes.ContentState {
        let exercises = draft.executionExercises
        let completed = draft.completedSets.values.reduce(0) { $0 + $1.count }
        let total = exercises.reduce(0) { $0 + $1.sets }
        var nextExercise: ExercisePlan?
        var nextSet = 0
        for exercise in exercises {
            let recorded = Set(draft.completedSets[exercise.exerciseId, default: []].map(\.setNumber))
            if let missing = (1...max(exercise.sets, 1)).first(where: { !recorded.contains($0) }) {
                nextExercise = exercise
                nextSet = missing
                break
            }
        }
        let state = draft.lifecycleState
        return WorkoutActivityAttributes.ContentState(
            sessionID: draft.sessionId.uuidString,
            planTitle: draft.plan.title,
            planRevision: draft.plan.revision,
            startedAt: DateFormatting.parse(draft.startedAt),
            lifecycle: lifecycleLabel(state),
            exerciseName: nextExercise?.name ?? "计划组次已完成",
            setNumber: nextSet,
            completedSets: completed,
            totalSets: total,
            activeDurationSeconds: draft.activeDuration(at: now),
            updatedAt: now,
            isRunning: state == .running,
            restUntil: draft.restUntil.flatMap { $0 > now ? $0 : nil }
        )
    }

    private func activity(
        for draft: TrainingDraft,
        state: WorkoutActivityAttributes.ContentState
    ) -> Activity<WorkoutActivityAttributes>? {
        if let activity,
           activity.activityState == .active || activity.activityState == .stale {
            if activity.content.state.sessionID == nil
                || activity.content.state.sessionID == draft.sessionId.uuidString {
                return activity
            }
        }
        if let restored = Activity<WorkoutActivityAttributes>.activities.first(where: {
            $0.content.state.sessionID == draft.sessionId.uuidString
        }) {
            return restored
        }
        let references = Activity<WorkoutActivityAttributes>.activities.map(ActivityReference.init)
        enqueueActivityOperation {
            guard !Task.isCancelled else { return }
            for reference in references {
                guard !Task.isCancelled else { return }
                await reference.value.end(nil, dismissalPolicy: .immediate)
            }
        }
        do {
            lastError = nil
            return try Activity.request(
                attributes: WorkoutActivityAttributes(activityID: UUID().uuidString),
                content: ActivityContent(state: state, staleDate: nil, relevanceScore: 1),
                pushType: nil
            )
        } catch {
            isVisible = false
            lastError = "实时活动不可用，训练记录不受影响。"
            return nil
        }
    }

    func flushPendingState() {
        guard let activity, let state = pendingState else { return }
        updateTask?.cancel()
        updateTask = nil
        pendingState = nil
        updateGeneration &+= 1
        let generation = updateGeneration
        let reference = ActivityReference(activity)
        enqueueActivityOperation { [weak self] in
            guard !Task.isCancelled, let self, self.updateGeneration == generation else { return }
            await reference.value.update(ActivityContent(
                state: state, staleDate: nil, relevanceScore: 1
            ))
            guard !Task.isCancelled, self.updateGeneration == generation else { return }
            self.activity = activity
        }
    }

    private func scheduleUpdate(priority: UpdatePriority) {
        guard let activity else { return }
        updateTask?.cancel()
        updateTask = nil
        updateGeneration &+= 1
        let generation = updateGeneration
        let reference = ActivityReference(activity)

        switch priority {
        case .immediate:
            guard let state = pendingState else { return }
            pendingState = nil
            enqueueActivityOperation { [weak self] in
                guard !Task.isCancelled, let self, self.updateGeneration == generation else { return }
                await reference.value.update(ActivityContent(
                    state: state, staleDate: nil, relevanceScore: 1
                ))
                guard !Task.isCancelled, self.updateGeneration == generation else { return }
            }
            return
        case .debounced:
            break
        }

        updateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, self.updateGeneration == generation else { return }
            guard let state = self.pendingState else {
                self.updateTask = nil
                return
            }
            self.pendingState = nil
            self.enqueueActivityOperation { [weak self] in
                guard !Task.isCancelled, let self, self.updateGeneration == generation else { return }
                await reference.value.update(ActivityContent(
                    state: state, staleDate: nil, relevanceScore: 1
                ))
                guard !Task.isCancelled, self.updateGeneration == generation else { return }
            }
            self.updateTask = nil
        }
    }

    private func enqueueActivityOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let previous = activityOperationTask
        activityOperationID &+= 1
        let operationID = activityOperationID
        let task = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }
            guard !Task.isCancelled, let self else { return }
            await operation()
            guard self.activityOperationID == operationID else { return }
            self.activityOperationTask = nil
        }
        activityOperationTask = task
    }

    nonisolated private static func lifecycleLabel(_ state: WorkoutLifecycleState) -> String {
        switch state {
        case .preparing: "准备中"
        case .running: "训练中"
        case .paused: "已暂停"
        case .stopped, .finalizing: "正在保存"
        case .completed: "训练完成"
        case .failed: "需要处理"
        }
    }
}
