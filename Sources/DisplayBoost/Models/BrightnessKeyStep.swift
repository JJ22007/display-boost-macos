import Foundation

enum BrightnessKeyDirection: Equatable {
    case increase
    case decrease
}

enum BrightnessKeyStep {
    static let coarse: Float = 1.0 / 16.0
    static let fine: Float = 1.0 / 64.0

    static func nextBoostLevel(
        from current: Float,
        direction: BrightnessKeyDirection,
        fineGrained: Bool
    ) -> BoostLevel {
        let step = fineGrained ? fine : coarse
        let position = current / step
        let epsilon: Float = 0.0001

        let targetPosition: Float
        switch direction {
        case .increase:
            targetPosition = floor(position + epsilon) + 1
        case .decrease:
            targetPosition = ceil(position - epsilon) - 1
        }
        return BoostLevel(targetPosition * step)
    }
}
