import Foundation
import WatchConnectivity

actor WatchEventQueue {
    private let fileURL: URL
    private var events: [WatchEvent] = []

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("watch-events.json")
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? ContractCoding.decoder.decode([WatchEvent].self, from: data) {
            events = stored
        }
    }

    @discardableResult
    func enqueue(_ event: WatchEvent) async -> Bool {
        guard !events.contains(where: { $0.eventId == event.eventId }) else { return true }
        events.append(event)
        guard persist() else {
            events.removeAll { $0.eventId == event.eventId }
            return false
        }
        await flush()
        return true
    }

    func flush() async {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let pending = events
        for event in pending {
            guard let data = try? ContractCoding.encoder.encode(event) else { continue }
            let payload = ["event": data]
            if WCSession.default.isReachable {
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        WCSession.default.sendMessage(payload) { _ in continuation.resume() } errorHandler: { error in
                            continuation.resume(throwing: error)
                        }
                    }
                    remove(event.eventId)
                } catch {
                    WCSession.default.transferUserInfo(payload)
                    remove(event.eventId)
                }
            } else {
                WCSession.default.transferUserInfo(payload)
                remove(event.eventId)
            }
        }
    }

    private func remove(_ id: UUID) {
        events.removeAll { $0.eventId == id }
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            let data = try ContractCoding.encoder.encode(events)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }
}
