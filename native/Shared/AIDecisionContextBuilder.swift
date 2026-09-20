import Foundation

enum AIDecisionContextBuilder {
    static let safetyRuleVersion = "local_ai_safety_v2"
    static let progressionRuleVersion = "gated_double_progression_v1"
    private static let maximumEvidenceCount = 64

    static func build(
        input: AIPlanUserInput,
        currentPlan: TrainingPlan?,
        health: DailyHealthMetrics,
        healthAsOf: Date,
        dataGaps: [String],
        trainingHistory: [SnapshotTrainingSummary],
        confirmedTrainingOutcomes: [TrainingSessionContract] = [],
        progression: [LocalProgressionDecision],
        now: Date,
        preservingIntent intentSnapshot: UserIntent? = nil
    ) -> TrainingContext {
        let generatedAt = DateFormatting.iso(now)
        let expiresAt = DateFormatting.iso(now.addingTimeInterval(4 * 60 * 60))
        var evidence: [Evidence] = []

        let objective = objectiveEvidence(health, observedAt: DateFormatting.iso(healthAsOf))
        evidence.append(contentsOf: objective)

        let subjective = subjectiveEvidence(input, observedAt: generatedAt)
        evidence.append(contentsOf: subjective)

        let progressionContext = progressionContext(
            progression, currentPlan: currentPlan, evidence: &evidence
        )
        let safety = safetyContext(
            symptoms: input.symptoms, evaluatedAt: generatedAt,
            expiresAt: expiresAt, evidence: &evidence
        )
        let history = historyContext(
            trainingHistory, confirmedOutcomes: confirmedTrainingOutcomes,
            evidenceBudget: max(0, maximumEvidenceCount - evidence.count),
            evidence: &evidence
        )

        let intent = makeIntent(
            input: input, currentPlan: currentPlan, preserving: intentSnapshot
        )

        var gaps = dataGaps.enumerated().map { index, gap in
            DataGap(key: "source_gap_\(index + 1)", status: .partial, note: gap)
        }
        for item in objective where item.quality == .missing {
            gaps.append(DataGap(key: item.key, status: .missing, note: item.note))
        }

        return TrainingContext(
            contextId: UUID(), generatedAt: generatedAt, expiresAt: expiresAt,
            intent: intent,
            objectiveHealth: ObjectiveHealthContext(
                asOf: DateFormatting.iso(healthAsOf), evidenceIds: objective.map(\.id)
            ),
            subjectiveUser: SubjectiveUserContext(
                reportedAt: generatedAt, evidenceIds: subjective.map(\.id)
            ),
            trainingHistory: history, progression: progressionContext,
            safety: safety, currentPlan: currentPlan, evidence: evidence,
            dataGaps: Array(gaps.prefix(20))
        )
    }

    private static func objectiveEvidence(
        _ health: DailyHealthMetrics, observedAt: String
    ) -> [Evidence] {
        [
            measurement("ev_obj_sleep", key: "sleep_duration", value: health.sleepHours.map { $0 * 60 }, observedAt: observedAt, unit: "minute"),
            measurement("ev_obj_hrv", key: "hrv_sdnn", value: health.hrvMs, observedAt: observedAt, unit: "millisecond"),
            measurement("ev_obj_rhr", key: "resting_heart_rate", value: health.restingHeartRate, observedAt: observedAt, unit: "bpm"),
            measurement("ev_obj_steps", key: "step_count", value: health.steps, observedAt: observedAt, unit: "count"),
        ]
    }

    private static func measurement(
        _ id: String, key: String, value: Double?, observedAt: String, unit: String
    ) -> Evidence {
        Evidence(
            id: id, provenance: .objectiveHealth, key: key,
            observedAt: value == nil ? nil : observedAt,
            quality: value == nil ? .missing : .confirmed,
            value: value.map(JSONValue.number), source: "healthkit_aggregate",
            note: value == nil ? "No covered HealthKit aggregate is available" : unit
        )
    }

    private static func subjectiveEvidence(
        _ input: AIPlanUserInput, observedAt: String
    ) -> [Evidence] {
        var result = [Evidence(
            id: "ev_sub_symptoms", provenance: .subjectiveUser,
            key: "reported_symptoms", observedAt: observedAt,
            quality: input.symptoms == .notReported ? .partial : .confirmed,
            value: .string(input.symptoms.rawValue), source: "user_report", note: nil
        )]
        if let energy = input.reportedEnergy {
            result.append(Evidence(
                id: "ev_sub_energy", provenance: .subjectiveUser,
                key: "user_reported_energy", observedAt: observedAt,
                quality: .confirmed, value: .string(energy.rawValue),
                source: "user_report", note: nil
            ))
        }
        if let notes = input.notes.nilIfBlank {
            result.append(Evidence(
                id: "ev_sub_notes", provenance: .subjectiveUser,
                key: "user_notes", observedAt: observedAt, quality: .confirmed,
                value: .string(notes), source: "user_report", note: nil
            ))
        }
        return result
    }

    private static func historyContext(
        _ history: [SnapshotTrainingSummary],
        confirmedOutcomes: [TrainingSessionContract],
        evidenceBudget: Int,
        evidence: inout [Evidence]
    ) -> TrainingHistoryContext {
        var confirmed: [ConfirmedTrainingSummary] = []
        var observed: [ObservedWorkoutSummary] = []
        var includedSessionIDs = Set<UUID>()
        var confirmedEvidenceCount = 0
        var historyEvidenceCount = 0
        let snapshotsByID = Dictionary(uniqueKeysWithValues: history.compactMap { item in
            UUID(uuidString: item.id).map { ($0, item) }
        })

        for session in confirmedOutcomes.prefix(4) {
            guard confirmed.count + observed.count < 12,
                  historyEvidenceCount < evidenceBudget,
                  includedSessionIDs.insert(session.sessionId).inserted else { continue }
            let index = confirmed.count + observed.count + 1
            let summaryEvidenceID = "ev_training_\(index)"
            let snapshot = snapshotsByID[session.sessionId]
            let completedSetCount = session.exerciseResults.reduce(0) { $0 + $1.sets.count }
            let durationMinutes = sessionDurationMinutes(session)
            evidence.append(Evidence(
                id: summaryEvidenceID, provenance: .confirmedTraining,
                key: "confirmed_training_result", observedAt: session.endedAt,
                quality: .confirmed,
                value: .object([
                    "title": .string(snapshot?.title ?? "训练记录"),
                    "completed_sets": .number(Double(completedSetCount)),
                    "duration_minutes": durationMinutes.map(JSONValue.number) ?? .null,
                    "status": .string(session.status.rawValue),
                ]),
                source: "kris_session", note: nil
            ))
            historyEvidenceCount += 1
            var evidenceIDs = [summaryEvidenceID]
            confirmedEvidenceCount += 1

            let remainingReferenceCapacity = min(
                max(0, 24 - confirmedEvidenceCount),
                max(0, evidenceBudget - historyEvidenceCount)
            )
            let performances = setPerformances(session).prefix(min(6, remainingReferenceCapacity))
            for (performanceIndex, performance) in performances.enumerated() {
                let evidenceID = "ev_training_\(index)_set_\(performanceIndex + 1)"
                evidence.append(Evidence(
                    id: evidenceID, provenance: .confirmedTraining,
                    key: "set_performance", observedAt: session.endedAt,
                    quality: .confirmed,
                    value: .object([
                        "exercise": .string(performance.exercise),
                        "equipment_variant": .string(performance.equipmentVariant),
                        "weight_kg": performance.weightKg.map(JSONValue.number) ?? .null,
                        "reps": .array(performance.reps.map { .number(Double($0)) }),
                    ]),
                    source: "kris_session", note: nil
                ))
                evidenceIDs.append(evidenceID)
                confirmedEvidenceCount += 1
                historyEvidenceCount += 1
            }
            confirmed.append(ConfirmedTrainingSummary(
                sessionId: session.sessionId,
                date: String(session.endedAt.prefix(10)),
                title: snapshot?.title ?? "训练记录", status: session.status,
                source: .krisSession, evidenceIds: evidenceIDs
            ))
        }

        for item in history.prefix(12) where confirmed.count + observed.count < 12 {
            let index = confirmed.count + observed.count + 1
            if item.source == "kris_coach_app",
               let sessionID = UUID(uuidString: item.id),
               let status = TrainingSessionStatus(rawValue: item.status),
               !includedSessionIDs.contains(sessionID),
               confirmedEvidenceCount < 24,
               historyEvidenceCount < evidenceBudget {
                let evidenceID = "ev_training_\(index)"
                evidence.append(Evidence(
                    id: evidenceID, provenance: .confirmedTraining,
                    key: "confirmed_training_result", observedAt: item.date,
                    quality: .confirmed,
                    value: .object([
                        "title": .string(item.title),
                        "completed_sets": item.completedSetCount.map { .number(Double($0)) } ?? .null,
                        "duration_minutes": item.durationMinutes.map(JSONValue.number) ?? .null,
                        "status": .string(item.status),
                    ]),
                    source: "kris_session", note: nil
                ))
                confirmed.append(ConfirmedTrainingSummary(
                    sessionId: sessionID, date: String(item.date.prefix(10)),
                    title: item.title, status: status, source: .krisSession,
                    evidenceIds: [evidenceID]
                ))
                includedSessionIDs.insert(sessionID)
                confirmedEvidenceCount += 1
                historyEvidenceCount += 1
            } else if item.source == "iphone_healthkit",
                      historyEvidenceCount < evidenceBudget {
                let evidenceID = "ev_workout_\(index)"
                evidence.append(Evidence(
                    id: evidenceID, provenance: .observedWorkout,
                    key: "observed_workout", observedAt: item.date,
                    quality: .confirmed,
                    value: .object([
                        "activity_type": .string(item.title),
                        "duration_minutes": item.durationMinutes.map(JSONValue.number) ?? .null,
                    ]),
                    source: "healthkit_workout", note: nil
                ))
                observed.append(ObservedWorkoutSummary(
                    observationId: item.id, date: String(item.date.prefix(10)),
                    activityType: item.title,
                    durationMinutes: item.durationMinutes.map { Int($0.rounded()) },
                    source: .healthKitObservation, evidenceIds: [evidenceID]
                ))
                historyEvidenceCount += 1
            }
        }
        return TrainingHistoryContext(
            confirmedSessions: confirmed, observedWorkouts: observed
        )
    }

    private struct SetPerformance {
        var exercise: String
        var equipmentVariant: String
        var weightKg: Double?
        var reps: [Int]
    }

    private static func setPerformances(_ session: TrainingSessionContract) -> [SetPerformance] {
        var result: [SetPerformance] = []
        for exercise in session.exerciseResults {
            let name = String(exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            let equipment = String(exercise.equipmentVariant
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            guard !name.isEmpty, !equipment.isEmpty else { continue }
            for set in exercise.sets.sorted(by: { $0.setNumber < $1.setNumber }) {
                guard (0...500).contains(set.reps),
                      set.weightKg.map({ (0...1_000).contains($0) }) ?? true else { continue }
                if let index = result.firstIndex(where: {
                    $0.exercise == name && $0.equipmentVariant == equipment
                        && $0.weightKg == set.weightKg && $0.reps.count < 20
                }) {
                    result[index].reps.append(set.reps)
                } else {
                    result.append(SetPerformance(
                        exercise: name, equipmentVariant: equipment,
                        weightKg: set.weightKg, reps: [set.reps]
                    ))
                }
            }
        }
        return result
    }

    private static func sessionDurationMinutes(_ session: TrainingSessionContract) -> Double? {
        guard let start = DateFormatting.parse(session.startedAt),
              let end = DateFormatting.parse(session.endedAt), end >= start else { return nil }
        return end.timeIntervalSince(start) / 60
    }

    private static func progressionContext(
        _ decisions: [LocalProgressionDecision],
        currentPlan: TrainingPlan?, evidence: inout [Evidence]
    ) -> ProgressionContext {
        let permissions = decisions.prefix(24).enumerated().map { index, decision in
            let evidenceID = "ev_progress_\(index + 1)"
            evidence.append(Evidence(
                id: evidenceID, provenance: .deterministicRule,
                key: "progression_rule_result", observedAt: nil,
                quality: .confirmed, value: .object([
                    "source_date": .string(decision.latestDate),
                    "state": .string(decision.state),
                ]),
                source: "local_rule",
                note: "\(decision.evidence)；\(decision.rollbackCondition)"
            ))
            // The current local history does not contain each machine's actual
            // smallest increment. Eligibility is retained as evidence, while an
            // exact AI-authored weight increase stays closed until that limit is known.
            return ProgressionPermission(
                exerciseName: decision.exercise,
                equipmentVariant: decision.equipmentVariant,
                allowsLoadIncrease: false,
                maximumWeightKg: currentPlan?.exercises.first(where: {
                    normalized($0.name) == normalized(decision.exercise)
                        && normalized($0.equipmentVariant) == normalized(decision.equipmentVariant)
                })?.targetWeightKg,
                evidenceIds: [evidenceID]
            )
        }
        return ProgressionContext(
            ruleVersion: progressionRuleVersion, permissions: permissions
        )
    }

    private static func safetyContext(
        symptoms: LocalTrainingSymptoms, evaluatedAt: String,
        expiresAt: String, evidence: inout [Evidence]
    ) -> SafetyContext {
        let symptomEvidenceID = "ev_sub_symptoms"
        let progressionGuardEvidenceID = "ev_rule_no_unapproved_load"
        evidence.append(Evidence(
            id: progressionGuardEvidenceID, provenance: .deterministicRule,
            key: "unapproved_load_increase_prohibited", observedAt: evaluatedAt,
            quality: .confirmed, value: .bool(true), source: "local_rule",
            note: "Exact load increases require a matching local progression permission"
        ))
        var disposition: SafetyDisposition = .allow
        var restrictions = [SafetyRestriction(
            id: "sr_no_unapproved_load", kind: .prohibitUnapprovedLoadIncrease,
            severity: .constraint, evidenceIds: [progressionGuardEvidenceID], authority: .localRule,
            message: "没有匹配的本地进阶许可时不得增加训练重量。"
        )]
        switch symptoms {
        case .emergencyReported:
            disposition = .block
            restrictions.append(SafetyRestriction(
                id: "sr_emergency_stop", kind: .prohibitTraining, severity: .block,
                evidenceIds: [symptomEvidenceID], authority: .localRule,
                message: "已报告危险信号，停止训练并及时寻求医疗帮助。"
            ))
        case .limitingDiscomfort:
            disposition = .needsUserInput
            restrictions.append(SafetyRestriction(
                id: "sr_discomfort_review", kind: .requireSymptomConfirmation,
                severity: .constraint, evidenceIds: [symptomEvidenceID], authority: .localRule,
                message: "先确认不适位置和受影响动作，再生成训练建议。"
            ))
        case .notReported:
            disposition = .needsUserInput
            restrictions.append(SafetyRestriction(
                id: "sr_symptom_confirmation", kind: .requireSymptomConfirmation,
                severity: .constraint, evidenceIds: [symptomEvidenceID], authority: .localRule,
                message: "生成训练建议前需要用户确认当前是否有不适。"
            ))
        case .noneReported:
            break
        }
        return SafetyContext(
            ruleVersion: safetyRuleVersion, disposition: disposition,
            restrictions: restrictions, evaluatedAt: evaluatedAt, expiresAt: expiresAt
        )
    }

    private static func equipment(from raw: String) -> [EquipmentAvailability] {
        let separators = CharacterSet(charactersIn: ",，、\n")
        let values = raw.components(separatedBy: separators)
            .compactMap(\.nilIfBlank)
        return (values.isEmpty ? ["未说明器械"] : values).map {
            EquipmentAvailability(name: $0, status: values.isEmpty ? .unknown : .available)
        }
    }

    private static func makeIntent(
        input: AIPlanUserInput,
        currentPlan: TrainingPlan?,
        preserving snapshot: UserIntent?
    ) -> UserIntent {
        let draftKind = snapshot?.kind ?? input.intent?.kind
            ?? (currentPlan == nil ? .createPlan : .revisePlan)
        let targetsCurrentPlan = draftKind != .createPlan
        let localExerciseIDs = Set(currentPlan?.exercises.map(\.exerciseId) ?? [])
        let requestedExerciseID = snapshot?.requestedExerciseId
            ?? input.intent?.requestedExerciseId
        let boundExerciseID = requestedExerciseID.flatMap {
            targetsCurrentPlan && localExerciseIDs.contains($0) ? $0 : nil
        }
        let changes = (snapshot?.requestedChanges ?? input.intent?.requestedChanges ?? [])
            .prefix(12)
            .compactMap { change -> RequestedChange? in
                guard let detail = change.detail.nilIfBlank else { return nil }
                let exerciseID = change.exerciseId.flatMap {
                    targetsCurrentPlan && localExerciseIDs.contains($0) ? $0 : nil
                }
                return RequestedChange(
                    kind: change.kind, exerciseId: exerciseID,
                    detail: String(detail.prefix(300))
                )
            }
        let suppliedEquipment = snapshot?.equipment ?? input.intent?.equipment ?? []
        let sanitizedEquipment = normalizedEquipment(suppliedEquipment)

        return UserIntent(
            intentId: snapshot?.intentId ?? UUID(), kind: draftKind,
            requestedDate: input.date, objective: input.objective,
            availableMinutes: input.availableMinutes,
            equipment: sanitizedEquipment.isEmpty
                ? equipment(from: input.equipment) : sanitizedEquipment,
            targetPlanId: targetsCurrentPlan ? currentPlan?.planId : nil,
            targetPlanRevision: targetsCurrentPlan ? currentPlan?.revision : nil,
            requestedExerciseId: boundExerciseID,
            requestedChanges: Array(changes), notes: input.notes.nilIfBlank
        )
    }

    private static func normalizedEquipment(
        _ values: [EquipmentAvailability]
    ) -> [EquipmentAvailability] {
        var seen: Set<String> = []
        return values.compactMap { item in
            guard let name = item.name.nilIfBlank else { return nil }
            let trimmed = String(name.prefix(120))
            let key = normalized(trimmed)
            guard seen.insert(key).inserted else { return nil }
            return EquipmentAvailability(name: trimmed, status: item.status)
        }.prefix(24).map { $0 }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension TrainingContext {
    var disclosureItems: [String] {
        var items = [
            "你的目标、可用时间、器械和主动填写的反馈",
            "睡眠、HRV、静息心率和步数的聚合值或明确缺失状态",
            "\(trainingHistory.confirmedSessions.count) 次已确认训练与 \(trainingHistory.observedWorkouts.count) 条设备运动观察（分开标记）",
            "本地安全限制、动作进阶许可和数据缺口",
        ]
        if currentPlan != nil { items.append("当前计划的动作与处方") }
        return items
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
