import Foundation

/// Never writes the backlight. Confirms small/transient changes before yielding.
struct BacklightObservation {
    enum Decision: Equatable { case ready, pending, yield, unavailable }
    private var uncertainSince: TimeInterval?

    mutating func reset() { uncertainSince = nil }

    mutating func observe(_ value: Float?, now: TimeInterval) -> Decision {
        let valid = value.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        if let valid, valid >= 0.995 {
            reset()
            return .ready
        }
        // A clear adjustment must take precedence immediately, including native F1.
        if let valid, valid < 0.98 {
            reset()
            return .yield
        }
        if uncertainSince == nil { uncertainSince = now }
        guard now - (uncertainSince ?? now) >= 1 else { return .pending }
        return valid == nil ? .unavailable : .yield
    }
}
