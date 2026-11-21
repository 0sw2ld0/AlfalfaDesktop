import AppKit
import XCTest
@testable import AlfalfaDesktop

final class PointerViewTests: XCTestCase {
    func testLeafIsEighteenPointsTallAndStartsAtTheHotspot() {
        let view = PointerView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let leaf = view.leafPath
        var firstPoint = NSPoint.zero

        XCTAssertEqual(leaf.bounds.height, 18, accuracy: 0.001)
        XCTAssertEqual(leaf.bounds.maxY, view.tip.y, accuracy: 0.001)
        XCTAssertEqual(leaf.element(at: 0, associatedPoints: &firstPoint), .moveTo)
        XCTAssertEqual(firstPoint, view.tip)
    }
}
