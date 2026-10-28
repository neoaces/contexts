import Foundation
import Testing
@testable import Contexts

@Suite struct MergeTests {
    /// Has letters, so its lowercase and uppercase spellings differ.
    let id = UUID(uuidString: "C3A1E5F2-7B4D-4E9A-8F6C-1D2B3A4C5E6F")!

    // MARK: Newest wins
    // The newer version comes from "mac", which loses a tie to "ubuntu", so only modifiedAt can pick it.

    @Test func concurrentEditKeepsTheHigherModifiedAt() {
        let older = textBlock("older", id: id, modifiedAt: 1_000, modifiedBy: "ubuntu")
        let newer = textBlock("newer", id: id, modifiedAt: 2_000, modifiedBy: "mac")

        #expect(BlockStore.merge([older], with: [newer]) == [newer])
        #expect(BlockStore.merge([newer], with: [older]) == [newer])
    }

    @Test func newerTombstoneBeatsOlderEdit() {
        let edit = textBlock("edit", id: id, modifiedAt: 1_000, modifiedBy: "ubuntu")
        let tombstone = textBlock("edit", id: id, modifiedAt: 2_000, modifiedBy: "mac", deletedAt: 2_000)

        #expect(BlockStore.merge([edit], with: [tombstone]) == [tombstone])
        #expect(BlockStore.merge([tombstone], with: [edit]) == [tombstone])
    }

    @Test func newerEditBeatsOlderTombstone() {
        let tombstone = textBlock("text", id: id, modifiedAt: 1_000, modifiedBy: "ubuntu", deletedAt: 1_000)
        let edit = textBlock("restored", id: id, modifiedAt: 2_000, modifiedBy: "mac")

        #expect(BlockStore.merge([tombstone], with: [edit]) == [edit])
        #expect(BlockStore.merge([edit], with: [tombstone]) == [edit])
    }

    @Test func tieGoesToTheGreaterModifiedByWhateverTheArgumentOrder() {
        let mac = textBlock("from mac", id: id, modifiedAt: 1_000, modifiedBy: "mac")
        let ubuntu = textBlock("from ubuntu", id: id, modifiedAt: 1_000, modifiedBy: "ubuntu")

        #expect(BlockStore.merge([mac], with: [ubuntu]) == [ubuntu])
        #expect(BlockStore.merge([ubuntu], with: [mac]) == [ubuntu])
    }

    // MARK: Ids

    @Test func idsDifferingOnlyInCaseMergeIntoOneBlock() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let raw = id.uuidString.lowercased()
        try writeBlockFile(device: "mac", in: tmp, blocks: [
            textJSON(id: raw.uppercased(), text: "newer", modifiedAt: 2_000, modifiedBy: "mac"),
        ])
        try writeBlockFile(device: "ubuntu", in: tmp, blocks: [
            textJSON(id: raw, text: "older", modifiedAt: 1_000, modifiedBy: "ubuntu"),
        ])
        let folder = tmp.syncFolder(device: "mac")
        let own = try #require(try folder.readOwn())
        let others = folder.readOthers()
        #expect(own.map(\.id) == [id])
        #expect(others.map(\.id) == [id])

        let merged = BlockStore.merge(own, with: own + others)

        let block = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(block.id == id)
        #expect(block.content == .text([TextRun(text: "newer")]))
    }

    // MARK: Editing

    @Test func protectedBlockIgnoresANewerRemoteVersion() {
        let otherID = UUID()
        let editing = textBlock("being edited", id: id, modifiedAt: 1_000, modifiedBy: "mac")
        let other = textBlock("other", id: otherID, modifiedAt: 1_000, modifiedBy: "mac")
        let remoteEditing = textBlock("remote edit", id: id, modifiedAt: 2_000, modifiedBy: "ubuntu")
        let remoteOther = textBlock("other, newer", id: otherID, modifiedAt: 2_000, modifiedBy: "ubuntu")

        let merged = BlockStore.merge([editing, other], with: [remoteEditing, remoteOther], protecting: id)

        #expect(merged.first { $0.id == id } == editing)
        #expect(merged.first { $0.id == otherID } == remoteOther)
    }

    // MARK: Unknown kinds

    @Test func unknownKindDecodesAsUnknown() throws {
        let block = try decodeBlock(imageJSON(modifiedAt: 1_000))

        guard case .unknown = block.content else {
            Issue.record("Expected .unknown, got \(block.content)")
            return
        }
        #expect(block.id == id)
        #expect(block.modifiedAt == 1_000)
        #expect(block.modifiedBy == "ubuntu")
    }

    @Test func unknownKindMergesByItsStamp() throws {
        let older = try decodeBlock(imageJSON(modifiedAt: 1_000, caption: "older"))
        let newer = try decodeBlock(imageJSON(modifiedAt: 2_000, caption: "newer"))

        #expect(BlockStore.merge([older], with: [newer]) == [newer])
        #expect(BlockStore.merge([newer], with: [older]) == [newer])
    }

    @Test func unknownKindReencodesFieldForField() throws {
        let original = imageJSON(modifiedAt: 1_000)
        let block = try decodeBlock(original)

        let reencoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String: Any]
        )

        #expect(NSDictionary(dictionary: original).isEqual(reencoded))
        // NSNumber equality treats false == 0, so check booleans stayed booleans.
        #expect(isJSONBool(reencoded["pinned"]))
        #expect(isJSONBool((reencoded["tags"] as? [Any])?[3]))
    }

    @Test func unknownKindSurvivesSyncFolderWriteFieldForField() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let original = imageJSON(modifiedAt: 1_000)
        let folder = tmp.syncFolder(device: "mac")

        try folder.write([try decodeBlock(original)])

        let file = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.ownFileURL)) as? [String: Any]
        )
        let blocks = try #require(file["blocks"] as? [Any])
        #expect(blocks.count == 1)
        #expect(NSDictionary(dictionary: original).isEqual(blocks.first))
    }

    @MainActor @Test func unknownKindIsKeptButNeverShown() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let text = textBlock("shown", modifiedAt: 1_000)
        let archivedID = UUID(uuidString: "D4B2F6A3-8C5E-4FAB-9A7D-2E3C4B5D6F7A")!
        var archived = imageJSON(modifiedAt: 1_000, id: archivedID)
        archived["archivedAt"] = 600
        let shown = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(text)) as? [String: Any])
        try writeBlockFile(device: "mac", in: tmp, blocks: [imageJSON(modifiedAt: 1_000), archived, shown])

        let store = BlockStore(folder: tmp.syncFolder(), legacyFileURL: nil)

        #expect(store.recent.map(\.id) == [text.id])
        #expect(store.history.isEmpty)
        #expect(store.block(id) != nil)
        #expect(store.block(archivedID) != nil)
    }

    /// An `"image"` block carrying every kind of JSON value this build has never seen.
    private func imageJSON(modifiedAt: Millis, caption: String = "a cat", id: UUID? = nil) -> [String: Any] {
        [
            "id": (id ?? self.id).uuidString.lowercased(),
            "kind": "image",
            "file": "images/cat.png",
            "caption": caption,
            "size": ["width": 640, "height": 480],
            "tags": ["pets", 3, 1.5, true, NSNull()],
            "scale": 0.75,
            "pinned": false,
            "source": NSNull(),
            "surfacedAt": 500,
            "lastUsed": 500,
            "archivedAt": NSNull(),
            "deletedAt": NSNull(),
            "modifiedAt": modifiedAt,
            "modifiedBy": "ubuntu",
        ]
    }
}

fileprivate func decodeBlock(_ json: [String: Any]) throws -> Block {
    try JSONDecoder().decode(Block.self, from: JSONSerialization.data(withJSONObject: json))
}

fileprivate func isJSONBool(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

fileprivate func textJSON(id: String, text: String, modifiedAt: Millis, modifiedBy: String) -> [String: Any] {
    [
        "id": id,
        "kind": "text",
        "runs": [["t": text]],
        "surfacedAt": 500,
        "lastUsed": 500,
        "archivedAt": NSNull(),
        "deletedAt": NSNull(),
        "modifiedAt": modifiedAt,
        "modifiedBy": modifiedBy,
    ]
}

/// Writes `blocks-<device>.json` the way another device would, bypassing `SyncFolder.write`.
fileprivate func writeBlockFile(device: String, in folder: TempFolder, blocks: [[String: Any]]) throws {
    let file: [String: Any] = ["schema": 2, "device": device, "blocks": blocks]
    try JSONSerialization.data(withJSONObject: file)
        .write(to: folder.url.appending(path: "blocks-\(device).json"))
}
