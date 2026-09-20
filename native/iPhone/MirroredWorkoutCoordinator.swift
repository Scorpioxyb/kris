import Foundation
import HealthKit
import Observation

@MainActor
@Observable
final class MirroredWorkoutCoordinator: NSObject, HKWorkoutSessionDelegate, @unchecked Sendable {
    private(set) var isConnected = false
    private(set) var sessionState: HKWorkoutSessionState?
    private(set) var lastError: String?

    @ObservationIgnored
    var onEvent: ((WatchEvent) -> Void)? {
        didSet {
            guard let onEvent, !pendingEvents.isEmpty else { return }
            let buffered = pendingEvents
            pendingEvents.removeAll()
            for event in buffered { onEvent(event) }
        }
    }

    @ObservationIgnored
    var onSessionAccepted: (() -> Void)? {
        didSet {
            if hasAcceptedSession { onSessionAccepted?() }
        }
    }

    private let healthStore: HKHealthStore
    private var mirroredSession: HKWorkoutSession?
    private var pendingEvents: [WatchEvent] = []
    private var hasAcceptedSession = false
    nonisolated private static let maximumPayloadBytes = 90_000

    override init() {
        healthStore = HKHealthStore()
        super.init()
        installHandler()
    }

    private func installHandler() {
        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor [weak self] in
                self?.accept(session)
            }
        }
    }

    private func accept(_ session: HKWorkoutSession) {
        guard session.type == .mirrored else { return }
        if mirroredSession === session {
            isConnected = true
            sessionState = session.state
            return
        }
        mirroredSession?.delegate = nil
        mirroredSession = session
        session.delegate = self
        hasAcceptedSession = true
        sessionState = session.state
        isConnected = session.state != .ended
        lastError = nil
        onSessionAccepted?()
    }

    func send(command: WorkoutCommand) {
        guard let session = mirroredSession,
              isConnected,
              let data = try? ContractCoding.encoder.encode(
                WorkoutMirrorEnvelope(command: command)
              ),
              data.count <= Self.maximumPayloadBytes else { return }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session, self.mirroredSession === session else { return }
            do {
                try await session.sendToRemoteWorkoutSession(data: data)
            } catch {
                guard self.mirroredSession === session else { return }
                self.lastError = "手表实时控制暂不可用，已转为后台补传。"
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            guard self.mirroredSession === workoutSession else { return }
            self.sessionState = toState
            self.isConnected = toState != .ended
            if toState == .ended { self.mirroredSession = nil }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor in
            guard self.mirroredSession === workoutSession else { return }
            self.lastError = "系统训练同步中断：\(message)"
            self.isConnected = false
            self.mirroredSession = nil
            self.hasAcceptedSession = false
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        let events = data.compactMap { item -> WatchEvent? in
            guard item.count <= Self.maximumPayloadBytes,
                  let envelope = try? ContractCoding.decoder.decode(
                    WorkoutMirrorEnvelope.self, from: item
                  ) else { return nil }
            return envelope.validatedEvent
        }
        guard !events.isEmpty else { return }
        Task { @MainActor in
            guard self.mirroredSession === workoutSession else { return }
            for event in events {
                if let onEvent = self.onEvent {
                    onEvent(event)
                } else if !self.pendingEvents.contains(where: { $0.eventId == event.eventId }) {
                    self.pendingEvents.append(event)
                }
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        let hadError = error != nil
        Task { @MainActor in
            guard self.mirroredSession === workoutSession else { return }
            self.isConnected = false
            self.sessionState = nil
            self.mirroredSession = nil
            self.hasAcceptedSession = false
            self.lastError = hadError
                ? "手表实时连接已中断，训练仍会在手表继续并稍后补传。"
                : nil
        }
    }
}
