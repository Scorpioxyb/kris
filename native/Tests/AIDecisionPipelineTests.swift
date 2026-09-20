import XCTest
@testable import KrisCoach

final class AIDecisionPipelineTests: XCTestCase {
    func testV2ContextJSONContainsFactsButNoReadinessOrRecoveryScore() throws {
        let context = makeContext()

        let data = try ContractCoding.encoder.encode(context)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(json["schema_version"] as? String, "TrainingContext.v2")
        XCTAssertTrue(encoded.contains("sleep_duration"))
        XCTAssertFalse(encoded.lowercased().contains("readiness"))
        XCTAssertFalse(encoded.lowercased().contains("recovery_score"))
    }

    func testV2ValidatorRejectsAllDerivedBodyStateScoreAliases() {
        for forbiddenKey in [
            "readiness", "readiness_score", "recovery", "recovery_score",
            "status_score", "status-score", "body_score", "body_state_score",
            "BodyStateScore",
        ] {
            var context = makeContext()
            context.evidence.append(Evidence(
                id: "objective.forbidden.\(forbiddenKey)", provenance: .objectiveHealth,
                key: forbiddenKey, observedAt: "2026-09-20T08:00:00Z",
                quality: .confirmed, value: .number(42), source: "local", note: nil
            ))
            let report = AIDecisionPipelineValidator.validate(
                recommendation: makeRecommendation(context: context), context: context
            )

            XCTAssertTrue(
                report.issues.contains { $0.code == .derivedScoreNotAllowed },
                "Expected \(forbiddenKey) to be rejected"
            )
        }
    }

    func testV2ValidatorRejectsDerivedBodyStateScoreDataGap() {
        var context = makeContext()
        context.dataGaps.append(DataGap(
            key: "status_score", status: .missing, note: "must remain absent"
        ))

        let report = AIDecisionPipelineValidator.validateContext(context)

        XCTAssertTrue(report.issues.contains { $0.code == .derivedScoreNotAllowed })
    }

    func testEvidenceProvenanceAndMissingValueRoundTripWithoutInventingAValue() throws {
        let missingSleep = Evidence(
            id: "objective.sleep.missing", provenance: .objectiveHealth,
            key: "sleep_duration", observedAt: nil, quality: .missing,
            value: nil, source: "healthkit", note: "no covered sample"
        )
        let energy = Evidence(
            id: "subjective.energy.low", provenance: .subjectiveUser,
            key: "user_reported_energy", observedAt: "2026-09-20T08:00:00Z",
            quality: .confirmed, value: .string("low"), source: "user", note: nil
        )

        let data = try ContractCoding.encoder.encode([missingSleep, energy])
        let decoded = try ContractCoding.decoder.decode([Evidence].self, from: data)

        XCTAssertEqual(decoded[0].provenance, .objectiveHealth)
        XCTAssertEqual(decoded[0].quality, .missing)
        XCTAssertNil(decoded[0].value)
        XCTAssertEqual(decoded[1].provenance, .subjectiveUser)
        XCTAssertEqual(decoded[1].value, .string("low"))
    }

    func testTrainingHistorySeparatesConfirmedSessionsFromObservedWorkouts() throws {
        let context = makeContext()

        XCTAssertEqual(context.trainingHistory.confirmedSessions.count, 1)
        XCTAssertEqual(context.trainingHistory.observedWorkouts.count, 1)
        XCTAssertEqual(context.trainingHistory.confirmedSessions[0].source, .krisSession)
        XCTAssertEqual(context.trainingHistory.observedWorkouts[0].source, .healthKitObservation)

        let decoded = try ContractCoding.decoder.decode(
            TrainingContext.self,
            from: ContractCoding.encoder.encode(context)
        )
        XCTAssertEqual(decoded.trainingHistory, context.trainingHistory)
    }

    func testRecommendationRejectsUnknownEvidenceReference() {
        let context = makeContext()
        var recommendation = makeRecommendation(context: context)
        recommendation.reasons[0].evidenceIds = ["evidence.does.not.exist"]

        let report = AIDecisionPipelineValidator.validate(
            recommendation: recommendation, context: context
        )

        XCTAssertTrue(report.issues.contains { $0.code == .unknownEvidenceReference })
    }

    func testAIRecommendationCannotContainOrCreateSafetyRestrictions() throws {
        let context = makeContext()
        var recommendation = makeRecommendation(context: context)
        recommendation.proposedPlan?.safetyGates = ["AI-created gate"]

        let data = try ContractCoding.encoder.encode(recommendation)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let candidate = try XCTUnwrap(AIDecisionCandidateFactory.makeCandidate(
            recommendation: recommendation, context: context,
            source: "kris-ai:v2", now: Date(timeIntervalSince1970: 1_758_355_800)
        ))

        XCTAssertFalse(json.contains("safety_restrictions"))
        XCTAssertEqual(recommendation.acknowledgedRestrictionIds, ["restriction.no_unapproved_load_increase"])
        XCTAssertEqual(context.safety.restrictions.count, 1)
        XCTAssertEqual(context.safety.restrictions[0].authority, .localRule)
        XCTAssertEqual(candidate.plan.safetyGates, ["未通过同器械进阶规则时不得加重"])
        XCTAssertFalse(candidate.plan.safetyGates.contains("AI-created gate"))
    }

    func testLoadIncreaseRequiresMatchingLocalProgressionPermission() {
        var context = makeContext()
        context.progression.permissions = []
        var recommendation = makeRecommendation(context: context)
        recommendation.proposedPlan?.exercises[0].targetWeightKg = 65

        let blocked = AIDecisionPipelineValidator.validate(
            recommendation: recommendation, context: context
        )
        XCTAssertTrue(blocked.issues.contains { $0.code == .progressionPermissionMissing })

        context.progression.permissions = [
            ProgressionPermission(
                exerciseName: "卧推", equipmentVariant: "杠铃",
                allowsLoadIncrease: true, maximumWeightKg: 65,
                evidenceIds: ["training.bench.latest"]
            )
        ]
        let allowed = AIDecisionPipelineValidator.validate(
            recommendation: recommendation, context: context
        )
        XCTAssertFalse(allowed.issues.contains { $0.code == .progressionPermissionMissing })
        XCTAssertFalse(allowed.issues.contains { $0.code == .progressionLimitExceeded })
    }

    func testRecommendationEnforcesAvailableTimeAndEquipment() {
        var context = makeContext()
        context.intent.availableMinutes = 30
        context.intent.equipment = [
            EquipmentAvailability(name: "杠铃", status: .unavailable),
            EquipmentAvailability(name: "自重", status: .available),
        ]
        var recommendation = makeRecommendation(context: context)
        recommendation.proposedPlan?.estimatedMinutes = 45

        let report = AIDecisionPipelineValidator.validate(
            recommendation: recommendation, context: context
        )

        XCTAssertTrue(report.issues.contains { $0.code == .durationExceedsAvailability })
        XCTAssertTrue(report.issues.contains { $0.code == .equipmentUnavailable })
    }

    func testAcceptTimeRevalidationRejectsExpiredContextPlanDriftAndNewRestriction() {
        let original = makeContext()
        let recommendation = makeRecommendation(context: original)
        let candidate = makeCandidate(context: original, recommendation: recommendation)

        var current = original
        current.currentPlan?.revision = 4
        current.safety.restrictions.append(
            SafetyRestriction(
                id: "restriction.stop", kind: .prohibitTraining, severity: .block,
                evidenceIds: ["subjective.energy.normal"], authority: .localRule,
                message: "stop"
            )
        )
        let report = AIDecisionPipelineValidator.revalidateForAcceptance(
            candidate: candidate,
            currentContext: current,
            now: ISO8601DateFormatter().date(from: "2026-09-20T12:30:00Z")!
        )

        XCTAssertTrue(report.issues.contains { $0.code == .contextExpired })
        XCTAssertTrue(report.issues.contains { $0.code == .planRevisionChanged })
        XCTAssertTrue(report.issues.contains { $0.code == .restrictionSetChanged })
        XCTAssertTrue(report.issues.contains { $0.code == .trainingProhibited })
    }

    func testAcceptTimeRevalidationRejectsChangedRestrictionContentAndExpiredCurrentContext() {
        let original = makeContext()
        let recommendation = makeRecommendation(context: original)
        let candidate = makeCandidate(context: original, recommendation: recommendation)

        var current = original
        current.contextId = UUID()
        current.safety.expiresAt = "2026-09-20T10:00:00Z"
        current.safety.restrictions[0].severity = .advisory
        current.safety.restrictions[0].message = "限制内容已重新评估"

        let report = AIDecisionPipelineValidator.revalidateForAcceptance(
            candidate: candidate,
            currentContext: current,
            now: ISO8601DateFormatter().date(from: "2026-09-20T11:00:00Z")!
        )

        XCTAssertTrue(report.issues.contains { $0.code == .contextExpired })
        XCTAssertTrue(report.issues.contains { $0.code == .restrictionSetChanged })
        XCTAssertFalse(report.issues.contains { $0.code == .candidateLinkMismatch })
    }

    func testUserDecisionAndV2CandidatePayloadRoundTripWhileV1StillDecodes() throws {
        let context = makeContext()
        let recommendation = makeRecommendation(context: context)
        var candidate = makeCandidate(context: context, recommendation: recommendation)
        candidate.userDecision = UserDecision(
            recommendationId: recommendation.recommendationId,
            candidateId: candidate.candidateId,
            kind: .acceptedWithEdits,
            decidedAt: "2026-09-20T09:10:00Z",
            acceptedPlanId: candidate.plan.planId,
            acceptedPlanRevision: candidate.plan.revision,
            edits: [PlanChange(path: "exercises[0].sets", before: "3", after: "2")],
            rejectionReason: nil
        )

        let decodedV2 = try ContractCoding.decoder.decode(
            TrainingPlanCandidateV2.self,
            from: ContractCoding.encoder.encode(candidate)
        )
        XCTAssertEqual(decodedV2, candidate)
        XCTAssertEqual(decodedV2.userDecision?.kind, .acceptedWithEdits)

        let legacy = TrainingPlanCandidate(
            candidateId: UUID(), plan: candidate.plan, status: .awaitingConfirmation,
            createdAt: "2026-09-20T09:00:00Z", source: "local_user",
            decisionRuleVersion: LocalPlanEngine.ruleVersion
        )
        let decodedV1 = try ContractCoding.decoder.decode(
            TrainingPlanCandidate.self,
            from: ContractCoding.encoder.encode(legacy)
        )
        XCTAssertEqual(decodedV1, legacy)
    }

    private func makeContext() -> TrainingContext {
        let currentPlan = TrainingPlan(
            planId: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            revision: 3, date: "2026-09-20", title: "上肢训练", estimatedMinutes: 45,
            goal: "减脂保肌", safetyGates: ["不适时停止"],
            exercises: [ExercisePlan(
                exerciseId: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                order: 1, name: "卧推", equipmentVariant: "杠铃", targetWeightKg: 60,
                sets: 3, targetReps: 8, restSeconds: 120, notes: nil, alternative: "俯卧撑"
            )], publishedAt: "2026-09-19T10:00:00Z"
        )
        let intent = UserIntent(
            intentId: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            kind: .revisePlan, requestedDate: "2026-09-20", objective: "减脂保肌",
            availableMinutes: 45,
            equipment: [EquipmentAvailability(name: "杠铃", status: .available)],
            targetPlanId: currentPlan.planId, targetPlanRevision: currentPlan.revision,
            requestedExerciseId: nil, requestedChanges: [], notes: nil
        )
        let evidence = [
            Evidence(
                id: "objective.sleep.duration", provenance: .objectiveHealth,
                key: "sleep_duration", observedAt: "2026-09-20T07:00:00Z",
                quality: .confirmed, value: .number(6.33), source: "healthkit", note: nil
            ),
            Evidence(
                id: "subjective.energy.normal", provenance: .subjectiveUser,
                key: "user_reported_energy", observedAt: "2026-09-20T08:00:00Z",
                quality: .confirmed, value: .string("normal"), source: "user", note: nil
            ),
            Evidence(
                id: "training.bench.latest", provenance: .confirmedTraining,
                key: "bench_press_sets", observedAt: "2026-09-18T10:00:00Z",
                quality: .confirmed, value: .string("60kg x 8 x 3"), source: "kris_session", note: nil
            ),
            Evidence(
                id: "rule.no_unapproved_load", provenance: .deterministicRule,
                key: "unapproved_load_increase_prohibited",
                observedAt: "2026-09-20T08:00:00Z", quality: .confirmed,
                value: .bool(true), source: "local_rule", note: nil
            ),
        ]
        return TrainingContext(
            contextId: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
            generatedAt: "2026-09-20T08:00:00Z", expiresAt: "2026-09-20T12:00:00Z",
            intent: intent,
            objectiveHealth: ObjectiveHealthContext(
                asOf: "2026-09-20T08:00:00Z", evidenceIds: ["objective.sleep.duration"]
            ),
            subjectiveUser: SubjectiveUserContext(
                reportedAt: "2026-09-20T08:00:00Z", evidenceIds: ["subjective.energy.normal"]
            ),
            trainingHistory: TrainingHistoryContext(
                confirmedSessions: [ConfirmedTrainingSummary(
                    sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000105")!,
                    date: "2026-09-18", title: "上肢", status: .completed,
                    source: .krisSession, evidenceIds: ["training.bench.latest"]
                )],
                observedWorkouts: [ObservedWorkoutSummary(
                    observationId: "healthkit-workout-1", date: "2026-09-19",
                    activityType: "walking", durationMinutes: 32,
                    source: .healthKitObservation, evidenceIds: []
                )]
            ),
            progression: ProgressionContext(
                ruleVersion: "gated_double_progression_v1",
                permissions: [ProgressionPermission(
                    exerciseName: "卧推", equipmentVariant: "杠铃",
                    allowsLoadIncrease: false, maximumWeightKg: nil,
                    evidenceIds: ["training.bench.latest"]
                )]
            ),
            safety: SafetyContext(
                ruleVersion: LocalPlanEngine.ruleVersion, disposition: .allow,
                restrictions: [SafetyRestriction(
                    id: "restriction.no_unapproved_load_increase",
                    kind: .prohibitUnapprovedLoadIncrease, severity: .constraint,
                    evidenceIds: ["rule.no_unapproved_load"], authority: .localRule,
                    message: "未通过同器械进阶规则时不得加重"
                )], evaluatedAt: "2026-09-20T08:00:00Z",
                expiresAt: "2026-09-20T12:00:00Z"
            ),
            currentPlan: currentPlan, evidence: evidence,
            dataGaps: [DataGap(key: "sleep_stages", status: .missing, note: "not required")]
        )
    }

    private func makeRecommendation(context: TrainingContext) -> AIRecommendation {
        AIRecommendation(
            recommendationId: UUID(uuidString: "00000000-0000-0000-0000-000000000106")!,
            kind: .planRevision, recommendation: "保持当前卧推重量",
            proposedPlan: AITrainingPlanDraft(
                title: "上肢训练", estimatedMinutes: 45, goal: "减脂保肌",
                safetyGates: [],
                exercises: [AIExerciseDraft(
                    name: "卧推", equipmentVariant: "杠铃", targetWeightKg: 60,
                    sets: 3, targetReps: 8, restSeconds: 120,
                    notes: ["保持动作质量"], alternative: "俯卧撑"
                )]
            ),
            reasons: [RecommendationReason(
                code: "maintain_latest_load", explanation: "最近实绩为 60kg x 8 x 3",
                evidenceIds: ["training.bench.latest"]
            )],
            evidenceIds: ["training.bench.latest", "subjective.energy.normal"],
            confidence: .medium,
            uncertainties: [RecommendationUncertainty(code: "sleep_stage_missing", explanation: "睡眠分期缺失")],
            optionalAdjustment: nil, alternatives: [],
            safetyConsiderations: [AISafetyConsideration(
                code: "stop_on_discomfort", explanation: "出现不适时停止",
                evidenceIds: ["subjective.energy.normal"]
            )],
            acknowledgedRestrictionIds: context.safety.restrictions.map(\.id),
            userConfirmationRequired: true
        )
    }

    private func makeCandidate(
        context: TrainingContext, recommendation: AIRecommendation
    ) -> TrainingPlanCandidateV2 {
        let plan = TrainingPlan(
            planId: UUID(uuidString: "00000000-0000-0000-0000-000000000107")!,
            revision: 4, date: context.intent.requestedDate,
            title: recommendation.proposedPlan!.title,
            estimatedMinutes: recommendation.proposedPlan!.estimatedMinutes,
            goal: recommendation.proposedPlan!.goal,
            safetyGates: context.safety.restrictions.map(\.message),
            exercises: recommendation.proposedPlan!.exercises.enumerated().map { index, draft in
                ExercisePlan(
                    exerciseId: UUID(), order: index + 1, name: draft.name,
                    equipmentVariant: draft.equipmentVariant,
                    targetWeightKg: draft.targetWeightKg, sets: draft.sets,
                    targetReps: draft.targetReps, restSeconds: draft.restSeconds,
                    notes: draft.notes, alternative: draft.alternative
                )
            }, publishedAt: nil
        )
        return TrainingPlanCandidateV2(
            candidateId: UUID(uuidString: "00000000-0000-0000-0000-000000000108")!,
            context: context, recommendation: recommendation, plan: plan,
            status: .awaitingConfirmation, createdAt: "2026-09-20T09:00:00Z",
            source: "kris-ai:v2", validationReport: .valid,
            basedOnPlanId: context.currentPlan?.planId,
            basedOnPlanRevision: context.currentPlan?.revision,
            userDecision: nil
        )
    }
}
