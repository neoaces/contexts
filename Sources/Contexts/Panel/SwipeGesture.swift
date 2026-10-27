import AppKit

/// Decides, per trackpad scroll gesture, whether it is a horizontal swipe on a
/// row. The first few points of travel pick the axis; after that the whole
/// gesture, including its momentum, belongs to one side.
struct SwipeGesture {
    enum Step {
        case passThrough
        case began(Block.ID)
        case moved
        case ended
        case swallowed
    }

    private enum Claim { case undecided, swipe, scroll }

    private static let decisionDistance: CGFloat = 4
    /// Horizontal travel must clearly dominate, so diagonal scrolling still scrolls.
    private static let horizontalBias: CGFloat = 1.5

    private var claim = Claim.scroll
    private var travel = CGSize.zero
    private var target: Block.ID?

    mutating func classify(_ event: NSEvent, rowAt row: () -> Block.ID?) -> Step {
        // Mouse wheels have no phases; momentum follows whoever owned the gesture.
        if event.phase.isEmpty {
            return event.momentumPhase.isEmpty || claim != .swipe ? .passThrough : .swallowed
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            claim = .undecided
            travel = .zero
            target = row()
        }
        switch claim {
        case .scroll:
            return .passThrough
        case .swipe:
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                return .ended
            }
            return .moved
        case .undecided:
            travel.width += abs(event.scrollingDeltaX)
            travel.height += abs(event.scrollingDeltaY)
            guard travel.width + travel.height >= Self.decisionDistance else { return .passThrough }
            if let target, travel.width > travel.height * Self.horizontalBias {
                claim = .swipe
                return .began(target)
            }
            claim = .scroll
            return .passThrough
        }
    }

    /// Finger travel along x, leftward negative, whatever the scroll direction setting.
    func fingerDeltaX(_ event: NSEvent) -> CGFloat {
        event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
    }
}
