import XCTest
@testable import AlfalfaDesktop

final class DesktopTests: XCTestCase {
    func testProtectedAppsHaveTheSameRestrictionsForBothTransports() throws {
        let edit = try DesktopRequest(command: "action", options: ["pid": "123", "kind": "type", "text": "hello"])
        let inspect = try DesktopRequest(command: "inspect", options: ["pid": "123"])
        let click = try DesktopRequest(command: "action", options: ["pid": "123", "kind": "click", "x": "1", "y": "1"])
        let terminal = AppAccess.level(bundle: "com.apple.Terminal", name: "", executable: "")
        XCTAssertFalse(terminal.allows(edit))
        XCTAssertTrue(terminal.allows(click))
        XCTAssertTrue(terminal.allows(inspect))
        let browser = AppAccess.level(bundle: "com.apple.Safari", name: "", executable: "")
        XCTAssertFalse(browser.allows(click))
        XCTAssertTrue(browser.allows(inspect))
        let agent = AppAccess.level(bundle: "com.cuycoders.alfalfacode", name: "", executable: "")
        XCTAssertFalse(agent.allows(inspect))
    }

    func testInvalidTargetOptionsAreRejected() {
        XCTAssertThrowsError(try DesktopRequest(command: "inspect", options: ["pid": "99999999999"]))
        XCTAssertThrowsError(try DesktopRequest(command: "inspect", options: ["pid": "2", "capture": "/tmp/other"]))
        XCTAssertThrowsError(try DesktopRequest(command: "action", options: [
            "pid": "2", "kind": "click", "path": "1.2"
        ]))
        XCTAssertThrowsError(try DesktopRequest(command: "action", options: [
            "pid": "2", "kind": "scroll", "dx": "nan"
        ]))
    }

    func testApprovalDigestIsIndependentOfInputOrder() throws {
        let digest = try PACAIAdapter.argumentDigest(["text": "é/🐹", "pid": "1"])
        XCTAssertEqual(digest, "sha256:671a182145d2d80278fdf5529020616d9f24f58f41b45fdb589bbc9407e1f043")
    }

    func testCLIRejectsDuplicateApprovalSwitches() {
        XCTAssertThrowsError(try EntryPoint.parse(["--approve", "--approve"]))
        XCTAssertThrowsError(try EntryPoint.parse(["--pid=17", "--pid=18"]))
    }
}
