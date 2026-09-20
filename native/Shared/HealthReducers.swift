import Foundation

struct HealthInterval: Equatable, Sendable {
    var start: Date
    var end: Date
}

struct LocalReadinessSnapshot: Codable, Sendable {
    var readiness: SnapshotReadiness
    var evidence: [ReadinessEvidence]
    var dataGaps: [String]
    var generatedAt: Date
}

struct DailyHealthMetrics: Codable, Equatable, Sendable {
    var sleepHours: Double?
    var hrvMs: Double?
    var restingHeartRate: Double?
    var steps: Double?
    var activeKcal: Double?
    var basalKcal: Double?
    var totalKcal: Double?
    var vo2Max: Double?
    var bodyMassKg: Double?
    var bodyFatPercent: Double?
    var leanBodyMassKg: Double?
}

enum HealthReducers {
    static func mergedDuration(_ intervals: [HealthInterval]) -> TimeInterval {
        let sorted = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return 0 }
        var duration: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)
            } else {
                duration += current.end.timeIntervalSince(current.start)
                current = interval
            }
        }
        return duration + current.end.timeIntervalSince(current.start)
    }

    static func latestCompleteBodySet(_ samples: [HealthSampleContract]) -> [HealthMetric: Double]? {
        let required: Set<HealthMetric> = [.bodyMass, .bodyFatPercentage, .leanBodyMass, .bmi]
        let body = samples.compactMap { sample -> (HealthSampleContract, Date)? in
            guard required.contains(sample.metric), let date = parse(sample.startAt) else { return nil }
            return (sample, date)
        }
        let anchors = body.filter { $0.0.metric == .bodyMass }.sorted { $0.1 > $1.1 }
        for anchor in anchors {
            let rows = body.filter {
                $0.0.source == anchor.0.source && abs($0.1.timeIntervalSince(anchor.1)) <= 120
            }
            var values = rows.reduce(into: [HealthMetric: Double]()) { result, item in
                result[item.0.metric] = item.0.value
            }
            if required.allSatisfy({ values[$0] != nil }) {
                values[.bodyFatPercentage] = values[.bodyFatPercentage].map(normalizedBodyFat)
                return values
            }
        }
        return nil
    }

    static func sourceFor(date: String, metric: String, coverage: [MetricCoverage]) -> String {
        coverage.contains(where: { $0.date == date && $0.metric == metric && $0.status == .complete })
            ? "iphone_healthkit" : "synchealth"
    }

    static func dailyMetrics(
        samples: [HealthSampleContract],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> DailyHealthMetrics {
        let unique = Array(Dictionary(samples.map { ($0.sampleUuid, $0) }, uniquingKeysWith: { _, latest in latest }).values)
        let today = dayKey(now, calendar: calendar)
        let todaySamples = unique.filter {
            guard let date = parse($0.startAt) else { return false }
            return dayKey(date, calendar: calendar) == today
        }
        let sleepIntervals = unique.filter { $0.metric == .sleep }.compactMap { sample -> HealthInterval? in
            guard let start = parse(sample.startAt), let end = parse(sample.endAt), end > start,
                  dayKey(end, calendar: calendar) == today else { return nil }
            return HealthInterval(start: start, end: end)
        }
        let body = latestCompleteBodySet(unique)
        let active = sum(todaySamples, metric: .activeEnergy)
        let basal = sum(todaySamples, metric: .basalEnergy)
        return DailyHealthMetrics(
            sleepHours: sleepIntervals.isEmpty ? nil : mergedDuration(sleepIntervals) / 3600,
            hrvMs: average(todaySamples, metric: .hrvSdnn),
            restingHeartRate: average(todaySamples, metric: .restingHeartRate),
            steps: dailyStepSum(todaySamples, calendar: calendar)[today],
            activeKcal: active,
            basalKcal: basal,
            totalKcal: active.flatMap { active in basal.map { active + $0 } },
            vo2Max: latestValue(todaySamples, metric: .vo2Max),
            bodyMassKg: body?[.bodyMass],
            bodyFatPercent: body?[.bodyFatPercentage],
            leanBodyMassKg: body?[.leanBodyMass]
        )
    }

    static func dailyTrends(
        samples: [HealthSampleContract],
        engine: ReadinessEngine? = nil,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        days: Int = 42
    ) -> SnapshotTrends {
        let unique = Array(Dictionary(
            samples.map { ($0.sampleUuid, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values)
        let cutoff = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: calendar.startOfDay(for: now)) ?? now
        let recent = unique.filter {
            guard let date = parse($0.startAt) else { return false }
            return date >= cutoff && date <= now
        }
        let bodySets = completeBodySets(recent, calendar: calendar)
        let sleep = dailySleep(recent, calendar: calendar)
        let hrv = dailyAverage(recent, metric: .hrvSdnn, calendar: calendar)
        let restingHeartRate = dailyAverage(recent, metric: .restingHeartRate, calendar: calendar)
        let basalEnergy = reliableDailyBasal(recent, calendar: calendar)
        let totalEnergy = combinedDailyEnergy(recent, calendar: calendar)
        return SnapshotTrends(
            latestBody: latestBodySummary(bodySets),
            latestCompleteHealthDay: latestCompleteEnergySummary(
                totalEnergy, now: now, calendar: calendar
            ),
            recovery: recoverySummary(
                sleep: sleep, hrv: hrv, restingHeartRate: restingHeartRate,
                now: now, calendar: calendar
            ),
            fatLoss: fatLossSummary(bodySets, now: now, calendar: calendar),
            weight: points(bodySets.compactMapValues { $0[.bodyMass] }),
            bodyFat: points(bodySets.compactMapValues { $0[.bodyFatPercentage] }),
            sleep: points(sleep),
            hrv: points(hrv),
            restingHeartRate: points(restingHeartRate),
            steps: points(dailyStepSum(recent, calendar: calendar)),
            activeEnergy: points(dailySum(recent, metric: .activeEnergy, calendar: calendar)),
            basalEnergy: points(basalEnergy),
            totalEnergy: points(totalEnergy),
            vo2Max: points(dailyLatest(recent, metric: .vo2Max, calendar: calendar)),
            readiness: engine.map {
                readinessHistory(
                    samples: unique, engine: $0, now: now,
                    calendar: calendar, days: days
                )
            }
        )
    }

    static func readinessHistory(
        samples: [HealthSampleContract],
        engine: ReadinessEngine,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        days: Int = 42
    ) -> [SnapshotReadinessPoint] {
        let unique = Array(Dictionary(
            samples.map { ($0.sampleUuid, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values)
        let sleep = dailySleep(unique, calendar: calendar)
        let hrv = dailyAverage(unique, metric: .hrvSdnn, calendar: calendar)
        let rhr = dailyAverage(unique, metric: .restingHeartRate, calendar: calendar)
        let cutoffDate = calendar.date(
            byAdding: .day, value: -(max(days, 1) - 1),
            to: calendar.startOfDay(for: now)
        ) ?? now
        let cutoff = dayKey(cutoffDate, calendar: calendar)
        let today = dayKey(now, calendar: calendar)
        let availableDays = Set(sleep.keys).union(hrv.keys).union(rhr.keys)
            .filter { $0 >= cutoff && $0 <= today }
            .sorted()

        return availableDays.compactMap { day in
            let sleepHistory = historicalValues(sleep, before: day, limit: 14)
            let hrvHistory = historicalValues(hrv, before: day, limit: 14)
            let rhrHistory = historicalValues(rhr, before: day, limit: 14)
            let historyCounts = [
                "sleep": sleepHistory.count,
                "hrv": hrvHistory.count,
                "rhr": rhrHistory.count,
            ]
            let currentCount = [sleep[day], hrv[day], rhr[day]].compactMap { $0 }.count
            let usableBaselines = historyCounts.values.filter { $0 >= 5 }.count >= 2
            let completeDays = Set(sleep.keys).intersection(hrv.keys).intersection(rhr.keys)
                .filter { $0 < day }.count
            let result = engine.evaluate(ReadinessInput(
                sleep: sleep[day], sleepBaseline: median(sleepHistory),
                hrv: hrv[day], hrvBaseline: median(hrvHistory),
                rhr: rhr[day], rhrBaseline: median(rhrHistory),
                loadRatio: nil,
                todayStatus: day == today ? "partial" : "final",
                dataQuality: currentCount == 3 && usableBaselines ? "pass" : "warning",
                baselineDays: min(completeDays, 14), historyCounts: historyCounts,
                fresh: currentCount > 0, pain: 0, flags: []
            ))
            guard let score = result.score else { return nil }
            return SnapshotReadinessPoint(
                date: day, score: score, state: result.state,
                confidence: result.confidence, source: "iphone_healthkit"
            )
        }
    }

    static func localReadiness(
        samples: [HealthSampleContract],
        engine: ReadinessEngine,
        loadRatio: Double? = nil,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> LocalReadinessSnapshot {
        let unique = Dictionary(samples.map { ($0.sampleUuid, $0) }, uniquingKeysWith: { _, latest in latest }).values
        let today = dayKey(now, calendar: calendar)
        let sleep = dailySleep(Array(unique), calendar: calendar)
        let hrv = dailyAverage(Array(unique), metric: .hrvSdnn, calendar: calendar)
        let rhr = dailyAverage(Array(unique), metric: .restingHeartRate, calendar: calendar)
        let historyLimit = 14
        let sleepHistory = historicalValues(sleep, before: today, limit: historyLimit)
        let hrvHistory = historicalValues(hrv, before: today, limit: historyLimit)
        let rhrHistory = historicalValues(rhr, before: today, limit: historyLimit)
        let completeDays = Set(sleep.keys).intersection(hrv.keys).intersection(rhr.keys).filter { $0 < today }.count
        let currentValues = [sleep[today], hrv[today], rhr[today]]
        let currentCount = currentValues.compactMap { $0 }.count
        let historyCounts = ["sleep": sleepHistory.count, "hrv": hrvHistory.count, "rhr": rhrHistory.count]
        let hasUsableBaselines = historyCounts.values.filter { $0 >= 5 }.count >= 2

        let input = ReadinessInput(
            sleep: sleep[today], sleepBaseline: median(sleepHistory),
            hrv: hrv[today], hrvBaseline: median(hrvHistory),
            rhr: rhr[today], rhrBaseline: median(rhrHistory),
            loadRatio: loadRatio,
            todayStatus: "partial",
            dataQuality: currentCount == 3 && hasUsableBaselines ? "pass" : "warning",
            baselineDays: min(completeDays, historyLimit),
            historyCounts: historyCounts,
            fresh: currentCount > 0,
            pain: 0,
            flags: []
        )
        let result = engine.evaluate(input)
        let evidence = [
            evidenceItem(
                signal: "sleep", value: sleep[today], unit: "h",
                baseline: median(sleepHistory), component: result.components["sleep"] ?? nil
            ),
            evidenceItem(
                signal: "hrv_sdnn", value: hrv[today], unit: "ms",
                baseline: median(hrvHistory), component: result.components["hrv"] ?? nil,
                usePercentageDelta: true
            ),
            evidenceItem(
                signal: "resting_hr", value: rhr[today], unit: "bpm",
                baseline: median(rhrHistory), component: result.components["rhr"] ?? nil
            ),
        ].compactMap { $0 }
        var gaps: [String] = []
        if sleep[today] == nil { gaps.append("今天缺少可用睡眠区间") }
        if hrv[today] == nil { gaps.append("今天缺少 HRV") }
        if rhr[today] == nil { gaps.append("今天缺少静息心率") }
        if !hasUsableBaselines { gaps.append("个人恢复基线仍在建立中") }
        if loadRatio == nil { gaps.append("本地训练负荷基线仍在建立") }

        return LocalReadinessSnapshot(
            readiness: SnapshotReadiness(
                score: result.score, state: result.state, label: result.label,
                confidence: result.confidence, safetyGate: result.safetyGate,
                components: result.components
            ),
            evidence: evidence,
            dataGaps: gaps,
            generatedAt: now
        )
    }

    private static func evidenceItem(
        signal: String, value: Double?, unit: String, baseline: Double?,
        component: Double?, usePercentageDelta: Bool = false
    ) -> ReadinessEvidence? {
        guard let value else { return nil }
        let delta = baseline.map { value - $0 }
        let deltaPct: Double?
        if usePercentageDelta, let baseline, baseline != 0, let delta {
            deltaPct = delta / baseline * 100
        } else {
            deltaPct = nil
        }
        let impact: String
        if let component, component < 40 {
            impact = "限制今天的训练负荷"
        } else if let component, component >= 60 {
            impact = "支持按计划训练"
        } else {
            impact = "当前影响中性"
        }
        return ReadinessEvidence(
            signal: signal, value: value, unit: unit, baseline: baseline,
            delta: delta, deltaPct: deltaPct, impact: impact, confidence: "medium"
        )
    }

    private static func dailySleep(
        _ samples: [HealthSampleContract], calendar: Calendar
    ) -> [String: Double] {
        let intervals = samples.filter { $0.metric == .sleep }.compactMap { sample -> (String, HealthInterval)? in
            guard let start = parse(sample.startAt), let end = parse(sample.endAt), end > start else { return nil }
            return (dayKey(end, calendar: calendar), HealthInterval(start: start, end: end))
        }
        return Dictionary(grouping: intervals, by: \.0).mapValues { rows in
            mergedDuration(rows.map(\.1)) / 3600
        }
    }

    private static func dailyAverage(
        _ samples: [HealthSampleContract], metric: HealthMetric, calendar: Calendar
    ) -> [String: Double] {
        let values = samples.filter { $0.metric == metric && $0.value.isFinite }.compactMap { sample -> (String, Double)? in
            guard let date = parse(sample.startAt) else { return nil }
            return (dayKey(date, calendar: calendar), sample.value)
        }
        return Dictionary(grouping: values, by: \.0).mapValues { rows in
            rows.map(\.1).reduce(0, +) / Double(rows.count)
        }
    }

    private static func dailySum(
        _ samples: [HealthSampleContract], metric: HealthMetric, calendar: Calendar
    ) -> [String: Double] {
        let values = samples.filter { $0.metric == metric && $0.value.isFinite }.compactMap { sample -> (String, Double)? in
            guard let date = parse(sample.startAt) else { return nil }
            return (dayKey(date, calendar: calendar), sample.value)
        }
        return Dictionary(grouping: values, by: \.0).mapValues { rows in rows.map(\.1).reduce(0, +) }
    }

    // HealthKit can return overlapping step samples from iPhone and Apple Watch.
    // Select one source for each time segment so the same steps are not counted twice.
    private static func dailyStepSum(
        _ samples: [HealthSampleContract], calendar: Calendar
    ) -> [String: Double] {
        let stepSamples = samples.filter { $0.metric == .stepCount && $0.value.isFinite }
        var byDay: [String: [HealthSampleContract]] = [:]
        for sample in stepSamples {
            guard let start = parse(sample.startAt) else { continue }
            byDay[dayKey(start, calendar: calendar), default: []].append(sample)
        }

        return byDay.reduce(into: [:]) { result, entry in
            let (day, rows) = entry
            guard let dayStart = dateForDay(day, calendar: calendar),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
            let intervals = rows.compactMap { sample -> (start: Date, end: Date, value: Double, source: String)? in
                guard let start = parse(sample.startAt), let end = parse(sample.endAt) else { return nil }
                let clippedStart = max(start, dayStart)
                let clippedEnd = min(max(end, start), dayEnd)
                return (clippedStart, clippedEnd, sample.value, sample.source)
            }

            var total = 0.0
            let ranged = intervals.filter { $0.end > $0.start }
            let boundaries = Set(ranged.flatMap { [$0.start, $0.end] }).sorted()
            for pair in zip(boundaries, boundaries.dropFirst()) {
                let segmentStart = pair.0
                let segmentEnd = pair.1
                guard segmentEnd > segmentStart else { continue }
                let active = ranged.filter { $0.start < segmentEnd && $0.end > segmentStart }
                guard let selected = active.max(by: {
                    stepSourcePriority($0.source) == stepSourcePriority($1.source)
                        ? $0.start < $1.start
                        : stepSourcePriority($0.source) < stepSourcePriority($1.source)
                }) else { continue }
                let duration = selected.end.timeIntervalSince(selected.start)
                guard duration > 0 else { continue }
                total += selected.value * segmentEnd.timeIntervalSince(segmentStart) / duration
            }

            // Some exported fixtures represent a quantity as a point sample. Keep one
            // point per timestamp/source and resolve cross-source duplicates by priority.
            let points = intervals.filter { $0.end == $0.start }
            let pointGroups = Dictionary(grouping: points, by: { "\($0.start.timeIntervalSinceReferenceDate)|\($0.source)" })
            let uniquePoints = pointGroups.values.compactMap { $0.first }
            let byTimestamp = Dictionary(grouping: uniquePoints, by: { $0.start })
            total += byTimestamp.values.compactMap { group in
                group.max { stepSourcePriority($0.source) < stepSourcePriority($1.source) }?.value
            }.reduce(0, +)
            result[day] = total
        }
    }

    private static func stepSourcePriority(_ source: String) -> Int {
        let normalized = source.lowercased()
        if normalized.contains("watch") { return 30 }
        if normalized.contains("iphone") { return 20 }
        return 10
    }

    private static func dailyLatest(
        _ samples: [HealthSampleContract], metric: HealthMetric, calendar: Calendar
    ) -> [String: Double] {
        let values = samples.filter { $0.metric == metric && $0.value.isFinite }.compactMap { sample -> (String, String, Double)? in
            guard let date = parse(sample.startAt) else { return nil }
            return (dayKey(date, calendar: calendar), sample.startAt, sample.value)
        }
        return Dictionary(grouping: values, by: \.0).compactMapValues { rows in
            rows.max(by: { $0.1 < $1.1 })?.2
        }
    }

    private static func combinedDailyEnergy(
        _ samples: [HealthSampleContract], calendar: Calendar
    ) -> [String: Double] {
        let active = dailySum(samples, metric: .activeEnergy, calendar: calendar)
        let basal = reliableDailyBasal(samples, calendar: calendar)
        return Set(active.keys).intersection(basal.keys).reduce(into: [:]) { result, day in
            result[day] = (active[day] ?? 0) + (basal[day] ?? 0)
        }
    }

    private static func reliableDailyBasal(
        _ samples: [HealthSampleContract], calendar: Calendar
    ) -> [String: Double] {
        let rows = samples.filter { $0.metric == .basalEnergy }.compactMap { sample -> (String, HealthInterval, Double)? in
            guard let start = parse(sample.startAt), let end = parse(sample.endAt),
                  end > start, sample.value.isFinite else { return nil }
            return (dayKey(start, calendar: calendar), HealthInterval(start: start, end: end), sample.value)
        }
        return Dictionary(grouping: rows, by: \.0).compactMapValues { dayRows in
            let coverage = mergedDuration(dayRows.map(\.1))
            guard coverage >= 20 * 3_600 else { return nil }
            return dayRows.map(\.2).reduce(0, +)
        }
    }

    private static func completeBodySets(
        _ samples: [HealthSampleContract], calendar: Calendar
    ) -> [String: [HealthMetric: Double]] {
        let required: Set<HealthMetric> = [.bodyMass, .bodyFatPercentage, .leanBodyMass, .bmi]
        let body = samples.compactMap { sample -> (HealthSampleContract, Date)? in
            guard required.contains(sample.metric), let date = parse(sample.startAt) else { return nil }
            return (sample, date)
        }
        let anchors = body.filter { $0.0.metric == .bodyMass }.sorted { $0.1 < $1.1 }
        return anchors.reduce(into: [:]) { result, anchor in
            let rows = body.filter {
                $0.0.source == anchor.0.source && abs($0.1.timeIntervalSince(anchor.1)) <= 120
            }
            var values = rows.reduce(into: [HealthMetric: Double]()) { values, item in
                values[item.0.metric] = item.0.value
            }
            guard required.allSatisfy({ values[$0] != nil }) else { return }
            values[.bodyFatPercentage] = values[.bodyFatPercentage].map(normalizedBodyFat)
            result[dayKey(anchor.1, calendar: calendar)] = values
        }
    }

    private static func latestBodySummary(
        _ bodySets: [String: [HealthMetric: Double]]
    ) -> [String: JSONValue]? {
        guard let date = bodySets.keys.max(), let body = bodySets[date] else { return nil }
        return [
            "date": .string(date),
            "weight_kg": body[.bodyMass].map(JSONValue.number) ?? .null,
            "body_fat_pct": body[.bodyFatPercentage].map(JSONValue.number) ?? .null,
            "lean_body_mass_kg": body[.leanBodyMass].map(JSONValue.number) ?? .null,
            "bmi": body[.bmi].map(JSONValue.number) ?? .null,
            "source_rule": .string("HealthKit 同来源 2 分钟内完整四项体测"),
        ]
    }

    private static func latestCompleteEnergySummary(
        _ totalEnergy: [String: Double], now: Date, calendar: Calendar
    ) -> [String: JSONValue]? {
        let today = dayKey(now, calendar: calendar)
        guard let date = totalEnergy.keys.filter({ $0 < today }).max(),
              let total = totalEnergy[date] else { return nil }
        return [
            "date": .string(date),
            "estimated_total_kcal": .number(total),
            "energy_method": .string("iPhone HealthKit 活动能量 + 静息能量（覆盖至少20小时）"),
        ]
    }

    private static func recoverySummary(
        sleep: [String: Double], hrv: [String: Double],
        restingHeartRate: [String: Double], now: Date, calendar: Calendar
    ) -> [String: JSONValue] {
        let today = dayKey(now, calendar: calendar)
        let completePriorDays = Set(sleep.keys)
            .intersection(hrv.keys)
            .intersection(restingHeartRate.keys)
            .filter { $0 < today }
            .sorted(by: >)
            .prefix(14)
        let days = Array(completePriorDays)
        let baselineSleep = median(days.compactMap { sleep[$0] })
        let baselineHRV = median(days.compactMap { hrv[$0] })
        let baselineRHR = median(days.compactMap { restingHeartRate[$0] })
        let currentSleep = sleep[today]
        let currentHRV = hrv[today]
        let currentRHR = restingHeartRate[today]
        var status = "baseline_building"
        var reason = "个人恢复基线建立中：\(days.count)/14个完整日"
        if days.count >= 14,
           let currentSleep, let currentHRV, let currentRHR,
           let baselineHRV, let baselineRHR, baselineHRV > 0 {
            let rhrDelta = currentRHR - baselineRHR
            let hrvDeltaPct = (currentHRV - baselineHRV) / baselineHRV * 100
            if rhrDelta >= 8 || hrvDeltaPct <= -20 || currentSleep < 6 {
                status = "reduce_intensity"
                reason = "恢复指标明显偏离个人14日基线"
            } else if rhrDelta >= 5 || hrvDeltaPct <= -12 || currentSleep < 6.5 {
                status = "caution"
                reason = "至少一项恢复指标偏弱"
            } else {
                status = "normal"
                reason = "设备恢复指标处于个人基线范围"
            }
        }
        return [
            "date": .string(today),
            "day_status": .string("partial"),
            "sleep_hours": currentSleep.map(JSONValue.number) ?? .null,
            "resting_hr_bpm": currentRHR.map(JSONValue.number) ?? .null,
            "hrv_sdnn_ms": currentHRV.map(JSONValue.number) ?? .null,
            "baseline_complete_days": .number(Double(days.count)),
            "baseline_rhr_median": baselineRHR.map(JSONValue.number) ?? .null,
            "baseline_hrv_median": baselineHRV.map(JSONValue.number) ?? .null,
            "baseline_sleep_median": baselineSleep.map(JSONValue.number) ?? .null,
            "recovery_status": .string(status),
            "reason": .string(reason),
        ]
    }

    private static func fatLossSummary(
        _ bodySets: [String: [HealthMetric: Double]], now: Date, calendar: Calendar
    ) -> [String: JSONValue] {
        let today = calendar.startOfDay(for: now)
        let dated = bodySets.compactMap { day, body -> (String, Date, [HealthMetric: Double])? in
            guard let date = dateForDay(day, calendar: calendar), body[.bodyMass] != nil else { return nil }
            return (day, date, body)
        }
        let recent = dated.filter {
            let distance = calendar.dateComponents([.day], from: $0.1, to: today).day ?? Int.max
            return (0...6).contains(distance)
        }
        let prior = dated.filter {
            let distance = calendar.dateComponents([.day], from: $0.1, to: today).day ?? Int.max
            return (7...13).contains(distance)
        }
        let recentAverage = average(recent.compactMap { $0.2[.bodyMass] })
        let priorAverage = average(prior.compactMap { $0.2[.bodyMass] })
        let change = recentAverage.flatMap { recent in priorAverage.map { recent - $0 } }
        let status: String
        let action: String
        if recent.count >= 5, prior.count >= 5, let change {
            if change >= -0.1 {
                status = "needs_waist_confirmation"
                action = "先补同情境腰围；不因体重单项直接削减热量"
            } else {
                status = "progressing"
                action = "维持当前策略，继续观察7日均重、腰围和力量"
            }
        } else {
            status = "insufficient_comparable_days"
            action = "继续晨起同口径称重；累计两个各至少5天的7日窗口后再判平台"
        }
        let latest = dated.max { $0.1 < $1.1 }
        return [
            "as_of": .string(dayKey(today, calendar: calendar)),
            "latest_measurement_date": latest.map { .string($0.0) } ?? .null,
            "latest_weight_kg": latest?.2[.bodyMass].map(JSONValue.number) ?? .null,
            "latest_body_fat_pct": latest?.2[.bodyFatPercentage].map(JSONValue.number) ?? .null,
            "recent_7d_measurements": .number(Double(recent.count)),
            "recent_7d_average_weight_kg": recentAverage.map(JSONValue.number) ?? .null,
            "prior_7d_measurements": .number(Double(prior.count)),
            "prior_7d_average_weight_kg": priorAverage.map(JSONValue.number) ?? .null,
            "average_weight_change_kg": change.map(JSONValue.number) ?? .null,
            "plateau_status": .string(status),
            "next_action": .string(action),
            "definition": .string("iPhone HealthKit 同来源完整四项体测；两个7日窗口各至少5次，腰围用于确认平台"),
        ]
    }

    private static func points(_ values: [String: Double]) -> [SnapshotTrends.Point] {
        values.map { SnapshotTrends.Point(date: $0.key, value: $0.value) }
            .sorted { $0.date < $1.date }
    }

    private static func historicalValues(_ values: [String: Double], before day: String, limit: Int) -> [Double] {
        values.keys.filter { $0 < day }.sorted(by: >).prefix(limit).compactMap { values[$0] }
    }

    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func normalizedBodyFat(_ value: Double) -> Double {
        value > 0 && value <= 1 ? value * 100 : value
    }

    private static func dateForDay(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func average(_ samples: [HealthSampleContract], metric: HealthMetric) -> Double? {
        let values = samples.filter { $0.metric == metric && $0.value.isFinite }.map(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func sum(_ samples: [HealthSampleContract], metric: HealthMetric) -> Double? {
        let values = samples.filter { $0.metric == metric && $0.value.isFinite }.map(\.value)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private static func latestValue(_ samples: [HealthSampleContract], metric: HealthMetric) -> Double? {
        samples.filter { $0.metric == metric && $0.value.isFinite }
            .max(by: { $0.startAt < $1.startAt })?.value
    }

    private static func parse(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
