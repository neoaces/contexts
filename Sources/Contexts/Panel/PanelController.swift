import AppKit
import SwiftUI

/// Owns the panel window: where it appears, when it ignores the mouse, and
/// when it leaves the screen. Pointer tracking only runs while it is visible.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 360
    private static let minimumHeight: CGFloat = 320
    /// Distance from the panel's top to the header's center, so the plus button lands under the pointer.
    private static let headerCenterOffset: CGFloat = 30
    /// Slack around the content before the pointer counts as having left.
    private static let hoverMargin: CGFloat = 10

    private let model: PanelModel
    private let panel = ContextPanel()
    private var pointerMonitors: [Any] = []
    private var swipeGesture = SwipeGesture()

    init(model: PanelModel) {
        self.model = model
        super.init()
        let hostingView = NSHostingView(rootView: ContextPanelView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.delegate = self
        model.onHidden = { [weak self] in self?.hidden() }
        model.onPinned = { [weak self] in self?.moveToTopRight() }
        panel.onCancel = { [weak model] in model?.cancel() }
    }

    func show(on screen: NSScreen, pointerY: CGFloat) {
        if model.isPresented {
            guard !model.isPinned else { return }
            // Sliding onto another display's edge moves the panel there.
            guard panel.screen?.frame != screen.frame else { return }
            model.dismiss()
        }
        let opensUpward = pointerY - screen.visibleFrame.minY < Self.minimumHeight
        panel.setFrame(frame(on: screen, pointerY: pointerY, opensUpward: opensUpward), display: false)
        panel.appearance = NSApp.effectiveAppearance
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        startTrackingPointer()
        model.present(opensUpward: opensUpward, colorScheme: systemColorScheme)
    }

    func windowDidResignKey(_ notification: Notification) {
        model.endEditing()
    }

    /// ⌘Z outside a text block undoes block-level changes.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.undoManager
    }

    /// An ordered-out window picks up appearance changes late, which showed as a
    /// light flash in Dark Mode, so the appearance is handed over explicitly on show.
    private var systemColorScheme: ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// Pinned panels park at the top-right, blocks growing down from the menu bar.
    private func moveToTopRight() {
        guard let screen = panel.screen else { return }
        let target = frame(on: screen, pointerY: screen.visibleFrame.maxY, opensUpward: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// The close animation has finished; a quick re-show in the meantime wins.
    private func hidden() {
        guard !model.isPresented else { return }
        stopTrackingPointer()
        panel.orderOut(nil)
    }

    /// Spans from the header, centered on the pointer, to the far edge of the
    /// screen in the direction the list grows. The transparent remainder passes
    /// clicks through (see `pointerMoved`).
    private func frame(on screen: NSScreen, pointerY: CGFloat, opensUpward: Bool) -> CGRect {
        let visible = screen.visibleFrame
        let (bottom, top) = opensUpward
            ? (max(visible.minY, pointerY - Self.headerCenterOffset), visible.maxY)
            : (visible.minY, min(visible.maxY, pointerY + Self.headerCenterOffset))
        return CGRect(x: screen.frame.maxX - Self.width, y: bottom, width: Self.width, height: top - bottom)
    }

    // MARK: Pointer

    private func startTrackingPointer() {
        guard pointerMonitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let global = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        // A click makes the panel key, like any window, so ⌘Z and Escape reach it.
        let clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let panel = self?.panel, event.window === panel, !panel.isKeyWindow else { return }
                panel.makeKey()
            }
            return event
        }
        let scrolls = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumesAsSwipe(event) ?? false }
            return consumed ? nil : event
        }
        pointerMonitors = [global, local, clicks, scrolls].compactMap { $0 }
    }

    private func stopTrackingPointer() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
    }

    private func pointerMoved() {
        let pointer = NSEvent.mouseLocation
        let content = contentRegion
        let capturesClicks = content.contains(pointer) || (!model.isPinned && isOnTriggerEdge(pointer))
        if panel.ignoresMouseEvents == capturesClicks { panel.ignoresMouseEvents = !capturesClicks }
        let isNearContent = content.insetBy(dx: -Self.hoverMargin, dy: -Self.hoverMargin).contains(pointer)
        model.pointerMoved(isInside: capturesClicks || isNearContent)
    }

    /// A horizontal two-finger swipe over a row moves that row; anything else,
    /// including vertical scrolling and mouse wheels, passes through to the list.
    private func consumesAsSwipe(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let point = CGPoint(x: event.locationInWindow.x, y: panel.frame.height - event.locationInWindow.y)
        switch swipeGesture.classify(event, rowAt: { model.blockID(at: point) }) {
        case .passThrough:
            return false
        case .began(let id):
            model.beginSwipe(on: id)
            model.moveSwipe(by: swipeGesture.fingerDeltaX(event))
        case .moved:
            model.moveSwipe(by: swipeGesture.fingerDeltaX(event))
        case .ended:
            model.endSwipe()
        case .swallowed:
            break
        }
        return true
    }

    /// Resting on the edge that opened the panel keeps it open.
    private func isOnTriggerEdge(_ pointer: CGPoint) -> Bool {
        guard let screen = panel.screen else { return false }
        let visible = screen.visibleFrame
        return pointer.x >= screen.frame.maxX - EdgeHotZones.thickness && (visible.minY...visible.maxY).contains(pointer.y)
    }

    /// The content's on-screen rect, stretched to the screen edge the pointer came from.
    private var contentRegion: CGRect {
        let content = model.contentFrame
        let flipped = CGRect(x: content.minX, y: panel.frame.height - content.maxY, width: content.width, height: content.height)
        let onScreen = panel.convertToScreen(flipped)
        return CGRect(x: onScreen.minX, y: onScreen.minY, width: panel.frame.maxX - onScreen.minX, height: onScreen.height)
    }
}

final class ContextPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// A held Return or Escape that just confirmed a block must not go on to
    /// close the panel or beep once the window itself is first responder.
    override func keyDown(with event: NSEvent) {
        let returnOrEscape: Set<UInt16> = [36, 76, 53]
        if event.isARepeat, returnOrEscape.contains(event.keyCode) { return }
        super.keyDown(with: event)
    }
}
