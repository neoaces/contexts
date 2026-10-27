import AppKit

/// Milliseconds since the Unix epoch: the one time format shared with other devices.
typealias Millis = Int64

extension Millis {
    static var now: Millis { Millis(date: .now) }

    init(date: Date) {
        self = Millis((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// One block, in the sync format shared with the Ubuntu app (schema 2).
/// Nothing is ever removed: a delete sets `deletedAt`, so it syncs like any edit.
struct Block: Identifiable, Equatable {
    enum Content: Equatable {
        case text([TextRun])
        case math(latex: String)
        /// A kind this build doesn't know (e.g. from a newer app). Kept verbatim, never shown.
        case unknown([String: JSONValue])
    }

    var id: UUID
    var content: Content
    /// When the block was created or last restored; Recent is ordered by it.
    var surfacedAt: Millis
    var lastUsed: Millis
    var archivedAt: Millis?
    var deletedAt: Millis?
    var modifiedAt: Millis
    var modifiedBy: String

    init(content: Content, device: String, at time: Millis = .now) {
        id = UUID()
        self.content = content
        surfacedAt = time
        lastUsed = time
        modifiedAt = time
        modifiedBy = device
    }

    var isArchived: Bool { archivedAt != nil }
    var isDeleted: Bool { deletedAt != nil }

    var isShown: Bool {
        if isDeleted { return false }
        if case .unknown = content { return false }
        return true
    }

    var isBlank: Bool {
        switch content {
        case .text(let runs): runs.allSatisfy { $0.text.allSatisfy(\.isWhitespace) }
        case .math(let latex): latex.allSatisfy(\.isWhitespace)
        case .unknown: false
        }
    }

    /// Newest change wins; the device name breaks exact ties the same way on every machine.
    func supersedes(_ other: Block) -> Bool {
        (modifiedAt, modifiedBy) > (other.modifiedAt, other.modifiedBy)
    }
}

/// A stretch of text with one combination of styles. Runs, not offsets, because
/// Swift, GTK and Rust count characters differently.
struct TextRun: Codable, Equatable {
    var text: String
    var isBold = false
    var isItalic = false
    var isUnderlined = false

    init(text: String, isBold: Bool = false, isItalic: Bool = false, isUnderlined: Bool = false) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
    }

    func hasSameStyle(as other: TextRun) -> Bool {
        (isBold, isItalic, isUnderlined) == (other.isBold, other.isItalic, other.isUnderlined)
    }

    private enum CodingKeys: String, CodingKey {
        case text = "t", isBold = "b", isItalic = "i", isUnderlined = "u"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        isBold = try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        isItalic = try container.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        isUnderlined = try container.decodeIfPresent(Bool.self, forKey: .isUnderlined) ?? false
    }

    /// Styles that are off are left out, keeping the file small and readable.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if isBold { try container.encode(true, forKey: .isBold) }
        if isItalic { try container.encode(true, forKey: .isItalic) }
        if isUnderlined { try container.encode(true, forKey: .isUnderlined) }
    }
}

extension Block: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, runs, latex, surfacedAt, lastUsed, archivedAt, deletedAt, modifiedAt, modifiedBy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        surfacedAt = try container.decode(Millis.self, forKey: .surfacedAt)
        lastUsed = try container.decode(Millis.self, forKey: .lastUsed)
        archivedAt = try container.decodeIfPresent(Millis.self, forKey: .archivedAt)
        deletedAt = try container.decodeIfPresent(Millis.self, forKey: .deletedAt)
        modifiedAt = try container.decode(Millis.self, forKey: .modifiedAt)
        modifiedBy = try container.decode(String.self, forKey: .modifiedBy)
        switch try container.decode(String.self, forKey: .kind) {
        case "text": content = .text(try container.decode([TextRun].self, forKey: .runs))
        case "math": content = .math(latex: try container.decode(String.self, forKey: .latex))
        default: content = .unknown(try [String: JSONValue](from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        if case .unknown(let fields) = content {
            try fields.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        switch content {
        case .text(let runs):
            try container.encode("text", forKey: .kind)
            try container.encode(runs, forKey: .runs)
        case .math(let latex):
            try container.encode("math", forKey: .kind)
            try container.encode(latex, forKey: .latex)
        case .unknown:
            break
        }
        try container.encode(surfacedAt, forKey: .surfacedAt)
        try container.encode(lastUsed, forKey: .lastUsed)
        try container.encode(archivedAt, forKey: .archivedAt)
        try container.encode(deletedAt, forKey: .deletedAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(modifiedBy, forKey: .modifiedBy)
    }
}

/// Any JSON value, so blocks of unknown kinds round-trip untouched.
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), int(Int64), double(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension Block.Content {
    var isRichText: Bool {
        if case .text = self { true } else { false }
    }

    /// What the block's text view shows while it is edited.
    var editableText: NSAttributedString {
        switch self {
        case .text(let runs): RichText.attributedString(from: runs)
        case .math(let latex): NSAttributedString(string: latex, attributes: LaTeX.sourceAttributes)
        case .unknown: NSAttributedString()
        }
    }

    func replacingText(with text: NSAttributedString) -> Block.Content {
        switch self {
        case .text: .text(RichText.runs(from: text))
        case .math: .math(latex: text.string)
        case .unknown: self
        }
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

    var emptyContent: Block.Content {
        switch self {
        case .richText: .text([])
        case .math: .math(latex: "")
        }
    }
}
