import CryptoKit
import Foundation

enum CompanionError: LocalizedError {
    case notPaired
    case certificateMismatch
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notPaired: "尚未与 Mac 配对"
        case .certificateMismatch: "Mac 证书指纹不匹配，已阻止连接"
        case .server(let code, let message): "Mac 返回 \(code)：\(message)"
        }
    }
}

final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint.replacingOccurrences(of: ":", with: "").uppercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustCopyCertificateChain(trust).flatMap({ $0 as? [SecCertificate] })?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let data = SecCertificateCopyData(certificate) as Data
        let actual = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
        guard actual == expectedFingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

actor CompanionClient {
    static let tokenAccount = "device-token"
    private let baseURL: URL
    private let session: URLSession
    private let deviceToken: String?

    init(baseURL: URL, fingerprint: String, deviceToken: String?) {
        self.baseURL = baseURL
        self.deviceToken = deviceToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: CertificatePinningDelegate(expectedFingerprint: fingerprint), delegateQueue: nil)
    }

    static func pair(descriptor: PairingDescriptor, deviceID: String, deviceName: String) async throws -> PairResponse {
        let client = CompanionClient(baseURL: descriptor.baseURL, fingerprint: descriptor.fingerprint, deviceToken: nil)
        let body: [String: String] = ["token": descriptor.token, "device_id": deviceID, "device_name": deviceName]
        return try await client.request("/v1/pair", method: "POST", body: try JSONSerialization.data(withJSONObject: body), requiresAuth: false)
    }

    func uploadHealth(_ payload: Data) async throws {
        let _: Acknowledgement = try await request("/v1/health/batches", method: "POST", body: payload)
    }

    func uploadSession(_ payload: Data) async throws {
        let response: Acknowledgement = try await request("/v1/training/sessions", method: "POST", body: payload)
        guard response.acknowledged, response.archiveState == "archived" else {
            throw CompanionError.server(503, "Mac 尚未完成训练归档")
        }
    }

    func refreshDerivedData() async throws {
        let body = try JSONSerialization.data(withJSONObject: [:])
        let response: Acknowledgement = try await request("/v1/refresh", method: "POST", body: body)
        guard response.acknowledged else { throw CompanionError.server(503, "Mac 尚未完成数据派生") }
    }

    func snapshot() async throws -> CoachSnapshot {
        try await request("/v1/snapshot", method: "GET", body: nil)
    }

    func changes(after: Int) async throws -> ChangesResponse {
        try await request("/v1/changes?after=\(after)", method: "GET", body: nil)
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String,
        body: Data?,
        requiresAuth: Bool = true
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if requiresAuth {
            guard let deviceToken else { throw CompanionError.notPaired }
            request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let http = response as? HTTPURLResponse
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            throw CompanionError.server(http?.statusCode ?? -1, message ?? "未知错误")
        }
        return try ContractCoding.decoder.decode(Response.self, from: data)
    }
}

private struct Acknowledgement: Decodable {
    var acknowledged: Bool
    var duplicate: Bool
    var archiveState: String?
    var version: Int
}
