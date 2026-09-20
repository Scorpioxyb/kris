import Foundation
import Observation
import WatchConnectivity

enum WatchConnectionStatus: Equatable, Sendable {
    case unsupported
    case checking
    case unavailable
    case noPairedWatch
    case needsInstallation
    case installed
    case reachable

    static func resolve(
        isSupported: Bool,
        activationCompleted: Bool,
        activationFailed: Bool,
        hasPairedWatch: Bool,
        isWatchAppInstalled: Bool,
        isReachable: Bool
    ) -> Self {
        guard isSupported else { return .unsupported }
        guard activationCompleted else { return activationFailed ? .unavailable : .checking }
        guard hasPairedWatch else { return .noPairedWatch }
        guard isWatchAppInstalled else { return .needsInstallation }
        return isReachable ? .reachable : .installed
    }

    var shortLabel: String {
        switch self {
        case .unsupported: "此设备不支持"
        case .checking: "正在检查"
        case .unavailable: "暂时不可用"
        case .noPairedWatch: "未检测到手表"
        case .needsInstallation: "需要安装 Kris"
        case .installed: "已安装"
        case .reachable: "可连接"
        }
    }
}

@MainActor
@Observable
final class PhoneWatchConnectivity: NSObject, WCSessionDelegate, @unchecked Sendable {
    private(set) var isPaired = false
    private(set) var hasPairedWatch = false
    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false
    private(set) var connectionStatus: WatchConnectionStatus = .checking
    private(set) var activationError: String?
    var onEvent: (@MainActor (WatchEvent) -> Void)?

    override init() {
        super.init()
        guard WCSession.isSupported() else {
            connectionStatus = .unsupported
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(plan: TrainingPlan, sessionID: UUID? = nil) {
        guard WCSession.isSupported(), let data = try? ContractCoding.encoder.encode(plan) else { return }
        var context: [String: Any] = ["plan": data]
        if let sessionID { context["session_id"] = sessionID.uuidString }
        try? WCSession.default.updateApplicationContext(context)
    }

    func send(command: WorkoutCommand) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              let data = try? ContractCoding.encoder.encode(command) else { return }
        let payload: [String: Any] = ["workout_command": data]
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        updateState(from: session, activationError: error?.localizedDescription)
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        updateState(from: session)
    }

    private nonisolated func updateState(from session: WCSession, activationError: String? = nil) {
        let hasPairedWatch = session.isPaired
        let isWatchAppInstalled = session.isWatchAppInstalled
        let paired = hasPairedWatch && isWatchAppInstalled
        let reachable = session.isReachable
        let activationCompleted = session.activationState == .activated
        let status = WatchConnectionStatus.resolve(
            isSupported: true,
            activationCompleted: activationCompleted,
            activationFailed: activationError != nil,
            hasPairedWatch: hasPairedWatch,
            isWatchAppInstalled: isWatchAppInstalled,
            isReachable: reachable
        )
        Task { @MainActor in
            self.hasPairedWatch = hasPairedWatch
            self.isWatchAppInstalled = isWatchAppInstalled
            self.isPaired = paired
            self.isReachable = reachable
            self.connectionStatus = status
            self.activationError = activationError
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        updateState(from: session)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo)
    }

    private nonisolated func receive(_ payload: [String: Any]) {
        guard let data = payload["event"] as? Data,
              let event = try? ContractCoding.decoder.decode(WatchEvent.self, from: data) else { return }
        Task { @MainActor in self.onEvent?(event) }
    }
}
