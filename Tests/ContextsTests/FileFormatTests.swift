import Foundation
import Testing
@testable import Contexts

/// The exact shape of `blocks-<device>.json`, read back as generic JSON the way the Ubuntu app sees it.
@Suite struct FileFormatTests {
    /// Has letters, so `uuidString` (uppercase) and the written id (lowercase) differ.
    let id = UUID(uuidString: "0B4F3C1E-2D9A-4C51-9F0E-6A7D2B1C8E44")!

    @Test func headerHasSchemaTwoAndThisDevice() throws {
        let file = try written([textBlock("hi", id: id)])
        #expect((file["schema"] as? NSNumber)?.intValue == 2)
        #expect(file["device"] as? String == "mac")
    }

    @Test func idsAreLowercase() throws {
        let block = try onlyBlock(in: written([textBlock("hi", id: id)]))
        #expect(id.uuidString != id.uuidString.lowercased())
        #expect(block["id"] as? String == id.uuidString.lowercased())
    }

    @Test func nilArchivedAtAndDeletedAtAreExplicitNull() throws {
        let block = try onlyBlock(in: written([textBlock("hi", id: id)]))
        #expect(block["archivedAt"] is NSNull)
        #expect(block["deletedAt"] is NSNull)
    }

    @Test func falseStylesAreLeftOutAndTrueOnesKept() throws {
        let runs = [
            TextRun(text: "plain"),
            TextRun(text: "bold", isBold: true),
            TextRun(text: "italic underlined", isItalic: true, isUnderlined: true),
        ]
        var source = textBlock("", id: id)
        source.content = .text(runs)
        let written = try #require(onlyBlock(in: written([source]))["runs"] as? [[String: Any]])

        #expect(written.map { Set($0.keys) } == [["t"], ["t", "b"], ["t", "i", "u"]])
        #expect(written[1]["b"] as? Bool == true)
        #expect(written[2]["i"] as? Bool == true)
        #expect(written[2]["u"] as? Bool == true)
    }

    @Test func timestampsAreIntegerMilliseconds() throws {
        var source = textBlock("hi", id: id, modifiedAt: 1_793_113_400_005)
        source.surfacedAt = 1_793_113_400_001
        source.lastUsed = 1_793_113_400_002
        source.archivedAt = 1_793_113_400_003
        source.deletedAt = 1_793_113_400_004
        let block = try onlyBlock(in: written([source]))

        let expected: [String: Millis] = [
            "surfacedAt": 1_793_113_400_001, "lastUsed": 1_793_113_400_002, "archivedAt": 1_793_113_400_003,
            "deletedAt": 1_793_113_400_004, "modifiedAt": 1_793_113_400_005,
        ]
        for (key, millis) in expected {
            #expect(integerMillis(block[key]) == millis, "\(key)")
        }
    }

    @Test func millisFromADateRoundToTheNearestMillisecond() {
        #expect(Millis(date: Date(timeIntervalSince1970: 1.0006)) == 1_001)
        #expect(Millis(date: Date(timeIntervalSince1970: 1.0004)) == 1_000)
    }

    @Test func noTempFileIsLeftBehind() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        try tmp.syncFolder().write([textBlock("hi", id: id)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["blocks-mac.json"])
    }

    @Test func keysAreSortedAndPrettyPrinted() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let folder = tmp.syncFolder()
        try folder.write([textBlock("hi", id: id)])
        let text = try String(contentsOf: folder.ownFileURL, encoding: .utf8)

        #expect(text.hasPrefix("{\n  \""))
        #expect(isInOrder(["\"blocks\"", "\"device\"", "\"schema\""], in: text))
        let blockKeys = ["archivedAt", "deletedAt", "id", "kind", "lastUsed", "modifiedAt", "modifiedBy", "runs", "surfacedAt"]
        #expect(isInOrder(blockKeys.map { "\"\($0)\"" }, in: text))
    }

    @Test func mathBlockWritesLatex() throws {
        var source = textBlock("", id: id)
        source.content = .math(latex: "\\frac{a}{b}")
        let block = try onlyBlock(in: written([source]))

        #expect(block["kind"] as? String == "math")
        #expect(block["latex"] as? String == "\\frac{a}{b}")
        #expect(block["runs"] == nil)
    }

    @MainActor
    @Test func storeSaveWritesTheSameFormat() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let folder = tmp.syncFolder()
        let store = BlockStore(folder: folder, legacyFileURL: nil)
        var source = textBlock("saved by the store", id: id)
        source.content = .text([TextRun(text: "saved by the store"), TextRun(text: "!", isBold: true)])
        store.insert(source)
        store.saveIfNeeded()
        let saved = try #require(store.block(id))

        let file = try readJSON(folder.ownFileURL)
        #expect((file["schema"] as? NSNumber)?.intValue == 2)
        #expect(file["device"] as? String == "mac")
        let block = try onlyBlock(in: file)
        #expect(block["id"] as? String == id.uuidString.lowercased())
        #expect(block["archivedAt"] is NSNull)
        #expect(block["deletedAt"] is NSNull)
        let runs = try #require(block["runs"] as? [[String: Any]])
        #expect(runs.map { Set($0.keys) } == [["t"], ["t", "b"]])
        #expect(integerMillis(block["modifiedAt"]) == saved.modifiedAt)
        #expect(integerMillis(block["surfacedAt"]) == saved.surfacedAt)
        #expect(integerMillis(block["lastUsed"]) == saved.lastUsed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["blocks-mac.json"])
    }
}

/// Writes `blocks` as device "mac" into a throwaway folder and reads the file back.
fileprivate func written(_ blocks: [Block]) throws -> [String: Any] {
    let tmp = try TempFolder()
    defer { tmp.remove() }
    let folder = tmp.syncFolder()
    try folder.write(blocks)
    return try readJSON(folder.ownFileURL)
}

fileprivate func readJSON(_ url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

fileprivate func onlyBlock(in file: [String: Any]) throws -> [String: Any] {
    let blocks = try #require(file["blocks"] as? [[String: Any]])
    try #require(blocks.count == 1)
    return blocks[0]
}

/// The value as Millis, or nil unless JSON held it as an integer (not a float like `1.0e12`).
fileprivate func integerMillis(_ value: Any?) -> Millis? {
    guard let number = value as? NSNumber, !CFNumberIsFloatType(number),
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number.int64Value
}

/// Whether each string first appears after the one before it.
fileprivate func isInOrder(_ strings: [String], in text: String) -> Bool {
    let positions = strings.map { text.range(of: $0)?.lowerBound }
    guard !positions.contains(nil) else { return false }
    return zip(positions, positions.dropFirst()).allSatisfy { $0! < $1! }
}
