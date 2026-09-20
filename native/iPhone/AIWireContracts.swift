import Foundation

struct AIRecommendationRequestV2: Encodable {
    var schemaVersion = "KrisAIPlanRequest.v2"
    var clientRequestId: UUID
    private var context: TrainingContextWireV2

    init(clientRequestId: UUID = UUID(), context: TrainingContext) {
        self.clientRequestId = clientRequestId
        self.context = TrainingContextWireV2(context)
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, clientRequestId, context }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(clientRequestId.uuidString.lowercased(), forKey: .clientRequestId)
        try container.encode(context, forKey: .context)
    }
}

private struct TrainingContextWireV2: Encodable {
    var schemaVersion = "TrainingContext.v2"
    var contextId: UUID
    var feature = "training_recommendation"
    var locale = "zh-CN"
    var generatedAt: String
    var expiresAt: String
    var intent: UserIntentWire
    var objectiveHealth: ObjectiveHealthWire
    var subjectiveUser: SubjectiveUserWire
    var trainingHistory: TrainingHistoryWire
    var progression: ProgressionWire
    var safety: SafetyWire
    var currentPlan: CurrentPlanWire?
    var evidence: [EvidenceWire]
    var dataGaps: [DataGapWire]

    init(_ context: TrainingContext) {
        contextId = context.contextId
        generatedAt = context.generatedAt
        expiresAt = context.expiresAt
        intent = UserIntentWire(context.intent)
        objectiveHealth = ObjectiveHealthWire(
            asOf: context.objectiveHealth.asOf,
            evidenceIds: context.objectiveHealth.evidenceIds
        )
        subjectiveUser = SubjectiveUserWire(
            reportedAt: context.subjectiveUser.reportedAt,
            evidenceIds: context.subjectiveUser.evidenceIds
        )
        trainingHistory = TrainingHistoryWire(context.trainingHistory)
        progression = ProgressionWire(context.progression, currentPlan: context.currentPlan)
        safety = SafetyWire(context.safety)
        currentPlan = context.currentPlan.map(CurrentPlanWire.init)
        evidence = context.evidence.map(EvidenceWire.init)
        dataGaps = context.dataGaps.enumerated().map(DataGapWire.init)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, contextId, feature, locale, generatedAt, expiresAt
        case intent, objectiveHealth, subjectiveUser, trainingHistory, progression
        case safety, currentPlan, evidence, dataGaps
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(contextId.uuidString.lowercased(), forKey: .contextId)
        try container.encode(feature, forKey: .feature)
        try container.encode(locale, forKey: .locale)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(intent, forKey: .intent)
        try container.encode(objectiveHealth, forKey: .objectiveHealth)
        try container.encode(subjectiveUser, forKey: .subjectiveUser)
        try container.encode(trainingHistory, forKey: .trainingHistory)
        try container.encode(progression, forKey: .progression)
        try container.encode(safety, forKey: .safety)
        if let currentPlan {
            try container.encode(currentPlan, forKey: .currentPlan)
        } else {
            try container.encodeNil(forKey: .currentPlan)
        }
        try container.encode(evidence, forKey: .evidence)
        try container.encode(dataGaps, forKey: .dataGaps)
    }
}

private struct UserIntentWire: Encodable {
    var intentId: UUID
    var kind: String
    var requestedDate: String
    var objective: String
    var availableMinutes: Int
    var equipment: [EquipmentAvailability]
    var targetPlanRevision: Int?
    var targetExerciseRef: String?
    var requestedChanges: [String]
    var freeText: String?

    init(_ intent: UserIntent) {
        intentId = intent.intentId
        kind = switch intent.kind {
        case .createPlan: "create_plan"
        case .revisePlan: "revise_plan"
        case .replaceExercise: "replace_exercise"
        case .adaptToEquipment: "adapt_equipment"
        case .shortenPlan: "shorten_plan"
        case .explainRecommendation: "explain_recommendation"
        }
        requestedDate = intent.requestedDate
        objective = intent.objective
        availableMinutes = intent.availableMinutes
        equipment = intent.equipment
        targetPlanRevision = intent.targetPlanRevision
        targetExerciseRef = intent.requestedExerciseId?.uuidString.lowercased()
        requestedChanges = intent.requestedChanges.map(\.detail)
        freeText = intent.notes
    }

    enum CodingKeys: String, CodingKey {
        case intentId, kind, requestedDate, objective, availableMinutes, equipment
        case targetPlanRevision, targetExerciseRef, requestedChanges, freeText
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intentId.uuidString.lowercased(), forKey: .intentId)
        try container.encode(kind, forKey: .kind)
        try container.encode(requestedDate, forKey: .requestedDate)
        try container.encode(objective, forKey: .objective)
        try container.encode(availableMinutes, forKey: .availableMinutes)
        try container.encode(equipment, forKey: .equipment)
        try container.encodeIfPresent(targetPlanRevision, forKey: .targetPlanRevision)
        if targetPlanRevision == nil { try container.encodeNil(forKey: .targetPlanRevision) }
        try container.encodeIfPresent(targetExerciseRef, forKey: .targetExerciseRef)
        if targetExerciseRef == nil { try container.encodeNil(forKey: .targetExerciseRef) }
        try container.encode(requestedChanges, forKey: .requestedChanges)
        try container.encodeIfPresent(freeText, forKey: .freeText)
        if freeText == nil { try container.encodeNil(forKey: .freeText) }
    }
}

private struct ObjectiveHealthWire: Encodable {
    var asOf: String
    var evidenceIds: [String]
}

private struct SubjectiveUserWire: Encodable {
    var reportedAt: String
    var evidenceIds: [String]
}

private struct TrainingHistoryWire: Encodable {
    var confirmedSessionEvidenceIds: [String]
    var observedWorkoutEvidenceIds: [String]

    init(_ value: TrainingHistoryContext) {
        confirmedSessionEvidenceIds = value.confirmedSessions.flatMap(\.evidenceIds)
        observedWorkoutEvidenceIds = value.observedWorkouts.flatMap(\.evidenceIds)
    }
}

private struct ProgressionWire: Encodable {
    struct Adjustment: Encodable {
        var type = "load_delta_kg"
        var maximumDeltaKg: Double
    }

    struct Decision: Encodable {
        var exerciseRef: String
        var disposition: String
        var allowedAdjustment: Adjustment?
        var evidenceIds: [String]
        var rollbackCondition: String

        enum CodingKeys: String, CodingKey {
            case exerciseRef, disposition, allowedAdjustment, evidenceIds, rollbackCondition
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(exerciseRef, forKey: .exerciseRef)
            try container.encode(disposition, forKey: .disposition)
            if let allowedAdjustment {
                try container.encode(allowedAdjustment, forKey: .allowedAdjustment)
            } else {
                try container.encodeNil(forKey: .allowedAdjustment)
            }
            try container.encode(evidenceIds, forKey: .evidenceIds)
            try container.encode(rollbackCondition, forKey: .rollbackCondition)
        }
    }

    var ruleVersion: String
    var exerciseDecisions: [Decision]

    init(_ value: ProgressionContext, currentPlan: TrainingPlan?) {
        ruleVersion = value.ruleVersion
        exerciseDecisions = value.permissions.map { permission in
            let current = currentPlan?.exercises.first {
                normalized($0.name) == normalized(permission.exerciseName)
                    && normalized($0.equipmentVariant) == normalized(permission.equipmentVariant)
            }?.targetWeightKg
            let delta = permission.maximumWeightKg.flatMap { maximum in
                current.map { max(0, maximum - $0) }
            }
            let allowedAdjustment = permission.allowsLoadIncrease
                ? delta.map { Adjustment(maximumDeltaKg: $0) } : nil
            let disposition: String
            if allowedAdjustment != nil {
                disposition = "increase_allowed"
            } else if permission.allowsLoadIncrease {
                disposition = "insufficient_data"
            } else {
                disposition = "hold"
            }
            return Decision(
                exerciseRef: String("\(permission.exerciseName)|\(permission.equipmentVariant)".prefix(80)),
                disposition: disposition,
                allowedAdjustment: allowedAdjustment,
                evidenceIds: permission.evidenceIds,
                rollbackCondition: "重新检查同器械实际训练结果、动作质量和用户反馈。"
            )
        }
    }
}

private struct SafetyWire: Encodable {
    struct Restriction: Encodable {
        struct Constraint: Encodable {
            var type: String
            var exerciseRef: String?
            var equipmentRef: String?
        }

        var restrictionId: String
        var ruleCode: String
        var severity: String
        var constraint: Constraint
        var evidenceIds: [String]
        var userFacingMessage: String
        var requiresAcknowledgement: Bool
    }

    var ruleVersion: String
    var disposition: SafetyDisposition
    var evaluatedAt: String
    var expiresAt: String
    var restrictions: [Restriction]

    init(_ value: SafetyContext) {
        ruleVersion = value.ruleVersion
        disposition = value.disposition
        evaluatedAt = value.evaluatedAt
        expiresAt = value.expiresAt
        restrictions = value.restrictions.map { restriction in
            let constraintType = switch restriction.kind {
            case .prohibitTraining: "prohibit_training"
            case .prohibitUnapprovedLoadIncrease: "prohibit_load_increase"
            case .excludeExercise: "exclude_exercise"
            case .prohibitEquipment: "exclude_equipment"
            case .requireSymptomConfirmation: "require_symptom_confirmation"
            case .recoveryOnly: "recovery_only"
            }
            let severity = switch restriction.severity {
            case .advisory: "info"
            case .constraint: "caution"
            case .block: "hard_stop"
            }
            return Restriction(
                restrictionId: restriction.id,
                ruleCode: restriction.kind.rawValue,
                severity: severity,
                constraint: .init(
                    type: constraintType,
                    exerciseRef: restriction.kind == .excludeExercise ? restriction.subject : nil,
                    equipmentRef: restriction.kind == .prohibitEquipment ? restriction.subject : nil
                ),
                evidenceIds: restriction.evidenceIds,
                userFacingMessage: restriction.message,
                requiresAcknowledgement: restriction.severity != .advisory
            )
        }
    }
}

private struct CurrentPlanWire: Encodable {
    struct Exercise: Encodable {
        var exerciseRef: String
        var name: String
        var equipmentVariant: String
        var targetWeightKg: Double?
        var sets: Int
        var targetReps: Int
        var restSeconds: Int

        enum CodingKeys: String, CodingKey {
            case exerciseRef, name, equipmentVariant, targetWeightKg
            case sets, targetReps, restSeconds
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(exerciseRef, forKey: .exerciseRef)
            try container.encode(name, forKey: .name)
            try container.encode(equipmentVariant, forKey: .equipmentVariant)
            if let targetWeightKg {
                try container.encode(targetWeightKg, forKey: .targetWeightKg)
            } else {
                try container.encodeNil(forKey: .targetWeightKg)
            }
            try container.encode(sets, forKey: .sets)
            try container.encode(targetReps, forKey: .targetReps)
            try container.encode(restSeconds, forKey: .restSeconds)
        }
    }

    var planRef: String
    var revision: Int
    var date: String
    var title: String
    var estimatedMinutes: Int
    var goal: String
    var exercises: [Exercise]

    init(_ plan: TrainingPlan) {
        planRef = plan.planId.uuidString.lowercased()
        revision = plan.revision
        date = plan.date
        title = plan.title
        estimatedMinutes = plan.estimatedMinutes
        goal = plan.goal ?? ""
        exercises = plan.exercises.map {
            Exercise(
                exerciseRef: $0.exerciseId.uuidString.lowercased(), name: $0.name,
                equipmentVariant: $0.equipmentVariant,
                targetWeightKg: $0.targetWeightKg, sets: $0.sets,
                targetReps: $0.targetReps, restSeconds: $0.restSeconds
            )
        }
    }
}

private struct EvidenceWire: Encodable {
    enum Payload: Encodable {
        case quantity(metric: String, value: Double, unit: String)
        case categorical(metric: String, value: String)
        case setPerformance(
            exercise: String, equipmentVariant: String,
            weightKg: Double?, reps: [Int]
        )
        case missing(signal: String, reason: String)

        enum CodingKeys: String, CodingKey {
            case type, metric, value, unit, signal, reason
            case exercise, equipmentVariant, weightKg, reps
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .quantity(let metric, let value, let unit):
                try container.encode("quantity", forKey: .type)
                try container.encode(metric, forKey: .metric)
                try container.encode(value, forKey: .value)
                try container.encode(unit, forKey: .unit)
            case .categorical(let metric, let value):
                try container.encode("categorical", forKey: .type)
                try container.encode(metric, forKey: .metric)
                try container.encode(value, forKey: .value)
            case .setPerformance(let exercise, let equipmentVariant, let weightKg, let reps):
                try container.encode("set_performance", forKey: .type)
                try container.encode(exercise, forKey: .exercise)
                try container.encode(equipmentVariant, forKey: .equipmentVariant)
                if let weightKg {
                    try container.encode(weightKg, forKey: .weightKg)
                } else {
                    try container.encodeNil(forKey: .weightKg)
                }
                try container.encode(reps, forKey: .reps)
            case .missing(let signal, let reason):
                try container.encode("missing_signal", forKey: .type)
                try container.encode(signal, forKey: .signal)
                try container.encode(reason, forKey: .reason)
            }
        }
    }

    var evidenceId: String
    var category: String
    var origin: String
    var observedAt: String?
    var quality: EvidenceQuality
    var payload: Payload

    init(_ value: Evidence) {
        evidenceId = value.id
        if value.quality == .missing {
            category = "missing_signal"
        } else {
            category = switch value.provenance {
            case .objectiveHealth: "objective_measurement"
            case .subjectiveUser: "user_reported_fact"
            case .confirmedTraining: "confirmed_training_result"
            case .observedWorkout: "device_observation"
            case .deterministicRule: "deterministic_assessment"
            }
        }
        origin = switch value.provenance {
        case .objectiveHealth: "healthkit_aggregate"
        case .subjectiveUser: "user_report"
        case .confirmedTraining: "kris_session"
        case .observedWorkout: "healthkit_workout"
        case .deterministicRule: "local_rule"
        }
        observedAt = value.observedAt
        quality = value.quality
        if value.quality == .missing {
            let reason = value.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let missingReason = reason?.isEmpty == false ? reason ?? "" : "Signal is unavailable"
            payload = .missing(
                signal: value.key,
                reason: missingReason
            )
        } else if value.key == "set_performance",
                  let performance = EvidenceWire.setPerformance(value.value) {
            payload = .setPerformance(
                exercise: performance.exercise,
                equipmentVariant: performance.equipmentVariant,
                weightKg: performance.weightKg, reps: performance.reps
            )
        } else if case .number(let number)? = value.value {
            payload = .quantity(
                metric: value.key, value: number,
                unit: EvidenceWire.unit(value.note, metric: value.key)
            )
        } else {
            payload = .categorical(metric: value.key, value: EvidenceWire.stringValue(value.value))
        }
    }

    private static func setPerformance(
        _ value: JSONValue?
    ) -> (exercise: String, equipmentVariant: String, weightKg: Double?, reps: [Int])? {
        guard case .object(let object)? = value,
              case .string(let exercise)? = object["exercise"],
              case .string(let equipmentVariant)? = object["equipment_variant"],
              let weightValue = object["weight_kg"],
              case .array(let repValues)? = object["reps"] else { return nil }
        let weightKg: Double?
        switch weightValue {
        case .number(let value): weightKg = value
        case .null: weightKg = nil
        default: return nil
        }
        let reps = repValues.compactMap { item -> Int? in
            guard case .number(let value) = item,
                  value.rounded() == value,
                  (0...500).contains(value) else { return nil }
            return Int(value)
        }
        guard reps.count == repValues.count, !reps.isEmpty else { return nil }
        return (exercise, equipmentVariant, weightKg, reps)
    }

    enum CodingKeys: String, CodingKey {
        case evidenceId, category, origin, observedAt, quality, payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(evidenceId, forKey: .evidenceId)
        try container.encode(category, forKey: .category)
        try container.encode(origin, forKey: .origin)
        if let observedAt {
            try container.encode(observedAt, forKey: .observedAt)
        } else {
            try container.encodeNil(forKey: .observedAt)
        }
        try container.encode(quality, forKey: .quality)
        try container.encode(payload, forKey: .payload)
    }

    private static func stringValue(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "unknown" : String(normalized.prefix(120))
        case .number(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .object(let object):
            return String(object.keys.sorted().compactMap { key in
                guard let value = object[key] else { return nil }
                return "\(key)=\(stringValue(value))"
            }.joined(separator: ";").prefix(120))
        case .array(let array): return String(array.map(stringValue).joined(separator: ",").prefix(120))
        case .null, nil: return "unknown"
        }
    }

    private static func unit(_ note: String?, metric: String) -> String {
        let supported = Set(["minute", "millisecond", "bpm", "count", "kg", "kcal", "percent"])
        if let note, supported.contains(note) { return note }
        return switch metric {
        case "sleep_duration", "duration_minutes": "minute"
        case "hrv_sdnn": "millisecond"
        case "resting_heart_rate", "heart_rate": "bpm"
        case "body_mass", "weight", "weight_kg": "kg"
        case "active_energy", "basal_energy": "kcal"
        case "body_fat_percentage": "percent"
        default: "count"
        }
    }
}

private struct DataGapWire: Encodable {
    var code: String
    var field: String
    var status: DataGapStatus
    var message: String

    init(_ index: Int, _ gap: DataGap) {
        let fallback = "gap_\(index + 1)"
        let normalizedKey = gap.key.trimmingCharacters(in: .whitespacesAndNewlines)
        code = String((normalizedKey.isEmpty ? fallback : normalizedKey).prefix(80))
        field = String((normalizedKey.isEmpty ? fallback : normalizedKey).prefix(120))
        status = gap.status
        let normalizedMessage = gap.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        message = String(((normalizedMessage?.isEmpty == false ? normalizedMessage : nil)
            ?? "Data is not available").prefix(300))
    }
}

struct AIRecommendationResponseWireV2: Decodable {
    struct RecommendationBody: Decodable {
        var type: String
        var candidatePlan: CandidatePlanWire?
        var message: String?
    }

    struct CandidatePlanWire: Codable {
        var title: String
        var estimatedMinutes: Int
        var goal: String
        var exercises: [AIExerciseDraft]

        var domain: AITrainingPlanDraft {
            AITrainingPlanDraft(
                title: title, estimatedMinutes: estimatedMinutes,
                goal: goal, safetyGates: [], exercises: exercises
            )
        }
    }

    struct AdjustmentWire: Decodable {
        var trigger: String
        var candidatePlan: CandidatePlanWire
        var evidenceIds: [String]
    }

    struct AlternativeWire: Decodable {
        var title: String
        var when: String
        var candidatePlan: CandidatePlanWire
        var evidenceIds: [String]
    }

    struct SafetyWire: Decodable {
        var code: String
        var message: String
        var evidenceIds: [String]
        var restrictionIds: [String]
    }

    var schemaVersion: String
    var requestId: UUID
    var recommendationId: UUID
    var contextId: UUID
    var kind: String
    var recommendation: RecommendationBody
    var reasons: [RecommendationReason]
    var evidenceIds: [String]
    var confidence: RecommendationConfidence
    var uncertainties: [RecommendationUncertainty]
    var optionalAdjustment: AdjustmentWire?
    var alternatives: [AlternativeWire]
    var safetyConsiderations: [SafetyWire]
    var acknowledgedRestrictionIds: [String]
    var userConfirmationRequired: Bool
    var inferenceMetadata: AIInferenceMetadata

    func domain(context: TrainingContext) throws -> AIRecommendation {
        guard schemaVersion == "AIRecommendation.v2", contextId == context.contextId else {
            throw AIServiceError.invalidResponse
        }
        let planKinds = Set([
            "create_plan", "revise_plan", "replace_exercise", "adapt_equipment", "shorten_plan",
        ])
        let requestedKind: String? = switch context.intent.kind {
        case .createPlan: "create_plan"
        case .revisePlan: "revise_plan"
        case .replaceExercise: "replace_exercise"
        case .adaptToEquipment: "adapt_equipment"
        case .shortenPlan: "shorten_plan"
        case .explainRecommendation: nil
        }
        let allowedKinds = Set(["no_change", "decline_unsafe_request"] + [requestedKind].compactMap { $0 })
        guard allowedKinds.contains(kind) else { throw AIServiceError.invalidResponse }
        if planKinds.contains(kind) {
            guard recommendation.type == "candidate_plan",
                  recommendation.candidatePlan != nil,
                  recommendation.message == nil else {
                throw AIServiceError.invalidResponse
            }
        } else if kind == "no_change" {
            guard recommendation.type == "no_change",
                  recommendation.candidatePlan == nil,
                  recommendation.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw AIServiceError.invalidResponse
            }
        } else if kind == "decline_unsafe_request" {
            guard recommendation.type == "decline_unsafe_request",
                  recommendation.candidatePlan == nil,
                  recommendation.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw AIServiceError.invalidResponse
            }
        }
        guard userConfirmationRequired else { throw AIServiceError.invalidResponse }
        let domainKind: AIRecommendationKind = switch kind {
        case "create_plan": .newPlan
        case "revise_plan", "adapt_equipment", "shorten_plan": .planRevision
        case "replace_exercise": .exerciseReplacement
        case "no_change": .noChange
        case "decline_unsafe_request": .declineUnsafeRequest
        default: throw AIServiceError.invalidResponse
        }
        return AIRecommendation(
            recommendationId: recommendationId, requestId: requestId,
            contextId: contextId, kind: domainKind,
            recommendation: recommendation.message
                ?? recommendation.candidatePlan?.title ?? "结构化训练建议",
            proposedPlan: recommendation.candidatePlan?.domain,
            reasons: reasons, evidenceIds: evidenceIds, confidence: confidence,
            uncertainties: uncertainties,
            optionalAdjustment: optionalAdjustment.map {
                ProposedPlanAdjustment(
                    summary: $0.trigger, plan: $0.candidatePlan.domain,
                    evidenceIds: $0.evidenceIds
                )
            },
            alternatives: alternatives.enumerated().map { index, item in
                AlternativeRecommendation(
                    id: "alternative_\(index + 1)",
                    summary: "\(item.title)：\(item.when)",
                    plan: item.candidatePlan.domain, evidenceIds: item.evidenceIds
                )
            },
            safetyConsiderations: safetyConsiderations.map {
                AISafetyConsideration(
                    code: $0.code, explanation: $0.message,
                    evidenceIds: $0.evidenceIds, restrictionIds: $0.restrictionIds
                )
            },
            acknowledgedRestrictionIds: acknowledgedRestrictionIds,
            userConfirmationRequired: userConfirmationRequired,
            inferenceMetadata: inferenceMetadata
        )
    }
}

private func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
