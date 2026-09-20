import Foundation
import Network
import Observation

@MainActor
@Observable
final class BonjourBrowser {
    struct Service: Identifiable, Hashable {
        var id: String { name }
        var name: String
    }

    private(set) var services: [Service] = []
    private(set) var error: String?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_kriscoach._tcp", domain: "local."), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.error = error.localizedDescription }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let values = results.compactMap { result -> Service? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Service(name: name)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.services = values }
        }
        browser.start(queue: DispatchQueue(label: "kriscoach.bonjour"))
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        services = []
    }
}
