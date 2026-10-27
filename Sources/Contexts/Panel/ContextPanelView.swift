import SwiftUI

/// The header sits under the pointer; blocks grow away from it, downward
/// unless the pointer is near the bottom of the screen.
struct ContextPanelView: View {
    let model: PanelModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !model.opensUpward { header }
            BlockList(model: model)
            if model.opensUpward { header }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            model.contentFrame = $0
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.opensUpward ? .bottomTrailing : .topTrailing)
        .environment(\.colorScheme, model.colorScheme)
        .allowsWindowActivationEvents()
    }

    @ViewBuilder private var header: some View {
        if model.isPresented {
            PanelHeader(model: model)
                .transition(.pop(0.7, anchor: .trailing))
        }
    }
}

extension AnyTransition {
    /// Grows in without fading (fading glass flashes light over white windows),
    /// and shrinks out while fading so nothing lingers half-closed.
    static func pop(_ scale: CGFloat, anchor: UnitPoint) -> AnyTransition {
        .asymmetric(
            insertion: .scale(scale: scale, anchor: anchor),
            removal: .scale(scale: scale, anchor: anchor).combined(with: .opacity)
        )
    }
}

/// [pin]  …  [new-block options | undo | tabs]  [+]  [≡]. The slot before +
/// shows one thing at a time, in that priority, so the header never crowds.
/// While pinned and not hovered the buttons shrink away, but the row keeps its
/// height so the blocks below never jump.
private struct PanelHeader: View {
    let model: PanelModel

    var body: some View {
        // Spacing below the HStack's, so neighbours sit side by side instead of fusing.
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 8) {
                if model.showsHeaderControls {
                    Button(action: model.togglePin) {
                        Image(systemName: model.isPinned ? "pin.fill" : "pin")
                            .contentTransition(.symbolEffect(.replace))
                            .iconFrame()
                    }
                    .buttonStyle(.panelGlass(.circle))
                    .accessibilityLabel(model.isPinned ? "Unpin" : "Pin to top right")
                    .transition(.pop(0.6, anchor: .leading))
                    Spacer(minLength: 0)
                    trailingControls
                        .transition(.pop(0.8, anchor: .trailing))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 8) {
            leadingSlot
                .transition(.pop(0.8, anchor: .trailing))
            Button(action: model.toggleNewBlockOptions) {
                Image(systemName: "plus")
                    .rotationEffect(.degrees(model.isChoosingNewBlock ? 45 : 0))
                    .iconFrame()
            }
            .buttonStyle(.panelGlass(.circle))
            .accessibilityLabel(model.isChoosingNewBlock ? "Close" : "New block")
            if !model.listedBlocks.isEmpty {
                Button(action: model.toggleListEditing) {
                    Image(systemName: model.isEditingList ? "checkmark" : "line.3.horizontal")
                        .contentTransition(.symbolEffect(.replace))
                        .iconFrame()
                }
                .buttonStyle(.panelGlass(.circle))
                .accessibilityLabel(model.isEditingList ? "Done" : "Edit blocks")
                .transition(.pop(0.6, anchor: .trailing))
            }
        }
    }

    @ViewBuilder private var leadingSlot: some View {
        if model.isChoosingNewBlock {
            ForEach(NewBlockOption.allCases) { option in
                Button { model.create(option) } label: {
                    Label(option.title, systemImage: option.symbol).capsuleFrame()
                }
                .buttonStyle(.panelGlass(.capsule))
            }
        } else if let action = model.undoableAction {
            Button(action: model.undo) {
                Label("Undo \(action)", systemImage: "arrow.uturn.backward").capsuleFrame()
            }
            .buttonStyle(.panelGlass(.capsule))
        } else {
            TabSwitch(model: model)
        }
    }
}

private struct TabSwitch: View {
    let model: PanelModel
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PanelModel.Tab.allCases) { tab in
                Button { model.show(tab) } label: {
                    Text(tab.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(model.tab == tab ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background {
                            if model.tab == tab {
                                Capsule().fill(.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .glassEffectTransition(.identity)
    }
}

/// Glass with a quick press-in, instead of `.interactive()` glass, which
/// warps the shape on hover and costs extra rendering.
///
/// Glass appears with its view, never by fading: half-transparent dark glass
/// over a white window reads as light grey, which looked like a late switch to
/// Dark Mode. `.identity` also keeps it on the panel's spring instead of the
/// system's slower materialize timing.
private struct PanelGlassButtonStyle<S: Shape>: ButtonStyle {
    let shape: S

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(shape)
            .glassEffect(.regular, in: shape)
            .glassEffectTransition(.identity)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.panel, value: configuration.isPressed)
    }
}

private extension ButtonStyle where Self == PanelGlassButtonStyle<Circle> {
    static func panelGlass(_ shape: Circle) -> Self { PanelGlassButtonStyle(shape: shape) }
}

private extension ButtonStyle where Self == PanelGlassButtonStyle<Capsule> {
    static func panelGlass(_ shape: Capsule) -> Self { PanelGlassButtonStyle(shape: shape) }
}

private extension View {
    func iconFrame() -> some View {
        font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
    }

    func capsuleFrame() -> some View {
        font(.callout.weight(.medium)).padding(.horizontal, 14).frame(height: 34)
    }
}
