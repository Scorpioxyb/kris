import Foundation

final class WatchExecutionStore {
    private let fileURL: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("active-watch-execution.json")
    }

    func load() -> WatchExecutionLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        do {
            return WatchExecutionPersistenceCodec.decode(try Data(contentsOf: fileURL))
        } catch {
            return .corrupt
        }
    }

    @discardableResult
    func save(_ snapshot: WatchExecutionSnapshot) -> Bool {
        write(snapshot: snapshot)
    }

    @discardableResult
    func clear() -> Bool {
        write(snapshot: nil)
    }

    private func write(snapshot: WatchExecutionSnapshot?) -> Bool {
        do {
            let data = try WatchExecutionPersistenceCodec.encode(snapshot: snapshot)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }
}
