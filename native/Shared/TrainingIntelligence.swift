import Foundation

/// Home navigation, not a health score or an exercise prescription.
/// Frequency and missing workout records are intentionally not inputs.
enum TodayFocus: Equatable, Sendable {
    case dailyHealth
    case activeSession
    case safetyReview

    static func resolve(safetyGate: String?, hasActiveSession: Bool) -> TodayFocus {
        if safetyGate == "stop_and_seek_care" || safetyGate == "reduce" {
            return .safetyReview
        }
        return hasActiveSession ? .activeSession : .dailyHealth
    }

    static func isPlanScheduledToday(_ date: String, now: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return false }
        let today = String(format: "%04d-%02d-%02d", year, month, day)
        return date == today
    }
}

struct LocalProgressionDecision: Hashable, Identifiable, Sendable {
    var exercise: String
    var equipmentVariant: String
    var state: String
    var nextAction: String
    var evidence: String
    var rollbackCondition: String
    var latestDate: String

    var id: String { "\(exercise.lowercased())|\(equipmentVariant.lowercased())" }
}

struct LocalTrainingIntelligence: Sendable {
    var trainingLoad7D: [SnapshotTrends.Point] = []
    var trainingLoad42D: [SnapshotTrends.Point] = []
    var rolling7D: Double?
    var loadRatio: Double?
    var loadStatus = "baseline_building"
    var performanceStatus = "baseline_building"
    var progression: [LocalProgressionDecision] = []

    var hasLoad: Bool { !trainingLoad7D.isEmpty && !trainingLoad42D.isEmpty }
}

struct TrainingSessionPerformance: Equatable, Sendable {
    var completedSets: Int
    var totalRepetitions: Int
    var loadedVolumeKg: Double?
    var feedbackExercises: Int
    var completedExercises: Int
    var completionRate: Double?
}

enum LocalPlanAction: String, Codable, Sendable {
    case needsPlan
    case needsAssessment
    case maintain
    case reduce
    case recovery
    case stop
}

enum LocalPlanEvidence: String, Codable, Sendable {
    case emergencyReported
    case readinessStopGate
    case discomfortReported
    case readinessReduceGate
    case noPlan
    case missingReadiness
    case staleReadiness
    case unsupportedReadiness
    case insufficientConfidence
    case symptomsNotReported
    case recoveryState
    case reducedState
    case maintainState
    case progressionRequiresSeparateReview
}

enum LocalTrainingSymptoms: String, Codable, Sendable {
    case notReported
    case noneReported
    case limitingDiscomfort
    case emergencyReported
}

struct LocalPlanDecision: Codable, Hashable, Sendable {
    var action: LocalPlanAction
    var title: String
    var summary: String
    var evidence: [LocalPlanEvidence]
    var rollbackCondition: String
    var ruleVersion: String
}

/// Advisory gate only: never edits a plan or grants weight progression.
/// Freshness includes upstream signal coverage, not just snapshot generation time.
enum LocalPlanEngine {
    static let ruleVersion = "local_plan_gate_v1"

    static func decide(
        readiness: SnapshotReadiness?,
        evaluatedAt: Date?,
        signalsFresh: Bool,
        symptoms: LocalTrainingSymptoms,
        hasPlan: Bool,
        now: Date,
        calendar: Calendar
    ) -> LocalPlanDecision {
        // Stop/reduce gates cannot be cleared by absent plans or stale scores.
        if symptoms == .emergencyReported || readiness?.safetyGate == "stop_and_seek_care" {
            let evidence: LocalPlanEvidence = symptoms == .emergencyReported ? .emergencyReported : .readinessStopGate
            return decision(.stop, title: "停止训练", summary: "存在安全停止信号，请停止训练并及时就医。", evidence: [evidence], rollback: "异常未评估前不恢复训练；症状严重或持续时立即寻求急救。")
        }
        if symptoms == .limitingDiscomfort || readiness?.safetyGate == "reduce" {
            let evidence: LocalPlanEvidence = symptoms == .limitingDiscomfort ? .discomfortReported : .readinessReduceGate
            return decision(.reduce, title: "需要调整训练", summary: "先检查不适及受影响动作，暂不增加重量或训练量。", evidence: [evidence], rollback: "停止引起不适的动作；确认症状变化后再决定替换或恢复。")
        }
        guard hasPlan else {
            return decision(.needsPlan, title: "尚无训练计划", summary: "创建或导入计划后，再评估当天的执行安排。", evidence: [.noPlan], rollback: "没有计划不代表需要休息，也不代表已经通过训练安全检查。")
        }
        guard let readiness else {
            return assessment(.missingReadiness)
        }
        guard signalsFresh, let evaluatedAt,
              evaluatedAt <= now, calendar.isDate(evaluatedAt, inSameDayAs: now) else {
            return assessment(.staleReadiness)
        }
        guard readiness.safetyGate == "normal",
              let score = readiness.score, score.isFinite, (0...100).contains(score),
              ["train_progress", "train_maintain", "train_reduce", "recover_or_light"].contains(readiness.state) else {
            return assessment(.unsupportedReadiness)
        }
        guard ["high", "medium"].contains(readiness.confidence) else {
            return assessment(.insufficientConfidence)
        }
        guard symptoms == .noneReported else {
            return assessment(.symptomsNotReported)
        }
        switch readiness.state {
        case "recover_or_light":
            return decision(.recovery, title: "建议恢复或轻活动", summary: "恢复指标偏低，建议调整当天安排，暂不推进负重。", evidence: [.recoveryState])
        case "train_reduce":
            return decision(.reduce, title: "建议降低训练负担", summary: "恢复指标提示需要调整，具体动作和训练量需在计划中确认。", evidence: [.reducedState])
        default:
            return decision(.maintain, title: "可按当前计划评估执行", summary: "恢复指标未提示额外限制；是否加重仍需检查同器械实绩和反馈。", evidence: [.maintainState, .progressionRequiresSeparateReview])
        }
    }

    private static func assessment(_ evidence: LocalPlanEvidence) -> LocalPlanDecision {
        decision(.needsAssessment, title: "训练建议待确认", summary: "当前信息不足以自动调整计划，不据此判断需要休息或可以加量。", evidence: [evidence], rollback: "补充当日恢复数据和不适反馈后重新评估。")
    }

    private static func decision(
        _ action: LocalPlanAction,
        title: String,
        summary: String,
        evidence: [LocalPlanEvidence],
        rollback: String = "训练中出现不适时停止相关动作并重新评估；出现胸痛、晕厥或明显呼吸困难等异常时停止训练并及时就医。"
    ) -> LocalPlanDecision {
        LocalPlanDecision(
            action: action,
            title: title,
            summary: summary,
            evidence: evidence,
            rollbackCondition: rollback,
            ruleVersion: ruleVersion
        )
    }
}

enum TrainingIntelligence {
    private struct LoadSession {
        var id: String
        var start: Date
        var end: Date
        var minutes: Double
        var factor: Double
    }

    private struct ProgressionSession {
        var date: String
        var sets: [CompletedSet]
        var repMax: Int
    }

    static func evaluate(
        sessions: [TrainingSessionContract],
        plans: [TrainingPlan],
        workoutSamples: [HealthSampleContract],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> LocalTrainingIntelligence {
        let planByKey = Dictionary(
            plans.map { (planKey($0.planId, $0.revision), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let loads = loadSessions(
            sessions: sessions, planByKey: planByKey,
            workoutSamples: workoutSamples
        )
        var result = buildLoad(loads, now: now, calendar: calendar)
        result.progression = progression(sessions: sessions, planByKey: planByKey)
        return result
    }

    static func workoutSummaries(
        samples: [HealthSampleContract],
        excluding sessions: [TrainingSessionContract]
    ) -> [SnapshotTrainingSummary] {
        let appIntervals = sessions.compactMap(sessionInterval)
        let referenced = Set(sessions.compactMap(\.watchWorkoutUuid).map { $0.lowercased() })
        return deduplicatedWorkoutSamples(samples).compactMap { sample in
            guard !referenced.contains(sample.sampleUuid.lowercased()),
                  let start = DateFormatting.parse(sample.startAt),
                  let end = DateFormatting.parse(sample.endAt),
                  !overlapsAppSession(start: start, end: end, appIntervals: appIntervals) else {
                return nil
            }
            let title = metadataString("activity_name", in: sample) ?? "其他训练"
            return SnapshotTrainingSummary(
                id: sample.sampleUuid, date: sample.endAt, title: title,
                durationMinutes: (sample.value / 60 * 10).rounded() / 10,
                activeKcal: metadataNumber("active_kcal", in: sample),
                averageHeartRate: metadataNumber("average_heart_rate", in: sample),
                maximumHeartRate: metadataNumber("maximum_heart_rate", in: sample),
                exerciseCount: nil, completedSetCount: nil,
                status: "completed", source: "iphone_healthkit", syncedToMac: nil,
                workoutDetails: HealthWorkoutDetails(
                    activityTypeCode: metadataNumber("activity_type", in: sample).map(Int.init),
                    startAt: sample.startAt,
                    endAt: sample.endAt,
                    sourceName: metadataString("source_name", in: sample) ?? sample.source,
                    deviceName: metadataString("device_name", in: sample),
                    indoor: metadataBool("indoor", in: sample),
                    distanceKilometers: metadataNumber("distance_km", in: sample)
                )
            )
        }
        .sorted { $0.date > $1.date }
    }

    static func sessionPerformance(
        _ session: TrainingSessionContract,
        plannedSetCount: Int? = nil
    ) -> TrainingSessionPerformance {
        let results = session.exerciseResults.filter { !$0.sets.isEmpty }
        let sets = results.flatMap(\.sets)
        let weightedSets = sets.compactMap { set -> Double? in
            guard let weight = set.weightKg else { return nil }
            return weight * Double(set.reps)
        }
        let completionRate = plannedSetCount.flatMap { planned -> Double? in
            guard planned > 0 else { return nil }
            return min(Double(sets.count) / Double(planned), 1)
        }
        return TrainingSessionPerformance(
            completedSets: sets.count,
            totalRepetitions: sets.map(\.reps).reduce(0, +),
            loadedVolumeKg: weightedSets.isEmpty ? nil : weightedSets.reduce(0, +),
            feedbackExercises: results.filter { result in
                result.sets.contains { $0.lastSetFeeling != nil }
            }.count,
            completedExercises: results.count,
            completionRate: completionRate
        )
    }

    private static func loadSessions(
        sessions: [TrainingSessionContract],
        planByKey: [String: TrainingPlan],
        workoutSamples: [HealthSampleContract]
    ) -> [LoadSession] {
        var result: [LoadSession] = sessions.compactMap { session in
            guard let interval = sessionInterval(session) else { return nil }
            let title = planByKey[planKey(session.planId, session.planRevision)]?.title
                ?? session.exerciseResults.map(\.name).joined(separator: " ")
            let duration = session.workout?.durationSeconds
                ?? interval.end.timeIntervalSince(interval.start)
            guard duration > 0 else { return nil }
            return LoadSession(
                id: session.sessionId.uuidString, start: interval.start, end: interval.end,
                minutes: duration / 60, factor: loadFactor(title)
            )
        }

        let appIntervals = sessions.compactMap(sessionInterval)
        let referenced = Set(sessions.compactMap(\.watchWorkoutUuid).map { $0.lowercased() })
        for sample in deduplicatedWorkoutSamples(workoutSamples) {
            guard !referenced.contains(sample.sampleUuid.lowercased()),
                  let start = DateFormatting.parse(sample.startAt),
                  let end = DateFormatting.parse(sample.endAt), end > start,
                  !overlapsAppSession(start: start, end: end, appIntervals: appIntervals) else {
                continue
            }
            let title = metadataString("activity_name", in: sample) ?? "其他训练"
            result.append(LoadSession(
                id: sample.sampleUuid, start: start, end: end,
                minutes: sample.value / 60, factor: loadFactor(title)
            ))
        }
        return result
    }

    private static func buildLoad(
        _ sessions: [LoadSession], now: Date, calendar: Calendar
    ) -> LocalTrainingIntelligence {
        guard let first = sessions.map(\.start).min() else { return LocalTrainingIntelligence() }
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -41, to: today) ?? today
        var cursor = max(calendar.startOfDay(for: first), windowStart)
        var daily: [Date: Double] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.start)
            guard day >= cursor, day <= today else { continue }
            daily[day, default: 0] += session.minutes * session.factor
        }

        var shortEMA = 0.0
        var longEMA = 0.0
        var shortPoints: [SnapshotTrends.Point] = []
        var longPoints: [SnapshotTrends.Point] = []
        var rolling7D: Double?
        var ratio: Double?
        var status = "baseline_building"
        var modelDays = 0
        let shortAlpha = 1 - Foundation.exp(-1.0 / 7.0)
        let longAlpha = 1 - Foundation.exp(-1.0 / 42.0)

        while cursor <= today {
            modelDays += 1
            let points = daily[cursor, default: 0]
            if modelDays == 1 {
                shortEMA = points
                longEMA = points
            } else {
                shortEMA += (points - shortEMA) * shortAlpha
                longEMA += (points - longEMA) * longAlpha
            }
            let acuteStart = calendar.date(byAdding: .day, value: -6, to: cursor) ?? cursor
            let chronicStart = calendar.date(byAdding: .day, value: -27, to: cursor) ?? cursor
            let acute = daily.reduce(0) { total, item in
                item.key >= acuteStart && item.key <= cursor ? total + item.value : total
            }
            let chronic = daily.reduce(0) { total, item in
                item.key >= chronicStart && item.key <= cursor ? total + item.value : total
            }
            let mature = modelDays >= 28
            let currentRatio = mature && chronic > 0 ? acute / (chronic / 4) : nil
            if cursor == today {
                rolling7D = acute
                ratio = currentRatio
                status = loadStatus(currentRatio)
            }
            let date = dayKey(cursor, calendar: calendar)
            shortPoints.append(.init(date: date, value: rounded(shortEMA)))
            longPoints.append(.init(date: date, value: rounded(longEMA)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return LocalTrainingIntelligence(
            trainingLoad7D: shortPoints, trainingLoad42D: longPoints,
            rolling7D: rolling7D.map(rounded), loadRatio: ratio,
            loadStatus: status,
            performanceStatus: modelDays < 42 ? "baseline_building" : "local_42d_model",
            progression: []
        )
    }

    private static func progression(
        sessions: [TrainingSessionContract], planByKey: [String: TrainingPlan]
    ) -> [LocalProgressionDecision] {
        var grouped: [String: [ProgressionSession]] = [:]
        var labels: [String: (String, String)] = [:]
        for session in sessions.sorted(by: { $0.endedAt < $1.endedAt }) {
            let plan = planByKey[planKey(session.planId, session.planRevision)]
            for exercise in session.exerciseResults where !exercise.sets.isEmpty {
                let key = exerciseKey(exercise.name, exercise.equipmentVariant)
                let target = plan?.exercises.first(where: {
                    exerciseKey($0.name, $0.equipmentVariant) == key
                })?.targetReps ?? defaultRepMax(exercise.name)
                grouped[key, default: []].append(ProgressionSession(
                    date: String(session.endedAt.prefix(10)),
                    sets: exercise.sets.sorted { $0.setNumber < $1.setNumber },
                    repMax: target
                ))
                labels[key] = (exercise.name, exercise.equipmentVariant)
            }
        }

        return grouped.compactMap { key, records in
            guard let latest = records.last, let label = labels[key] else { return nil }
            return progressionDecision(
                exercise: label.0, variant: label.1,
                latest: latest, prior: records.dropLast().last
            )
        }
        .sorted { $0.latestDate > $1.latestDate }
    }

    private static func progressionDecision(
        exercise: String, variant: String,
        latest: ProgressionSession, prior: ProgressionSession?
    ) -> LocalProgressionDecision {
        let repMax = latest.repMax
        let repMin = max(1, repMax - (repMax >= 15 ? 5 : 4))
        let latestAtTop = latest.sets.count >= 2 && (latest.sets.map(\.reps).min() ?? 0) >= repMax
        let priorAtTop = prior.map { $0.sets.count >= 2 && ($0.sets.map(\.reps).min() ?? 0) >= repMax } ?? false
        let sameScheme = prior.map { row in
            row.sets.count == latest.sets.count && row.sets.map(\.weightKg) == latest.sets.map(\.weightKg)
        } ?? false
        let latestAcceptable = acceptableFeedback(latest.sets)
        let priorAcceptable = prior.map { acceptableFeedback($0.sets) } ?? false

        let state: String
        let action: String
        let evidence: String
        let rollback: String
        if latest.sets.count < 2 {
            state = "establish_baseline"
            action = "先补全至少2个明确工作组"
            evidence = "最近仅\(latest.sets.count)个明确工作组"
            rollback = "基线未建立，不执行自动进阶"
        } else if latest.sets.contains(where: { $0.lastSetFeeling == .formBreakdown }) {
            state = "technique_hold"
            action = "保持负重，先消除动作变形"
            evidence = "最近一次明确记录动作变形"
            rollback = "完整工作组无变形后再回到补次数阶段"
        } else if latestAtTop && priorAtTop && sameScheme && latestAcceptable && priorAcceptable {
            state = "increase_smallest_step"
            action = "下次按同器械最小档加重，回到\(repMin)次"
            evidence = "连续2次同方案全部达到\(repMax)次，且反馈可接受"
            rollback = "加重后任一组低于\(repMin)次或动作变形时退回原重量"
        } else if latestAtTop {
            state = "confirm_top_range"
            action = "维持最新方案，再确认一次全部达到\(repMax)次"
            evidence = (!latestAcceptable || (prior != nil && !priorAcceptable))
                ? "缺少连续两次轻松/合适反馈" : "仅确认1次达到次数上限"
            rollback = "出现动作变形或关节不适时转为技术维持"
        } else if (latest.sets.map(\.reps).min() ?? 0) >= repMin {
            state = "add_repetitions"
            action = "维持同器械负重，先把全部工作组补到\(repMax)次"
            evidence = "最近全部工作组已达\(repMin)次，但未全部达上限"
            rollback = "任一组低于\(repMin)次或变形时维持或回退最小档"
        } else {
            state = "rebuild_at_lower_bound"
            action = "维持或回退最小档，先回到每组至少\(repMin)次"
            evidence = "最近至少一组低于\(repMin)次"
            rollback = "连续一次全部回到下限后，再进入补次数阶段"
        }
        return LocalProgressionDecision(
            exercise: exercise, equipmentVariant: variant, state: state,
            nextAction: action, evidence: evidence, rollbackCondition: rollback,
            latestDate: latest.date
        )
    }

    private static func acceptableFeedback(_ sets: [CompletedSet]) -> Bool {
        let recorded = sets.compactMap(\.lastSetFeeling)
        return !recorded.isEmpty && recorded.allSatisfy { $0 == .easy || $0 == .appropriate }
    }

    private static func loadFactor(_ title: String) -> Double {
        let lower = title.lowercased()
        if title.contains("上肢") || title.contains("下肢")
            || lower.contains("strength") || title.contains("力量") { return 1.00 }
        if title.contains("游泳") || lower.contains("swim") { return 0.90 }
        if title.contains("高强度") || lower.contains("hiit") { return 1.15 }
        if title.contains("跑步") || title.contains("有氧") || title.contains("爬坡")
            || lower.contains("run") || lower.contains("cardio") {
            return title.contains("恢复") || title.contains("轻松") ? 0.65 : 0.85
        }
        if title.contains("走路") || lower.contains("walk") { return 0.65 }
        if title.contains("核心") || lower.contains("core") { return 0.75 }
        if title.contains("柔韧") || title.contains("活动度") || lower.contains("flexibility") { return 0.50 }
        return 0.75
    }

    private static func loadStatus(_ ratio: Double?) -> String {
        guard let ratio else { return "baseline_building" }
        if ratio > 1.5 { return "elevated_recent_load" }
        if ratio > 1.3 { return "above_28d_baseline" }
        if ratio >= 0.8 { return "within_28d_baseline" }
        return "below_28d_baseline"
    }

    private static func sessionInterval(_ session: TrainingSessionContract) -> (start: Date, end: Date)? {
        guard let start = DateFormatting.parse(session.startedAt),
              let end = DateFormatting.parse(session.endedAt), end > start else { return nil }
        return (start, end)
    }

    private static func overlapsAppSession(
        start: Date, end: Date, appIntervals: [(start: Date, end: Date)]
    ) -> Bool {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return false }
        return appIntervals.contains { interval in
            let overlap = min(end, interval.end).timeIntervalSince(max(start, interval.start))
            let reference = min(duration, interval.end.timeIntervalSince(interval.start))
            return overlap > 0 && overlap / max(reference, 1) >= 0.80
        }
    }

    private static func deduplicatedWorkoutSamples(
        _ samples: [HealthSampleContract]
    ) -> [HealthSampleContract] {
        let sorted = samples.filter { $0.metric == .workout }.sorted { left, right in
            let leftPriority = workoutSourcePriority(left.source)
            let rightPriority = workoutSourcePriority(right.source)
            return leftPriority == rightPriority ? left.startAt < right.startAt : leftPriority > rightPriority
        }
        var accepted: [HealthSampleContract] = []
        var intervals: [(start: Date, end: Date)] = []
        for sample in sorted {
            guard let start = DateFormatting.parse(sample.startAt),
                  let end = DateFormatting.parse(sample.endAt), end > start else { continue }
            if overlapsAppSession(start: start, end: end, appIntervals: intervals) { continue }
            accepted.append(sample)
            intervals.append((start, end))
        }
        return accepted.sorted { $0.startAt < $1.startAt }
    }

    private static func workoutSourcePriority(_ source: String) -> Int {
        let normalized = source.lowercased()
        if normalized.contains("kris coach") { return 3 }
        if normalized.contains("apple watch") || normalized.contains("watch") { return 2 }
        return 1
    }

    private static func metadataString(_ key: String, in sample: HealthSampleContract) -> String? {
        guard case .string(let value)? = sample.metadata?[key] else { return nil }
        return value
    }

    private static func metadataNumber(_ key: String, in sample: HealthSampleContract) -> Double? {
        guard case .number(let value)? = sample.metadata?[key] else { return nil }
        return value
    }

    private static func metadataBool(_ key: String, in sample: HealthSampleContract) -> Bool? {
        guard case .bool(let value)? = sample.metadata?[key] else { return nil }
        return value
    }

    private static func planKey(_ id: UUID, _ revision: Int) -> String {
        "\(id.uuidString.lowercased()):\(revision)"
    }

    private static func exerciseKey(_ name: String, _ variant: String) -> String {
        "\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(variant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func defaultRepMax(_ name: String) -> Int {
        ["侧平举", "飞鸟", "提踵", "髋外展"].contains(where: name.contains) ? 15 : 12
    }

    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
