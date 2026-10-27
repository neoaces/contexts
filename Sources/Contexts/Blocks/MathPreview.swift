import AppKit
import SwiftMath
import SwiftUI

/// The rendered form of a math block, centered across the block's width.
/// A wide formula first shrinks, down to a still-legible size, then scrolls sideways.
struct MathPreview: View {
    let latex: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            MathLabel(latex: latex)
            ScrollView(.horizontal) { MathLabel(latex: latex) }
                .scrollIndicators(.never)
        }
    }
}

private struct MathLabel: NSViewRepresentable {
    private static let minimumHeight: CGFloat = 22

    let latex: String

    func makeNSView(context: Context) -> MathPreviewView {
        MathPreviewView()
    }

    func updateNSView(_ view: MathPreviewView, context: Context) {
        if view.label.latex != latex { view.label.latex = latex }
    }

    /// With no width offered (ViewThatFits asking, or inside the scroll view)
    /// this reports the smallest legible rendering.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MathPreviewView, context: Context) -> CGSize? {
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        if let errorHeight = view.errorHeight(fittingWidth: available) {
            return CGSize(width: available, height: max(errorHeight, Self.minimumHeight))
        }
        let size = view.fit(to: available)
        // A size query may leave a smaller font behind; the real layout re-fits.
        view.needsLayout = true
        return CGSize(width: max(available, size.width), height: max(size.height, Self.minimumHeight))
    }
}

/// Hosts the label and stays invisible to clicks, so the card's tap gesture
/// starts editing wherever the formula is drawn.
final class MathPreviewView: NSView {
    private static let fontSize: CGFloat = 18
    private static let minimumFontSize: CGFloat = 12

    let label = MTMathUILabel()

    init() {
        super.init(frame: .zero)
        label.labelMode = .display
        label.textAlignment = .center
        label.textColor = .labelColor
        label.errorLabel?.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    /// Sets the largest font, between the floor and full size, at which the
    /// formula fits `available`, and returns the resulting size. On macOS the
    /// label measures through `fittingSize`; its `intrinsicContentSize` is unset.
    @discardableResult
    func fit(to available: CGFloat) -> CGSize {
        if label.fontSize != Self.fontSize { label.fontSize = Self.fontSize }
        let natural = label.fittingSize
        if natural.width > available, natural.width > 0 {
            label.fontSize = max(Self.minimumFontSize, Self.fontSize * available / natural.width)
        }
        return label.fittingSize
    }

    /// Height of the wrapped error message, or nil when the LaTeX parses.
    func errorHeight(fittingWidth width: CGFloat) -> CGFloat? {
        guard label.error != nil, width > 0, let cell = label.errorLabel?.cell else { return nil }
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return ceil(cell.cellSize(forBounds: bounds).height)
    }

    override func layout() {
        super.layout()
        if label.error == nil { fit(to: bounds.width) }
        label.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
