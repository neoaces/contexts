import AppKit

struct Block: Identifiable, Codable, Equatable {
    enum Content: Codable, Equatable {
        case richText(rtf: Data)
        case math(latex: String)
    }

    var id = UUID()
    var content: Content
    var lastUsed = Date.now
    var archivedAt: Date?

    var isArchived: Bool { archivedAt != nil }

    var isBlank: Bool {
        switch content {
        case .richText(let rtf): RichText.isBlank(rtf)
        case .math(let latex): latex.allSatisfy(\.isWhitespace)
        }
    }
}

extension Block.Content {
    var isRichText: Bool {
        if case .richText = self { true } else { false }
    }

    /// What the block's text view shows while it is edited.
    var editableText: NSAttributedString {
        switch self {
        case .richText(let rtf): RichText.decode(rtf)
        case .math(let latex): NSAttributedString(string: latex, attributes: LaTeX.sourceAttributes)
        }
    }

    func replacingText(with text: NSAttributedString) -> Block.Content {
        switch self {
        case .richText: .richText(rtf: RichText.encode(text))
        case .math: .math(latex: text.string)
        }
    }
}

extension Block {
    /// Fields added after 0.1 fall back to defaults, so older files keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(Content.self, forKey: .content)
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed) ?? .now
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
    }
}

/// What the plus button offers. Separate from `Block.Content` because several
/// options (screenshot, upload) will produce the same kind of content.
enum NewBlockOption: CaseIterable, Identifiable {
    case richText, math

    var id: Self { self }

    var title: String {
        switch self {
        case .richText: "Text"
        case .math: "Math"
        }
    }

    var symbol: String {
        switch self {
        case .richText: "textformat"
        case .math: "function"
        }
    }

    func makeBlock() -> Block {
        switch self {
        case .richText: Block(content: .richText(rtf: Data()))
        case .math: Block(content: .math(latex: ""))
        }
    }
}
