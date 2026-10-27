import AppKit

/// A 2pt invisible strip on the right edge of each screen. The window server
/// does the hover tracking, so nothing runs in this process until the
/// pointer actually rests on an edge.
@MainActor
final class EdgeHotZones: NSObject {
    static let thickness: CGFloat = 2
    private static let dwell = Duration.milliseconds(60)

    private let onTrigger: (NSScreen) -> Void
    private var zones: [NSPanel] = []

    init(onTrigger: @escaping (NSScreen) -> Void) {
        self.onTrigger = onTrigger
        super.init()
        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func rebuild() {
        zones.forEach { $0.orderOut(nil) }
        zones = NSScreen.screens.filter(Self.hasOpenRightEdge).map(makeZone)
    }

    private func makeZone(on screen: NSScreen) -> NSPanel {
        let visible = screen.visibleFrame
        let frame = CGRect(
            x: screen.frame.maxX - Self.thickness, y: visible.minY,
            width: Self.thickness, height: visible.height
        )
        // Non-activating, so a stray click on the edge never steals focus from the user's app.
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false  // explicit: receive events despite being transparent
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = HotZoneView(dwell: Self.dwell) { [weak self, weak screen] in
            guard let screen else { return }
            self?.onTrigger(screen)
        }
        window.orderFrontRegardless()
        return window
    }

    /// Edges shared with another display, or claimed by the Dock, are not triggers.
    private static func hasOpenRightEdge(_ screen: NSScreen) -> Bool {
        let dockOnRight = screen.visibleFrame.maxX < screen.frame.maxX - 0.5
        return !dockOnRight && !NSScreen.screens.contains { other in
            other != screen
                && abs(other.frame.minX - screen.frame.maxX) < 1
                && other.frame.minY < screen.frame.maxY
                && other.frame.maxY > screen.frame.minY
        }
    }
}

private final class HotZoneView: NSView {
    private let dwell: Duration
    private let onDwell: () -> Void
    private var pendingTrigger: Task<Void, Never>?

    init(dwell: Duration, onDwell: @escaping () -> Void) {
        self.dwell = dwell
        self.onDwell = onDwell
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        pendingTrigger = Task { [weak self, dwell] in
            try? await Task.sleep(for: dwell)
            // A held button means a window or file is being dragged to the edge.
            guard !Task.isCancelled, NSEvent.pressedMouseButtons == 0 else { return }
            self?.onDwell()
        }
    }

    override func mouseExited(with event: NSEvent) {
        pendingTrigger?.cancel()
    }

    override func scrollWheel(with event: NSEvent) {}
}
