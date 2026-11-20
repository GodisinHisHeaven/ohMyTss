import Foundation

/// Changing the target creates a new adjustment, unless the user chose its date.
/// A draft has no persistence effects until the editor saves it.
struct MuscleRPEEditDraft {
    private(set) var side: BodySide
    var rpe: Int?
    private(set) var observedAt: Date
    private(set) var hasSelectedDate = false

    init(side: BodySide, rpe: Int?, observedAt: Date) {
        self.side = side
        self.rpe = rpe
        self.observedAt = observedAt
    }

    mutating func selectSide(_ side: BodySide, now: Date) {
        guard side != self.side else { return }
        self.side = side
        if !hasSelectedDate { observedAt = now }
    }

    mutating func selectDate(_ date: Date) {
        observedAt = date
        hasSelectedDate = true
    }
}
