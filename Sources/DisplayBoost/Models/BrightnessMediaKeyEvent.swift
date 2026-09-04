import Foundation

enum BrightnessMediaKeyPhase: Equatable {
    case keyDown
    case keyUp
    case other
}

struct BrightnessMediaKeyEvent: Equatable {
    let direction: BrightnessKeyDirection
    let keyCode: Int
    let phase: BrightnessMediaKeyPhase

    static func decode(subtype: Int, data1: Int) -> BrightnessMediaKeyEvent? {
        guard subtype == 8 else { return nil }

        let keyCode = Int((data1 >> 16) & 0xFFFF)
        let direction: BrightnessKeyDirection
        switch keyCode {
        case 2:
            direction = .increase
        case 3:
            direction = .decrease
        default:
            return nil
        }

        let rawPhase = Int((data1 >> 8) & 0xFF)
        let phase: BrightnessMediaKeyPhase
        switch rawPhase {
        case 0x0A:
            phase = .keyDown
        case 0x0B:
            phase = .keyUp
        default:
            phase = .other
        }
        return BrightnessMediaKeyEvent(
            direction: direction,
            keyCode: keyCode,
            phase: phase
        )
    }
}
