import XCTest
@testable import AIMCore

final class AIMMascotRulesTests: XCTestCase {
    func testFacesStayInsideGridAndDefaultExpressionSmiles() {
        XCTAssertEqual(AIMMascotRules.gridSide, 10)
        XCTAssertEqual(AIMMascotExpression.default, .happy)
        XCTAssertEqual(AIMMascotExpression.allCases, [.happy, .neutral, .angry, .surprised, .thinking])
        for expression in AIMMascotExpression.allCases {
            let face = AIMMascotRules.face(expression: expression)
            XCTAssertEqual(face.eyes.count, 2)
            XCTAssertGreaterThanOrEqual(face.mouth.points.count, 2)
            XCTAssertTrue(face.eyes.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= 10 && $0.y + $0.height <= 10 })
            XCTAssertTrue(face.mouth.points.allSatisfy { $0.x >= 0 && $0.x <= 10 && $0.y >= 0 && $0.y <= 10 })
        }
        let happy = AIMMascotRules.face(expression: .happy)
        guard let happyStart = happy.mouth.points.first?.y, let happyBottom = happy.mouth.points.map(\.y).max() else {
            return XCTFail("Happy mouth fixture is incomplete")
        }
        XCTAssertLessThan(happyStart, happyBottom)
        let angry = AIMMascotRules.face(expression: .angry)
        guard let angryStart = angry.mouth.points.first?.y, let angryTop = angry.mouth.points.map(\.y).min() else {
            return XCTFail("Angry mouth fixture is incomplete")
        }
        XCTAssertGreaterThan(angryStart, angryTop)
    }

    func testCubeVariationIsDeterministicJointAndVaried() {
        var maximumOffset = 0.0
        var offsets = Set<Double>()
        for index in 0..<100 {
            let variation = AIMMascotRules.cubeVariation(index: index)
            XCTAssertEqual(variation, AIMMascotRules.cubeVariation(index: index))
            XCTAssertLessThanOrEqual(abs(variation.rotation), 2)
            XCTAssertTrue((3...6).contains(variation.duration))
            XCTAssertTrue((-1...1).contains(variation.tint))
            maximumOffset = max(maximumOffset, abs(variation.dx), abs(variation.dy))
            offsets.insert((variation.dx * 1_000).rounded() / 1_000)
        }
        XCTAssertGreaterThanOrEqual(AIMMascotRules.cubeOverlap, 2 * maximumOffset + 0.1)
        XCTAssertGreaterThan(offsets.count, 30)
        XCTAssertEqual(AIMMascotRules.touchReaction, .init(expression: .angry, durationMilliseconds: 1_400, shakes: true))
    }
}
