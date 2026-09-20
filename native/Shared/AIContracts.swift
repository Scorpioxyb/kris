import Foundation

enum AIFeature: String, Codable, Sendable {
    case trainingPlanCandidate = "training_plan_candidate"
    case healthExplanation = "health_explanation"
    case weeklyReview = "weekly_review"
}

struct AIPlanUserInput: Codable, Hashable, Sendable {
    var date: String
    var objective: String
    var availableMinutes: Int
    var equipment: String
    var notes: String
    var symptoms: LocalTrainingSymptoms
    var reportedEnergy: SubjectiveEnergy? = nil
    var intent: AIPlanIntentInput? = nil
}

enum SubjectiveEnergy: String, Codable, Hashable, Sendable {
    case good
    case normal
    case low
    case exhausted
}

struct AIRedactedReadiness: Codable, Hashable, Sendable {
    var score: Double?
    var state: String
    var confidence: String
    var safetyGate: String
}

struct AIRedactedTrainingSummary: Codable, Hashable, Sendable {
    var date: String
    var title: String
    var durationMinutes: Int?
    var completedSetCount: Int?
    var status: String
}

struct AIRedactedCurrentPlan: Codable, Hashable, Sendable {
    var title: String
    var date: String
    var revision: Int
    var exercisePrescriptions: [String]
}

/// Provider-neutral, intentionally aggregated input. It never contains
/// HealthKit UUIDs, device identifiers, source names, or raw sample timestamps.
struct AIRedactedPlanContext: Codable, Hashable, Sendable {
    var schemaVersion = "AIRedactedPlanContext.v1"
    var feature = AIFeature.trainingPlanCandidate
    var locale = "zh-CN"
    var generatedAt: String
    var userInput: AIPlanUserInput
    var readiness: AIRedactedReadiness?
    var localDecision: LocalPlanDecision
    var recentConfirmedTraining: [AIRedactedTrainingSummary]
    var currentPlan: AIRedactedCurrentPlan?
    var progressionNotes: [String]
    var dataGaps: [String]

    var disclosureItems: [String] {
        var items = [
            "你的目标、可用时间、器械和主动填写的备注",
            "准备度分级、置信度和安全门槛（不含原始健康样本）",
            "最近 \(recentConfirmedTraining.count) 次已确认训练的日期级摘要",
            "本地规则结论与数据缺口",
        ]
        if currentPlan != nil { items.append("当前计划的动作与处方摘要") }
        if !progressionNotes.isEmpty { items.append("已通过本地规则计算的动作进阶结论") }
        return items
    }
}

struct AIExerciseDraft: Codable, Hashable, Sendable {
    var name: String
    var equipmentVariant: String
    var targetWeightKg: Double?
    var sets: Int
    var targetReps: Int
    var restSeconds: Int
    var notes: [String]?
    var alternative: String?
}

struct AITrainingPlanDraft: Codable, Hashable, Sendable {
    var title: String
    var estimatedMinutes: Int
    var goal: String
    var safetyGates: [String]
    var exercises: [AIExerciseDraft]
}

struct AIPlanResponseEnvelope: Codable, Hashable, Sendable {
    var schemaVersion: String
    var rationale: String
    var cautions: [String]
    var plan: AITrainingPlanDraft
}

enum UserIntentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case createPlan = "create_plan"
    case revisePlan = "revise_plan"
    case replaceExercise = "replace_exercise"
    case adaptToEquipment = "adapt_to_equipment"
    case shortenPlan = "shorten_plan"
    case explainRecommendation = "explain_recommendation"
}

enum EquipmentAvailabilityStatus: String, Codable, Hashable, Sendable {
    case available
    case unavailable
    case unknown
}

struct EquipmentAvailability: Codable, Hashable, Sendable {
    var name: String
    var status: EquipmentAvailabilityStatus
}

enum RequestedChangeKind: String, Codable, Hashable, Sendable, CaseIterable {
    case addExercise = "add_exercise"
    case removeExercise = "remove_exercise"
    case replaceExercise = "replace_exercise"
    case changeLoad = "change_load"
    case changeVolume = "change_volume"
    case changeDuration = "change_duration"
}

struct RequestedChange: Codable, Hashable, Sendable {
    var kind: RequestedChangeKind
    var exerciseId: UUID?
    var detail: String
}

/// User-editable intent fields. Plan identity and revision are deliberately
/// absent: AppModel binds those values from the active local plan.
struct AIPlanIntentInput: Codable, Hashable, Sendable {
    var kind: UserIntentKind
    var equipment: [EquipmentAvailability]
    var requestedExerciseId: UUID?
    var requestedChanges: [RequestedChange]
}

struct UserIntent: Codable, Hashable, Sendable {
    var intentId: UUID
    var kind: UserIntentKind
    var requestedDate: String
    var objective: String
    var availableMinutes: Int
    var equipment: [EquipmentAvailability]
    var targetPlanId: UUID?
    var targetPlanRevision: Int?
    var requestedExerciseId: UUID?
    var requestedChanges: [RequestedChange]
    var notes: String?
}

enum EvidenceProvenance: String, Codable, Hashable, Sendable {
    case objectiveHealth = "objective_health"
    case subjectiveUser = "subjective_user"
    case confirmedTraining = "confirmed_training"
    case observedWorkout = "observed_workout"
    case deterministicRule = "deterministic_rule"
}

enum EvidenceQuality: String, Codable, Hashable, Sendable {
    case confirmed
    case partial
    case missing
    case stale
}

struct Evidence: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var provenance: EvidenceProvenance
    var key: String
    var observedAt: String?
    var quality: EvidenceQuality
    var value: JSONValue?
    var source: String
    var note: String?
}

enum DataGapStatus: String, Codable, Hashable, Sendable {
    case missing
    case partial
    case stale
}

struct DataGap: Codable, Hashable, Sendable {
    var key: String
    var status: DataGapStatus
    var note: String?
}

struct ObjectiveHealthContext: Codable, Hashable, Sendable {
    var asOf: String
    var evidenceIds: [String]
}

struct SubjectiveUserContext: Codable, Hashable, Sendable {
    var reportedAt: String
    var evidenceIds: [String]
}

enum ConfirmedTrainingSource: String, Codable, Hashable, Sendable {
    case krisSession = "kris_session"
}

struct ConfirmedTrainingSummary: Codable, Hashable, Identifiable, Sendable {
    var sessionId: UUID
    var date: String
    var title: String
    var status: TrainingSessionStatus
    var source: ConfirmedTrainingSource
    var evidenceIds: [String]

    var id: UUID { sessionId }
}

enum ObservedWorkoutSource: String, Codable, Hashable, Sendable {
    case healthKitObservation = "healthkit_observation"
}

struct ObservedWorkoutSummary: Codable, Hashable, Identifiable, Sendable {
    var observationId: String
    var date: String
    var activityType: String
    var durationMinutes: Int?
    var source: ObservedWorkoutSource
    var evidenceIds: [String]

    var id: String { observationId }
}

struct TrainingHistoryContext: Codable, Hashable, Sendable {
    var confirmedSessions: [ConfirmedTrainingSummary]
    var observedWorkouts: [ObservedWorkoutSummary]
}

struct ProgressionPermission: Codable, Hashable, Sendable {
    var exerciseName: String
    var equipmentVariant: String
    var allowsLoadIncrease: Bool
    var maximumWeightKg: Double?
    var evidenceIds: [String]
}

struct ProgressionContext: Codable, Hashable, Sendable {
    var ruleVersion: String
    var permissions: [ProgressionPermission]
}

enum SafetyDisposition: String, Codable, Hashable, Sendable {
    case allow
    case constrain
    case needsUserInput = "needs_user_input"
    case block
}

enum SafetyRestrictionKind: String, Codable, Hashable, Sendable {
    case prohibitTraining = "prohibit_training"
    case prohibitUnapprovedLoadIncrease = "prohibit_unapproved_load_increase"
    case excludeExercise = "exclude_exercise"
    case prohibitEquipment = "prohibit_equipment"
    case requireSymptomConfirmation = "require_symptom_confirmation"
    case recoveryOnly = "recovery_only"
}

enum SafetyRestrictionSeverity: String, Codable, Hashable, Sendable {
    case advisory
    case constraint
    case block
}

enum SafetyRestrictionAuthority: String, Codable, Hashable, Sendable {
    case localRule = "local_rule"
}

struct SafetyRestriction: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: SafetyRestrictionKind
    var severity: SafetyRestrictionSeverity
    var evidenceIds: [String]
    var authority: SafetyRestrictionAuthority
    var message: String
    var subject: String? = nil
}

struct SafetyContext: Codable, Hashable, Sendable {
    var ruleVersion: String
    var disposition: SafetyDisposition
    var restrictions: [SafetyRestriction]
    var evaluatedAt: String
    var expiresAt: String
}

struct TrainingContext: Codable, Hashable, Sendable {
    var schemaVersion = "TrainingContext.v2"
    var contextId: UUID
    var generatedAt: String
    var expiresAt: String
    var intent: UserIntent
    var objectiveHealth: ObjectiveHealthContext
    var subjectiveUser: SubjectiveUserContext
    var trainingHistory: TrainingHistoryContext
    var progression: ProgressionContext
    var safety: SafetyContext
    var currentPlan: TrainingPlan?
    var evidence: [Evidence]
    var dataGaps: [DataGap]
}

enum AIRecommendationKind: String, Codable, Hashable, Sendable {
    case newPlan = "new_plan"
    case planRevision = "plan_revision"
    case exerciseReplacement = "exercise_replacement"
    case noChange = "no_change"
    case declineUnsafeRequest = "decline_unsafe_request"
}

enum RecommendationConfidence: String, Codable, Hashable, Sendable {
    case low
    case medium
    case high
}

struct RecommendationReason: Codable, Hashable, Sendable {
    var code: String
    var explanation: String
    var evidenceIds: [String]
}

struct RecommendationUncertainty: Codable, Hashable, Sendable {
    var code: String
    var explanation: String
    var evidenceIds: [String] = []
    var dataGapCodes: [String] = []
}

struct AISafetyConsideration: Codable, Hashable, Sendable {
    var code: String
    var explanation: String
    var evidenceIds: [String]
    var restrictionIds: [String] = []
}

struct ProposedPlanAdjustment: Codable, Hashable, Sendable {
    var summary: String
    var plan: AITrainingPlanDraft?
    var evidenceIds: [String] = []
}

struct AlternativeRecommendation: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var summary: String
    var plan: AITrainingPlanDraft?
    var evidenceIds: [String]
}

struct AIInferenceMetadata: Codable, Hashable, Sendable {
    var provider: String
    var model: String
    var promptVersion: String
    var generatedAt: String
}

/// Provider output. Safety restrictions are intentionally absent: only local
/// deterministic rules may create or change them.
struct AIRecommendation: Codable, Hashable, Sendable {
    var schemaVersion = "AIRecommendation.v2"
    var recommendationId: UUID
    var requestId: UUID? = nil
    var contextId: UUID? = nil
    var kind: AIRecommendationKind
    var recommendation: String
    var proposedPlan: AITrainingPlanDraft?
    var reasons: [RecommendationReason]
    var evidenceIds: [String]
    var confidence: RecommendationConfidence
    var uncertainties: [RecommendationUncertainty]
    var optionalAdjustment: ProposedPlanAdjustment?
    var alternatives: [AlternativeRecommendation]
    var safetyConsiderations: [AISafetyConsideration]
    var acknowledgedRestrictionIds: [String]
    var userConfirmationRequired: Bool
    var inferenceMetadata: AIInferenceMetadata? = nil
}

enum UserDecisionKind: String, Codable, Hashable, Sendable {
    case accepted
    case acceptedWithEdits = "accepted_with_edits"
    case rejected
}

struct PlanChange: Codable, Hashable, Sendable {
    var path: String
    var before: String?
    var after: String?
}

struct UserDecision: Codable, Hashable, Sendable {
    var recommendationId: UUID
    var candidateId: UUID
    var kind: UserDecisionKind
    var decidedAt: String
    var acceptedPlanId: UUID?
    var acceptedPlanRevision: Int?
    var edits: [PlanChange]
    var rejectionReason: String?
}

enum AIDecisionValidationCode: String, Codable, Hashable, Sendable {
    case unsupportedSchema = "unsupported_schema"
    case unknownEvidenceReference = "unknown_evidence_reference"
    case duplicateEvidenceId = "duplicate_evidence_id"
    case missingEvidenceHasValue = "missing_evidence_has_value"
    case derivedScoreNotAllowed = "derived_score_not_allowed"
    case userConfirmationRequired = "user_confirmation_required"
    case restrictionNotAcknowledged = "restriction_not_acknowledged"
    case unknownRestrictionAcknowledgement = "unknown_restriction_acknowledgement"
    case trainingProhibited = "training_prohibited"
    case durationExceedsAvailability = "duration_exceeds_availability"
    case equipmentUnavailable = "equipment_unavailable"
    case exerciseExcluded = "exercise_excluded"
    case progressionPermissionMissing = "progression_permission_missing"
    case progressionLimitExceeded = "progression_limit_exceeded"
    case planMissing = "plan_missing"
    case invalidPlan = "invalid_plan"
    case contextExpired = "context_expired"
    case planRevisionChanged = "plan_revision_changed"
    case restrictionSetChanged = "restriction_set_changed"
    case candidateLinkMismatch = "candidate_link_mismatch"
    case userInputRequired = "user_input_required"
    case ruleVersionChanged = "rule_version_changed"
}

struct AIDecisionValidationIssue: Codable, Hashable, Sendable {
    var code: AIDecisionValidationCode
    var path: String
    var message: String
}

struct AIDecisionValidationReport: Codable, Hashable, Sendable {
    var issues: [AIDecisionValidationIssue]

    var isValid: Bool { issues.isEmpty }
    static let valid = AIDecisionValidationReport(issues: [])
}

struct TrainingPlanCandidateV2: Codable, Hashable, Identifiable, Sendable {
    var schemaVersion = "TrainingPlanCandidate.v2"
    var candidateId: UUID
    var context: TrainingContext
    var recommendation: AIRecommendation
    var plan: TrainingPlan
    var status: TrainingPlanCandidateStatus
    var createdAt: String
    var source: String
    var validationReport: AIDecisionValidationReport
    var basedOnPlanId: UUID?
    var basedOnPlanRevision: Int?
    var userDecision: UserDecision?

    var id: UUID { candidateId }
}

enum AIDecisionCandidateFactory {
    static func makeCandidate(
        recommendation: AIRecommendation,
        context: TrainingContext,
        source: String,
        planId: UUID? = nil,
        revision: Int? = nil,
        now: Date = Date()
    ) -> TrainingPlanCandidateV2? {
        let validation = AIDecisionPipelineValidator.validate(
            recommendation: recommendation, context: context
        )
        guard validation.isValid else { return nil }
        if recommendation.kind == .noChange || recommendation.kind == .declineUnsafeRequest {
            guard let currentPlan = context.currentPlan else { return nil }
            return TrainingPlanCandidateV2(
                candidateId: UUID(), context: context, recommendation: recommendation,
                plan: currentPlan, status: .awaitingConfirmation,
                createdAt: ISO8601DateFormatter().string(from: now), source: source,
                validationReport: validation,
                basedOnPlanId: currentPlan.planId,
                basedOnPlanRevision: currentPlan.revision,
                userDecision: nil
            )
        }
        guard let draft = recommendation.proposedPlan else { return nil }
        let revisesCurrentDate = context.currentPlan?.date == context.intent.requestedDate
        let resolvedPlanId = planId
            ?? (revisesCurrentDate ? context.currentPlan?.planId : nil)
            ?? UUID()
        let resolvedRevision = revision
            ?? (revisesCurrentDate ? (context.currentPlan?.revision ?? 0) + 1 : 1)
        let exercises = draft.exercises.enumerated().map { index, item in
            let existingId = context.currentPlan?.exercises.first(where: {
                normalized($0.name) == normalized(item.name)
                    && normalized($0.equipmentVariant) == normalized(item.equipmentVariant)
            })?.exerciseId
            return ExercisePlan(
                exerciseId: existingId ?? UUID(), order: index + 1,
                name: item.name.trimmingCharacters(in: .whitespacesAndNewlines),
                equipmentVariant: item.equipmentVariant.trimmingCharacters(in: .whitespacesAndNewlines),
                targetWeightKg: item.targetWeightKg, sets: item.sets,
                targetReps: item.targetReps, restSeconds: item.restSeconds,
                notes: item.notes, alternative: item.alternative
            )
        }
        let plan = TrainingPlan(
            planId: resolvedPlanId, revision: resolvedRevision,
            date: context.intent.requestedDate,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            estimatedMinutes: draft.estimatedMinutes,
            goal: draft.goal.trimmingCharacters(in: .whitespacesAndNewlines),
            safetyGates: uniqueNonEmpty(context.safety.restrictions.map(\.message)),
            exercises: exercises, publishedAt: nil
        )
        return TrainingPlanCandidateV2(
            candidateId: UUID(), context: context, recommendation: recommendation,
            plan: plan, status: .awaitingConfirmation,
            createdAt: ISO8601DateFormatter().string(from: now), source: source,
            validationReport: validation,
            basedOnPlanId: context.currentPlan?.planId,
            basedOnPlanRevision: context.currentPlan?.revision,
            userDecision: nil
        )
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedValue.isEmpty, seen.insert(normalizedValue).inserted else { return nil }
            return normalizedValue
        }
    }
}

enum AIDecisionPipelineValidator {
    static func validateContext(_ context: TrainingContext) -> AIDecisionValidationReport {
        report(contextIssues(context))
    }

    static func validate(
        recommendation: AIRecommendation,
        context: TrainingContext
    ) -> AIDecisionValidationReport {
        var issues = contextIssues(context)
        if recommendation.schemaVersion != "AIRecommendation.v2"
            || context.schemaVersion != "TrainingContext.v2" {
            issues.append(issue(.unsupportedSchema, "schema_version", "V2 contract schema is required"))
        }
        if !recommendation.userConfirmationRequired {
            issues.append(issue(
                .userConfirmationRequired, "user_confirmation_required",
                "AI recommendations always require explicit user confirmation"
            ))
        }

        let knownEvidence = Set(context.evidence.map(\.id))
        let referencedEvidence = recommendation.evidenceIds
            + recommendation.reasons.flatMap(\.evidenceIds)
            + recommendation.uncertainties.flatMap(\.evidenceIds)
            + (recommendation.optionalAdjustment?.evidenceIds ?? [])
            + recommendation.safetyConsiderations.flatMap(\.evidenceIds)
            + recommendation.alternatives.flatMap(\.evidenceIds)
        for evidenceId in Set(referencedEvidence).subtracting(knownEvidence).sorted() {
            issues.append(issue(
                .unknownEvidenceReference, "evidence_ids", "Unknown evidence reference: \(evidenceId)"
            ))
        }

        let restrictionIds = Set(context.safety.restrictions.map(\.id))
        let acknowledged = Set(recommendation.acknowledgedRestrictionIds)
        for restrictionId in restrictionIds.subtracting(acknowledged).sorted() {
            issues.append(issue(
                .restrictionNotAcknowledged, "acknowledged_restriction_ids",
                "Local restriction was not acknowledged: \(restrictionId)"
            ))
        }
        for restrictionId in acknowledged.subtracting(restrictionIds).sorted() {
            issues.append(issue(
                .unknownRestrictionAcknowledgement, "acknowledged_restriction_ids",
                "Unknown local restriction: \(restrictionId)"
            ))
        }

        if context.safety.disposition == .block
            || context.safety.restrictions.contains(where: {
                $0.kind == .prohibitTraining || $0.severity == .block
            }) {
            issues.append(issue(.trainingProhibited, "safety", "Local safety rules prohibit training"))
        }
        if context.safety.disposition == .needsUserInput {
            issues.append(issue(
                .userInputRequired, "safety", "Additional user input is required before AI reasoning"
            ))
        }

        if let draft = recommendation.proposedPlan {
            issues.append(contentsOf: planIssues(draft: draft, context: context))
        } else if recommendation.kind != .noChange && recommendation.kind != .declineUnsafeRequest {
            issues.append(issue(.planMissing, "proposed_plan", "Recommendation requires a proposed plan"))
        }
        return report(issues)
    }

    static func revalidateForAcceptance(
        candidate: TrainingPlanCandidateV2,
        currentContext: TrainingContext,
        now: Date
    ) -> AIDecisionValidationReport {
        var issues = validate(
            recommendation: candidate.recommendation,
            context: currentContext
        ).issues
        if candidate.recommendation.kind != .noChange
            && candidate.recommendation.kind != .declineUnsafeRequest {
            issues.append(contentsOf: planIssues(plan: candidate.plan, context: currentContext))
        }

        guard candidate.schemaVersion == "TrainingPlanCandidate.v2" else {
            issues.append(issue(.unsupportedSchema, "schema_version", "V2 candidate schema is required"))
            return report(issues)
        }
        if isExpired(candidate.context.expiresAt, now: now)
            || isExpired(candidate.context.safety.expiresAt, now: now)
            || isExpired(currentContext.expiresAt, now: now)
            || isExpired(currentContext.safety.expiresAt, now: now) {
            issues.append(issue(.contextExpired, "expires_at", "Decision context has expired"))
        }

        let currentPlan = currentContext.currentPlan
        if candidate.basedOnPlanId != currentPlan?.planId
            || candidate.basedOnPlanRevision != currentPlan?.revision
            || currentContext.intent.targetPlanId != currentPlan?.planId
            || currentContext.intent.targetPlanRevision != currentPlan?.revision {
            issues.append(issue(
                .planRevisionChanged, "based_on_plan_revision",
                "Current plan identity or revision changed after recommendation generation"
            ))
        }

        let originalRestrictions = Set(candidate.context.safety.restrictions)
        let currentRestrictions = Set(currentContext.safety.restrictions)
        if originalRestrictions != currentRestrictions {
            issues.append(issue(
                .restrictionSetChanged, "safety.restrictions",
                "Local safety restrictions changed after recommendation generation"
            ))
        }
        if candidate.context.safety.ruleVersion != currentContext.safety.ruleVersion
            || candidate.context.progression.ruleVersion != currentContext.progression.ruleVersion {
            issues.append(issue(
                .ruleVersionChanged, "rule_version",
                "Local safety or progression rule version changed after generation"
            ))
        }
        if candidate.context.contextId != currentContext.contextId
            && candidate.context.intent.intentId != currentContext.intent.intentId {
            issues.append(issue(
                .candidateLinkMismatch, "context_id", "Candidate does not belong to the active intent"
            ))
        }
        return report(issues)
    }

    private static func contextIssues(_ context: TrainingContext) -> [AIDecisionValidationIssue] {
        var issues: [AIDecisionValidationIssue] = []
        let ids = context.evidence.map(\.id)
        if Set(ids).count != ids.count {
            issues.append(issue(.duplicateEvidenceId, "evidence", "Evidence IDs must be unique"))
        }
        let forbiddenKeys = Set([
            "readiness", "readinessscore", "recovery", "recoveryscore",
            "statusscore", "bodyscore", "bodystatescore",
        ])
        for item in context.evidence {
            if item.quality == .missing, item.value != nil {
                issues.append(issue(
                    .missingEvidenceHasValue, "evidence.\(item.id).value",
                    "Missing evidence must remain unknown"
                ))
            }
            if forbiddenKeys.contains(normalizedScoreKey(item.key)) {
                issues.append(issue(
                    .derivedScoreNotAllowed, "evidence.\(item.id).key",
                    "Derived body-state scores are not accepted in V2 context"
                ))
            }
        }
        for gap in context.dataGaps where forbiddenKeys.contains(normalizedScoreKey(gap.key)) {
            issues.append(issue(
                .derivedScoreNotAllowed, "data_gaps.\(gap.key)",
                "Derived body-state scores are not accepted in V2 context"
            ))
        }
        let evidenceByID = Dictionary(
            context.evidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sections: [([String], Set<EvidenceProvenance>, String)] = [
            (context.objectiveHealth.evidenceIds, [.objectiveHealth], "objective_health"),
            (context.subjectiveUser.evidenceIds, [.subjectiveUser], "subjective_user"),
            (context.trainingHistory.confirmedSessions.flatMap(\.evidenceIds), [.confirmedTraining], "confirmed_sessions"),
            (context.trainingHistory.observedWorkouts.flatMap(\.evidenceIds), [.observedWorkout], "observed_workouts"),
            (context.progression.permissions.flatMap(\.evidenceIds), [.confirmedTraining, .deterministicRule], "progression"),
            (context.safety.restrictions.flatMap(\.evidenceIds), [.objectiveHealth, .subjectiveUser, .deterministicRule], "safety"),
        ]
        for (references, allowed, path) in sections {
            for reference in references {
                guard let evidence = evidenceByID[reference] else {
                    issues.append(issue(
                        .unknownEvidenceReference, path, "Unknown context evidence reference: \(reference)"
                    ))
                    continue
                }
                if !allowed.contains(evidence.provenance) {
                    issues.append(issue(
                        .unknownEvidenceReference, path,
                        "Evidence provenance is incompatible with context section: \(reference)"
                    ))
                }
            }
        }
        return issues
    }

    private static func planIssues(
        draft: AITrainingPlanDraft,
        context: TrainingContext
    ) -> [AIDecisionValidationIssue] {
        let plan = TrainingPlan(
            planId: UUID(), revision: 1, date: context.intent.requestedDate,
            title: draft.title, estimatedMinutes: draft.estimatedMinutes,
            goal: draft.goal, safetyGates: [],
            exercises: draft.exercises.enumerated().map { index, exercise in
                ExercisePlan(
                    exerciseId: UUID(), order: index + 1, name: exercise.name,
                    equipmentVariant: exercise.equipmentVariant,
                    targetWeightKg: exercise.targetWeightKg, sets: exercise.sets,
                    targetReps: exercise.targetReps, restSeconds: exercise.restSeconds,
                    notes: exercise.notes, alternative: exercise.alternative
                )
            }, publishedAt: nil
        )
        return planIssues(plan: plan, context: context)
    }

    private static func planIssues(
        plan: TrainingPlan,
        context: TrainingContext
    ) -> [AIDecisionValidationIssue] {
        var issues: [AIDecisionValidationIssue] = []
        if !(10...180).contains(plan.estimatedMinutes)
            || plan.exercises.isEmpty || plan.exercises.count > 12
            || plan.exercises.contains(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || $0.equipmentVariant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(1...10).contains($0.sets)
                    || !(1...50).contains($0.targetReps)
                    || !(0...600).contains($0.restSeconds)
                    || $0.targetWeightKg.map { !$0.isFinite || !(0...500).contains($0) } == true
            }) {
            issues.append(issue(.invalidPlan, "plan", "Plan contains invalid exercise parameters"))
        }
        if plan.estimatedMinutes > context.intent.availableMinutes {
            issues.append(issue(
                .durationExceedsAvailability, "plan.estimated_minutes",
                "Plan duration exceeds user availability"
            ))
        }

        let unavailableEquipment = Set(context.intent.equipment.compactMap {
            $0.status == .unavailable ? normalized($0.name) : nil
        })
        let prohibitedEquipment = Set(context.safety.restrictions.compactMap {
            $0.kind == .prohibitEquipment ? $0.subject.map(normalized) : nil
        })
        let excludedExercises = Set(context.safety.restrictions.compactMap {
            $0.kind == .excludeExercise ? $0.subject.map(normalized) : nil
        })
        for exercise in plan.exercises {
            if unavailableEquipment.contains(normalized(exercise.equipmentVariant))
                || prohibitedEquipment.contains(normalized(exercise.equipmentVariant)) {
                issues.append(issue(
                    .equipmentUnavailable, "plan.exercises.\(exercise.order).equipment_variant",
                    "Equipment is unavailable or prohibited: \(exercise.equipmentVariant)"
                ))
            }
            if excludedExercises.contains(normalized(exercise.name)) {
                issues.append(issue(
                    .exerciseExcluded, "plan.exercises.\(exercise.order).name",
                    "Exercise is excluded by a local restriction: \(exercise.name)"
                ))
            }
            guard let proposedWeight = exercise.targetWeightKg,
                  let previous = matchingExercise(exercise, in: context.currentPlan),
                  let previousWeight = previous.targetWeightKg,
                  proposedWeight > previousWeight + 0.000_001 else { continue }
            guard let permission = context.progression.permissions.first(where: {
                normalized($0.exerciseName) == normalized(exercise.name)
                    && normalized($0.equipmentVariant) == normalized(exercise.equipmentVariant)
                    && $0.allowsLoadIncrease
            }) else {
                issues.append(issue(
                    .progressionPermissionMissing, "plan.exercises.\(exercise.order).target_weight_kg",
                    "Load increase lacks a matching local progression permission"
                ))
                continue
            }
            if let maximum = permission.maximumWeightKg, proposedWeight > maximum + 0.000_001 {
                issues.append(issue(
                    .progressionLimitExceeded, "plan.exercises.\(exercise.order).target_weight_kg",
                    "Load increase exceeds the local progression limit"
                ))
            }
        }
        return issues
    }

    private static func matchingExercise(
        _ exercise: ExercisePlan,
        in plan: TrainingPlan?
    ) -> ExercisePlan? {
        plan?.exercises.first {
            normalized($0.name) == normalized(exercise.name)
                && normalized($0.equipmentVariant) == normalized(exercise.equipmentVariant)
        }
    }

    private static func isExpired(_ value: String, now: Date) -> Bool {
        guard let date = ISO8601DateFormatter().date(from: value) else { return true }
        return date <= now
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedScoreKey(_ value: String) -> String {
        normalized(value)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func issue(
        _ code: AIDecisionValidationCode,
        _ path: String,
        _ message: String
    ) -> AIDecisionValidationIssue {
        AIDecisionValidationIssue(code: code, path: path, message: message)
    }

    private static func report(
        _ issues: [AIDecisionValidationIssue]
    ) -> AIDecisionValidationReport {
        AIDecisionValidationReport(
            issues: Array(Set(issues)).sorted {
                ($0.code.rawValue, $0.path, $0.message) < ($1.code.rawValue, $1.path, $1.message)
            }
        )
    }
}

enum AIPlanPolicy {
    static let responseSchemaVersion = "AIPlanResponse.v1"
    static let promptVersion = "training_plan_candidate.zh-CN.v1"

    static func draftErrors(
        _ response: AIPlanResponseEnvelope,
        input: AIPlanUserInput
    ) -> [String] {
        var errors: [String] = []
        if response.schemaVersion != responseSchemaVersion {
            errors.append("AI 返回的结构版本不支持")
        }
        if response.plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("计划标题不能为空")
        }
        if !(10...120).contains(response.plan.estimatedMinutes) {
            errors.append("预计时长必须在 10–120 分钟之间")
        }
        if response.plan.estimatedMinutes > input.availableMinutes {
            errors.append("计划时长超过用户可用时间")
        }
        if response.plan.exercises.isEmpty || response.plan.exercises.count > 12 {
            errors.append("计划动作数量必须在 1–12 个之间")
        }
        for exercise in response.plan.exercises {
            if exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("动作名称不能为空")
            }
            if exercise.equipmentVariant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("器械类型不能为空")
            }
            if !(1...10).contains(exercise.sets) {
                errors.append("单个动作组数必须在 1–10 组之间")
            }
            if !(1...50).contains(exercise.targetReps) {
                errors.append("单组次数必须在 1–50 次之间")
            }
            if !(0...600).contains(exercise.restSeconds) {
                errors.append("组间休息必须在 0–600 秒之间")
            }
            if let weight = exercise.targetWeightKg,
               !weight.isFinite || !(0...500).contains(weight) {
                errors.append("目标重量超出可接受范围")
            }
        }
        if input.symptoms != .noneReported {
            errors.append("存在未排除的不适或安全症状，不能生成训练处方")
        }
        return Array(Set(errors)).sorted()
    }

    static func makeCandidate(
        response: AIPlanResponseEnvelope,
        context: AIRedactedPlanContext,
        model: String,
        previousPlan: TrainingPlan?,
        now: Date = Date()
    ) -> TrainingPlanCandidate? {
        guard draftErrors(response, input: context.userInput).isEmpty else { return nil }
        let mandatoryGates = [
            context.localDecision.rollbackCondition,
            "出现胸痛、晕厥、明显呼吸困难、异常心悸，或放射痛、麻木、无力时立即停止训练并及时就医。",
        ]
        let gates = uniqueNonEmpty(response.plan.safetyGates + response.cautions + mandatoryGates)
        let exercises = response.plan.exercises.enumerated().map { index, exercise in
            ExercisePlan(
                exerciseId: UUID(), order: index + 1,
                name: exercise.name.trimmingCharacters(in: .whitespacesAndNewlines),
                equipmentVariant: exercise.equipmentVariant.trimmingCharacters(in: .whitespacesAndNewlines),
                targetWeightKg: exercise.targetWeightKg,
                sets: exercise.sets, targetReps: exercise.targetReps,
                restSeconds: exercise.restSeconds,
                notes: exercise.notes,
                alternative: exercise.alternative?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let sameDate = previousPlan?.date == context.userInput.date
        let plan = TrainingPlan(
            planId: sameDate ? previousPlan?.planId ?? UUID() : UUID(),
            revision: sameDate ? (previousPlan?.revision ?? 0) + 1 : 1,
            date: context.userInput.date,
            title: response.plan.title.trimmingCharacters(in: .whitespacesAndNewlines),
            estimatedMinutes: response.plan.estimatedMinutes,
            goal: response.plan.goal.trimmingCharacters(in: .whitespacesAndNewlines),
            safetyGates: gates,
            exercises: exercises,
            publishedAt: nil
        )
        return TrainingPlanCandidate(
            candidateId: UUID(), plan: plan, status: .awaitingConfirmation,
            createdAt: DateFormatting.iso(now),
            source: "kris-ai:\(model):\(promptVersion)",
            decisionRuleVersion: context.localDecision.ruleVersion
        )
    }

    static func publicationErrors(
        _ candidate: TrainingPlanCandidate,
        currentSafetyGate: String?
    ) -> [String] {
        var errors = TrainingPlanCandidateValidation.errors(candidate)
        guard candidate.source.hasPrefix("kris-ai:") || candidate.source.hasPrefix("deepseek:") else {
            return errors
        }
        if candidate.decisionRuleVersion != LocalPlanEngine.ruleVersion {
            errors.append("本地训练规则版本已变化，请重新生成候选计划")
        }
        if currentSafetyGate == "stop_and_seek_care" {
            errors.append("当前存在安全停止信号，不能采用 AI 候选计划")
        }
        if candidate.plan.safetyGates.isEmpty {
            errors.append("AI 候选计划缺少安全门槛")
        }
        if !(10...120).contains(candidate.plan.estimatedMinutes)
            || candidate.plan.exercises.isEmpty
            || candidate.plan.exercises.count > 12 {
            errors.append("AI 候选计划超出本地处方范围")
        }
        if candidate.plan.exercises.contains(where: { exercise in
            !(1...10).contains(exercise.sets)
                || !(1...50).contains(exercise.targetReps)
                || !(0...600).contains(exercise.restSeconds)
                || exercise.targetWeightKg.map { !$0.isFinite || !(0...500).contains($0) } == true
        }) {
            errors.append("AI 候选动作参数超出本地处方范围")
        }
        return errors
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}
