import Foundation
import Testing
@testable import Contexts

/// The cases in `fixtures/sync-v2/`, which the Ubuntu app's Rust tests also run.
/// Each `<case>/` holds `blocks-mac.json`, `blocks-ubuntu.json`, `expected.json`
/// and optionally `case.json` (`{"device": "ubuntu", "now": <ms>}`).
fileprivate let fixturesURL = repoRoot.appending(path: "fixtures/sync-v2", directoryHint: .isDirectory)

fileprivate let fixtureCases: [String] = {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: fixturesURL.path)) ?? []
    return names.filter { fixturesURL.appending(path: "\($0)/expected.json").isReadableFile }.sorted()
}()

@Suite struct SharedFixtureTests {
    /// The fixtures are written on the Ubuntu side; until they're pushed this is skipped, not failed.
    @Test(
        .enabled(if: !fixtureCases.isEmpty, "No cases in fixtures/sync-v2/ (they come from the Ubuntu side)"),
        arguments: fixtureCases
    )
    func mergeMatchesExpected(_ name: String) throws {
        let caseURL = fixturesURL.appending(path: name, directoryHint: .isDirectory)
        let options = try CaseOptions(url: caseURL.appending(path: "case.json"))
        let tmp = try TempFolder()
        defer { tmp.remove() }
        for file in ["blocks-mac.json", "blocks-ubuntu.json"] {
            try FileManager.default.copyItem(at: caseURL.appending(path: file), to: tmp.url.appending(path: file))
        }

        let folder = tmp.syncFolder(device: options.device)
        let own = try folder.readOwn() ?? []
        let others = folder.readOthers()
        let merged = BlockStore.merge(own, with: own + others)
        let result = BlockStore.pruned(merged, keepingLiveIn: others, now: options.now)

        let actual = try normalizedBlocks(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)))
        let expected = try normalizedBlocks(JSONSerialization.jsonObject(with: Data(contentsOf: caseURL.appending(path: "expected.json"))))
        #expect(actual.map(\.id) == expected.map(\.id), "\(name): block ids")
        for (actual, expected) in zip(actual, expected) where actual.id == expected.id {
            #expect(actual.json == expected.json, "\(name): block \(expected.id)")
        }
    }
}

/// `case.json`, with its defaults when the file or a field is missing.
fileprivate struct CaseOptions {
    var device = "ubuntu"
    var now = Millis.now

    init(url: URL) throws {
        guard url.isReadableFile else { return }
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        if let device = object["device"] as? String { self.device = device }
        if let now = object["now"] as? NSNumber { self.now = now.int64Value }
    }
}

/// `expected.json` may be a whole block file (`{schema, device, blocks}`) or just
/// the blocks array; only the blocks are compared. Each block becomes canonical
/// JSON text (sorted keys, missing `archivedAt`/`deletedAt` as `null`), sorted by
/// lowercased id, so unknown kinds compare field for field and a mismatch reads well.
fileprivate func normalizedBlocks(_ json: Any) throws -> [(id: String, json: String)] {
    let list = try #require(((json as? [String: Any])?["blocks"] ?? json) as? [Any], "expected a block file or an array of blocks")
    return try list.map { item in
        var block = try #require(item as? [String: Any], "a block is not an object")
        let id = try #require(block["id"] as? String, "a block has no id").lowercased()
        for key in ["archivedAt", "deletedAt"] where block[key] == nil { block[key] = NSNull() }
        let data = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return (id, String(decoding: data, as: UTF8.self))
    }
    .sorted { $0.id < $1.id }
}

fileprivate extension URL {
    var isReadableFile: Bool { FileManager.default.isReadableFile(atPath: path) }
}
