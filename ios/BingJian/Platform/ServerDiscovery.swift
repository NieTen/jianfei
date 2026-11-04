import Foundation

struct DiscoveredServer: Identifiable {
    var id: String
    var name: String
    var url: String
}

@MainActor
final class ServerDiscovery: NSObject, ObservableObject {
    @Published var servers: [DiscoveredServer] = []
    @Published var searching = false
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        servers = []
        services = []
        searching = true
        browser.searchForServices(ofType: "_fatloss._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        searching = false
    }
}

extension ServerDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            self.services.append(service)
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            guard let host = sender.hostName else { return }
            let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
            let value = DiscoveredServer(id: sender.name, name: sender.name, url: "https://\(normalized):\(sender.port)")
            if !self.servers.contains(where: { $0.id == value.id }) { self.servers.append(value) }
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor in self.searching = false }
    }
}
