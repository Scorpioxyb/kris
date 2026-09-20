import XCTest
import SwiftData
@testable import KrisCoach

private actor AIRequestRecorder {
    private var responses: [(status: Int, data: Data)]
    private(set) var requests: [URLRequest] = []

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
    func requestCount() -> Int { requests.count }
}

final class ReadinessEngineTests: XCTestCase {
    func testWatchStatusDoesNotClaimUnpairedBeforeActivationCompletes() {
        XCTAssertEqual(
            WatchConnectionStatus.resolve(
                isSupported: true,
                activationCompleted: false,
                activationFailed: false,
                hasPairedWatch: false,
                isWatchAppInstalled: false,
                isReachable: false
            ),
            .checking
        )
    }

    func testWatchStatusSeparatesPairingInstallationAndReachability() {
        XCTAssertEqual(
            WatchConnectionStatus.resolve(
                isSupported: true,
                activationCompleted: true,
                activationFailed: false,
                hasPairedWatch: true,
                isWatchAppInstalled: false,
                isReachable: false
            ),
            .needsInstallation
        )
        XCTAssertEqual(
            WatchConnectionStatus.resolve(
                isSupported: true,
                activationCompleted: true,
                activationFailed: false,
                hasPairedWatch: true,
                isWatchAppInstalled: true,
                isReachable: false
            ),
            .installed
        )
        XCTAssertEqual(
            WatchConnectionStatus.resolve(
                isSupported: true,
                activationCompleted: true,
                activationFailed: false,
                hasPairedWatch: true,
                isWatchAppInstalled: true,
                isReachable: true
            ),
            .reachable
        )
    }

    func testDailyHealthIsNormalWithoutTrainingOrReadiness() {
        XCTAssertEqual(TodayFocus.resolve(safetyGate: nil, hasActiveSession: false), .dailyHealth)
        XCTAssertEqual(TodayFocus.resolve(safetyGate: "normal", hasActiveSession: false), .dailyHealth)
        XCTAssertEqual(TodayFocus.resolve(safetyGate: "unknown", hasActiveSession: false), .dailyHealth)
    }

    func testHomeSafetyReviewPrecedesActiveSession() {
        XCTAssertEqual(TodayFocus.resolve(safetyGate: "stop_and_seek_care", hasActiveSession: true), .safetyReview)
        XCTAssertEqual(TodayFocus.resolve(safetyGate: "reduce", hasActiveSession: true), .safetyReview)
        XCTAssertEqual(TodayFocus.resolve(safetyGate: "normal", hasActiveSession: true), .activeSession)
    }

    func testHomePlansUseLocalDateAndDoNotRollOverSilently() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-06T17:00:00Z"))
        XCTAssertTrue(TodayFocus.isPlanScheduledToday("2026-09-07", now: now, calendar: calendar))
        for date in ["2026-09-06", "2026-09-08", "", "2026-9-7", "invalid"] {
            XCTAssertFalse(TodayFocus.isPlanScheduledToday(date, now: now, calendar: calendar))
        }
    }

    @MainActor
    func testHealthHomeKeepsOldPlanInTrainingAndActiveSessionAccessible() throws {
        let model = AppModel(inMemory: true)
        var plan = try XCTUnwrap(model.currentPlan)
        plan.revision += 1
        plan.date = "2000-01-01"
        model.savePlan(plan)
        XCTAssertNil(model.homeTrainingPlan)
        XCTAssertEqual(model.currentPlan, plan)
        XCTAssertEqual(model.todayFocus, .dailyHealth)
        model.startTraining()
        XCTAssertEqual(model.homeTrainingPlan, plan)
        XCTAssertEqual(model.todayFocus, .activeSession)
    }

    func testLegacyTrainingPlanCandidateCannotBePublished() {
        let plan = TrainingPlan(
            planId: UUID(), revision: 1, date: "2026-09-06", title: "上肢训练",
            estimatedMinutes: 45, goal: "减脂保肌", safetyGates: [],
            exercises: [ExercisePlan(
                exerciseId: UUID(), order: 1, name: "高位下拉", equipmentVariant: "常规器械",
                targetWeightKg: 40, sets: 3, targetReps: 10, restSeconds: 90,
                notes: nil, alternative: nil
            )], publishedAt: nil
        )
        var candidate = TrainingPlanCandidate(
            candidateId: UUID(), plan: plan, status: .draft,
            createdAt: "2026-09-06T10:00:00+08:00", source: "local_user",
            decisionRuleVersion: "local_plan_gate_v1"
        )
        XCTAssertFalse(TrainingPlanCandidateValidation.canPublish(candidate))
        XCTAssertTrue(TrainingPlanCandidateValidation.errors(candidate).isEmpty)
        candidate.status = .awaitingConfirmation
        XCTAssertFalse(TrainingPlanCandidateValidation.canPublish(candidate))
    }

    func testTrainingPlanCandidateRejectsInvalidExerciseValues() {
        let plan = TrainingPlan(
            planId: UUID(), revision: 1, date: "2026-09-06", title: "",
            estimatedMinutes: 0, goal: nil, safetyGates: [],
            exercises: [ExercisePlan(
                exerciseId: UUID(), order: 1, name: "", equipmentVariant: "器械",
                targetWeightKg: nil, sets: 0, targetReps: 0, restSeconds: -1,
                notes: nil, alternative: nil
            )], publishedAt: nil
        )
        let candidate = TrainingPlanCandidate(
            candidateId: UUID(), plan: plan, status: .awaitingConfirmation,
            createdAt: "2026-09-06T10:00:00+08:00", source: "local_user",
            decisionRuleVersion: nil
        )
        XCTAssertFalse(TrainingPlanCandidateValidation.errors(candidate).isEmpty)
        XCTAssertFalse(TrainingPlanCandidateValidation.canPublish(candidate))
    }

    func testAIRedactedContextDoesNotContainRawHealthIdentifiers() throws {
        let input = AIPlanUserInput(
            date: "2026-09-10", objective: "减脂保肌",
            availableMinutes: 50, equipment: "常规健身房",
            notes: "上肢", symptoms: .noneReported
        )
        let context = AIRedactedPlanContext(
            generatedAt: "2026-09-10T09:00:00Z", userInput: input,
            readiness: .init(score: 68, state: "train_maintain", confidence: "medium", safetyGate: "normal"),
            localDecision: LocalPlanDecision(
                action: .maintain, title: "可训练", summary: "维持",
                evidence: [.maintainState], rollbackCondition: "不适时停止",
                ruleVersion: LocalPlanEngine.ruleVersion
            ),
            recentConfirmedTraining: [
                .init(date: "2026-09-08", title: "上肢", durationMinutes: 42, completedSetCount: 12, status: "completed")
            ],
            currentPlan: nil, progressionNotes: [], dataGaps: []
        )
        let data = try ContractCoding.encoder.encode(context)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("sample_uuid"))
        XCTAssertFalse(json.contains("device_id"))
        XCTAssertFalse(json.contains("source_name"))
        XCTAssertFalse(json.contains("heart_rate_samples"))
        XCTAssertTrue(json.contains("recent_confirmed_training"))
    }

    func testStructuredGatewayResponseBecomesReviewableCandidate() throws {
        let input = AIPlanUserInput(
            date: "2026-09-10", objective: "减脂保肌",
            availableMinutes: 55, equipment: "常规健身房",
            notes: "上肢", symptoms: .noneReported
        )
        let json = """
        {
          "schema_version":"AIPlanResponse.v1",
          "rationale":"最近训练较少，先恢复动作质量。",
          "cautions":["首组校准重量"],
          "plan":{
            "title":"上肢回归",
            "estimated_minutes":50,
            "goal":"恢复力量训练",
            "safety_gates":["动作变形时停止加重"],
            "exercises":[{
              "name":"高位下拉","equipment_variant":"常规器械","target_weight_kg":40,
              "sets":3,"target_reps":10,"rest_seconds":90,
              "notes":["保持躯干稳定"],"alternative":"辅助引体向上"
            }]
          }
        }
        """
        let response = try KrisAIGatewayService.decodePlanResponse(
            try XCTUnwrap(json.data(using: .utf8)), input: input
        )
        let context = AIRedactedPlanContext(
            generatedAt: DateFormatting.iso(), userInput: input,
            readiness: nil,
            localDecision: LocalPlanDecision(
                action: .needsAssessment, title: "待确认", summary: "数据不足",
                evidence: [.missingReadiness], rollbackCondition: "训练中出现不适时停止",
                ruleVersion: LocalPlanEngine.ruleVersion
            ),
            recentConfirmedTraining: [], currentPlan: nil,
            progressionNotes: [], dataGaps: ["恢复基线建立中"]
        )
        let candidate = try XCTUnwrap(AIPlanPolicy.makeCandidate(
            response: response, context: context,
            model: "managed", previousPlan: nil
        ))
        XCTAssertEqual(candidate.status, .awaitingConfirmation)
        XCTAssertTrue(candidate.source.hasPrefix("kris-ai:"))
        XCTAssertTrue(candidate.plan.safetyGates.contains("训练中出现不适时停止"))
        XCTAssertTrue(AIPlanPolicy.publicationErrors(candidate, currentSafetyGate: "normal").isEmpty)
    }

    func testAIPlanCannotBypassLocalSafetyStopOrParameterBounds() throws {
        let input = AIPlanUserInput(
            date: "2026-09-10", objective: "训练", availableMinutes: 30,
            equipment: "自重", notes: "", symptoms: .noneReported
        )
        let oversized = AIPlanResponseEnvelope(
            schemaVersion: AIPlanPolicy.responseSchemaVersion,
            rationale: "", cautions: [],
            plan: AITrainingPlanDraft(
                title: "过量计划", estimatedMinutes: 90, goal: "训练",
                safetyGates: [],
                exercises: [.init(
                    name: "深蹲", equipmentVariant: "自重", targetWeightKg: nil,
                    sets: 30, targetReps: 10, restSeconds: 90,
                    notes: nil, alternative: nil
                )]
            )
        )
        XCTAssertFalse(AIPlanPolicy.draftErrors(oversized, input: input).isEmpty)

        let validPlan = TrainingPlan(
            planId: UUID(), revision: 1, date: input.date, title: "恢复训练",
            estimatedMinutes: 30, goal: "恢复",
            safetyGates: ["不适时停止"],
            exercises: [.init(
                exerciseId: UUID(), order: 1, name: "徒手深蹲", equipmentVariant: "自重",
                targetWeightKg: nil, sets: 2, targetReps: 10, restSeconds: 60,
                notes: nil, alternative: nil
            )], publishedAt: nil
        )
        let candidate = TrainingPlanCandidate(
            candidateId: UUID(), plan: validPlan, status: .awaitingConfirmation,
            createdAt: DateFormatting.iso(),
            source: "deepseek:deepseek-flash:\(AIPlanPolicy.promptVersion)",
            decisionRuleVersion: LocalPlanEngine.ruleVersion
        )
        XCTAssertFalse(AIPlanPolicy.publicationErrors(
            candidate, currentSafetyGate: "stop_and_seek_care"
        ).isEmpty)
    }

    @MainActor
    func testAppModelRejectsUnsafeAICandidateBeforePersistence() throws {
        let model = AppModel(inMemory: true)
        var plan = try XCTUnwrap(model.currentPlan)
        plan.exercises[0].sets = 30
        let candidate = TrainingPlanCandidate(
            candidateId: UUID(), plan: plan, status: .awaitingConfirmation,
            createdAt: DateFormatting.iso(),
            source: "deepseek:deepseek-flash:\(AIPlanPolicy.promptVersion)",
            decisionRuleVersion: LocalPlanEngine.ruleVersion
        )
        XCTAssertFalse(model.savePlanCandidate(candidate).isEmpty)
        XCTAssertNil(model.planCandidate)
    }

    func testGatewayRequestUsesMinimalizedContractWithoutVendorCredential() async throws {
        let context = makeAIContext()
        let recorder = AIRequestRecorder(responses: [
            (200, try XCTUnwrap(validAIPlanJSON().data(using: .utf8))),
        ])
        let service = KrisAIGatewayService(
            endpoint: URL(string: "https://api.kris.example/v1/ai/training-plan-candidates")!,
            sessionToken: "test-device-session",
            requestLoader: { request in try await recorder.load(request) }
        )

        _ = try await service.generatePlan(context: context)

        let recordedRequest = await recorder.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-device-session"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Kris-Response-Schema"),
            AIPlanPolicy.responseSchemaVersion
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? String, "KrisAIPlanRequest.v1")
        XCTAssertNotNil(json["client_request_id"] as? String)
        let sentContext = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertNotNil(sentContext["schema_version"])
        XCTAssertNotNil(sentContext["recent_confirmed_training"])
        XCTAssertNil(sentContext["sample_uuid"])
        XCTAssertNil(sentContext["device_id"])
        XCTAssertNil(json["model"])
        XCTAssertNil(json["api_key"])
    }

    func testGatewayMapsHTTPFailures() async throws {
        let errorPayload = try JSONSerialization.data(withJSONObject: [
            "message": "fixture error",
        ])
        let cases: [(Int, AIServiceError)] = [
            (400, .invalidRequest("fixture error")),
            (401, .authentication),
            (402, .insufficientBalance),
            (422, .invalidRequest("fixture error")),
            (429, .rateLimited),
            (500, .serverUnavailable),
            (503, .serverUnavailable),
        ]

        for (status, expected) in cases {
            let service = KrisAIGatewayService(
                endpoint: URL(string: "https://api.kris.example/v1/ai/training-plan-candidates")!,
                sessionToken: "test-device-session",
                requestLoader: { request in
                    let response = HTTPURLResponse(
                        url: request.url!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: nil
                    )!
                    return (errorPayload, response)
                }
            )
            do {
                _ = try await service.generatePlan(context: makeAIContext())
                XCTFail("HTTP \(status) should fail")
            } catch let error as AIServiceError {
                XCTAssertEqual(error, expected, "HTTP \(status)")
            }
        }
    }

    func testGatewayRequiresKrisDeviceSessionBeforeNetworkRequest() async throws {
        let recorder = AIRequestRecorder(responses: [
            (200, try XCTUnwrap(validAIPlanJSON().data(using: .utf8))),
        ])
        let service = KrisAIGatewayService(
            endpoint: URL(string: "https://api.kris.example/v1/ai/training-plan-candidates")!,
            sessionToken: "",
            requestLoader: { request in try await recorder.load(request) }
        )

        do {
            _ = try await service.generatePlan(context: makeAIContext())
            XCTFail("A missing Kris device session must fail before networking")
        } catch let error as AIServiceError {
            XCTAssertEqual(error, .notConfigured)
        }
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testGatewayRetriesOneEmptyResponse() async throws {
        let recorder = AIRequestRecorder(responses: [
            (200, Data()),
            (200, try XCTUnwrap(validAIPlanJSON().data(using: .utf8))),
        ])
        let service = KrisAIGatewayService(
            endpoint: URL(string: "https://api.kris.example/v1/ai/training-plan-candidates")!,
            sessionToken: "test-device-session",
            requestLoader: { request in try await recorder.load(request) }
        )

        let response = try await service.generatePlan(context: makeAIContext())
        XCTAssertEqual(response.schemaVersion, AIPlanPolicy.responseSchemaVersion)
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testGatewayCancellationStopsGeneration() async {
        let service = KrisAIGatewayService(
            endpoint: URL(string: "https://api.kris.example/v1/ai/training-plan-candidates")!,
            sessionToken: "test-device-session",
            requestLoader: { request in
                try await Task.sleep(for: .seconds(5))
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: nil
                )!
                return (Data(), response)
            }
        )
        let context = makeAIContext()
        let task = Task { try await service.generatePlan(context: context) }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled generation should not produce a plan")
        } catch let error as AIServiceError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    private func makeAIContext() -> AIRedactedPlanContext {
        let input = AIPlanUserInput(
            date: "2026-09-10", objective: "减脂保肌", availableMinutes: 55,
            equipment: "常规健身房", notes: "上肢", symptoms: .noneReported
        )
        return AIRedactedPlanContext(
            generatedAt: "2026-09-10T09:00:00Z", userInput: input,
            readiness: .init(
                score: 68, state: "train_maintain", confidence: "medium", safetyGate: "normal"
            ),
            localDecision: LocalPlanDecision(
                action: .maintain, title: "可训练", summary: "维持计划",
                evidence: [.maintainState], rollbackCondition: "不适时停止",
                ruleVersion: LocalPlanEngine.ruleVersion
            ),
            recentConfirmedTraining: [
                .init(
                    date: "2026-09-08", title: "上肢", durationMinutes: 42,
                    completedSetCount: 12, status: "completed"
                ),
            ],
            currentPlan: nil, progressionNotes: [], dataGaps: []
        )
    }

    private func validAIPlanJSON() -> String {
        """
        {
          "schema_version":"AIPlanResponse.v1",
          "rationale":"先恢复动作质量。",
          "cautions":["首组校准重量"],
          "plan":{
            "title":"上肢回归","estimated_minutes":50,"goal":"恢复力量训练",
            "safety_gates":["动作变形时停止加重"],
            "exercises":[{
              "name":"高位下拉","equipment_variant":"常规器械","target_weight_kg":40,
              "sets":3,"target_reps":10,"rest_seconds":90,
              "notes":["保持躯干稳定"],"alternative":"辅助引体向上"
            }]
          }
        }
        """
    }

    @MainActor
    func testV1CandidateRemainsInspectableButCannotPublish() throws {
        let model = AppModel(inMemory: true)
        let plan = try XCTUnwrap(model.currentPlan)
        let candidate = TrainingPlanCandidate(
            candidateId: UUID(), plan: plan, status: .draft,
            createdAt: DateFormatting.iso(), source: "local_user",
            decisionRuleVersion: LocalPlanEngine.ruleVersion
        )
        XCTAssertTrue(model.savePlanCandidate(candidate).isEmpty)
        XCTAssertFalse(model.publishPlanCandidate())
        XCTAssertFalse(model.confirmPlanCandidate())
        XCTAssertFalse(model.publishPlanCandidate())
        XCTAssertEqual(model.currentPlan?.planId, plan.planId)
    }

    @MainActor
    func testLegacyAICandidateCannotBeEditedAfterPersistence() throws {
        let model = AppModel(inMemory: true)
        var plan = try XCTUnwrap(model.currentPlan)
        plan.title = "AI 候选"
        plan.exercises[0].sets = 3
        var candidate = TrainingPlanCandidate(
            candidateId: UUID(), plan: plan, status: .awaitingConfirmation,
            createdAt: DateFormatting.iso(),
            source: "deepseek:deepseek-flash:\(AIPlanPolicy.promptVersion)",
            decisionRuleVersion: LocalPlanEngine.ruleVersion
        )
        XCTAssertTrue(model.savePlanCandidate(candidate).isEmpty)

        candidate.plan.exercises[0].sets = 4
        candidate.plan.exercises[0].targetReps = 8
        candidate.plan.exercises[0].restSeconds = 120
        XCTAssertFalse(model.savePlanCandidate(candidate).isEmpty)

        XCTAssertEqual(model.planCandidate?.status, .awaitingConfirmation)
        XCTAssertEqual(model.planCandidate?.plan.exercises[0].sets, 3)
        XCTAssertEqual(model.planCandidate?.plan.exercises[0].targetReps, plan.exercises[0].targetReps)
        XCTAssertEqual(model.planCandidate?.plan.exercises[0].restSeconds, plan.exercises[0].restSeconds)
        XCTAssertNotEqual(model.currentPlan?.title, "AI 候选")
    }

    func testLocalPlanGatePrioritizesSafetyBeforePlanAvailability() {
        let result = LocalPlanEngine.decide(
            readiness: nil, evaluatedAt: nil, signalsFresh: false,
            symptoms: .emergencyReported, hasPlan: false,
            now: Date(), calendar: .autoupdatingCurrent
        )
        XCTAssertEqual(result.action, .stop)
        XCTAssertEqual(result.evidence, [.emergencyReported])
    }

    func testLocalPlanGateDoesNotTreatMissingPlanOrReadinessAsRecovery() {
        let now = Date()
        let noPlan = LocalPlanEngine.decide(
            readiness: nil, evaluatedAt: nil, signalsFresh: false,
            symptoms: .noneReported, hasPlan: false,
            now: now, calendar: .autoupdatingCurrent
        )
        XCTAssertEqual(noPlan.action, .needsPlan)

        let missingReadiness = LocalPlanEngine.decide(
            readiness: nil, evaluatedAt: nil, signalsFresh: false,
            symptoms: .noneReported, hasPlan: true,
            now: now, calendar: .autoupdatingCurrent
        )
        XCTAssertEqual(missingReadiness.action, .needsAssessment)
    }

    func testLocalPlanGateRequiresFreshConfidentKnownReadiness() {
        let now = Date()
        let readiness = SnapshotReadiness(
            score: 85, state: "train_progress", label: "可推进",
            confidence: "high", safetyGate: "normal", components: nil
        )
        let stale = LocalPlanEngine.decide(
            readiness: readiness, evaluatedAt: now.addingTimeInterval(-86_400),
            signalsFresh: true, symptoms: .noneReported, hasPlan: true,
            now: now, calendar: .autoupdatingCurrent
        )
        XCTAssertEqual(stale.action, .needsAssessment)

        let lowReadinessConfidence = SnapshotReadiness(
            score: 85, state: "train_progress", label: "可推进",
            confidence: "low", safetyGate: "normal", components: nil
        )
        let lowConfidence = LocalPlanEngine.decide(
            readiness: lowReadinessConfidence, evaluatedAt: now, signalsFresh: true,
            symptoms: .noneReported, hasPlan: true,
            now: now, calendar: .autoupdatingCurrent
        )
        XCTAssertEqual(lowConfidence.action, .needsAssessment)
    }

    func testLocalPlanGateHighReadinessDoesNotAuthorizeWeightIncrease() {
        let now = Date()
        let readiness = SnapshotReadiness(
            score: 92, state: "train_progress", label: "状态良好",
            confidence: "high", safetyGate: "normal", components: nil
        )
        let result = LocalPlanEngine.decide(
            readiness: readiness, evaluatedAt: now, signalsFresh: true,
            symptoms: .noneReported, hasPlan: true,
            now: now, calendar: .autoupdatingCurrent
        )
        XCTAssertEqual(result.action, .maintain)
        XCTAssertTrue(result.evidence.contains(.progressionRequiresSeparateReview))
    }

    func testLocalPlanGateDoesNotInferSymptomsFromMissingFeedback() {
        let now = Date()
        let readiness = SnapshotReadiness(
            score: 70, state: "train_maintain", label: "可训练",
            confidence: "medium", safetyGate: "normal", components: nil
        )
        let result = LocalPlanEngine.decide(
            readiness: readiness, evaluatedAt: now, signalsFresh: true,
            symptoms: .notReported, hasPlan: true,
            now: now, calendar: .autoupdatingCurrent
        )
        XCTAssertEqual(result.action, .needsAssessment)
        XCTAssertEqual(result.evidence, [.symptomsNotReported])
    }

    @MainActor
    func testPairingScannerRejectsInvalidAndDuplicateQueryValues() {
        XCTAssertFalse(QRCodeScannerView.isValidPairingCode("https://example.com"))
        XCTAssertFalse(QRCodeScannerView.isValidPairingCode("kriscoach://pair?host=192.168.1.2"))
        XCTAssertFalse(QRCodeScannerView.isValidPairingCode(
            "kriscoach://pair?host=192.168.1.2&host=evil.test&port=8843&fingerprint=AA&token=one"
        ))
        XCTAssertTrue(QRCodeScannerView.isValidPairingCode(
            "kriscoach://pair?host=192.168.1.2&port=8843&fingerprint=AA&token=one"
        ))
    }

    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Expected: Decodable {
                var score: Double?
                var state: String
                var confidence: String
                var safetyGate: String
            }
            var name: String
            var input: ReadinessInput
            var expected: Expected
        }
        var cases: [Case]
    }

    func testPythonAndSwiftGoldenCasesMatch() throws {
        let rulesURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "readiness.v1", withExtension: "json"))
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "readiness_golden.v1", withExtension: "json"))
        let engine = try ReadinessEngine(data: Data(contentsOf: rulesURL))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fixture = try decoder.decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        for item in fixture.cases {
            let result = engine.evaluate(item.input)
            XCTAssertEqual(result.score, item.expected.score, item.name)
            XCTAssertEqual(result.state, item.expected.state, item.name)
            XCTAssertEqual(result.confidence, item.expected.confidence, item.name)
            XCTAssertEqual(result.safetyGate, item.expected.safetyGate, item.name)
        }
    }

    func testWatchExecutionPersistenceClassifiesMissingAndClearedData() throws {
        guard case .missing = WatchExecutionPersistenceCodec.decode(nil) else {
            return XCTFail("不存在的快照应返回 missing")
        }

        let cleared = try WatchExecutionPersistenceCodec.encode(snapshot: nil)
        guard case .missing = WatchExecutionPersistenceCodec.decode(cleared) else {
            return XCTFail("显式清空的快照应返回 missing")
        }
    }

    func testWatchExecutionPersistenceRoundTripsCurrentSchema() throws {
        let snapshot = watchExecutionSnapshot()
        let data = try WatchExecutionPersistenceCodec.encode(snapshot: snapshot)

        guard case .valid(let restored) = WatchExecutionPersistenceCodec.decode(data) else {
            return XCTFail("当前 schema 的完整快照应成功恢复")
        }
        XCTAssertEqual(restored, snapshot)
    }

    func testWatchExecutionPersistenceClassifiesCorruptAndUnsupportedData() {
        guard case .corrupt = WatchExecutionPersistenceCodec.decode(Data("not-json".utf8)) else {
            return XCTFail("损坏数据应返回 corrupt")
        }

        let unsupported = Data(#"{"schema_version":999}"#.utf8)
        guard case .unsupported(let version) = WatchExecutionPersistenceCodec.decode(unsupported) else {
            return XCTFail("未知 schema 应返回 unsupported")
        }
        XCTAssertEqual(version, 999)
    }

    func testWorkoutMirrorEnvelopeRoundTripsEventsAndCommands() throws {
        let sessionID = UUID()
        let event = WatchEvent(
            eventId: UUID(), sessionId: sessionID, kind: .sessionStarted,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil,
            feeling: nil, createdAt: DateFormatting.iso(), workoutUuid: nil, workout: nil
        )
        let eventData = try ContractCoding.encoder.encode(WorkoutMirrorEnvelope(event: event))
        let decodedEvent = try ContractCoding.decoder.decode(
            WorkoutMirrorEnvelope.self, from: eventData
        )
        XCTAssertEqual(decodedEvent.validatedEvent, event)
        XCTAssertNil(decodedEvent.validatedCommand)

        let command = WorkoutCommand(
            commandId: UUID(), sessionId: sessionID, kind: .pause,
            createdAt: DateFormatting.iso()
        )
        let commandData = try ContractCoding.encoder.encode(WorkoutMirrorEnvelope(command: command))
        let decodedCommand = try ContractCoding.decoder.decode(
            WorkoutMirrorEnvelope.self, from: commandData
        )
        XCTAssertEqual(decodedCommand.validatedCommand, command)
        XCTAssertNil(decodedCommand.validatedEvent)
    }

    func testWorkoutMirrorEnvelopeRejectsMismatchedIdentityAndVersion() {
        let command = WorkoutCommand(
            commandId: UUID(), sessionId: UUID(), kind: .stop,
            createdAt: DateFormatting.iso()
        )
        var mismatched = WorkoutMirrorEnvelope(command: command)
        mismatched.messageId = UUID()
        XCTAssertNil(mismatched.validatedCommand)

        var future = WorkoutMirrorEnvelope(command: command)
        future.schemaVersion = "WorkoutMirror.v2"
        XCTAssertNil(future.validatedCommand)
    }

    func testWatchExecutionRecoveryUsesExerciseIDBeforeStaleIndex() {
        var snapshot = watchExecutionSnapshot()
        let expectedID = snapshot.plan.exercises[1].exerciseId
        snapshot.currentExerciseId = expectedID
        snapshot.exerciseIndex = 0
        snapshot.plan.exercises.swapAt(0, 1)

        XCTAssertEqual(WatchExecutionRecovery.exerciseIndex(for: snapshot), 0)
        XCTAssertEqual(snapshot.plan.exercises[0].exerciseId, expectedID)
    }

    func testReadinessPresentationUsesVersionedContractValues() {
        XCTAssertEqual(ReadinessPresentation.stateLabel("train_progress"), "可推进")
        XCTAssertEqual(ReadinessPresentation.stateLabel("train_maintain"), "可训练")
        XCTAssertEqual(ReadinessPresentation.stateLabel("train_reduce"), "需降阶")
        XCTAssertEqual(ReadinessPresentation.stateLabel("recover_or_light"), "恢复优先")
        XCTAssertEqual(ReadinessPresentation.stateLabel("insufficient_data"), "数据不足")
        XCTAssertEqual(ReadinessPresentation.stateLabel("unknown"), "等待本地数据")
        XCTAssertEqual(
            ReadinessPresentation.decisionLine(nil),
            "授权 Apple 健康后开始形成个人基线"
        )

        let reduced = SnapshotReadiness(
            score: 57, state: "train_reduce", label: "可训练，但降阶",
            confidence: "medium", safetyGate: "normal", components: nil
        )
        XCTAssertEqual(
            ReadinessPresentation.decisionLine(reduced),
            "保留训练习惯，降低今天的训练负荷"
        )

        let recovery = SnapshotReadiness(
            score: 33, state: "recover_or_light", label: "恢复优先",
            confidence: "high", safetyGate: "normal", components: nil
        )
        XCTAssertEqual(ReadinessPresentation.decisionLine(recovery), "优先恢复，或只进行轻量活动")

        var stopped = reduced
        stopped.safetyGate = "stop_and_seek_care"
        XCTAssertEqual(ReadinessPresentation.decisionLine(stopped), "停止训练并优先处理异常信号")
    }

    func testTodayStatePresentationSeparatesDailyHealthFromTrainingPrescription() {
        let stable = SnapshotReadiness(
            score: 72, state: "train_maintain", label: "可训练",
            confidence: "high", safetyGate: "normal", components: nil
        )
        XCTAssertEqual(TodayStatePresentation.title(stable), "恢复状态稳定")
        XCTAssertEqual(TodayStatePresentation.status(stable), "状态正常")
        XCTAssertEqual(
            TodayStatePresentation.summary(stable, hasTrainingPlan: false),
            "恢复信号接近近期基线，保持日常活动即可。"
        )
        XCTAssertEqual(
            TodayStatePresentation.summary(stable, hasTrainingPlan: true),
            "恢复信号接近近期基线，今天可以按计划训练。"
        )

        var reduced = stable
        reduced.state = "train_reduce"
        reduced.safetyGate = "reduce"
        XCTAssertEqual(TodayStatePresentation.title(reduced), "今天适合放慢一点")
        XCTAssertEqual(TodayStatePresentation.status(reduced), "需调整")
        XCTAssertTrue(
            TodayStatePresentation.summary(reduced, hasTrainingPlan: true)
                .contains("降低强度或容量")
        )
    }

    func testSleepIntervalsAreDeduplicated() {
        let start = Date(timeIntervalSince1970: 0)
        let intervals = [
            HealthInterval(start: start, end: start.addingTimeInterval(3600)),
            HealthInterval(start: start.addingTimeInterval(1800), end: start.addingTimeInterval(5400)),
        ]
        XCTAssertEqual(HealthReducers.mergedDuration(intervals), 5400)
    }

    func testMorningBodyRequiresCompleteQuartet() {
        let base = HealthSampleContract(
            sampleUuid: "1", metric: .bodyMass, startAt: "2026-08-31T08:00:00+08:00",
            endAt: "2026-08-31T08:00:01+08:00", value: 80, unit: "kg", source: "S800", metadata: nil
        )
        var samples = [base]
        for (index, pair) in [(HealthMetric.bodyFatPercentage, 24.0), (.leanBodyMass, 60.8), (.bmi, 25.5)].enumerated() {
            var sample = base
            sample.sampleUuid = "\(index + 2)"
            sample.metric = pair.0
            sample.value = pair.1
            samples.append(sample)
        }
        XCTAssertNotNil(HealthReducers.latestCompleteBodySet(samples))
        XCTAssertNil(HealthReducers.latestCompleteBodySet(Array(samples.dropLast())))
    }

    func testIncompleteIPhoneCoverageFallsBackToSyncHealth() {
        let coverage = [MetricCoverage(date: "2026-08-31", metric: "step_count", status: .partial, reason: nil)]
        XCTAssertEqual(HealthReducers.sourceFor(date: "2026-08-31", metric: "step_count", coverage: coverage), "synchealth")
    }

    func testCompleteBodySetAllowsSmallTimestampDifferencesButNotLaterWeightOnly() {
        let rows = [
            bodySample(id: "mass", metric: .bodyMass, time: "2026-09-01T08:00:00+08:00", value: 84),
            bodySample(id: "fat", metric: .bodyFatPercentage, time: "2026-09-01T08:00:12+08:00", value: 24),
            bodySample(id: "lean", metric: .leanBodyMass, time: "2026-09-01T08:00:09+08:00", value: 63.8),
            bodySample(id: "bmi", metric: .bmi, time: "2026-09-01T08:00:05+08:00", value: 26.8),
            bodySample(id: "later", metric: .bodyMass, time: "2026-09-01T20:00:00+08:00", value: 85),
        ]
        let result = HealthReducers.latestCompleteBodySet(rows)
        XCTAssertEqual(result?[.bodyMass], 84)
    }

    func testLocalReadinessUsesMergedSleepAndPersonalBaselines() throws {
        let rulesURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "readiness.v1", withExtension: "json"))
        let engine = try ReadinessEngine(data: Data(contentsOf: rulesURL))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-01T12:00:00+08:00"))
        var samples: [HealthSampleContract] = []
        for day in 25...31 {
            let date = String(format: "2026-08-%02d", day)
            samples += recoverySamples(date: date, sleepHours: 8, hrv: 50, rhr: 60)
        }
        samples += [
            sample(id: "sleep-a", metric: .sleep, start: "2026-09-01T00:00:00+08:00", end: "2026-09-01T05:00:00+08:00", value: 18_000),
            sample(id: "sleep-b", metric: .sleep, start: "2026-09-01T04:00:00+08:00", end: "2026-09-01T08:00:00+08:00", value: 14_400),
            sample(id: "hrv-today", metric: .hrvSdnn, start: "2026-09-01T07:00:00+08:00", value: 60),
            sample(id: "hrv-today", metric: .hrvSdnn, start: "2026-09-01T07:00:00+08:00", value: 60),
            sample(id: "rhr-today", metric: .restingHeartRate, start: "2026-09-01T07:00:00+08:00", value: 58),
        ]

        let result = HealthReducers.localReadiness(samples: samples, engine: engine, now: now, calendar: calendar)
        XCTAssertEqual(result.readiness.components?["sleep"]!, 50)
        XCTAssertEqual(result.readiness.components?["hrv"]!, 66)
        XCTAssertEqual(result.readiness.components?["rhr"]!, 53)
        XCTAssertEqual(result.readiness.confidence, "medium")
        XCTAssertEqual(result.dataGaps, ["本地训练负荷基线仍在建立"])
    }

    func testPartialHealthPermissionKeepsResultLowConfidenceAndNamesGaps() throws {
        let rulesURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "readiness.v1", withExtension: "json"))
        let engine = try ReadinessEngine(data: Data(contentsOf: rulesURL))
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-01T12:00:00+08:00"))
        let samples = [sample(id: "hrv", metric: .hrvSdnn, start: "2026-09-01T08:00:00+08:00", value: 55)]
        let result = HealthReducers.localReadiness(samples: samples, engine: engine, now: now)
        XCTAssertEqual(result.readiness.confidence, "low")
        XCTAssertTrue(result.dataGaps.contains("今天缺少可用睡眠区间"))
        XCTAssertTrue(result.dataGaps.contains("今天缺少静息心率"))
    }

    func testDailyMetricsDeduplicateSamplesAndUseCompleteBodySet() {
        let samples = [
            sample(id: "steps", metric: .stepCount, start: "2026-09-01T08:00:00+08:00", value: 1200),
            sample(id: "steps", metric: .stepCount, start: "2026-09-01T08:00:00+08:00", value: 1200),
            sample(id: "energy", metric: .activeEnergy, start: "2026-09-01T09:00:00+08:00", value: 88),
            bodySample(id: "mass", metric: .bodyMass, time: "2026-09-01T07:00:00+08:00", value: 84),
            bodySample(id: "fat", metric: .bodyFatPercentage, time: "2026-09-01T07:00:10+08:00", value: 24),
            bodySample(id: "lean", metric: .leanBodyMass, time: "2026-09-01T07:00:08+08:00", value: 63.8),
            bodySample(id: "bmi", metric: .bmi, time: "2026-09-01T07:00:06+08:00", value: 26.8),
        ]
        let now = DateFormatting.parse("2026-09-01T12:00:00+08:00")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let result = HealthReducers.dailyMetrics(samples: samples, now: now, calendar: calendar)
        XCTAssertEqual(result.steps, 1200)
        XCTAssertEqual(result.activeKcal, 88)
        XCTAssertEqual(result.bodyMassKg, 84)
        XCTAssertEqual(result.bodyFatPercent, 24)
    }

    func testStepCountsPreferHigherPrioritySourceDuringOverlappingIntervals() {
        let samples = [
            sample(id: "iphone-steps", metric: .stepCount,
                   start: "2026-09-01T08:00:00+08:00", end: "2026-09-01T08:10:00+08:00",
                   value: 1_000, source: "iPhone"),
            sample(id: "watch-steps", metric: .stepCount,
                   start: "2026-09-01T08:05:00+08:00", end: "2026-09-01T08:15:00+08:00",
                   value: 900, source: "Apple Watch"),
            sample(id: "later-steps", metric: .stepCount,
                   start: "2026-09-01T09:00:00+08:00", end: "2026-09-01T09:00:00+08:00",
                   value: 100, source: "iPhone"),
        ]
        let now = DateFormatting.parse("2026-09-01T12:00:00+08:00")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let daily = HealthReducers.dailyMetrics(samples: samples, now: now, calendar: calendar)
        let trends = HealthReducers.dailyTrends(samples: samples, now: now, calendar: calendar)

        // 08:00-08:05 uses iPhone (500), 08:05-08:15 uses Watch (900),
        // plus the independent point sample (100).
        XCTAssertEqual(try XCTUnwrap(daily.steps), 1_500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(trends.steps?.last?.value), 1_500, accuracy: 0.001)
    }

    func testHealthKitFractionalBodyFatIsPresentedAsPercent() throws {
        let samples = [
            bodySample(id: "mass", metric: .bodyMass, time: "2026-09-01T07:00:00+08:00", value: 84.3),
            bodySample(id: "fat", metric: .bodyFatPercentage, time: "2026-09-01T07:00:10+08:00", value: 0.264),
            bodySample(id: "lean", metric: .leanBodyMass, time: "2026-09-01T07:00:08+08:00", value: 62),
            bodySample(id: "bmi", metric: .bmi, time: "2026-09-01T07:00:06+08:00", value: 26.9),
        ]
        let now = DateFormatting.parse("2026-09-01T12:00:00+08:00")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let daily = HealthReducers.dailyMetrics(samples: samples, now: now, calendar: calendar)
        let trends = HealthReducers.dailyTrends(samples: samples, now: now, calendar: calendar)

        XCTAssertEqual(try XCTUnwrap(daily.bodyFatPercent), 26.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(trends.bodyFat?.last?.value), 26.4, accuracy: 0.001)
        guard case .number(let latest)? = trends.latestBody?["body_fat_pct"] else {
            return XCTFail("缺少本地最新体脂摘要")
        }
        XCTAssertEqual(latest, 26.4, accuracy: 0.001)
    }

    func testLocalTrendsUseDeduplicatedHealthKitDaysAndCompleteBodySets() {
        var samples = [
            sample(id: "sleep-1", metric: .sleep, start: "2026-08-31T00:00:00+08:00", end: "2026-08-31T07:00:00+08:00", value: 25_200),
            sample(id: "sleep-2", metric: .sleep, start: "2026-09-01T00:00:00+08:00", end: "2026-09-01T08:00:00+08:00", value: 28_800),
            sample(id: "hrv-1", metric: .hrvSdnn, start: "2026-08-31T07:00:00+08:00", value: 48),
            sample(id: "hrv-2", metric: .hrvSdnn, start: "2026-09-01T07:00:00+08:00", value: 54),
            sample(id: "hrv-2", metric: .hrvSdnn, start: "2026-09-01T07:00:00+08:00", value: 54),
            sample(id: "steps-1", metric: .stepCount, start: "2026-08-31T12:00:00+08:00", value: 6_000),
            sample(id: "steps-2", metric: .stepCount, start: "2026-09-01T12:00:00+08:00", value: 7_500),
            sample(id: "energy-1", metric: .activeEnergy, start: "2026-08-31T12:00:00+08:00", value: 520),
            sample(id: "energy-2", metric: .activeEnergy, start: "2026-09-01T12:00:00+08:00", value: 680),
        ]
        for (day, weight, fat) in [("2026-08-31", 84.5, 24.5), ("2026-09-01", 84.1, 24.2)] {
            samples += [
                bodySample(id: "mass-\(day)", metric: .bodyMass, time: "\(day)T07:10:00+08:00", value: weight),
                bodySample(id: "fat-\(day)", metric: .bodyFatPercentage, time: "\(day)T07:10:05+08:00", value: fat),
                bodySample(id: "lean-\(day)", metric: .leanBodyMass, time: "\(day)T07:10:03+08:00", value: 63.7),
                bodySample(id: "bmi-\(day)", metric: .bmi, time: "\(day)T07:10:02+08:00", value: 26.8),
            ]
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let trends = HealthReducers.dailyTrends(
            samples: samples,
            now: DateFormatting.parse("2026-09-01T12:00:00+08:00")!,
            calendar: calendar
        )
        XCTAssertEqual(trends.sleep?.map(\.value), [7, 8])
        XCTAssertEqual(trends.hrv?.map(\.value), [48, 54])
        XCTAssertEqual(trends.weight?.map(\.value), [84.5, 84.1])
        XCTAssertEqual(trends.bodyFat?.map(\.value), [24.5, 24.2])
        XCTAssertEqual(trends.steps?.map(\.value), [6_000, 7_500])
        XCTAssertEqual(trends.activeEnergy?.map(\.value), [520, 680])
    }

    func testLocalReadinessHistoryUsesTheVersionedEngineForEachDay() throws {
        let rulesURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "readiness.v1", withExtension: "json"))
        let engine = try ReadinessEngine(data: Data(contentsOf: rulesURL))
        let days = [
            "2026-08-25", "2026-08-26", "2026-08-27", "2026-08-28",
            "2026-08-29", "2026-08-30", "2026-08-31", "2026-09-01",
        ]
        var samples: [HealthSampleContract] = []
        for (index, day) in days.enumerated() {
            samples += [
                sample(
                    id: "sleep-\(day)", metric: .sleep,
                    start: "\(day)T00:00:00+08:00", end: "\(day)T07:00:00+08:00",
                    value: 25_200
                ),
                sample(id: "hrv-\(day)", metric: .hrvSdnn, start: "\(day)T07:10:00+08:00", value: 42 + Double(index)),
                sample(id: "rhr-\(day)", metric: .restingHeartRate, start: "\(day)T07:12:00+08:00", value: 66 - Double(index) / 2),
            ]
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let trends = HealthReducers.dailyTrends(
            samples: samples, engine: engine,
            now: DateFormatting.parse("2026-09-01T12:00:00+08:00")!,
            calendar: calendar
        )

        XCTAssertEqual(trends.readiness?.count, days.count)
        XCTAssertEqual(trends.readiness?.last?.date, "2026-09-01")
        XCTAssertEqual(trends.readiness?.last?.source, "iphone_healthkit")
        XCTAssertNotNil(trends.readiness?.last?.score)
    }

    func testHealthImportOnlyFailsWhenNoUsefulDataOrAllCoreMetricsFail() {
        XCTAssertEqual(HealthKitService.resolvedState(successful: 9, failedMetrics: [.sleep]), .ready)
        XCTAssertEqual(
            HealthKitService.resolvedState(successful: 9, failedMetrics: [.sleep, .hrvSdnn, .restingHeartRate]),
            .failed
        )
        XCTAssertEqual(HealthKitService.resolvedState(successful: 0, failedMetrics: []), .failed)
        XCTAssertEqual(
            HealthKitService.resolvedState(successful: 12, failedMetrics: [], usefulSampleCount: 0),
            .noData
        )
        XCTAssertEqual(
            HealthKitService.resolvedState(successful: 12, failedMetrics: [], usefulSampleCount: 1),
            .ready
        )
    }

    func testAutomaticHealthRefreshOnlyRunsAfterInitialAuthorizationAndCoalescesImports() {
        XCTAssertTrue(HealthKitService.shouldEnableAutomaticUpdates(successfulMetricQueries: 12))
        XCTAssertTrue(HealthKitService.shouldEnableAutomaticUpdates(successfulMetricQueries: 1))
        XCTAssertFalse(HealthKitService.shouldEnableAutomaticUpdates(successfulMetricQueries: 0))
        XCTAssertTrue(HealthKitService.shouldRefreshAutomatically(
            hasImportedBefore: true, state: .ready
        ))
        XCTAssertTrue(HealthKitService.shouldRefreshAutomatically(
            hasImportedBefore: true, state: .failed
        ))
        XCTAssertFalse(HealthKitService.shouldRefreshAutomatically(
            hasImportedBefore: false, state: .idle
        ))
        XCTAssertFalse(HealthKitService.shouldRefreshAutomatically(
            hasImportedBefore: true, state: .importing
        ))
        XCTAssertFalse(HealthKitService.shouldRefreshAutomatically(
            hasImportedBefore: true, state: .authorizing
        ))
        XCTAssertFalse(HealthKitService.shouldRefreshAutomatically(
            hasImportedBefore: true, state: .ready,
            interactiveTrainingActive: true
        ))

        var accumulator = HealthRefreshAccumulator()
        accumulator.enqueue(.hrvSdnn)
        accumulator.enqueue(.workout)
        accumulator.enqueue(.hrvSdnn)
        XCTAssertEqual(accumulator.takeAll(), [.hrvSdnn, .workout])
        XCTAssertTrue(accumulator.isEmpty)

        XCTAssertFalse(AppModel.shouldRunForegroundMaintenance(hasActiveTraining: true))
        XCTAssertTrue(AppModel.shouldRunForegroundMaintenance(hasActiveTraining: false))
    }

    func testWorkoutMetadataBackfillRunsOnceForWorkoutOnly() {
        XCTAssertTrue(HealthKitService.needsWorkoutMetadataBackfill(
            metric: .workout, hasCompletedBackfill: false
        ))
        XCTAssertFalse(HealthKitService.needsWorkoutMetadataBackfill(
            metric: .workout, hasCompletedBackfill: true
        ))
        XCTAssertFalse(HealthKitService.needsWorkoutMetadataBackfill(
            metric: .activeEnergy, hasCompletedBackfill: false
        ))
    }

    @MainActor
    func testPendingHealthBatchesMergeBySampleUUIDAndPreferCompleteCoverage() throws {
        let sampleA = sample(id: "a", metric: .stepCount, start: "2026-09-01T08:00:00+08:00", value: 100)
        let sampleB = sample(id: "b", metric: .stepCount, start: "2026-09-01T09:00:00+08:00", value: 200)
        let first = HealthBatch(
            batchId: UUID(), deviceId: "phone", createdAt: DateFormatting.iso(), anchor: nil,
            samples: [sampleA],
            coverage: [MetricCoverage(date: "2026-09-01", metric: "step_count", status: .partial, reason: nil)]
        )
        let second = HealthBatch(
            batchId: UUID(), deviceId: "phone", createdAt: DateFormatting.iso(), anchor: nil,
            samples: [sampleA, sampleB],
            coverage: [MetricCoverage(date: "2026-09-01", metric: "step_count", status: .complete, reason: nil)]
        )
        let merged = try XCTUnwrap(AppModel.mergeHealthBatches([first, second]))
        XCTAssertEqual(merged.samples.map(\.sampleUuid), ["a", "b"])
        XCTAssertEqual(merged.coverage.first?.status, .complete)
    }

    func testHealthBatchChunksStayWithinUploadSampleLimit() throws {
        let template = sample(
            id: "0", metric: .hrvSdnn,
            start: "2026-09-01T08:00:00+08:00", value: 55
        )
        let samples = (0..<4_501).map { index -> HealthSampleContract in
            var row = template
            row.sampleUuid = "sample-\(index)"
            return row
        }
        let batch = HealthBatch(
            batchId: UUID(), deviceId: "phone", createdAt: DateFormatting.iso(),
            anchor: nil, samples: samples,
            coverage: [MetricCoverage(date: "2026-09-01", metric: "hrv_sdnn", status: .partial, reason: nil)]
        )
        let chunks = batch.chunked()
        XCTAssertEqual(chunks.map(\.samples.count), [2_000, 2_000, 501])
        XCTAssertEqual(Set(chunks.flatMap(\.samples).map(\.sampleUuid)).count, 4_501)
        for chunk in chunks {
            XCTAssertLessThan(try ContractCoding.encoder.encode(chunk).count, 5 * 1_024 * 1_024)
        }
    }

    func testHealthKitErrorsAreLocalizedIntoActionableCategories() {
        let entitlement = NSError(
            domain: "HKErrorDomain", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Missing com.apple.developer.healthkit entitlement."]
        )
        let entitlementResult = HealthKitService.present(entitlement)
        XCTAssertEqual(entitlementResult.action, .reinstall)
        XCTAssertFalse(entitlementResult.message.contains("Missing"))

        let permission = NSError(
            domain: "HKErrorDomain", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Not authorized to access protected health data"]
        )
        XCTAssertEqual(HealthKitService.present(permission).action, .permissions)
    }

    func testBundledSamplePlanIsPreviewOnly() {
        XCTAssertTrue(AppModel.allowsBundledSamplePlan(bundleIdentifier: "com.albertdaisy.kriscoach.preview"))
        XCTAssertFalse(AppModel.allowsBundledSamplePlan(bundleIdentifier: "com.albertdaisy.kriscoach"))
        XCTAssertFalse(AppModel.allowsBundledSamplePlan(bundleIdentifier: nil))
    }

    func testWorkoutLifecycleAllowsOnlyDeclaredTransitions() {
        XCTAssertTrue(WorkoutLifecycleState.preparing.canTransition(to: .running))
        XCTAssertTrue(WorkoutLifecycleState.running.canTransition(to: .paused))
        XCTAssertTrue(WorkoutLifecycleState.paused.canTransition(to: .running))
        XCTAssertTrue(WorkoutLifecycleState.stopped.canTransition(to: .finalizing))
        XCTAssertTrue(WorkoutLifecycleState.finalizing.canTransition(to: .completed))
        XCTAssertFalse(WorkoutLifecycleState.preparing.canTransition(to: .completed))
        XCTAssertFalse(WorkoutLifecycleState.completed.canTransition(to: .running))
        XCTAssertFalse(WorkoutLifecycleState.failed.canTransition(to: .paused))
    }

    @MainActor
    func testPausedTimeIsExcludedFromEffectiveTrainingDuration() throws {
        let model = AppModel(inMemory: true)
        let plan = try XCTUnwrap(model.currentPlan)
        let start = try XCTUnwrap(DateFormatting.parse("2026-09-03T10:00:00Z"))
        var draft = TrainingDraft(
            sessionId: UUID(), plan: plan, startedAt: DateFormatting.iso(start),
            completedSets: [:], watchWorkoutUuid: nil, workout: nil,
            lifecycle: WorkoutLifecycleSnapshot(
                state: .running, sequence: 0,
                startedAt: DateFormatting.iso(start), transitionAt: DateFormatting.iso(start),
                activeDurationSeconds: 0, elapsedDurationSeconds: 0
            ), workoutManagedByWatch: false
        )

        XCTAssertTrue(draft.transitionLocally(to: .paused, at: start.addingTimeInterval(120)))
        XCTAssertEqual(draft.activeDuration(at: start.addingTimeInterval(180)), 120, accuracy: 0.01)
        XCTAssertEqual(draft.elapsedDuration(at: start.addingTimeInterval(180)), 180, accuracy: 0.01)
        XCTAssertTrue(draft.transitionLocally(to: .running, at: start.addingTimeInterval(180)))
        XCTAssertEqual(draft.activeDuration(at: start.addingTimeInterval(240)), 180, accuracy: 0.01)
        XCTAssertTrue(draft.transitionLocally(to: .stopped, at: start.addingTimeInterval(240)))
        XCTAssertEqual(draft.activeDuration(at: start.addingTimeInterval(300)), 180, accuracy: 0.01)
        XCTAssertEqual(draft.elapsedDuration(at: start.addingTimeInterval(300)), 240, accuracy: 0.01)
    }

    @MainActor
    func testPausedTrainingRestoresAfterRelaunch() throws {
        let original = AppModel(inMemory: true)
        original.startTraining()
        original.pauseTraining()
        XCTAssertEqual(original.activeDraft?.lifecycleState, .paused)

        let restored = AppModel(testContainer: original.container)
        XCTAssertEqual(restored.activeDraft?.lifecycleState, .paused)
        XCTAssertTrue(restored.health.interactiveTrainingActive)
    }

    @MainActor
    func testOlderWatchLifecycleSnapshotCannotReopenPausedWorkout() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        let draft = try XCTUnwrap(model.activeDraft)
        let startedAt = draft.startedAt
        let paused = WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .sessionPaused,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil, feeling: nil,
            createdAt: "2026-09-03T10:02:00Z", workoutUuid: nil, workout: nil,
            lifecycle: WorkoutLifecycleSnapshot(
                state: .paused, sequence: 2, startedAt: startedAt,
                transitionAt: "2026-09-03T10:02:00Z",
                activeDurationSeconds: 120, elapsedDurationSeconds: 120
            )
        )
        let staleRunning = WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .sessionResumed,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil, feeling: nil,
            createdAt: "2026-09-03T10:01:00Z", workoutUuid: nil, workout: nil,
            lifecycle: WorkoutLifecycleSnapshot(
                state: .running, sequence: 1, startedAt: startedAt,
                transitionAt: "2026-09-03T10:01:00Z",
                activeDurationSeconds: 60, elapsedDurationSeconds: 60
            )
        )

        model.receiveWatchEvent(paused)
        model.receiveWatchEvent(staleRunning)

        XCTAssertEqual(model.activeDraft?.lifecycleState, .paused)
        XCTAssertEqual(model.activeDraft?.lifecycle?.sequence, 2)
        XCTAssertEqual(model.activeDraft?.workoutManagedByWatch, true)
    }

    @MainActor
    func testWatchManagedTrainingWaitsForWorkoutCompletionBeforeArchiving() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        let draft = try XCTUnwrap(model.activeDraft)
        let running = WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .sessionStarted,
            planId: draft.plan.planId, planRevision: draft.plan.revision,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil, feeling: nil,
            createdAt: draft.startedAt, workoutUuid: nil, workout: nil,
            lifecycle: WorkoutLifecycleSnapshot(
                state: .running, sequence: 1, startedAt: draft.startedAt,
                transitionAt: draft.startedAt,
                activeDurationSeconds: 0, elapsedDurationSeconds: 0
            )
        )
        model.receiveWatchEvent(running)
        let feedback = SessionFeedback(
            energy: .normal, targetMuscleResponse: .good,
            symptoms: "无不适", notes: ""
        )

        model.finishTraining(feedback: feedback, stoppedEarly: true)
        XCTAssertNotNil(model.activeDraft)
        XCTAssertFalse(model.canFinalizeTraining)

        let completed = WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .sessionCompleted,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil, feeling: nil,
            createdAt: "2026-09-03T10:30:00Z", workoutUuid: UUID().uuidString,
            workout: WorkoutSummary(
                durationSeconds: 1_500, activeKcal: 180,
                averageHeartRate: 132, maximumHeartRate: 165
            ),
            lifecycle: WorkoutLifecycleSnapshot(
                state: .completed, sequence: 2, startedAt: draft.startedAt,
                transitionAt: "2026-09-03T10:30:00Z",
                activeDurationSeconds: 1_500, elapsedDurationSeconds: 1_800
            )
        )
        model.receiveWatchEvent(completed)
        XCTAssertTrue(model.canFinalizeTraining)
        model.finishTraining(feedback: feedback, stoppedEarly: true)

        XCTAssertNil(model.activeDraft)
        XCTAssertEqual(model.lastCompletedSession?.workout?.durationSeconds, 1_500)
        XCTAssertEqual(model.queueSummary.trainingSessions, 0)
    }

    @MainActor
    func testWatchManagedDiscardCompletesAfterTerminalEvent() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        let draft = try XCTUnwrap(model.activeDraft)
        model.receiveWatchEvent(WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .sessionStarted,
            planId: draft.plan.planId, planRevision: draft.plan.revision,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil, feeling: nil,
            createdAt: draft.startedAt, workoutUuid: nil, workout: nil,
            lifecycle: WorkoutLifecycleSnapshot(
                state: .running, sequence: 1, startedAt: draft.startedAt,
                transitionAt: draft.startedAt, activeDurationSeconds: 0,
                elapsedDurationSeconds: 0
            )
        ))

        XCTAssertFalse(model.discardTraining())
        XCTAssertTrue(model.isTrainingDiscardPending)

        model.receiveWatchEvent(WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .sessionCompleted,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil, feeling: nil,
            createdAt: "2026-09-03T10:01:00Z", workoutUuid: UUID().uuidString,
            workout: WorkoutSummary(
                durationSeconds: 60, activeKcal: 5,
                averageHeartRate: 100, maximumHeartRate: 110
            ),
            lifecycle: WorkoutLifecycleSnapshot(
                state: .completed, sequence: 2, startedAt: draft.startedAt,
                transitionAt: "2026-09-03T10:01:00Z", activeDurationSeconds: 60,
                elapsedDurationSeconds: 60
            )
        ))

        XCTAssertNil(model.activeDraft)
        XCTAssertFalse(model.isTrainingDiscardPending)
        XCTAssertNil(model.lastCompletedSession)
        let verification = ModelContext(model.container)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ArchivedSessionRecord>()), 0)
    }

    func testSyncErrorsAreLocalizedAndActionable() {
        XCTAssertEqual(
            AppModel.presentSyncError(URLError(.cannotConnectToHost)),
            "暂时无法连接 Mac。确认双方在同一局域网且 companion 正在运行。"
        )
        XCTAssertEqual(
            AppModel.presentSyncError(URLError(.serverCertificateUntrusted)),
            "Mac 身份校验失败，已阻止连接；请在数据页重新扫码配对。"
        )
        XCTAssertFalse(AppModel.presentSyncError(URLError(.timedOut)).contains("timed out"))
    }

    @MainActor
    func testFinishedTrainingArchivesLocallyWithoutCreatingExportWork() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        XCTAssertTrue(model.health.interactiveTrainingActive)
        let draft = try XCTUnwrap(model.activeDraft)
        let exercise = try XCTUnwrap(draft.plan.exercises.first)
        model.recordSet(
            exercise: exercise, setNumber: 1,
            weight: exercise.targetWeightKg, reps: exercise.targetReps, feeling: nil
        )
        model.finishTraining(
            feedback: SessionFeedback(
                energy: .normal, targetMuscleResponse: .good,
                symptoms: "未填写", notes: ""
            ),
            stoppedEarly: false
        )
        XCTAssertEqual(model.queueSummary.trainingSessions, 0)
        XCTAssertEqual(model.queueCount, 0)
        XCTAssertNil(model.activeDraft)
        XCTAssertFalse(model.health.interactiveTrainingActive)
    }

    @MainActor
    func testDiscardEmptyTrainingCreatesNoHistory() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        XCTAssertNotNil(model.activeDraft)

        XCTAssertTrue(model.discardTraining())

        XCTAssertNil(model.activeDraft)
        XCTAssertNil(model.lastCompletedSession)
        XCTAssertFalse(model.health.interactiveTrainingActive)
        let verification = ModelContext(model.container)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ActiveTrainingRecord>()), 0)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ArchivedSessionRecord>()), 0)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<SyncQueueItem>()), 0)
    }

    @MainActor
    func testDiscardTrainingWithCompletedSetCreatesNoHistory() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        let draft = try XCTUnwrap(model.activeDraft)
        let exercise = try XCTUnwrap(draft.plan.exercises.first)
        model.recordSet(
            exercise: exercise, setNumber: 1,
            weight: exercise.targetWeightKg, reps: exercise.targetReps, feeling: .appropriate
        )

        XCTAssertTrue(model.discardTraining())

        let verification = ModelContext(model.container)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ArchivedSessionRecord>()), 0)
        XCTAssertNil(model.localSession(id: draft.sessionId.uuidString))
    }

    @MainActor
    func testFinishedTrainingCreatesReceiptAndQueryableHistory() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        let draft = try XCTUnwrap(model.activeDraft)
        let exercise = try XCTUnwrap(draft.plan.exercises.first)
        model.recordSet(
            exercise: exercise, setNumber: 1,
            weight: exercise.targetWeightKg, reps: exercise.targetReps,
            feeling: .appropriate
        )

        model.finishTraining(
            feedback: SessionFeedback(
                energy: .normal, targetMuscleResponse: .good,
                symptoms: "无不适", notes: "状态稳定"
            ),
            stoppedEarly: true
        )

        let receipt = try XCTUnwrap(model.lastCompletedSession)
        XCTAssertEqual(receipt.status, .stoppedEarly)
        XCTAssertEqual(receipt.exerciseResults.first?.sets.first?.reps, exercise.targetReps)
        XCTAssertEqual(model.localSession(id: receipt.sessionId.uuidString), receipt)
        XCTAssertFalse(model.sessionIsArchivedToMac(receipt.sessionId))

        model.dismissTrainingReceipt()
        XCTAssertNil(model.lastCompletedSession)
        XCTAssertNotNil(model.localSession(id: receipt.sessionId.uuidString))
    }

    @MainActor
    func testDeletingLocalTrainingRemovesArchiveAndPendingExport() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        model.finishTraining(
            feedback: SessionFeedback(
                energy: .normal, targetMuscleResponse: .notRecorded,
                symptoms: "", notes: ""
            ),
            stoppedEarly: true
        )
        let sessionID = try XCTUnwrap(model.lastCompletedSession?.sessionId)
        let context = ModelContext(model.container)
        let session = try XCTUnwrap(model.localSession(id: sessionID.uuidString))
        context.insert(SyncQueueItem(
            kind: "training", payload: try ContractCoding.encoder.encode(session)
        ))
        try context.save()

        XCTAssertTrue(model.deleteLocalSession(id: sessionID.uuidString))

        XCTAssertNil(model.localSession(id: sessionID.uuidString))
        XCTAssertNil(model.lastCompletedSession)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ArchivedSessionRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncQueueItem>()), 0)
    }

    @MainActor
    func testHealthWorkoutCanBeHiddenPersistentlyWithoutDeletingHealthData() {
        let suiteName = "ReadinessEngineTests.history.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(inMemory: true, defaults: defaults)
        model.installHealthWorkoutHistoryFixture()
        XCTAssertTrue(model.effectiveTrainingHistory.contains { $0.id == "fixture-health-run" })

        XCTAssertTrue(model.deleteLocalSession(id: "fixture-health-run"))
        XCTAssertFalse(model.effectiveTrainingHistory.contains { $0.id == "fixture-health-run" })

        let restored = AppModel(inMemory: true, defaults: defaults)
        restored.installHealthWorkoutHistoryFixture()
        XCTAssertFalse(restored.effectiveTrainingHistory.contains { $0.id == "fixture-health-run" })
        XCTAssertFalse(model.deleteLocalSession(id: UUID().uuidString))
    }

    @MainActor
    func testFailedTrainingArchiveKeepsActiveDraftAndCanRetry() throws {
        struct SimulatedSaveFailure: Error {}

        let model = AppModel(inMemory: true)
        model.startTraining()
        let sessionID = try XCTUnwrap(model.activeDraft?.sessionId)
        model.trainingArchiveSaveOverride = { throw SimulatedSaveFailure() }
        let feedback = SessionFeedback(
            energy: .slightlyTired, targetMuscleResponse: .good,
            symptoms: "无不适", notes: "状态一般，提前结束"
        )

        XCTAssertFalse(model.finishTraining(feedback: feedback, stoppedEarly: true))
        XCTAssertEqual(model.activeDraft?.sessionId, sessionID)
        XCTAssertTrue(model.health.interactiveTrainingActive)
        XCTAssertNotNil(model.trainingCompletionError)
        XCTAssertNil(model.lastCompletedSession)

        let verification = ModelContext(model.container)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ActiveTrainingRecord>()), 1)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ArchivedSessionRecord>()), 0)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<SyncQueueItem>()), 0)

        model.trainingArchiveSaveOverride = nil
        XCTAssertTrue(model.finishTraining(feedback: feedback, stoppedEarly: true))
        XCTAssertNil(model.activeDraft)
        XCTAssertNil(model.trainingCompletionError)
        XCTAssertEqual(model.lastCompletedSession?.sessionId, sessionID)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ActiveTrainingRecord>()), 0)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ArchivedSessionRecord>()), 1)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<SyncQueueItem>()), 0)
    }

    func testDataQualityGapsExplainImpactAndRecoveryAction() {
        let incompleteDay = AppModel.explainDataGap("今天尚未结束，能量数据不用于日结")
        XCTAssertEqual(incompleteDay.title, "今日仍在累积")
        XCTAssertEqual(incompleteDay.severity, .information)
        XCTAssertTrue(incompleteDay.impact.contains("不生成完整日总消耗"))

        let missingHRV = AppModel.explainDataGap("今天缺少 HRV")
        XCTAssertEqual(missingHRV.title, "恢复信号缺失")
        XCTAssertEqual(missingHRV.severity, .warning)
        XCTAssertTrue(missingHRV.nextStep.contains("Apple 健康权限"))
    }

    func testReadinessComponentsKeepMissingSignalsExplicit() {
        XCTAssertEqual(ReadinessComponentPresentation.label("load"), "训练负荷")
        XCTAssertEqual(ReadinessComponentPresentation.interpretation(score: 72), "支持训练")
        XCTAssertEqual(ReadinessComponentPresentation.interpretation(score: 51), "接近个人常态")
        XCTAssertEqual(ReadinessComponentPresentation.interpretation(score: 28), "限制今日负荷")
        XCTAssertEqual(ReadinessComponentPresentation.interpretation(score: nil), "未参与今日计算")
    }

    @MainActor
    func testEditingACompletedSetReplacesItsRecordedValues() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        let draft = try XCTUnwrap(model.activeDraft)
        let exercise = try XCTUnwrap(draft.plan.exercises.first)
        model.recordSet(
            exercise: exercise, setNumber: 1,
            weight: 80, reps: 12, feeling: nil
        )
        model.recordSet(
            exercise: exercise, setNumber: 1,
            weight: 82.5, reps: 10, feeling: nil
        )

        let recorded = try XCTUnwrap(model.activeDraft?.completedSets[exercise.exerciseId])
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.weightKg, 82.5)
        XCTAssertEqual(recorded.first?.reps, 10)
    }

    @MainActor
    func testActiveTrainingDraftRestoresAfterAppRelaunch() throws {
        let original = AppModel(inMemory: true)
        original.startTraining()
        let draft = try XCTUnwrap(original.activeDraft)
        let exercise = try XCTUnwrap(draft.plan.exercises.first)
        original.recordSet(
            exercise: exercise, setNumber: 1,
            weight: exercise.targetWeightKg, reps: exercise.targetReps, feeling: .appropriate
        )

        let restored = AppModel(testContainer: original.container)

        XCTAssertEqual(restored.activeDraft?.sessionId, draft.sessionId)
        XCTAssertTrue(restored.health.interactiveTrainingActive)
        XCTAssertEqual(
            restored.activeDraft?.completedSets[exercise.exerciseId]?.first?.reps,
            exercise.targetReps
        )
        XCTAssertEqual(
            restored.activeDraft?.completedSets[exercise.exerciseId]?.first?.lastSetFeeling,
            .appropriate
        )
    }

    @MainActor
    func testExerciseAdjustmentKeepsPublishedPlanLockedAndRestoresAfterRelaunch() throws {
        let original = AppModel(inMemory: true)
        original.startTraining()
        let draft = try XCTUnwrap(original.activeDraft)
        let planned = try XCTUnwrap(draft.plan.exercises.first)

        original.updateExerciseExecution(
            plannedExerciseId: planned.exerciseId,
            name: "坐姿水平腿举",
            equipmentVariant: "另一台水平腿举机",
            targetWeightKg: 72.5,
            sets: 4,
            targetReps: 10,
            restSeconds: 105,
            kind: .plannedAlternative
        )

        XCTAssertEqual(original.activeDraft?.plan, draft.plan)
        let execution = try XCTUnwrap(
            original.activeDraft?.executionExercise(for: planned.exerciseId)
        )
        XCTAssertEqual(execution.name, "坐姿水平腿举")
        XCTAssertEqual(execution.equipmentVariant, "另一台水平腿举机")
        XCTAssertEqual(execution.targetWeightKg, 72.5)
        XCTAssertEqual(execution.sets, 4)
        XCTAssertEqual(execution.targetReps, 10)
        XCTAssertEqual(execution.restSeconds, 105)

        let restored = AppModel(testContainer: original.container)
        XCTAssertEqual(restored.activeDraft?.plan, draft.plan)
        let restoredExecution = try XCTUnwrap(
            restored.activeDraft?.executionExercise(for: planned.exerciseId)
        )
        XCTAssertEqual(restoredExecution.name, "坐姿水平腿举")
        XCTAssertEqual(restoredExecution.equipmentVariant, "另一台水平腿举机")
        XCTAssertEqual(restoredExecution.sets, 4)
    }

    @MainActor
    func testChangingExerciseMidSessionPreservesActualIdentityForEverySet() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        let draft = try XCTUnwrap(model.activeDraft)
        let planned = try XCTUnwrap(draft.plan.exercises.first)
        model.recordSet(
            exercise: planned, setNumber: 1,
            weight: planned.targetWeightKg, reps: planned.targetReps, feeling: nil
        )
        model.updateExerciseExecution(
            plannedExerciseId: planned.exerciseId,
            name: "坐姿水平腿举",
            equipmentVariant: "水平腿举机 B",
            targetWeightKg: 70,
            sets: planned.sets,
            targetReps: 10,
            restSeconds: planned.restSeconds,
            kind: .plannedAlternative
        )
        model.recordSet(
            exercise: planned, setNumber: 2,
            weight: 70, reps: 10, feeling: nil
        )
        model.finishTraining(
            feedback: SessionFeedback(
                energy: .slightlyTired, targetMuscleResponse: .good,
                symptoms: "无不适", notes: "现场更换器械"
            ),
            stoppedEarly: true
        )

        let results = try XCTUnwrap(model.lastCompletedSession?.exerciseResults)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].name, planned.name)
        XCTAssertEqual(results[0].equipmentVariant, planned.equipmentVariant)
        XCTAssertEqual(results[0].sets.map(\.setNumber), [1])
        XCTAssertEqual(results[0].planned?.name, planned.name)
        XCTAssertEqual(results[0].planned?.targetWeightKg, planned.targetWeightKg)
        XCTAssertEqual(results[1].name, "坐姿水平腿举")
        XCTAssertEqual(results[1].equipmentVariant, "水平腿举机 B")
        XCTAssertEqual(results[1].sets.map(\.setNumber), [2])
        XCTAssertEqual(results[1].planned?.name, planned.name)
        XCTAssertEqual(results[1].planned?.equipmentVariant, planned.equipmentVariant)
    }

    @MainActor
    func testAdjustedSetCountCannotHideAnAlreadyRecordedSet() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        let planned = try XCTUnwrap(model.activeDraft?.plan.exercises.first)
        model.recordSet(
            exercise: planned, setNumber: 3,
            weight: planned.targetWeightKg, reps: planned.targetReps, feeling: .appropriate
        )
        model.updateExerciseExecution(
            plannedExerciseId: planned.exerciseId,
            name: planned.name,
            equipmentVariant: "同动作另一台器械",
            targetWeightKg: planned.targetWeightKg,
            sets: 1,
            targetReps: planned.targetReps,
            restSeconds: planned.restSeconds,
            kind: .equipmentChange
        )

        XCTAssertEqual(
            model.activeDraft?.executionExercise(for: planned.exerciseId)?.sets,
            3
        )
    }

    @MainActor
    func testAppLaunchDoesNotSynchronouslyDecodeHealthCache() throws {
        let original = AppModel(inMemory: true)
        for index in 0..<1_000 {
            let sample = sample(
                id: "startup-\(index)", metric: .activeEnergy,
                start: "2026-09-01T08:00:00+08:00", value: Double(index)
            )
            let payload = try ContractCoding.encoder.encode(sample)
            original.container.mainContext.insert(
                CachedHealthSampleRecord(sample: sample, payload: payload)
            )
        }
        try original.container.mainContext.save()

        let restored = AppModel(testContainer: original.container)

        XCTAssertEqual(restored.health.cachedSampleCount, 0)
        XCTAssertEqual(restored.queueCount, 0)
    }

    @MainActor
    func testHealthPersistenceWorkerDeduplicatesIncrementalBatches() async throws {
        let model = AppModel(inMemory: true)
        let worker = HealthPersistenceWorker(modelContainer: model.container)
        let healthSample = sample(
            id: "dedupe-healthkit-uuid", metric: .hrvSdnn,
            start: "2026-09-01T08:00:00+08:00", value: 52
        )
        let batch = HealthBatch(
            batchId: UUID(), deviceId: "test-device", createdAt: DateFormatting.iso(),
            anchor: nil, samples: [healthSample], coverage: []
        )

        try await worker.enqueue(batch, replacing: nil)
        try await worker.enqueue(batch, replacing: nil)

        let verificationContext = ModelContext(model.container)
        XCTAssertEqual(try verificationContext.fetchCount(FetchDescriptor<CachedHealthSampleRecord>()), 1)
        XCTAssertEqual(try verificationContext.fetchCount(FetchDescriptor<SyncQueueItem>()), 0)
    }

    @MainActor
    func testHealthPersistenceWorkerUpdatesExistingWorkoutMetadata() async throws {
        let model = AppModel(inMemory: true)
        let worker = HealthPersistenceWorker(modelContainer: model.container)
        let cached = HealthSampleContract(
            sampleUuid: "workout-metadata-update", metric: .workout,
            startAt: "2026-09-01T20:00:00+08:00", endAt: "2026-09-01T20:30:00+08:00",
            value: 1_800, unit: "s", source: "Apple Watch", metadata: nil
        )
        var enriched = cached
        enriched.metadata = [
            "activity_name": .string("传统力量训练"),
            "activity_type": .number(50),
        ]
        func batch(_ sample: HealthSampleContract) -> HealthBatch {
            HealthBatch(
                batchId: UUID(), deviceId: "test-device", createdAt: DateFormatting.iso(),
                anchor: nil, samples: [sample], coverage: []
            )
        }

        try await worker.enqueue(batch(cached), replacing: nil)
        try await worker.enqueue(batch(enriched), replacing: nil)

        let restored = try await worker.loadDecisionSamples()
        let workout = try XCTUnwrap(restored.first { $0.sampleUuid == cached.sampleUuid })
        XCTAssertEqual(workout.metadata?["activity_name"], .string("传统力量训练"))
        let verificationContext = ModelContext(model.container)
        XCTAssertEqual(try verificationContext.fetchCount(FetchDescriptor<CachedHealthSampleRecord>()), 1)
        XCTAssertEqual(try verificationContext.fetchCount(FetchDescriptor<SyncQueueItem>()), 0)
    }

    @MainActor
    func testExplicitExportBackfillQueuesEveryPreviouslyCachedChunk() async throws {
        let model = AppModel(inMemory: true)
        let worker = HealthPersistenceWorker(modelContainer: model.container)
        let firstSample = sample(
            id: "backfill-first", metric: .activeEnergy,
            start: "2026-08-31T08:00:00+08:00", value: 2
        )
        let secondSample = sample(
            id: "backfill-second", metric: .activeEnergy,
            start: "2026-08-31T08:05:00+08:00", value: 3
        )
        for healthSample in [firstSample, secondSample] {
            let payload = try ContractCoding.encoder.encode(healthSample)
            model.container.mainContext.insert(
                CachedHealthSampleRecord(sample: healthSample, payload: payload)
            )
        }
        try model.container.mainContext.save()
        func batch(_ healthSample: HealthSampleContract) -> HealthBatch {
            HealthBatch(
                batchId: UUID(), deviceId: "test-device", createdAt: DateFormatting.iso(),
                anchor: nil, samples: [healthSample], coverage: []
            )
        }

        try await worker.enqueue(
            batch(firstSample), replacing: .activeEnergy,
            forceQueue: true, queueForExport: true
        )
        try await worker.enqueue(
            batch(secondSample), replacing: nil,
            forceQueue: true, queueForExport: true
        )

        let verificationContext = ModelContext(model.container)
        XCTAssertEqual(try verificationContext.fetchCount(FetchDescriptor<SyncQueueItem>()), 2)
    }

    @MainActor
    func testNewPlanWaitsUntilActiveTrainingFinishes() throws {
        let model = AppModel(inMemory: true)
        let original = try XCTUnwrap(model.currentPlan)
        model.startTraining()

        var incoming = original
        incoming.revision += 1
        incoming.title = "下一课"
        incoming.publishedAt = DateFormatting.iso()
        model.savePlan(incoming)

        XCTAssertEqual(model.currentPlan?.revision, original.revision)
        XCTAssertEqual(model.activeDraft?.plan.revision, original.revision)

        model.finishTraining(
            feedback: SessionFeedback(
                energy: .normal, targetMuscleResponse: .good,
                symptoms: "未填写", notes: ""
            ),
            stoppedEarly: false
        )

        XCTAssertNil(model.activeDraft)
        XCTAssertEqual(model.currentPlan?.revision, incoming.revision)
        XCTAssertEqual(model.currentPlan?.title, "下一课")
    }

    @MainActor
    func testNewestPlanRevisionWinsWhenUpdatesArriveOutOfOrder() throws {
        let model = AppModel(inMemory: true)
        let original = try XCTUnwrap(model.currentPlan)
        model.startTraining()

        var newest = original
        newest.revision += 2
        newest.title = "修订 3"
        model.savePlan(newest)

        var lateOlder = original
        lateOlder.revision += 1
        lateOlder.title = "迟到的修订 2"
        model.savePlan(lateOlder)

        model.finishTraining(
            feedback: SessionFeedback(
                energy: .normal, targetMuscleResponse: .good,
                symptoms: "未填写", notes: ""
            ),
            stoppedEarly: false
        )

        XCTAssertEqual(model.currentPlan?.revision, newest.revision)
        XCTAssertEqual(model.currentPlan?.title, "修订 3")
    }

    @MainActor
    func testPlanRevisionCannotBeSilentlyRewritten() throws {
        let model = AppModel(inMemory: true)
        let original = try XCTUnwrap(model.currentPlan)
        var conflicting = original
        conflicting.title = "未增加修订号的不同处方"

        model.savePlan(conflicting)

        XCTAssertEqual(model.currentPlan, original)
    }

    func testPlanComparisonUsesExerciseAndEquipmentInsteadOfUUID() {
        let originalExercise = ExercisePlan(
            exerciseId: UUID(), order: 1, name: "高位下拉", equipmentVariant: "常规龙门架",
            targetWeightKg: 40, sets: 3, targetReps: 10, restSeconds: 90,
            notes: nil, alternative: nil
        )
        var revisedExercise = originalExercise
        revisedExercise.exerciseId = UUID()
        revisedExercise.targetWeightKg = 42.5
        revisedExercise.targetReps = 12
        let original = TrainingPlan(
            planId: UUID(), revision: 1, date: "2026-09-01", title: "上肢",
            estimatedMinutes: 55, safetyGates: ["疼痛停止"], exercises: [originalExercise]
        )
        var revised = original
        revised.revision = 2
        revised.estimatedMinutes = 50
        revised.exercises = [revisedExercise]

        let changes = TrainingPlanComparison.changes(from: original, to: revised)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0], "预计时长：55 → 50 分钟")
        XCTAssertTrue(changes[1].contains("高位下拉：40 kg · 3×10"))
        XCTAssertTrue(changes[1].contains("42.5 kg · 3×12"))
        XCTAssertFalse(changes.contains(where: { $0.hasPrefix("新增") || $0.hasPrefix("移除") }))
    }

    func testTrainingHistoryMergePrefersLocalSyncStateAndNewestDate() {
        let remote = SnapshotTrainingSummary(
            id: "same-session", date: "2026-08-31", title: "远端旧标题",
            durationMinutes: 50, activeKcal: nil, averageHeartRate: nil,
            maximumHeartRate: nil, exerciseCount: nil, completedSetCount: nil,
            status: "archived", source: "kris_coach_app", syncedToMac: true
        )
        var local = remote
        local.id = "SAME-SESSION"
        local.date = "2026-08-31T19:00:00+08:00"
        local.title = "本机完整记录"
        local.completedSetCount = 15
        local.syncedToMac = false
        let older = SnapshotTrainingSummary(
            id: "older", date: "2026-08-29", title: "跑步",
            durationMinutes: 30, activeKcal: nil, averageHeartRate: nil,
            maximumHeartRate: nil, exerciseCount: nil, completedSetCount: nil,
            status: "archived", source: "obsidian_archive", syncedToMac: true
        )

        let merged = AppModel.mergeTrainingHistory(local: [local], remote: [remote, older])

        XCTAssertEqual(merged.map(\.id), ["SAME-SESSION", "older"])
        XCTAssertEqual(merged.first?.title, "本机完整记录")
        XCTAssertEqual(merged.first?.syncedToMac, false)
    }

    func testWeeklyTrainingSummaryUsesConfirmedHistoryOnly() throws {
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-02T12:00:00+08:00"))
        let history = [
            SnapshotTrainingSummary(
                id: "recent", date: "2026-09-01T18:00:00+08:00", title: "上肢",
                durationMinutes: 52, activeKcal: 310, averageHeartRate: 128,
                maximumHeartRate: 158, exerciseCount: 5, completedSetCount: 14,
                status: "stopped_early", source: "kris_coach_app", syncedToMac: false
            ),
            SnapshotTrainingSummary(
                id: "old", date: "2026-08-20T18:00:00+08:00", title: "跑步",
                durationMinutes: 30, activeKcal: 350, averageHeartRate: 150,
                maximumHeartRate: 174, exerciseCount: nil, completedSetCount: nil,
                status: "completed", source: "iphone_healthkit", syncedToMac: nil
            ),
        ]

        let summary = AppModel.summarizeWeeklyTraining(history, now: now)
        XCTAssertEqual(summary.completedSessions, 1)
        XCTAssertEqual(summary.completedSets, 14)
        XCTAssertEqual(summary.trainingMinutes, 52)
        XCTAssertEqual(summary.stoppedEarlySessions, 1)
        XCTAssertTrue(summary.hasTraining)
    }

    func testSnapshotDecodesLoadHistoryAndRecentTraining() throws {
        let payload = #"""
        {
          "schema_version":"CoachSnapshot.v1","version":4,"generated_at":"2026-09-01T12:00:00Z",
          "readiness":{"score":null,"state":"insufficient_data","label":"数据不足","confidence":"low","safety_gate":"normal"},
          "evidence":[],"data_gaps":[],"training_load":{},"progression":[],
          "trends":{"training_load_7d":[{"date":"2026-09-01","value":22}],"training_load_42d":[{"date":"2026-09-01","value":29}],"readiness":[{"date":"2026-09-01","score":57.5,"state":"train_reduce","confidence":"medium","source":"mac_derived"}]},
          "recent_training":[{"id":"session-1","date":"2026-08-31","title":"上肢 A","duration_minutes":52,"status":"archived","source":"obsidian_archive","synced_to_mac":true}],
          "decision_trace":{"as_of":"2026-09-01","summary":"准备度 57.5 分 · 可训练，但降阶","actions":["减少一组"],"plan_basis":"静息心率高于基线","adjustment_note":"不做力竭"},
          "current_plan":null
        }
        """#.data(using: .utf8)!

        let snapshot = try ContractCoding.decoder.decode(CoachSnapshot.self, from: payload)

        XCTAssertEqual(snapshot.trends.trainingLoad7D?.first?.value, 22)
        XCTAssertEqual(snapshot.trends.trainingLoad42D?.first?.value, 29)
        XCTAssertEqual(snapshot.trends.readiness?.first?.state, "train_reduce")
        XCTAssertEqual(snapshot.recentTraining?.first?.title, "上肢 A")
        XCTAssertEqual(snapshot.decisionTrace?.actions, ["减少一组"])
    }

    func testReadinessEvidenceDecodesAndPresentsPersonalBaseline() throws {
        let payload = #"{"signal":"hrv_sdnn","value":43.6,"unit":"ms","baseline":39.5,"delta_pct":10.4,"impact":"中性/支持","confidence":"medium"}"#.data(using: .utf8)!
        let item = try ContractCoding.decoder.decode(ReadinessEvidence.self, from: payload)
        XCTAssertEqual(ReadinessEvidencePresentation.label(item.signal), "HRV · SDNN")
        XCTAssertEqual(ReadinessEvidencePresentation.valueLine(item), "43.6 ms · 个人基线 39.5 ms")
        XCTAssertEqual(ReadinessEvidencePresentation.deltaLine(item), "较基线 +10.4%")
        XCTAssertEqual(ReadinessEvidencePresentation.impactLine(item), "支持按计划训练")
    }

    func testLocalReadinessProducesEvidenceOnlyForAvailableSignals() throws {
        let rulesURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "readiness.v1", withExtension: "json"))
        let engine = try ReadinessEngine(data: Data(contentsOf: rulesURL))
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-01T12:00:00+08:00"))
        let samples = [sample(id: "hrv", metric: .hrvSdnn, start: "2026-09-01T08:00:00+08:00", value: 55)]
        let result = HealthReducers.localReadiness(samples: samples, engine: engine, now: now)
        XCTAssertEqual(result.evidence.map(\.signal), ["hrv_sdnn"])
        XCTAssertEqual(result.evidence.first?.value, 55)
    }

    func testLocalReadinessUsesPhoneTrainingLoadWhenAvailable() throws {
        let rulesURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "readiness.v1", withExtension: "json"))
        let engine = try ReadinessEngine(data: Data(contentsOf: rulesURL))
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-01T12:00:00+08:00"))
        var samples: [HealthSampleContract] = []
        for day in 25...31 {
            samples += recoverySamples(date: String(format: "2026-08-%02d", day), sleepHours: 8, hrv: 50, rhr: 60)
        }
        samples += recoverySamples(date: "2026-09-01", sleepHours: 8, hrv: 50, rhr: 60)

        let result = HealthReducers.localReadiness(
            samples: samples, engine: engine, loadRatio: 1.0, now: now
        )

        XCTAssertNotNil(result.readiness.components?["load"] ?? nil)
        XCTAssertFalse(result.dataGaps.contains("本地训练负荷基线仍在建立"))
    }

    func testLocalTrainingLoadDeduplicatesWatchWorkoutAndUnlocksProgression() throws {
        let exerciseID = UUID()
        let planID = UUID()
        let plan = TrainingPlan(
            planId: planID, revision: 1, date: "2026-09-01", title: "上肢 A",
            estimatedMinutes: 60, goal: nil, safetyGates: [],
            exercises: [ExercisePlan(
                exerciseId: exerciseID, order: 1, name: "高位下拉",
                equipmentVariant: "常规龙门架", targetWeightKg: 40,
                sets: 3, targetReps: 12, restSeconds: 90,
                notes: nil, alternative: nil
            )], publishedAt: nil
        )
        let workoutID = UUID().uuidString
        func session(_ day: String, workoutUUID: String? = nil) -> TrainingSessionContract {
            TrainingSessionContract(
                sessionId: UUID(), planId: planID, planRevision: 1,
                startedAt: "\(day)T19:00:00+08:00", endedAt: "\(day)T20:00:00+08:00",
                status: .completed,
                exerciseResults: [ExerciseResult(
                    exerciseId: exerciseID, name: "高位下拉", equipmentVariant: "常规龙门架",
                    sets: (1...3).map { number in
                        CompletedSet(
                            setId: UUID(), setNumber: number, weightKg: 40, reps: 12,
                            completedAt: "\(day)T19:30:00+08:00",
                            lastSetFeeling: number == 3 ? .appropriate : nil
                        )
                    }
                )],
                feedback: SessionFeedback(
                    energy: .normal, targetMuscleResponse: .good, symptoms: "", notes: ""
                ),
                watchWorkoutUuid: workoutUUID,
                workout: WorkoutSummary(
                    durationSeconds: 3_600, activeKcal: 400,
                    averageHeartRate: 130, maximumHeartRate: 160
                )
            )
        }
        let sessions = [session("2026-08-30"), session("2026-09-01", workoutUUID: workoutID)]
        let duplicateWorkout = HealthSampleContract(
            sampleUuid: workoutID, metric: .workout,
            startAt: "2026-09-01T19:00:00+08:00", endAt: "2026-09-01T20:00:00+08:00",
            value: 3_600, unit: "s", source: "Apple Watch",
            metadata: ["activity_name": .string("传统力量训练")]
        )
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-01T23:00:00+08:00"))

        let result = TrainingIntelligence.evaluate(
            sessions: sessions, plans: [plan], workoutSamples: [duplicateWorkout], now: now
        )

        XCTAssertEqual(result.rolling7D, 120)
        XCTAssertEqual(result.progression.first?.state, "increase_smallest_step")
        XCTAssertEqual(result.progression.first?.exercise, "高位下拉")
    }

    func testHealthWorkoutSummaryPreservesTypeAndAvailableDetails() throws {
        let sample = HealthSampleContract(
            sampleUuid: UUID().uuidString, metric: .workout,
            startAt: "2026-09-01T18:10:00+08:00",
            endAt: "2026-09-01T18:40:00+08:00",
            value: 1_800, unit: "s", source: "Apple Watch",
            metadata: [
                "activity_name": .string("跑步"),
                "activity_type": .number(37),
                "source_name": .string("Apple Watch"),
                "device_name": .string("Apple Watch"),
                "indoor": .bool(false),
                "distance_km": .number(4.82),
                "active_kcal": .number(352),
                "average_heart_rate": .number(154),
                "maximum_heart_rate": .number(177),
            ]
        )

        let summary = try XCTUnwrap(
            TrainingIntelligence.workoutSummaries(samples: [sample], excluding: []).first
        )

        XCTAssertEqual(summary.title, "跑步")
        XCTAssertEqual(summary.durationMinutes, 30)
        XCTAssertEqual(summary.activeKcal, 352)
        XCTAssertEqual(summary.averageHeartRate, 154)
        XCTAssertEqual(summary.maximumHeartRate, 177)
        XCTAssertEqual(summary.workoutDetails?.distanceKilometers, 4.82)
        XCTAssertEqual(summary.workoutDetails?.indoor, false)
        XCTAssertEqual(summary.workoutDetails?.sourceName, "Apple Watch")
    }

    func testHealthWorkoutSummaryUsesNeutralFallbackWhenActivityMetadataIsMissing() throws {
        let sample = HealthSampleContract(
            sampleUuid: UUID().uuidString, metric: .workout,
            startAt: "2026-09-01T18:10:00+08:00",
            endAt: "2026-09-01T18:40:00+08:00",
            value: 1_800, unit: "s", source: "第三方训练源", metadata: nil
        )

        let summary = try XCTUnwrap(
            TrainingIntelligence.workoutSummaries(samples: [sample], excluding: []).first
        )

        XCTAssertEqual(summary.title, "其他训练")
        XCTAssertNotEqual(summary.title, "Apple Watch 训练")
        XCTAssertEqual(summary.workoutDetails?.sourceName, "第三方训练源")
    }

    func testTrainingSessionPerformanceUsesOnlyRecordedSetsAndWeightedVolume() {
        let session = TrainingSessionContract(
            sessionId: UUID(), planId: UUID(), planRevision: 1,
            startedAt: "2026-09-01T19:00:00+08:00",
            endedAt: "2026-09-01T20:00:00+08:00", status: .stoppedEarly,
            exerciseResults: [
                ExerciseResult(
                    exerciseId: UUID(), name: "高位下拉", equipmentVariant: "常规龙门架",
                    sets: [
                        CompletedSet(
                            setId: UUID(), setNumber: 1, weightKg: 40, reps: 12,
                            completedAt: "2026-09-01T19:20:00+08:00", lastSetFeeling: nil
                        ),
                        CompletedSet(
                            setId: UUID(), setNumber: 2, weightKg: 40, reps: 10,
                            completedAt: "2026-09-01T19:24:00+08:00", lastSetFeeling: .veryHard
                        ),
                    ]
                ),
                ExerciseResult(
                    exerciseId: UUID(), name: "俯卧撑", equipmentVariant: "自重",
                    sets: [
                        CompletedSet(
                            setId: UUID(), setNumber: 1, weightKg: nil, reps: 15,
                            completedAt: "2026-09-01T19:40:00+08:00", lastSetFeeling: .appropriate
                        )
                    ]
                ),
            ],
            feedback: SessionFeedback(
                energy: .slightlyTired, targetMuscleResponse: .good,
                symptoms: "", notes: "时间受限"
            ),
            watchWorkoutUuid: nil, workout: nil
        )

        let summary = TrainingIntelligence.sessionPerformance(session, plannedSetCount: 6)

        XCTAssertEqual(summary.completedSets, 3)
        XCTAssertEqual(summary.totalRepetitions, 37)
        XCTAssertEqual(summary.loadedVolumeKg, 880)
        XCTAssertEqual(summary.feedbackExercises, 2)
        XCTAssertEqual(summary.completedExercises, 2)
        XCTAssertEqual(summary.completionRate, 0.5)
    }

    func testTotalEnergyTrendRequiresTwentyHoursOfBasalCoverage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-02T12:00:00+08:00"))
        var samples = [
            sample(
                id: "active", metric: .activeEnergy,
                start: "2026-09-01T12:00:00+08:00", value: 400
            )
        ]
        for hour in 0..<20 {
            let start = String(format: "2026-09-01T%02d:00:00+08:00", hour)
            let end = String(format: "2026-09-01T%02d:00:00+08:00", hour + 1)
            samples.append(sample(
                id: "basal-\(hour)", metric: .basalEnergy,
                start: start, end: end, value: 60
            ))
        }

        let complete = HealthReducers.dailyTrends(
            samples: samples, now: now, calendar: calendar
        )
        XCTAssertEqual(complete.basalEnergy?.first?.value, 1_200)
        XCTAssertEqual(complete.totalEnergy?.first?.value, 1_600)
        guard case .number(let latestTotal)? = complete.latestCompleteHealthDay?["estimated_total_kcal"] else {
            return XCTFail("缺少本地完整日总消耗摘要")
        }
        XCTAssertEqual(latestTotal, 1_600)

        let incomplete = HealthReducers.dailyTrends(
            samples: Array(samples.dropLast()), now: now, calendar: calendar
        )
        XCTAssertTrue(incomplete.totalEnergy?.isEmpty ?? true)
    }

    func testLocalRecoveryAndFatLossSummariesDoNotRequireMacSnapshot() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(DateFormatting.parse("2026-09-01T12:00:00+08:00"))
        var samples: [HealthSampleContract] = []
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: now)))
        for offset in 0...14 {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
            let day = String(format: "%04d-%02d-%02d", calendar.component(.year, from: date), calendar.component(.month, from: date), calendar.component(.day, from: date))
            samples += recoverySamples(date: day, sleepHours: 8, hrv: 50, rhr: 60)
            if offset > 0 {
                samples += [
                    bodySample(id: "mass-\(day)", metric: .bodyMass, time: "\(day)T07:00:00+08:00", value: 84),
                    bodySample(id: "fat-\(day)", metric: .bodyFatPercentage, time: "\(day)T07:00:04+08:00", value: 0.25),
                    bodySample(id: "lean-\(day)", metric: .leanBodyMass, time: "\(day)T07:00:03+08:00", value: 63),
                    bodySample(id: "bmi-\(day)", metric: .bmi, time: "\(day)T07:00:02+08:00", value: 26.8),
                ]
            }
        }

        let trends = HealthReducers.dailyTrends(samples: samples, now: now, calendar: calendar)

        XCTAssertEqual(trends.recovery?["baseline_complete_days"], .number(14))
        XCTAssertEqual(trends.recovery?["recovery_status"], .string("normal"))
        XCTAssertEqual(trends.fatLoss?["recent_7d_measurements"], .number(7))
        XCTAssertEqual(trends.fatLoss?["prior_7d_measurements"], .number(7))
        XCTAssertEqual(trends.fatLoss?["plateau_status"], .string("needs_waist_confirmation"))
    }

    @MainActor
    func testWatchEventsAreDeduplicatedAndAppliedOutOfOrder() throws {
        let model = AppModel(inMemory: true)
        model.startTraining()
        let draft = try XCTUnwrap(model.activeDraft)
        let exercise = try XCTUnwrap(draft.plan.exercises.first)
        let second = WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .setCompleted,
            exerciseId: exercise.exerciseId, setNumber: 2, reps: 9,
            weightKg: exercise.targetWeightKg, feeling: nil,
            createdAt: DateFormatting.iso(), workoutUuid: nil, workout: nil
        )
        let first = WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .setCompleted,
            exerciseId: exercise.exerciseId, setNumber: 1, reps: 10,
            weightKg: exercise.targetWeightKg, feeling: nil,
            createdAt: DateFormatting.iso(), workoutUuid: nil, workout: nil
        )
        model.receiveWatchEvent(second)
        model.receiveWatchEvent(first)
        model.receiveWatchEvent(first)
        XCTAssertEqual(model.activeDraft?.completedSets[exercise.exerciseId]?.map(\.setNumber), [1, 2])
    }

    @MainActor
    func testTrainingDraftRestUpdatesIgnoreOlderRevisionsAndClearAtStop() throws {
        let model = AppModel(inMemory: true)
        let plan = try XCTUnwrap(model.currentPlan)
        let startedAt = "2026-09-02T10:00:00Z"
        var draft = TrainingDraft(
            sessionId: UUID(), plan: plan, startedAt: startedAt,
            completedSets: [:], watchWorkoutUuid: nil, workout: nil,
            lifecycle: WorkoutLifecycleSnapshot(
                state: .running, sequence: 1, startedAt: startedAt,
                transitionAt: startedAt, activeDurationSeconds: 0,
                elapsedDurationSeconds: 0
            ), workoutManagedByWatch: true
        )
        let firstDeadline = Date(timeIntervalSince1970: 1_788_400_100)
        let newerDeadline = Date(timeIntervalSince1970: 1_788_400_220)
        let newer = WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .restUpdated,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil,
            feeling: nil, createdAt: startedAt, workoutUuid: nil, workout: nil,
            restUntil: newerDeadline, restRevision: 2
        )
        let older = WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .restUpdated,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil,
            feeling: nil, createdAt: startedAt, workoutUuid: nil, workout: nil,
            restUntil: firstDeadline, restRevision: 1
        )

        draft.apply(newer)
        draft.apply(older)
        XCTAssertEqual(draft.restRevision, 2)
        XCTAssertEqual(draft.restUntil, newerDeadline)

        let stopped = WatchEvent(
            eventId: UUID(), sessionId: draft.sessionId, kind: .sessionStopped,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil,
            feeling: nil, createdAt: startedAt, workoutUuid: nil, workout: nil,
            lifecycle: WorkoutLifecycleSnapshot(
                state: .stopped, sequence: 2, startedAt: startedAt,
                transitionAt: startedAt, activeDurationSeconds: 0,
                elapsedDurationSeconds: 0
            )
        )
        draft.apply(stopped)
        XCTAssertEqual(draft.lifecycleState, .stopped)
        XCTAssertNil(draft.restUntil)
    }

    @MainActor
    func testLiveActivityProjectsRestAndTerminalState() throws {
        let model = AppModel(inMemory: true)
        let plan = try XCTUnwrap(model.currentPlan)
        let start = Date(timeIntervalSince1970: 1_788_400_000)
        var draft = TrainingDraft(
            sessionId: UUID(), plan: plan, startedAt: DateFormatting.iso(start),
            completedSets: [:], watchWorkoutUuid: nil, workout: nil,
            lifecycle: WorkoutLifecycleSnapshot(
                state: .running, sequence: 0, startedAt: DateFormatting.iso(start),
                transitionAt: DateFormatting.iso(start), activeDurationSeconds: 60,
                elapsedDurationSeconds: 60
            ), workoutManagedByWatch: true,
            restUntil: start.addingTimeInterval(75), restRevision: 3
        )
        let state = WorkoutLiveActivityController.contentState(
            for: draft, now: start.addingTimeInterval(10)
        )
        XCTAssertEqual(state.sessionID, draft.sessionId.uuidString)
        XCTAssertEqual(state.completedSets, 0)
        XCTAssertEqual(state.setNumber, 1)
        XCTAssertEqual(state.restUntil, draft.restUntil)

        for exercise in plan.exercises {
            for setNumber in 1...exercise.sets {
                draft.record(
                    exercise: exercise, setNumber: setNumber,
                    weight: exercise.targetWeightKg, reps: exercise.targetReps, feeling: nil
                )
            }
        }
        draft.restUntil = nil
        let terminal = WorkoutLiveActivityController.contentState(
            for: draft, now: start.addingTimeInterval(20)
        )
        XCTAssertEqual(terminal.completedSets, terminal.totalSets)
        XCTAssertEqual(terminal.exerciseName, "计划组次已完成")
        XCTAssertNil(terminal.restUntil)
    }

    @MainActor
    func testWatchCanStartSessionAndReplayEarlierSetEvent() throws {
        let model = AppModel(inMemory: true)
        let plan = try XCTUnwrap(model.currentPlan)
        let exercise = try XCTUnwrap(plan.exercises.first)
        let sessionID = UUID()
        let set = WatchEvent(
            eventId: UUID(), sessionId: sessionID, kind: .setCompleted,
            exerciseId: exercise.exerciseId, setNumber: 1, reps: exercise.targetReps,
            weightKg: exercise.targetWeightKg, feeling: nil,
            createdAt: DateFormatting.iso(), workoutUuid: nil, workout: nil
        )
        model.receiveWatchEvent(set)
        XCTAssertNil(model.activeDraft)

        let started = WatchEvent(
            eventId: UUID(), sessionId: sessionID, kind: .sessionStarted,
            planId: plan.planId, planRevision: plan.revision,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil,
            feeling: nil, createdAt: DateFormatting.iso(), workoutUuid: nil, workout: nil
        )
        model.receiveWatchEvent(started)
        model.receiveWatchEvent(set)

        XCTAssertEqual(model.activeDraft?.sessionId, sessionID)
        XCTAssertEqual(model.activeDraft?.plan.revision, plan.revision)
        XCTAssertEqual(model.activeDraft?.completedSets[exercise.exerciseId]?.map(\.setNumber), [1])
    }

    @MainActor
    func testWatchSessionResumesWhenMatchingPlanArrivesLater() throws {
        let model = AppModel(inMemory: true)
        let currentPlan = try XCTUnwrap(model.currentPlan)
        var revisedPlan = currentPlan
        revisedPlan.revision += 1
        let sessionID = UUID()
        let started = WatchEvent(
            eventId: UUID(), sessionId: sessionID, kind: .sessionStarted,
            planId: revisedPlan.planId, planRevision: revisedPlan.revision,
            exerciseId: nil, setNumber: nil, reps: nil, weightKg: nil,
            feeling: nil, createdAt: DateFormatting.iso(), workoutUuid: nil, workout: nil
        )

        model.receiveWatchEvent(started)
        XCTAssertNil(model.activeDraft)

        model.savePlan(revisedPlan)

        XCTAssertEqual(model.activeDraft?.sessionId, sessionID)
        XCTAssertEqual(model.activeDraft?.plan.revision, revisedPlan.revision)
    }

    private func recoverySamples(date: String, sleepHours: Double, hrv: Double, rhr: Double) -> [HealthSampleContract] {
        [
            sample(id: "sleep-\(date)", metric: .sleep, start: "\(date)T00:00:00+08:00", end: "\(date)T\(String(format: "%02d", Int(sleepHours))):00:00+08:00", value: sleepHours * 3600),
            sample(id: "hrv-\(date)", metric: .hrvSdnn, start: "\(date)T07:00:00+08:00", value: hrv),
            sample(id: "rhr-\(date)", metric: .restingHeartRate, start: "\(date)T07:00:00+08:00", value: rhr),
        ]
    }

    private func watchExecutionSnapshot() -> WatchExecutionSnapshot {
        let exercises = [
            ExercisePlan(
                exerciseId: UUID(), order: 1, name: "高位下拉", equipmentVariant: "常规龙门架",
                targetWeightKg: 40, sets: 3, targetReps: 10, restSeconds: 90,
                notes: nil, alternative: nil
            ),
            ExercisePlan(
                exerciseId: UUID(), order: 2, name: "坐姿划船", equipmentVariant: "配重片器械",
                targetWeightKg: 45, sets: 3, targetReps: 10, restSeconds: 90,
                notes: nil, alternative: nil
            ),
        ]
        let plan = TrainingPlan(
            planId: UUID(), revision: 3, date: "2026-09-03", title: "上肢",
            estimatedMinutes: 55, goal: "恢复训练容量", safetyGates: ["疼痛立即停止"],
            exercises: exercises, publishedAt: "2026-09-03T12:00:00+08:00"
        )
        let sessionID = UUID()
        let lifecycle = WorkoutLifecycleSnapshot(
            state: .paused, sequence: 4,
            startedAt: "2026-09-03T19:00:00+08:00",
            transitionAt: "2026-09-03T19:20:00+08:00",
            activeDurationSeconds: 1_100, elapsedDurationSeconds: 1_200
        )
        let pendingEvent = WatchEvent(
            eventId: UUID(), sessionId: sessionID, kind: .setCompleted,
            exerciseId: exercises[0].exerciseId, setNumber: 1, reps: 10,
            weightKg: exercises[0].targetWeightKg, feeling: nil,
            createdAt: "2026-09-03T19:10:00+08:00",
            workoutUuid: nil, workout: nil, lifecycle: lifecycle
        )
        return WatchExecutionSnapshot(
            sessionId: sessionID, plan: plan, currentExerciseId: exercises[1].exerciseId,
            exerciseIndex: 1, setNumber: 2, completedSets: 4, reps: 9,
            feeling: .appropriate, restUntil: Date(timeIntervalSince1970: 1_788_400_000),
            processedCommandIds: [UUID()], lastLifecycleSequence: 4,
            hasPublishedStart: true,
            lifecycle: lifecycle,
            pendingEvents: [pendingEvent]
        )
    }

    private func bodySample(id: String, metric: HealthMetric, time: String, value: Double) -> HealthSampleContract {
        sample(id: id, metric: metric, start: time, value: value, source: "S800")
    }

    private func sample(
        id: String, metric: HealthMetric, start: String, end: String? = nil,
        value: Double, source: String = "Apple Watch"
    ) -> HealthSampleContract {
        HealthSampleContract(
            sampleUuid: id, metric: metric, startAt: start, endAt: end ?? start,
            value: value, unit: metric == .sleep ? "s" : "count", source: source, metadata: nil
        )
    }
}
