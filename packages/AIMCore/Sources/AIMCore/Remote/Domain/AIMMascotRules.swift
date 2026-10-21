import Foundation

public enum AIMMascotExpression: String, CaseIterable, Sendable {
    case happy, neutral, angry, surprised, thinking
    public static let `default`: Self = .happy
}

public struct AIMPoint: Equatable, Sendable { public let x: Double; public let y: Double }
public struct AIMRect: Equatable, Sendable { public let x: Double; public let y: Double; public let width: Double; public let height: Double }
public struct AIMMouth: Equatable, Sendable { public let points: [AIMPoint]; public let thickness: Double }
public struct AIMMascotFace: Equatable, Sendable { public let eyes: [AIMRect]; public let mouth: AIMMouth }
public struct AIMCubeVariation: Equatable, Sendable { public let dx: Double; public let dy: Double; public let rotation: Double; public let tint: Double; public let delay: Double; public let duration: Double }
public struct AIMMascotReaction: Equatable, Sendable { public let expression: AIMMascotExpression; public let durationMilliseconds: Int; public let shakes: Bool }

public enum AIMMascotRules {
    public static let gridSide = 10.0
    public static let cubeOverlap = 0.35
    public static let touchReaction = AIMMascotReaction(expression: .angry, durationMilliseconds: 1_400, shakes: true)

    public static func face(expression: AIMMascotExpression, look: Int = 0) -> AIMMascotFace {
        let base: AIMMascotFace = switch expression {
        case .happy: .init(eyes: pair(x: 2.2, y: 2.2, width: 1.6, height: 2.6), mouth: mouth([(2.5, 6.3), (2.5, 7.5), (7.5, 7.5), (7.5, 6.3)], 1))
        case .neutral: .init(eyes: pair(x: 2.2, y: 2.2, width: 1.6, height: 2.6), mouth: mouth([(3, 7), (7, 7)], 1))
        case .angry: .init(eyes: pair(x: 2, y: 3.3, width: 2, height: 1.2), mouth: mouth([(2.5, 7.7), (2.5, 6.6), (7.5, 6.6), (7.5, 7.7)], 1))
        case .surprised: .init(eyes: pair(x: 2.2, y: 1.6, width: 1.6, height: 3.2), mouth: mouth([(4.3, 6.4), (5.7, 6.4), (5.7, 7.6), (4.3, 7.6), (4.3, 6.4)], 0.9))
        case .thinking: .init(eyes: [.init(x: 2.8, y: 1.6, width: 1.6, height: 2.6), .init(x: 6.8, y: 1.6, width: 1.6, height: 2.6)], mouth: mouth([(4.6, 7), (6.6, 7)], 1))
        }
        return .init(eyes: base.eyes.map { .init(x: $0.x + Double(max(-1, min(1, look))) * 0.6, y: $0.y, width: $0.width, height: $0.height) }, mouth: base.mouth)
    }

    public static func cubeVariation(index: Int) -> AIMCubeVariation {
        var random = Mulberry32(seed: UInt32(truncatingIfNeeded: index + 1))
        return .init(
            dx: (random.next() - 0.5) * 0.24,
            dy: (random.next() - 0.5) * 0.24,
            rotation: (random.next() - 0.5) * 3.2,
            tint: random.next() * 2 - 1,
            delay: random.next() * 3,
            duration: 3.2 + random.next() * 2.6
        )
    }

    private static func pair(x: Double, y: Double, width: Double, height: Double) -> [AIMRect] {
        [.init(x: x, y: y, width: width, height: height), .init(x: gridSide - x - width, y: y, width: width, height: height)]
    }

    private static func mouth(_ points: [(Double, Double)], _ thickness: Double) -> AIMMouth {
        .init(points: points.map { .init(x: $0.0, y: $0.1) }, thickness: thickness)
    }
}

private struct Mulberry32 {
    private var value: UInt32
    init(seed: UInt32) { value = seed &* 2_654_435_761 }
    mutating func next() -> Double {
        value &+= 0x6D2B79F5
        var t = value
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}
