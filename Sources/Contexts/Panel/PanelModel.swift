import SwiftUI

extension Animation {
    /// The one motion curve: short, with a little spring.
    static let panel = Animation.spring(duration: 0.07, bounce: 0.15)
}

/// UI state and intents for the panel. Window concerns live in `PanelController`.
@MainActor @Observable
final class PanelModel {
    enum Tab: CaseIterable, Identifiable {
        case recent, history

        var id: Self { self }
        var title: String { self == .recent ? "Recent" : "History" }
    }

    let store: BlockStore
    /// Block-level undo (delete, restore). Text edits use each block's own stack.
    @ObservationIgnored let undoManager = UndoManager()

    private(set) var isPresented = false
    /// Rows stay mounted through the close so the list fades out as one piece,
    /// instead of vanishing on the first frame while the header animates.
    private(set) var mountsRows = false
    /// Near the bottom of the screen the list grows upward from the header instead.
    private(set) var opensUpward = false
    /// Pinned: parked at the top-right, stays open, and only shows its header while hovered.
    private(set) var isPinned = false
    private(set) var isPointerInside = false
    /// Resolved before each presentation so the first frame already matches the system.
    private(set) var colorScheme = ColorScheme.light
    private(set) var tab = Tab.recent
    private(set) var isChoosingNewBlock = false
    private(set) var isEditingList = false
    private(set) var blockPendingDeletion: Block.ID?
    private(set) var editingBlockID: Block.ID?
    /// A two-finger swipe in progress on one row; nil once it settles open or closed.
    private(set) var swipe: Swipe?
    /// Name of the action the undo button would reverse, while it is offered.
    private(set) var undoableAction: String?

    /// Each mounted row's frame in the panel's SwiftUI global space, for finding the swiped row.
    @ObservationIgnored var rowFrames: [Block.ID: CGRect] = [:]
    /// Frame of the visible content in the panel's SwiftUI global space.
    @ObservationIgnored var contentFrame: CGRect = .zero
    /// Called once the close animation has finished, so the window can leave the screen.
    @ObservationIgnored var onHidden: (() -> Void)?
    @ObservationIgnored var onPinned: (() -> Void)?
    @ObservationIgnored private var pendingDismissal: Task<Void, Never>?
    @ObservationIgnored private var pendingUndoExpiry: Task<Void, Never>?
    /// What the edited block held when editing began, so clearing it out can be undone.
    @ObservationIgnored private var contentBeforeEditing: Block.Content?

    init(store: BlockStore) {
        self.store = store
        undoManager.levelsOfUndo = 20
    }

    var listedBlocks: [Block] {
        tab == .recent ? store.recent : store.history
    }

    var showsHeaderControls: Bool {
        !isPinned || isPointerInside
    }

    // MARK: Presentation

    func present(opensUpward: Bool, colorScheme: ColorScheme) {
        pendingDismissal?.cancel()
        isPointerInside = true
        self.opensUpward = opensUpward
        self.colorScheme = colorScheme
        archiveUnusedBlocks()
        if undoableAction != nil { offerUndo() }
        resetTransientState()
        withAnimation(.panel) {
            isPresented = true
            mountsRows = true
        }
    }

    /// The undo offer survives hiding, so a delete just before the pointer left can still be reversed.
    func dismiss() {
        pendingDismissal?.cancel()
        guard isPresented else { return }
        commitEditing()
        pendingUndoExpiry?.cancel()
        withAnimation(.panel, completionCriteria: .logicallyComplete) {
            isPresented = false
            isChoosingNewBlock = false
            isPinned = false
        } completion: { [weak self] in
            guard let self, !isPresented else { return }
            mountsRows = false
            resetTransientState()
            onHidden?()
        }
    }

    private func resetTransientState() {
        isEditingList = false
        blockPendingDeletion = nil
        swipe = nil
        tab = .recent
    }

    /// Escape outside a text block closes the innermost open state.
    func cancel() {
        if isChoosingNewBlock {
            toggleNewBlockOptions()
        } else if isEditingList {
            toggleListEditing()
        } else if tab == .history {
            show(.recent)
        } else {
            dismiss()
        }
    }

    func pointerMoved(isInside: Bool) {
        guard isInside != isPointerInside else { return }
        withAnimation(.panel) { isPointerInside = isInside }
        if isInside {
            pendingDismissal?.cancel()
        } else {
            dismissIfIdle()
        }
    }

    func togglePin() {
        withAnimation(.panel) {
            isPinned.toggle()
            if isPinned { opensUpward = false }
        }
        if isPinned {
            pendingDismissal?.cancel()
            onPinned?()
        } else {
            dismissIfIdle()
        }
    }

    func show(_ tab: Tab) {
        commitEditing()
        withAnimation(.panel) {
            isEditingList = false
            blockPendingDeletion = nil
            self.tab = tab
        }
    }

    // MARK: Creating

    func toggleNewBlockOptions() {
        withAnimation(.panel) {
            isEditingList = false
            blockPendingDeletion = nil
            isChoosingNewBlock.toggle()
        }
    }

    func create(_ option: NewBlockOption) {
        commitEditing()
        let block = option.makeBlock()
        withAnimation(.panel) {
            isChoosingNewBlock = false
            tab = .recent
            store.insert(block)
            editingBlockID = block.id
        }
    }

    // MARK: Editing

    /// A click on a block. Returns whether it should start editing in place:
    /// in delete mode a click only disarms, and in History it restores the block.
    @discardableResult
    func activate(_ id: Block.ID) -> Bool {
        if isEditingList || blockPendingDeletion != nil {
            withAnimation(.panel) { blockPendingDeletion = nil }
            return false
        }
        if tab == .history {
            restore(id)
            return false
        }
        guard editingBlockID != id else { return true }
        commitEditing()
        store.markUsed(id)
        contentBeforeEditing = store.block(id)?.content
        withAnimation(.panel) {
            isChoosingNewBlock = false
            editingBlockID = id
        }
        return true
    }

    func update(_ id: Block.ID, content: Block.Content) {
        store.update(id, content: content)
    }

    /// Ends editing from the user's side (Escape, clicking elsewhere).
    func endEditing() {
        commitEditing()
        dismissIfIdle()
    }

    func prepareForTermination() {
        commitEditing()
        store.saveIfNeeded()
    }

    // MARK: Deleting, restoring, undo

    func toggleListEditing() {
        commitEditing()
        withAnimation(.panel) {
            isChoosingNewBlock = false
            blockPendingDeletion = nil
            isEditingList.toggle()
        }
    }

    func toggleDeletion(of id: Block.ID) {
        withAnimation(.panel) {
            blockPendingDeletion = blockPendingDeletion == id ? nil : id
        }
    }

    // MARK: Swipe to delete

    struct Swipe {
        let id: Block.ID
        var offset: CGFloat
    }

    /// How far a row slides left to uncover its Delete button.
    static let deleteRevealWidth: CGFloat = 84

    /// How far the row's card sits to the left: following the fingers, open, or closed.
    func revealOffset(for id: Block.ID) -> CGFloat {
        if let swipe, swipe.id == id { return swipe.offset }
        return blockPendingDeletion == id ? -Self.deleteRevealWidth : 0
    }

    func blockID(at point: CGPoint) -> Block.ID? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    func beginSwipe(on id: Block.ID) {
        guard id != editingBlockID else { return }
        let start = revealOffset(for: id)
        withAnimation(.panel) {
            if blockPendingDeletion != id { blockPendingDeletion = nil }
        }
        swipe = Swipe(id: id, offset: start)
    }

    /// `dx` is finger travel; leftward is negative. A little give past fully open.
    func moveSwipe(by dx: CGFloat) {
        guard var swipe else { return }
        swipe.offset = min(0, max(-Self.deleteRevealWidth * 1.25, swipe.offset + dx))
        self.swipe = swipe
    }

    /// Settles open past halfway, closed otherwise.
    func endSwipe() {
        guard let swipe else { return }
        let opens = swipe.offset < -Self.deleteRevealWidth / 2
        withAnimation(.panel) {
            self.swipe = nil
            if opens {
                blockPendingDeletion = swipe.id
            } else if blockPendingDeletion == swipe.id {
                blockPendingDeletion = nil
            }
        }
    }

    func delete(_ id: Block.ID) {
        replace(id, with: nil, at: .front, actionName: "Delete")
        withAnimation(.panel) {
            blockPendingDeletion = nil
            if listedBlocks.isEmpty { isEditingList = false }
        }
        offerUndo()
    }

    func restore(_ id: Block.ID) {
        guard var block = store.block(id) else { return }
        block.archivedAt = nil
        block.lastUsed = .now
        replace(id, with: block, at: .front, actionName: "Restore")
        withAnimation(.panel) { tab = .recent }
        offerUndo()
    }

    func undo() {
        commitEditing()
        undoManager.undo()
    }

    // MARK: Private

    /// Where a block goes back: in front of the block that used to follow it,
    /// or at its old index if that one is gone too.
    private struct Slot {
        var index: Int
        var follower: Block.ID?

        static let front = Slot(index: 0, follower: nil)
    }

    /// Swaps whatever is stored under `id` for `block` (nil removes it) and
    /// registers the exact inverse, so undo and redo are the same operation.
    /// Only state and position swap: text typed in between is kept.
    private func replace(_ id: Block.ID, with block: Block?, at slot: Slot, actionName: String) {
        var block = block
        if let current = store.block(id) { block?.content = current.content }
        let previous: (block: Block, slot: Slot)? = withAnimation(.panel) {
            let removed = store.remove(id).map { removed in
                let follower = removed.index < store.blocks.count ? store.blocks[removed.index].id : nil
                return (removed.block, Slot(index: removed.index, follower: follower))
            }
            if let block { store.insert(block, at: index(of: slot)) }
            return removed
        }
        store.saveIfNeeded()
        if undoManager.isUndoing || undoManager.isRedoing {
            withAnimation(.panel) { undoableAction = nil }
        }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.replace(id, with: previous?.block, at: previous?.slot ?? slot, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func index(of slot: Slot) -> Int {
        slot.follower.flatMap { follower in store.blocks.firstIndex { $0.id == follower } } ?? slot.index
    }

    private func offerUndo() {
        withAnimation(.panel) { undoableAction = undoManager.canUndo ? undoManager.undoActionName : nil }
        pendingUndoExpiry?.cancel()
        pendingUndoExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.panel) { self?.undoableAction = nil }
        }
    }

    /// Blocks untouched for the configured interval move to History before the panel shows.
    private func archiveUnusedBlocks() {
        guard let interval = ArchivePolicy.interval else { return }
        store.archiveBlocks(unusedSince: .now - interval)
    }

    /// A new block left empty is discarded silently. An existing block that was
    /// cleared out is deleted as an undoable action, keeping its previous text.
    private func commitEditing() {
        guard let id = editingBlockID else { return }
        let original = contentBeforeEditing
        contentBeforeEditing = nil
        withAnimation(.panel) { editingBlockID = nil }
        if store.block(id)?.isBlank == true {
            if let original, !Block(content: original).isBlank {
                store.update(id, content: original)
                delete(id)
            } else {
                withAnimation(.panel) { _ = store.remove(id) }
            }
        }
        store.saveIfNeeded()
    }

    private func dismissIfIdle() {
        guard isPresented, !isPinned, !isPointerInside, editingBlockID == nil else { return }
        pendingDismissal?.cancel()
        pendingDismissal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}

/// How long a block may go unused before it is archived.
/// Override with `defaults write local.contexts archiveAfterMinutes -int 60`; 0 turns archiving off.
enum ArchivePolicy {
    static let defaultMinutes = 30

    static var interval: TimeInterval? {
        let stored = UserDefaults.standard.object(forKey: "archiveAfterMinutes") as? Int
        let minutes = stored ?? defaultMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }
}
