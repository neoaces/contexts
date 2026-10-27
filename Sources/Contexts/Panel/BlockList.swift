import SwiftUI

/// Rows exist only while the panel is on screen (through its close), so a
/// hidden panel holds no text views. Each row drops in from the header with a short stagger.
struct BlockList: View {
    let model: PanelModel
    @State private var contentHeight: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// Newest block sits next to the header, whichever way the list grows.
    private var visibleBlocks: [Block] {
        guard model.mountsRows else { return [] }
        return model.opensUpward ? model.listedBlocks.reversed() : model.listedBlocks
    }

    private var headerEdge: Edge { model.opensUpward ? .bottom : .top }

    private var showsEmptyHistory: Bool {
        model.mountsRows && model.tab == .history && visibleBlocks.isEmpty
    }

    var body: some View {
        ScrollView {
            // Spacing 0: cards never fuse, but still share one glass rendering pass.
            GlassEffectContainer(spacing: 0) {
                VStack(spacing: 8) {
                    ForEach(Array(visibleBlocks.enumerated()), id: \.element.id) { index, block in
                        let distanceFromHeader = model.opensUpward ? visibleBlocks.count - 1 - index : index
                        BlockRow(block: block, model: model)
                            .transition(.dropIn(from: headerEdge, order: distanceFromHeader))
                    }
                    if showsEmptyHistory {
                        EmptyHistoryNote()
                            .transition(.dropIn(from: headerEdge, order: 0))
                    }
                }
            }
            .frame(maxWidth: .infinity)  // full width even when empty, so presenting never springs it open from zero
            .padding(.vertical, 2)
            .onGeometryChange(for: CGFloat.self, of: \.size.height, action: track)
        }
        .frame(maxHeight: contentHeight)
        .opacity(model.isPresented || !model.mountsRows ? 1 : 0)
        .scrollIndicators(.never)
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(model.opensUpward ? .bottom : .top)
        .onChange(of: model.listedBlocks.first?.id) { _, newID in
            guard model.isPresented, newID != nil, newID == model.editingBlockID else { return }
            withAnimation(.panel) { scrollPosition.scrollTo(edge: headerEdge) }
        }
        .onChange(of: model.isPresented) { _, isPresented in
            guard isPresented, model.opensUpward else { return }
            Task { await revealHeaderEdgeAfterDropIn() }
        }
    }

    /// Hiding empties the list, which resets its offset to the top. Upward, the
    /// newest blocks are at the bottom; a scroll issued mid-insertion is lost.
    private func revealHeaderEdgeAfterDropIn() async {
        try? await Task.sleep(for: .milliseconds(400))
        guard model.isPresented else { return }
        scrollPosition.scrollTo(edge: headerEdge)
    }

    /// Grows instantly so typing never clips; shrinks with the rows' spring so
    /// removals aren't cut off. Holds still while the panel animates away.
    private func track(_ height: CGFloat) {
        guard model.isPresented else { return }
        if height < contentHeight {
            withAnimation(.panel) { contentHeight = height }
        } else {
            contentHeight = height
        }
    }
}

private extension AnyTransition {
    static func dropIn(from edge: Edge, order: Int) -> AnyTransition {
        .asymmetric(
            insertion: .offset(y: edge == .top ? -10 : 10)
                .animation(.panel.delay(Double(min(order, 6)) * 0.006)),
            removal: .scale(scale: 0.96, anchor: edge == .top ? .top : .bottom).combined(with: .opacity)
        )
    }
}

/// A row slides left to uncover Delete, either by a two-finger swipe
/// (tracked in `PanelController`) or by the minus button in delete mode.
private struct BlockRow: View {
    let block: Block
    let model: PanelModel

    private var isArmedForDeletion: Bool { model.blockPendingDeletion == block.id }
    private var offset: CGFloat { model.revealOffset(for: block.id) }

    var body: some View {
        HStack(spacing: 8) {
            if model.isEditingList {
                Button { model.toggleDeletion(of: block.id) } label: {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .font(.system(size: 20))
                        .rotationEffect(.degrees(isArmedForDeletion ? -90 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ZStack(alignment: .trailing) {
                BlockCard(block: block, model: model)
                    .offset(x: offset)
                if offset < 0 {
                    deleteButton
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            model.rowFrames[block.id] = $0
        }
        .onDisappear { model.rowFrames[block.id] = nil }
    }

    /// Fills exactly the space the card has moved out of, so the two never overlap.
    private var deleteButton: some View {
        Button { model.delete(block.id) } label: {
            Text("Delete")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.red, in: .rect(cornerRadius: 16))
                .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .frame(width: max(0, -offset - 8))
        .clipped()
        .accessibilityLabel("Delete")
    }
}

private struct BlockCard: View {
    let block: Block
    let model: PanelModel

    private var isEditing: Bool { model.editingBlockID == block.id }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(isEditing ? .accentColor.opacity(0.12) : nil), in: .rect(cornerRadius: 16))
            .glassEffectTransition(.identity)
            .contentShape(.rect(cornerRadius: 16))
            .onTapGesture { model.activate(block.id) }
    }

    @ViewBuilder private var content: some View {
        switch block.content {
        case .richText:
            editor
        case .math(let latex):
            // Reading shows only the result; editing adds the source line above
            // and sets the result in a slightly darker well. Source that fails
            // to parse stays visible, so the block is never just an error.
            VStack(spacing: 8) {
                if isEditing || !LaTeX.parses(latex) { editor }
                MathPreview(latex: latex)
                    .padding(.vertical, isEditing ? 10 : 2)
                    .background {
                        if isEditing {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.14))
                        }
                    }
            }
        }
    }

    private var editor: some View {
        BlockEditor(
            content: block.content,
            isEditing: isEditing,
            onActivate: { model.activate(block.id) },
            onChange: { model.update(block.id, content: $0) },
            onCommit: model.endEditing
        )
    }
}

private struct EmptyHistoryNote: View {
    private var message: String {
        guard let interval = ArchivePolicy.interval else { return "Archiving is off." }
        return "Blocks unused for \(Int(interval / 60)) minutes move here."
    }

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .glassEffectTransition(.identity)
    }
}
