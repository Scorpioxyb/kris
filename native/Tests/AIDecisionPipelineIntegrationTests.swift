import SwiftData
import XCTest
@testable import KrisCoach

private actor AIV2RequestRecorder {
    private var responses: [(status: Int, data: Data)]
    private var requests: [URLRequest] = []

    init(responses: [(status: Int, data: Data)]) {
        self.responses = responses
    }

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let response = responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        return (response.data, http)
    }

    func lastRequest() -> URLRequest? { requests.last }
}

final class AIDecisionPipelineIntegrationTests: XCTestCase {
    private enum ExpectedPersistenceFailure: Error { case save }

    @MainActor
    func testAppModelBuildsV2ContextWithoutReadinessAndKeepsMissingHealthUnknown() throws {
        let model = AppModel(inMemory: true)
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        let context = model.makeAITrainingContext(
            input: makeInput(symptoms: .noneReported), now: now
        )

        let encoded = try ContractCoding.encoder.encode(context)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8)).lowercased()

        XCTAssertFalse(json.contains("readiness"))
        XCTAssertFalse(json.contains("recovery_score"))
        let sleep = try XCTUnwrap(context.evidence.first { $0.key == "sleep_duration" })
        XCTAssertEqual(sleep.quality, .missing)
        XCTAssertNil(sleep.value)
        XCTAssertTrue(context.trainingHistory.confirmedSessions.isEmpty)
        XCTAssertTrue(context.trainingHistory.observedWorkouts.isEmpty)
        let loadRestriction = try XCTUnwrap(context.safety.restrictions.first {
            $0.kind == .prohibitUnapprovedLoadIncrease
        })
        let restrictionEvidence = context.evidence.filter {
            loadRestriction.evidenceIds.contains($0.id)
        }
        XCTAssertEqual(restrictionEvidence.map(\.provenance), [.deterministicRule])
    }

    @MainActor
    func testConfirmedTrainingOutcomeFeedsActualSetPerformanceIntoFutureContext() throws {
        let model = AppModel(inMemory: true)
        let session = TrainingSessionContract(
            sessionId: UUID(), planId: UUID(), planRevision: 2,
            startedAt: "2026-09-18T10:00:00Z", endedAt: "2026-09-18T11:00:00Z",
            status: .completed,
            exerciseResults: [ExerciseResult(
                exerciseId: UUID(), name: "卧推", equipmentVariant: "杠铃",
                sets: [
                    CompletedSet(
                        setId: UUID(), setNumber: 1, weightKg: 60, reps: 8,
                        completedAt: "2026-09-18T10:20:00Z", lastSetFeeling: nil
                    ),
                    CompletedSet(
                        setId: UUID(), setNumber: 2, weightKg: 60, reps: 8,
                        completedAt: "2026-09-18T10:24:00Z", lastSetFeeling: nil
                    ),
                    CompletedSet(
                        setId: UUID(), setNumber: 3, weightKg: 60, reps: 7,
                        completedAt: "2026-09-18T10:28:00Z", lastSetFeeling: .appropriate
                    ),
                ]
            )],
            feedback: SessionFeedback(
                energy: .normal, targetMuscleResponse: .good,
                symptoms: "", notes: ""
            ),
            watchWorkoutUuid: nil, workout: nil
        )
        let payload = try ContractCoding.encoder.encode(session)
        model.container.mainContext.insert(ArchivedSessionRecord(
            sessionId: session.sessionId, payload: payload,
            endedAt: try XCTUnwrap(DateFormatting.parse(session.endedAt))
        ))
        try model.container.mainContext.save()

        let context = model.makeAITrainingContext(
            input: makeInput(symptoms: .noneReported),
            now: try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        )
        let performance = try XCTUnwrap(context.evidence.first {
            $0.provenance == .confirmedTraining && $0.key == "set_performance"
        })

        guard case .object(let value)? = performance.value,
              case .string(let exercise)? = value["exercise"],
              case .string(let equipment)? = value["equipment_variant"],
              case .number(let weight)? = value["weight_kg"],
              case .array(let reps)? = value["reps"] else {
            return XCTFail("Expected structured set-performance evidence")
        }
        XCTAssertEqual(exercise, "卧推")
        XCTAssertEqual(equipment, "杠铃")
        XCTAssertEqual(weight, 60)
        XCTAssertEqual(reps, [.number(8), .number(8), .number(7)])
        XCTAssertTrue(context.trainingHistory.confirmedSessions.first?.evidenceIds.contains(
            performance.id
        ) == true)

        let body = try ContractCoding.encoder.encode(AIRecommendationRequestV2(context: context))
        let json = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(json.contains("\"type\":\"set_performance\""))
        XCTAssertTrue(json.contains("\"weight_kg\":60"))
        XCTAssertTrue(json.contains("\"reps\":[8,8,7]"))
    }

    func testProgressionEvidenceKeepsCalendarDateOutOfObservedAt() throws {
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        let sourceDate = "2026-09-18"
        let context = AIDecisionContextBuilder.build(
            input: makeInput(symptoms: .noneReported), currentPlan: nil,
            health: emptyHealthMetrics(), healthAsOf: now, dataGaps: [],
            trainingHistory: [], progression: [progressionDecision(0, latestDate: sourceDate)],
            now: now
        )
        let evidence = try XCTUnwrap(context.evidence.first {
            $0.key == "progression_rule_result"
        })

        XCTAssertNil(evidence.observedAt)
        guard case .object(let value)? = evidence.value,
              case .string(let encodedDate)? = value["source_date"] else {
            return XCTFail("Expected progression source date in structured evidence")
        }
        XCTAssertEqual(encodedDate, sourceDate)

        let data = try ContractCoding.encoder.encode(AIRecommendationRequestV2(context: context))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wireContext = try XCTUnwrap(request["context"] as? [String: Any])
        let wireEvidence = try XCTUnwrap(wireContext["evidence"] as? [[String: Any]])
        let progression = try XCTUnwrap(wireEvidence.first {
            $0["evidence_id"] as? String == evidence.id
        })
        XCTAssertTrue(progression["observed_at"] is NSNull)
        let payload = try XCTUnwrap(progression["payload"] as? [String: Any])
        XCTAssertTrue((payload["value"] as? String)?.contains("source_date=\(sourceDate)") == true)
    }

    func testContextEvidenceBudgetPreservesAllReferencesAtSchemaMaximum() throws {
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        var input = makeInput(symptoms: .noneReported)
        input.notes = "保留用户主动反馈"
        input.reportedEnergy = .good
        let outcomes = (0..<4).map(makeConfirmedOutcome)
        let observed = (0..<8).map(makeObservedWorkout)
        let progression = (0..<24).map { progressionDecision($0, latestDate: "2026-09-18") }

        let context = AIDecisionContextBuilder.build(
            input: input, currentPlan: nil,
            health: completeHealthMetrics(), healthAsOf: now, dataGaps: [],
            trainingHistory: observed, confirmedTrainingOutcomes: outcomes,
            progression: progression, now: now
        )

        XCTAssertEqual(context.evidence.count, 64)
        XCTAssertEqual(Set(context.evidence.map(\.id)).count, 64)
        XCTAssertEqual(context.trainingHistory.confirmedSessions.count, 4)
        XCTAssertEqual(context.trainingHistory.observedWorkouts.count, 8)
        XCTAssertEqual(context.progression.permissions.count, 24)

        let evidenceIDs = Set(context.evidence.map(\.id))
        let referencedIDs = context.objectiveHealth.evidenceIds
            + context.subjectiveUser.evidenceIds
            + context.trainingHistory.confirmedSessions.flatMap(\.evidenceIds)
            + context.trainingHistory.observedWorkouts.flatMap(\.evidenceIds)
            + context.progression.permissions.flatMap(\.evidenceIds)
            + context.safety.restrictions.flatMap(\.evidenceIds)
        XCTAssertTrue(Set(referencedIDs).isSubset(of: evidenceIDs))

        let data = try ContractCoding.encoder.encode(AIRecommendationRequestV2(context: context))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wireContext = try XCTUnwrap(request["context"] as? [String: Any])
        XCTAssertEqual((wireContext["evidence"] as? [[String: Any]])?.count, 64)
    }

    func testProhibitedEquipmentKeepsEquipmentSemanticsOnGatewayWire() throws {
        var context = makeContext()
        let evidenceID = try XCTUnwrap(context.evidence.first?.id)
        context.safety.restrictions = [SafetyRestriction(
            id: "sr_no_barbell", kind: .prohibitEquipment, severity: .constraint,
            evidenceIds: [evidenceID], authority: .localRule,
            message: "本次训练不得使用杠铃。", subject: "杠铃"
        )]

        let data = try ContractCoding.encoder.encode(AIRecommendationRequestV2(context: context))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wireContext = try XCTUnwrap(request["context"] as? [String: Any])
        let safety = try XCTUnwrap(wireContext["safety"] as? [String: Any])
        let restrictions = try XCTUnwrap(safety["restrictions"] as? [[String: Any]])
        let constraint = try XCTUnwrap(restrictions.first?["constraint"] as? [String: Any])

        XCTAssertEqual(constraint["type"] as? String, "exclude_equipment")
        XCTAssertEqual(constraint["equipment_ref"] as? String, "杠铃")
        XCTAssertNil(constraint["exercise_ref"])
    }

    @MainActor
    func testExplicitReplaceIntentBindsTargetToCurrentLocalPlan() throws {
        let model = AppModel(inMemory: true)
        let plan = makeIntentTargetPlan()
        model.savePlan(plan)
        var input = makeInput(symptoms: .noneReported)
        input.intent = AIPlanIntentInput(
            kind: .replaceExercise,
            equipment: [.init(name: "杠铃", status: .available)],
            requestedExerciseId: plan.exercises[0].exerciseId,
            requestedChanges: [.init(
                kind: .replaceExercise, exerciseId: plan.exercises[0].exerciseId,
                detail: "换成不需要卧推架的动作"
            )]
        )

        let context = model.makeAITrainingContext(
            input: input,
            now: try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        )

        XCTAssertEqual(context.intent.kind, .replaceExercise)
        XCTAssertEqual(context.intent.targetPlanId, plan.planId)
        XCTAssertEqual(context.intent.targetPlanRevision, plan.revision)
        XCTAssertEqual(context.intent.requestedExerciseId, plan.exercises[0].exerciseId)
        XCTAssertEqual(context.intent.requestedChanges.first?.kind, .replaceExercise)
        XCTAssertEqual(context.intent.requestedChanges.first?.exerciseId, plan.exercises[0].exerciseId)

        let wire = try intentWire(from: context)
        XCTAssertEqual(wire["kind"] as? String, "replace_exercise")
        XCTAssertEqual(wire["target_plan_revision"] as? Int, plan.revision)
        XCTAssertEqual(
            wire["target_exercise_ref"] as? String,
            plan.exercises[0].exerciseId.uuidString.lowercased()
        )
    }

    @MainActor
    func testExplicitEquipmentIntentPreservesUnavailableAndUnknownStates() throws {
        let model = AppModel(inMemory: true)
        model.savePlan(makeIntentTargetPlan())
        var input = makeInput(symptoms: .noneReported)
        input.intent = AIPlanIntentInput(
            kind: .adaptToEquipment,
            equipment: [
                .init(name: "史密斯机", status: .unavailable),
                .init(name: "哑铃", status: .available),
                .init(name: "绳索", status: .unknown),
            ],
            requestedExerciseId: nil,
            requestedChanges: [.init(
                kind: .replaceExercise, exerciseId: nil,
                detail: "按当前器械可用性调整计划"
            )]
        )

        let context = model.makeAITrainingContext(input: input)

        XCTAssertEqual(context.intent.kind, .adaptToEquipment)
        XCTAssertEqual(context.intent.equipment, input.intent?.equipment)
        let wire = try intentWire(from: context)
        let equipment = try XCTUnwrap(wire["equipment"] as? [[String: Any]])
        XCTAssertTrue(equipment.contains {
            $0["name"] as? String == "史密斯机" && $0["status"] as? String == "unavailable"
        })
        XCTAssertTrue(equipment.contains {
            $0["name"] as? String == "绳索" && $0["status"] as? String == "unknown"
        })
    }

    @MainActor
    func testExplicitShortenIntentCarriesThirtyMinuteConstraint() throws {
        let model = AppModel(inMemory: true)
        let plan = makeIntentTargetPlan()
        model.savePlan(plan)
        var input = makeInput(symptoms: .noneReported)
        input.availableMinutes = 30
        input.intent = AIPlanIntentInput(
            kind: .shortenPlan,
            equipment: [.init(name: "杠铃", status: .available)],
            requestedExerciseId: nil,
            requestedChanges: [.init(
                kind: .changeDuration, exerciseId: nil,
                detail: "将计划调整至 30 分钟以内"
            )]
        )

        let context = model.makeAITrainingContext(input: input)

        XCTAssertEqual(context.intent.kind, .shortenPlan)
        XCTAssertEqual(context.intent.availableMinutes, 30)
        XCTAssertEqual(context.intent.targetPlanId, plan.planId)
        XCTAssertEqual(context.intent.targetPlanRevision, plan.revision)
        XCTAssertEqual(context.intent.requestedChanges.first?.kind, .changeDuration)
        let wire = try intentWire(from: context)
        XCTAssertEqual(wire["kind"] as? String, "shorten_plan")
        XCTAssertEqual(wire["available_minutes"] as? Int, 30)
        XCTAssertEqual(
            wire["requested_changes"] as? [String],
            ["将计划调整至 30 分钟以内"]
        )
    }

    @MainActor
    func testEmergencyFeedbackBlocksBeforeProviderRequest() throws {
        let model = AppModel(inMemory: true)
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        let context = model.makeAITrainingContext(
            input: makeInput(symptoms: .emergencyReported), now: now
        )

        XCTAssertEqual(context.safety.disposition, .block)
        XCTAssertTrue(context.safety.restrictions.contains {
            $0.kind == .prohibitTraining && $0.authority == .localRule
        })
        XCTAssertFalse(model.canRequestAIRecommendation(context: context))
    }

    func testGoodEnergyRemainsSubjectiveEvidenceAndCannotGrantLoadIncrease() throws {
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        var input = makeInput(symptoms: .noneReported)
        input.reportedEnergy = .good
        let context = AIDecisionContextBuilder.build(
            input: input, currentPlan: makeIntentTargetPlan(),
            health: completeHealthMetrics(), healthAsOf: now,
            dataGaps: [], trainingHistory: [], progression: [], now: now
        )
        let energy = try XCTUnwrap(context.evidence.first {
            $0.key == "user_reported_energy"
        })
        XCTAssertEqual(energy.provenance, .subjectiveUser)
        XCTAssertEqual(energy.value, .string("good"))
        XCTAssertTrue(context.progression.permissions.isEmpty)

        var recommendation = makeRecommendation(context: context)
        recommendation.proposedPlan?.exercises[0].targetWeightKg = 65
        let report = AIDecisionPipelineValidator.validate(
            recommendation: recommendation, context: context
        )
        XCTAssertTrue(report.issues.contains { $0.code == .progressionPermissionMissing })
    }

    func testLowHRVAndUserReportedStateRemainSeparateWithoutBodyScore() throws {
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        var input = makeInput(symptoms: .noneReported)
        input.reportedEnergy = .normal
        var health = completeHealthMetrics()
        health.hrvMs = 20
        let context = AIDecisionContextBuilder.build(
            input: input, currentPlan: nil, health: health, healthAsOf: now,
            dataGaps: [], trainingHistory: [], progression: [], now: now
        )
        let hrv = try XCTUnwrap(context.evidence.first { $0.key == "hrv_sdnn" })
        let energy = try XCTUnwrap(context.evidence.first {
            $0.key == "user_reported_energy"
        })
        XCTAssertEqual(hrv.provenance, .objectiveHealth)
        XCTAssertEqual(hrv.value, .number(20))
        XCTAssertEqual(energy.provenance, .subjectiveUser)
        XCTAssertEqual(energy.value, .string("normal"))
        let json = try XCTUnwrap(String(
            data: ContractCoding.encoder.encode(context), encoding: .utf8
        )).lowercased()
        XCTAssertFalse(json.contains("readiness"))
        XCTAssertFalse(json.contains("recovery_score"))
    }

    @MainActor
    func testFatiguePainAndDangerousInsistenceCannotBeSilentlyNormalized() throws {
        let model = AppModel(inMemory: true)
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        var fatiguedInput = makeInput(symptoms: .noneReported)
        fatiguedInput.reportedEnergy = .low
        let fatigued = model.makeAITrainingContext(input: fatiguedInput, now: now)
        XCTAssertEqual(fatigued.evidence.first {
            $0.key == "user_reported_energy"
        }?.value, .string("low"))

        let pain = model.makeAITrainingContext(
            input: makeInput(symptoms: .limitingDiscomfort), now: now
        )
        XCTAssertEqual(pain.safety.disposition, .needsUserInput)
        XCTAssertFalse(model.canRequestAIRecommendation(context: pain))

        var insistence = makeInput(symptoms: .emergencyReported)
        insistence.notes = "我仍然坚持按原重量训练"
        let dangerous = model.makeAITrainingContext(input: insistence, now: now)
        XCTAssertEqual(dangerous.safety.disposition, .block)
        XCTAssertTrue(dangerous.safety.restrictions.contains {
            $0.kind == .prohibitTraining && $0.severity == .block
        })
        XCTAssertFalse(model.canRequestAIRecommendation(context: dangerous))
    }

    func testGatewayV2RequestContainsNoReadinessAndDecodesStructuredRecommendation() async throws {
        let context = makeContext()
        let requestId = UUID()
        let recorder = AIV2RequestRecorder(responses: [
            (200, try makeRecommendationResponseJSON(context: context, requestId: requestId)),
        ])
        let service = KrisAIGatewayService(
            endpoint: URL(string: "https://api.kris.example/v2/ai/training-recommendations")!,
            sessionToken: "test-device-session",
            requestLoader: { request in try await recorder.load(request) }
        )

        let decoded = try await service.generateRecommendation(
            context: context, clientRequestId: requestId
        )

        XCTAssertEqual(decoded.requestId, requestId)
        XCTAssertEqual(decoded.contextId, context.contextId)
        XCTAssertEqual(decoded.kind, .planRevision)
        XCTAssertEqual(decoded.proposedPlan?.title, "上肢 V2")
        let recordedRequest = await recorder.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? String, "KrisAIPlanRequest.v2")
        XCTAssertEqual(json["client_request_id"] as? String, requestId.uuidString.lowercased())
        let wireContext = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual(wireContext["schema_version"] as? String, "TrainingContext.v2")
        let subjective = try XCTUnwrap(wireContext["subjective_user"] as? [String: Any])
        XCTAssertNotNil(subjective["reported_at"])
        XCTAssertNil(subjective["as_of"])
        let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8)).lowercased()
        XCTAssertFalse(bodyText.contains("readiness"))
        XCTAssertFalse(bodyText.contains("recovery_score"))
        XCTAssertNil(json["model"])
        XCTAssertNil(json["api_key"])
    }

    func testGatewayV2RejectsDerivedBodyStateScoreBeforeNetworkRequest() async throws {
        var context = makeContext()
        context.evidence.append(Evidence(
            id: "ev_objective_status_score", provenance: .objectiveHealth,
            key: "status_score", observedAt: "2026-09-20T08:00:00Z",
            quality: .confirmed, value: .number(42), source: "local", note: nil
        ))
        let service = KrisAIGatewayService(
            endpoint: URL(string: "https://api.kris.example/v2/ai/training-recommendations")!,
            sessionToken: "test-device-session",
            requestLoader: { _ in
                XCTFail("Forbidden derived scores must be rejected before the request loader")
                throw URLError(.dataNotAllowed)
            }
        )

        do {
            _ = try await service.generateRecommendation(context: context)
            XCTFail("status_score should be rejected locally")
        } catch let error as AIServiceError {
            guard case .invalidRequest = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
        }
    }

    func testGatewayV2MapsContractConflictAndProviderFailures() async throws {
        let cases: [(status: Int, code: String, expected: AIServiceError)] = [
            (409, "idempotency_conflict", .conflict("fixture error")),
            (422, "invalid_contract", .invalidRequest("fixture error")),
            (502, "invalid_provider_response", .invalidResponse),
            (503, "provider_unavailable", .serverUnavailable),
        ]
        let payload = try JSONSerialization.data(withJSONObject: [
            "schema_version": "GatewayError.v1",
            "request_id": UUID().uuidString,
            "error": ["code": "placeholder", "message": "fixture error"],
        ])

        for item in cases {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            object["error"] = ["code": item.code, "message": "fixture error"]
            let responseData = try JSONSerialization.data(withJSONObject: object)
            let service = KrisAIGatewayService(
                endpoint: URL(string: "https://api.kris.example/v2/ai/training-recommendations")!,
                sessionToken: "test-device-session",
                requestLoader: { request in
                    let response = HTTPURLResponse(
                        url: request.url!, statusCode: item.status,
                        httpVersion: "HTTP/1.1", headerFields: nil
                    )!
                    return (responseData, response)
                }
            )
            do {
                _ = try await service.generateRecommendation(context: makeContext())
                XCTFail("HTTP \(item.status) should fail")
            } catch let error as AIServiceError {
                XCTAssertEqual(error, item.expected, "HTTP \(item.status)")
            }
        }
    }

    func testGatewayV2RejectsAIAuthoredSafetyFieldsLocally() async throws {
        let context = makeContext()
        let requestId = UUID()
        let valid = try makeRecommendationResponseJSON(context: context, requestId: requestId)
        var response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        var recommendation = try XCTUnwrap(response["recommendation"] as? [String: Any])
        var candidate = try XCTUnwrap(recommendation["candidate_plan"] as? [String: Any])
        candidate["safety_gates"] = ["AI-created gate"]
        recommendation["candidate_plan"] = candidate
        response["recommendation"] = recommendation
        let invalid = try JSONSerialization.data(withJSONObject: response)
        let service = KrisAIGatewayService(
            endpoint: URL(string: "https://api.kris.example/v2/ai/training-recommendations")!,
            sessionToken: "test-device-session",
            requestLoader: { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: nil
                )!
                return (invalid, response)
            }
        )

        do {
            _ = try await service.generateRecommendation(
                context: context, clientRequestId: requestId
            )
            XCTFail("AI-authored safety fields must be rejected locally")
        } catch let error as AIServiceError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    @MainActor
    func testV2CandidatePersistsRecommendationAndAdoptsPlanAtomically() throws {
        let model = AppModel(inMemory: true)
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        let context = model.makeAITrainingContext(
            input: makeInput(symptoms: .noneReported), now: now
        )
        let recommendation = makeRecommendation(context: context)
        let candidate = try XCTUnwrap(
            model.makeAIRecommendationCandidate(
                recommendation: recommendation, context: context, now: now
            )
        )

        let saveReport = model.saveAIRecommendationCandidate(candidate)
        XCTAssertTrue(saveReport.isValid, "\(saveReport.issues)")
        XCTAssertTrue(model.publishAIRecommendationCandidate(now: now.addingTimeInterval(60)))
        XCTAssertEqual(model.currentPlan?.planId, candidate.plan.planId)
        XCTAssertEqual(model.currentPlan?.revision, candidate.plan.revision)

        let restored = AppModel(testContainer: model.container)
        XCTAssertNil(restored.aiRecommendationCandidate)
        let record = try XCTUnwrap(try model.container.mainContext.fetch(
            FetchDescriptor<TrainingPlanCandidateRecord>()
        ).first { $0.candidateId == candidate.candidateId })
        let persisted = try ContractCoding.decoder.decode(
            TrainingPlanCandidateV2.self, from: record.payload
        )
        XCTAssertEqual(persisted.status, .published)
        XCTAssertEqual(persisted.userDecision?.kind, .accepted)
        XCTAssertEqual(persisted.recommendation.reasons, recommendation.reasons)
    }

    @MainActor
    func testV2PendingCandidateRestoresAndRejectPersistsDecision() throws {
        let model = AppModel(inMemory: true)
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        let context = model.makeAITrainingContext(
            input: makeInput(symptoms: .noneReported), now: now
        )
        let candidate = try XCTUnwrap(model.makeAIRecommendationCandidate(
            recommendation: makeRecommendation(context: context),
            context: context, now: now
        ))
        XCTAssertTrue(model.saveAIRecommendationCandidate(candidate).isValid)

        let restored = AppModel(testContainer: model.container)
        XCTAssertEqual(restored.aiRecommendationCandidate?.candidateId, candidate.candidateId)
        XCTAssertTrue(restored.rejectAIRecommendationCandidate(reason: "改用手动计划"))
        XCTAssertNil(restored.aiRecommendationCandidate)

        let record = try XCTUnwrap(try model.container.mainContext.fetch(
            FetchDescriptor<TrainingPlanCandidateRecord>()
        ).first { $0.candidateId == candidate.candidateId })
        let persisted = try ContractCoding.decoder.decode(
            TrainingPlanCandidateV2.self, from: record.payload
        )
        XCTAssertEqual(persisted.status, .rejected)
        XCTAssertEqual(persisted.userDecision?.kind, .rejected)
        XCTAssertEqual(persisted.userDecision?.rejectionReason, "改用手动计划")
    }

    @MainActor
    func testV2AdoptionRollsBackCandidateAndPlanWhenSaveFails() throws {
        let model = AppModel(inMemory: true)
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        let originalPlan = model.currentPlan
        let context = model.makeAITrainingContext(
            input: makeInput(symptoms: .noneReported), now: now
        )
        let candidate = try XCTUnwrap(model.makeAIRecommendationCandidate(
            recommendation: makeRecommendation(context: context),
            context: context, now: now
        ))
        XCTAssertTrue(model.saveAIRecommendationCandidate(candidate).isValid)
        model.aiCandidateSaveOverride = { throw ExpectedPersistenceFailure.save }

        XCTAssertFalse(model.publishAIRecommendationCandidate(now: now.addingTimeInterval(60)))
        XCTAssertEqual(model.currentPlan, originalPlan)
        XCTAssertEqual(model.aiRecommendationCandidate?.status, .awaitingConfirmation)

        let record = try XCTUnwrap(try model.container.mainContext.fetch(
            FetchDescriptor<TrainingPlanCandidateRecord>()
        ).first { $0.candidateId == candidate.candidateId })
        let persisted = try ContractCoding.decoder.decode(
            TrainingPlanCandidateV2.self, from: record.payload
        )
        XCTAssertEqual(persisted.status, .awaitingConfirmation)
        XCTAssertNil(persisted.userDecision)
        XCTAssertFalse(try model.container.mainContext.fetch(
            FetchDescriptor<CachedPlanRecord>()
        ).contains { $0.planId == candidate.plan.planId && $0.revision == candidate.plan.revision })
    }

    @MainActor
    func testV2EditedPlanPersistsAcceptedWithEditsDecision() throws {
        let model = AppModel(inMemory: true)
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        let context = model.makeAITrainingContext(
            input: makeInput(symptoms: .noneReported), now: now
        )
        var candidate = try XCTUnwrap(model.makeAIRecommendationCandidate(
            recommendation: makeRecommendation(context: context),
            context: context, now: now
        ))
        candidate.plan.estimatedMinutes = 40

        XCTAssertTrue(model.saveAIRecommendationCandidate(candidate).isValid)
        XCTAssertTrue(model.publishAIRecommendationCandidate(now: now.addingTimeInterval(60)))

        let record = try XCTUnwrap(try model.container.mainContext.fetch(
            FetchDescriptor<TrainingPlanCandidateRecord>()
        ).first { $0.candidateId == candidate.candidateId })
        let persisted = try ContractCoding.decoder.decode(
            TrainingPlanCandidateV2.self, from: record.payload
        )
        XCTAssertEqual(persisted.userDecision?.kind, .acceptedWithEdits)
        XCTAssertTrue(persisted.userDecision?.edits.contains {
            $0.path == "estimated_minutes" && $0.after == "40"
        } == true)
    }

    @MainActor
    func testExplainRecommendationCanBeAcknowledgedWithoutChangingPlanRevision() throws {
        let model = AppModel(inMemory: true)
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-20T08:00:00Z"))
        let originalPlan = try XCTUnwrap(model.currentPlan)
        let recordsBefore = try model.container.mainContext.fetch(FetchDescriptor<CachedPlanRecord>())
        var input = makeInput(symptoms: .noneReported)
        input.intent = AIPlanIntentInput(
            kind: .explainRecommendation,
            equipment: [.init(name: "杠铃", status: .available)],
            requestedExerciseId: nil, requestedChanges: []
        )
        let context = model.makeAITrainingContext(input: input, now: now)
        var recommendation = makeRecommendation(context: context)
        recommendation.kind = .noChange
        recommendation.recommendation = "当前计划无需调整，继续按原方案执行。"
        recommendation.proposedPlan = nil
        let candidate = try XCTUnwrap(model.makeAIRecommendationCandidate(
            recommendation: recommendation, context: context, now: now
        ))

        XCTAssertEqual(candidate.plan.planId, originalPlan.planId)
        XCTAssertEqual(candidate.plan.revision, originalPlan.revision)
        let advisorySaveReport = model.saveAIRecommendationCandidate(candidate)
        XCTAssertTrue(advisorySaveReport.isValid, "\(advisorySaveReport.issues)")
        XCTAssertTrue(model.publishAIRecommendationCandidate(now: now.addingTimeInterval(60)))
        XCTAssertEqual(model.currentPlan, originalPlan)

        let recordsAfter = try model.container.mainContext.fetch(FetchDescriptor<CachedPlanRecord>())
        XCTAssertEqual(recordsAfter.map(\.key).sorted(), recordsBefore.map(\.key).sorted())
        let decisionRecord = try XCTUnwrap(try model.container.mainContext.fetch(
            FetchDescriptor<TrainingPlanCandidateRecord>()
        ).first { $0.candidateId == candidate.candidateId })
        let persisted = try ContractCoding.decoder.decode(
            TrainingPlanCandidateV2.self, from: decisionRecord.payload
        )
        XCTAssertEqual(persisted.userDecision?.kind, .accepted)
        XCTAssertEqual(persisted.userDecision?.acceptedPlanRevision, originalPlan.revision)
    }

    private func makeInput(symptoms: LocalTrainingSymptoms) -> AIPlanUserInput {
        AIPlanUserInput(
            date: "2026-09-20", objective: "减脂保肌", availableMinutes: 45,
            equipment: "杠铃", notes: "", symptoms: symptoms
        )
    }

    private func makeIntentTargetPlan() -> TrainingPlan {
        TrainingPlan(
            planId: UUID(), revision: 3, date: "2026-09-20", title: "上肢训练",
            estimatedMinutes: 55, goal: "减脂保肌", safetyGates: [],
            exercises: [ExercisePlan(
                exerciseId: UUID(), order: 1, name: "卧推", equipmentVariant: "杠铃",
                targetWeightKg: 60, sets: 3, targetReps: 8, restSeconds: 120,
                notes: nil, alternative: "俯卧撑"
            )], publishedAt: nil
        )
    }

    private func intentWire(from context: TrainingContext) throws -> [String: Any] {
        let data = try ContractCoding.encoder.encode(AIRecommendationRequestV2(context: context))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wireContext = try XCTUnwrap(request["context"] as? [String: Any])
        return try XCTUnwrap(wireContext["intent"] as? [String: Any])
    }

    private func emptyHealthMetrics() -> DailyHealthMetrics {
        DailyHealthMetrics(
            sleepHours: nil, hrvMs: nil, restingHeartRate: nil, steps: nil,
            activeKcal: nil, basalKcal: nil, totalKcal: nil, vo2Max: nil,
            bodyMassKg: nil, bodyFatPercent: nil, leanBodyMassKg: nil
        )
    }

    private func completeHealthMetrics() -> DailyHealthMetrics {
        DailyHealthMetrics(
            sleepHours: 7.5, hrvMs: 48, restingHeartRate: 58, steps: 8_000,
            activeKcal: 520, basalKcal: 1_700, totalKcal: 2_220, vo2Max: 42,
            bodyMassKg: 78, bodyFatPercent: 18, leanBodyMassKg: 64
        )
    }

    private func progressionDecision(
        _ index: Int, latestDate: String
    ) -> LocalProgressionDecision {
        LocalProgressionDecision(
            exercise: "动作 \(index + 1)", equipmentVariant: "器械 \(index + 1)",
            state: "hold", nextAction: "维持", evidence: "最近训练证据",
            rollbackCondition: "动作变形时回退", latestDate: latestDate
        )
    }

    private func makeConfirmedOutcome(_ index: Int) -> TrainingSessionContract {
        let exercises = (0..<6).map { exerciseIndex in
            ExerciseResult(
                exerciseId: UUID(), name: "动作 \(index)-\(exerciseIndex)",
                equipmentVariant: "器械 \(exerciseIndex)",
                sets: [CompletedSet(
                    setId: UUID(), setNumber: 1, weightKg: 20, reps: 10,
                    completedAt: "2026-09-18T10:20:00Z", lastSetFeeling: .appropriate
                )]
            )
        }
        return TrainingSessionContract(
            sessionId: UUID(), planId: UUID(), planRevision: 1,
            startedAt: "2026-09-18T10:00:00Z", endedAt: "2026-09-18T11:00:00Z",
            status: .completed, exerciseResults: exercises,
            feedback: SessionFeedback(
                energy: .normal, targetMuscleResponse: .good, symptoms: "", notes: ""
            ),
            watchWorkoutUuid: nil, workout: nil
        )
    }

    private func makeObservedWorkout(_ index: Int) -> SnapshotTrainingSummary {
        SnapshotTrainingSummary(
            id: "health-workout-\(index)", date: "2026-09-17T0\(index):00:00Z",
            title: "步行", durationMinutes: 30, activeKcal: 180,
            averageHeartRate: 105, maximumHeartRate: 125,
            exerciseCount: nil, completedSetCount: nil, status: "observed",
            source: "iphone_healthkit", syncedToMac: nil
        )
    }

    private func makeContext() -> TrainingContext {
        let plan = TrainingPlan(
            planId: UUID(), revision: 1, date: "2026-09-20", title: "上肢",
            estimatedMinutes: 45, goal: "减脂保肌", safetyGates: ["不适时停止"],
            exercises: [ExercisePlan(
                exerciseId: UUID(), order: 1, name: "卧推", equipmentVariant: "杠铃",
                targetWeightKg: 60, sets: 3, targetReps: 8, restSeconds: 120,
                notes: nil, alternative: "俯卧撑"
            )], publishedAt: nil
        )
        let intent = UserIntent(
            intentId: UUID(), kind: .revisePlan, requestedDate: "2026-09-20",
            objective: "减脂保肌", availableMinutes: 45,
            equipment: [.init(name: "杠铃", status: .available)],
            targetPlanId: plan.planId, targetPlanRevision: plan.revision,
            requestedExerciseId: nil, requestedChanges: [], notes: nil
        )
        let evidence = Evidence(
            id: "ev_training_bench_latest", provenance: .confirmedTraining,
            key: "bench_press_sets", observedAt: "2026-09-18T10:00:00Z",
            quality: .confirmed, value: .string("60kg x 8 x 3"),
            source: "kris_session", note: nil
        )
        return TrainingContext(
            contextId: UUID(), generatedAt: "2026-09-20T08:00:00Z",
            expiresAt: "2026-09-20T12:00:00Z", intent: intent,
            objectiveHealth: .init(asOf: "2026-09-20T08:00:00Z", evidenceIds: []),
            subjectiveUser: .init(reportedAt: "2026-09-20T08:00:00Z", evidenceIds: []),
            trainingHistory: .init(confirmedSessions: [], observedWorkouts: []),
            progression: .init(ruleVersion: "gated_double_progression_v1", permissions: [
                .init(
                    exerciseName: "卧推", equipmentVariant: "杠铃",
                    allowsLoadIncrease: false, maximumWeightKg: nil,
                    evidenceIds: [evidence.id]
                ),
            ]),
            safety: .init(
                ruleVersion: "local_ai_safety_v2", disposition: .allow,
                restrictions: [.init(
                    id: "sr_no_unapproved_load",
                    kind: .prohibitUnapprovedLoadIncrease, severity: .constraint,
                    evidenceIds: [], authority: .localRule,
                    message: "未获本地进阶许可时不得加重"
                )], evaluatedAt: "2026-09-20T08:00:00Z",
                expiresAt: "2026-09-20T12:00:00Z"
            ),
            currentPlan: plan, evidence: [evidence], dataGaps: []
        )
    }

    private func makeRecommendation(context: TrainingContext) -> AIRecommendation {
        let plan = context.currentPlan ?? TrainingPlan(
            planId: UUID(), revision: 1,
            date: context.intent.requestedDate, title: "全身训练",
            estimatedMinutes: min(45, context.intent.availableMinutes),
            goal: context.intent.objective, safetyGates: [],
            exercises: [ExercisePlan(
                exerciseId: UUID(), order: 1, name: "高脚杯深蹲",
                equipmentVariant: "杠铃", targetWeightKg: nil,
                sets: 3, targetReps: 10, restSeconds: 90,
                notes: nil, alternative: "徒手深蹲"
            )], publishedAt: nil
        )
        let evidenceID = context.evidence.first(where: { $0.quality != .missing })?.id
            ?? context.evidence.first?.id
            ?? "ev_sub_symptoms"
        return AIRecommendation(
            recommendationId: UUID(), kind: .planRevision,
            recommendation: "维持当前重量并完成原定组次",
            proposedPlan: AITrainingPlanDraft(
                title: "上肢 V2", estimatedMinutes: 45, goal: "减脂保肌",
                safetyGates: [], exercises: plan.exercises.map {
                    AIExerciseDraft(
                        name: $0.name, equipmentVariant: $0.equipmentVariant,
                        targetWeightKg: $0.targetWeightKg, sets: $0.sets,
                        targetReps: $0.targetReps, restSeconds: $0.restSeconds,
                        notes: $0.notes, alternative: $0.alternative
                    )
                }
            ),
            reasons: [.init(
                code: "maintain_latest_load", explanation: "沿用最近已确认负重",
                evidenceIds: [evidenceID]
            )], evidenceIds: [evidenceID], confidence: .medium,
            uncertainties: [], optionalAdjustment: nil, alternatives: [],
            safetyConsiderations: [],
            acknowledgedRestrictionIds: context.safety.restrictions.map(\.id),
            userConfirmationRequired: true
        )
    }

    private func makeRecommendationResponseJSON(
        context: TrainingContext,
        requestId: UUID
    ) throws -> Data {
        let plan = try XCTUnwrap(context.currentPlan)
        let exercises: [[String: Any]] = plan.exercises.map { exercise in
            [
                "name": exercise.name,
                "equipment_variant": exercise.equipmentVariant,
                "target_weight_kg": exercise.targetWeightKg.map { $0 as Any } ?? NSNull(),
                "sets": exercise.sets,
                "target_reps": exercise.targetReps,
                "rest_seconds": exercise.restSeconds,
                "notes": exercise.notes ?? [],
                "alternative": exercise.alternative.map { $0 as Any } ?? NSNull(),
            ]
        }
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": "AIRecommendation.v2",
            "request_id": requestId.uuidString.lowercased(),
            "recommendation_id": UUID().uuidString.lowercased(),
            "context_id": context.contextId.uuidString.lowercased(),
            "kind": "revise_plan",
            "recommendation": [
                "type": "candidate_plan",
                "candidate_plan": [
                    "title": "上肢 V2",
                    "estimated_minutes": 45,
                    "goal": "减脂保肌",
                    "exercises": exercises,
                ],
            ],
            "reasons": [[
                "code": "maintain_latest_load",
                "explanation": "沿用最近已确认负重",
                "evidence_ids": ["ev_training_bench_latest"],
            ]],
            "evidence_ids": ["ev_training_bench_latest"],
            "confidence": "medium",
            "uncertainties": [],
            "optional_adjustment": NSNull(),
            "alternatives": [],
            "safety_considerations": [],
            "acknowledged_restriction_ids": context.safety.restrictions.map(\.id),
            "user_confirmation_required": true,
            "inference_metadata": [
                "provider": "stub",
                "model": "deterministic-stub",
                "prompt_version": "training_recommendation.stub.v2",
                "generated_at": "2026-09-20T08:00:01Z",
            ],
        ])
    }
}
