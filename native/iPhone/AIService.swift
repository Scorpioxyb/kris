import Foundation

typealias AIRequestLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
typealias AISessionTokenLoader = @Sendable () -> String?

enum AIServiceError: LocalizedError, Equatable {
    case notConfigured
    case invalidRequest(String)
    case authentication
    case insufficientBalance
    case rateLimited
    case conflict(String)
    case serverUnavailable
    case emptyResponse
    case invalidResponse
    case cancelled
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "智能建议服务尚未接通，健康和训练功能仍可正常使用。"
        case .invalidRequest(let detail): "请求未通过校验：\(detail)"
        case .authentication: "智能建议服务认证暂时不可用，请稍后重试。"
        case .insufficientBalance: "智能建议服务暂时不可用，请稍后重试。"
        case .rateLimited: "请求较多，请稍后再试。"
        case .conflict(let detail): "请求状态已发生变化：\(detail)"
        case .serverUnavailable: "智能建议服务暂时不可用，请稍后重试。"
        case .emptyResponse: "没有收到有效内容，请重新生成。"
        case .invalidResponse: "返回内容未通过结构校验，不会写入训练计划。"
        case .cancelled: "已取消生成。"
        case .transport(let detail): "网络请求失败：\(detail)"
        }
    }
}

struct KrisAIGatewayConfiguration: Sendable {
    let endpoint: URL
    fileprivate let legacyEndpoint: URL

    static let sessionTokenAccount = "ai.gateway.session-token.v1"

    static var current: KrisAIGatewayConfiguration? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "KrisAIGatewayURL") as? String else {
            return nil
        }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.contains("$("),
              let baseURL = URL(string: normalized),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && baseURL.host == "127.0.0.1")
        else { return nil }
        return KrisAIGatewayConfiguration(
            endpoint: baseURL.appending(path: "v2/ai/training-recommendations"),
            legacyEndpoint: baseURL.appending(path: "v1/ai/training-plan-candidates")
        )
    }

    static var hasDeviceSession: Bool {
        guard let token = KeychainStore.read(account: sessionTokenAccount) else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var isAvailable: Bool { current != nil && hasDeviceSession }
}

actor KrisAIGatewayService {
    private struct RequestBody: Encodable {
        var schemaVersion = "KrisAIPlanRequest.v1"
        var clientRequestID: UUID
        var context: AIRedactedPlanContext

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case clientRequestID = "client_request_id"
            case context
        }
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            var code: String
            var message: String
        }

        var message: String?
        var error: Detail?
    }

    private let legacyEndpoint: URL?
    private let recommendationEndpoint: URL?
    private let requestLoader: AIRequestLoader
    private let sessionTokenLoader: AISessionTokenLoader

    init(
        configuration: KrisAIGatewayConfiguration? = .current,
        session: URLSession? = nil,
        sessionTokenLoader: @escaping AISessionTokenLoader = {
            KeychainStore.read(account: KrisAIGatewayConfiguration.sessionTokenAccount)
        }
    ) {
        legacyEndpoint = configuration?.legacyEndpoint
        recommendationEndpoint = configuration?.endpoint
        self.sessionTokenLoader = sessionTokenLoader
        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.waitsForConnectivity = false
            resolvedSession = URLSession(configuration: configuration)
        }
        requestLoader = { request in try await resolvedSession.data(for: request) }
    }

    init(
        endpoint: URL,
        sessionToken: String,
        requestLoader: @escaping AIRequestLoader
    ) {
        let endpoints = Self.gatewayEndpoints(from: endpoint)
        legacyEndpoint = endpoints.legacy
        recommendationEndpoint = endpoints.recommendation
        sessionTokenLoader = { sessionToken }
        self.requestLoader = requestLoader
    }

    func generatePlan(context: AIRedactedPlanContext) async throws -> AIPlanResponseEnvelope {
        guard let legacyEndpoint else { throw AIServiceError.notConfigured }
        let request = try makeRequest(
            body: RequestBody(clientRequestID: UUID(), context: context),
            endpoint: legacyEndpoint,
            responseSchema: AIPlanPolicy.responseSchemaVersion
        )

        for attempt in 0...1 {
            let data = try await perform(request)
            guard !data.isEmpty else {
                if attempt == 1 { throw AIServiceError.emptyResponse }
                continue
            }
            return try Self.decodePlanResponse(data, input: context.userInput)
        }
        throw AIServiceError.emptyResponse
    }

    func generateRecommendation(
        context: TrainingContext,
        clientRequestId: UUID = UUID()
    ) async throws -> AIRecommendation {
        guard context.safety.disposition != .block else {
            throw AIServiceError.invalidRequest("本地安全规则已阻止生成训练建议")
        }
        guard context.safety.disposition != .needsUserInput else {
            throw AIServiceError.invalidRequest("需要先补充主观反馈，再生成训练建议")
        }
        let contextValidation = AIDecisionPipelineValidator.validateContext(context)
        guard contextValidation.isValid else {
            throw AIServiceError.invalidRequest(
                contextValidation.issues.first?.message ?? "V2 训练上下文无效"
            )
        }
        guard let recommendationEndpoint else { throw AIServiceError.notConfigured }

        let body = AIRecommendationRequestV2(
            clientRequestId: clientRequestId, context: context
        )
        let request = try makeRequest(
            body: body, endpoint: recommendationEndpoint,
            responseSchema: "AIRecommendation.v2"
        )
        for attempt in 0...1 {
            let data = try await perform(request)
            guard !data.isEmpty else {
                if attempt == 1 { throw AIServiceError.emptyResponse }
                continue
            }
            return try Self.decodeRecommendationResponse(
                data, context: context, expectedRequestId: body.clientRequestId
            )
        }
        throw AIServiceError.emptyResponse
    }

    static func decodePlanResponse(
        _ data: Data,
        input: AIPlanUserInput
    ) throws -> AIPlanResponseEnvelope {
        guard let response = try? ContractCoding.decoder.decode(AIPlanResponseEnvelope.self, from: data),
              AIPlanPolicy.draftErrors(response, input: input).isEmpty else {
            throw AIServiceError.invalidResponse
        }
        return response
    }

    static func decodeRecommendationResponse(
        _ data: Data,
        context: TrainingContext,
        expectedRequestId: UUID
    ) throws -> AIRecommendation {
        guard !containsForbiddenRecommendationFields(data) else {
            throw AIServiceError.invalidResponse
        }
        let wire: AIRecommendationResponseWireV2
        do {
            wire = try ContractCoding.decoder.decode(AIRecommendationResponseWireV2.self, from: data)
        } catch {
            throw AIServiceError.invalidResponse
        }
        guard wire.requestId == expectedRequestId else {
            throw AIServiceError.invalidResponse
        }
        let recommendation = try wire.domain(context: context)
        guard AIDecisionPipelineValidator.validate(
            recommendation: recommendation, context: context
        ).isValid else {
            throw AIServiceError.invalidResponse
        }
        return recommendation
    }

    private func makeRequest<Body: Encodable>(
        body: Body,
        endpoint: URL,
        responseSchema: String
    ) throws -> URLRequest {
        guard let token = sessionTokenLoader()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw AIServiceError.notConfigured
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(responseSchema, forHTTPHeaderField: "X-Kris-Response-Schema")
        request.httpBody = try ContractCoding.encoder.encode(body)
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await requestLoader(request)
            guard let http = response as? HTTPURLResponse else {
                throw AIServiceError.invalidResponse
            }
            switch http.statusCode {
            case 200:
                return data
            case 400, 422:
                let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data)
                throw AIServiceError.invalidRequest(
                    decoded?.error?.message ?? decoded?.message ?? "参数不受支持"
                )
            case 409:
                let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data)
                let detail = decoded?.error?.message ?? decoded?.message ?? "请求与当前状态冲突"
                switch decoded?.error?.code {
                case "local_safety_block", "user_input_required":
                    throw AIServiceError.invalidRequest(detail)
                default:
                    throw AIServiceError.conflict(detail)
                }
            case 401, 403:
                throw AIServiceError.authentication
            case 402:
                throw AIServiceError.insufficientBalance
            case 429:
                throw AIServiceError.rateLimited
            case 502:
                throw AIServiceError.invalidResponse
            case 500...599:
                throw AIServiceError.serverUnavailable
            default:
                throw AIServiceError.serverUnavailable
            }
        } catch is CancellationError {
            throw AIServiceError.cancelled
        } catch let error as AIServiceError {
            throw error
        } catch {
            throw AIServiceError.transport(error.localizedDescription)
        }
    }

    private static func gatewayEndpoints(from endpoint: URL) -> (legacy: URL, recommendation: URL) {
        let legacySuffix = "/v1/ai/training-plan-candidates"
        let recommendationSuffix = "/v2/ai/training-recommendations"
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        let path = components?.path ?? endpoint.path
        if path.hasSuffix(legacySuffix) {
            components?.path = String(path.dropLast(legacySuffix.count)) + recommendationSuffix
            return (endpoint, components?.url ?? endpoint)
        }
        if path.hasSuffix(recommendationSuffix) {
            components?.path = String(path.dropLast(recommendationSuffix.count)) + legacySuffix
            return (components?.url ?? endpoint, endpoint)
        }
        return (endpoint, endpoint)
    }

    private static func containsForbiddenRecommendationFields(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return true }
        let forbidden = Set([
            "safetygates", "safetyrestrictions", "restrictions",
            "readiness", "readinessscore", "recovery", "recoveryscore",
            "statusscore", "bodyscore", "bodystatescore",
        ])
        func scan(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    let normalized = key
                        .replacingOccurrences(of: "_", with: "")
                        .replacingOccurrences(of: "-", with: "")
                        .lowercased()
                    if forbidden.contains(normalized) || scan(child) { return true }
                }
            } else if let array = value as? [Any] {
                return array.contains(where: scan)
            }
            return false
        }
        return scan(object)
    }
}
