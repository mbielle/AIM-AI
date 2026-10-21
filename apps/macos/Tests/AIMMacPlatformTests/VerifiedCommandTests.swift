import AIMAgentKit
import AIMMacPlatform
import XCTest

final class VerifiedCommandTests: XCTestCase {
    func testOnlyExactReadCommandsBypassShellApproval() {
        let service = WorkspaceShellToolService()
        for command in ["pwd", "git status", "git diff --no-ext-diff"] {
            XCTAssertEqual(service.risk(for: ["command": command]), .readOnly)
        }
        for command in ["pwd; rm -rf .", "git status && curl example.com", "git -c core.fsmonitor=evil status", "git diff --output=/tmp/file", "$(pwd)", "pwd > file", "git status\nrm file", "swift build"] {
            XCTAssertEqual(service.risk(for: ["command": command]), .destructive)
        }
    }
}
