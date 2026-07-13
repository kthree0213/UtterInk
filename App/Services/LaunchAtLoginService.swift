import ServiceManagement

@MainActor
final class LaunchAtLoginService: LaunchAtLoginManaging {
    private let service: SMAppService
    private(set) var state: LaunchAtLoginState = .disabled

    init(service: SMAppService = .mainApp) {
        self.service = service
        refresh()
    }

    func refresh() {
        switch service.status {
        case .enabled:
            state = .enabled
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered:
            state = .disabled
        case .notFound:
            state = .unavailable
        @unknown default:
            state = .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) async {
        do {
            if enabled {
                try service.register()
            } else {
                try await service.unregister()
            }
            refresh()
        } catch {
            state = .failed
        }
    }
}
