import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLoginController {
    public init() {}

    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
