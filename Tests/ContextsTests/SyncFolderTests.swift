import Foundation
import Testing
@testable import Contexts

/// How `SyncFolder` writes this device's file and reads everyone's.
@Suite struct SyncFolderTests {
    /// A rename gives the file a new inode; writing in place would keep it, and a
    /// reader or Syncthing could see a half-written file.
    @Test func writeReplacesTheFileByRenameRatherThanInPlace() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let folder = tmp.syncFolder()

        try folder.write([textBlock("first")])
        let first = try inode(of: folder.ownFileURL)
        try folder.write([textBlock("second")])

        #expect(try inode(of: folder.ownFileURL) != first)
    }

    @Test func readOthersSkipsSyncConflictFiles() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let ubuntu = textBlock("ubuntu", modifiedBy: "ubuntu")
        try tmp.syncFolder(device: "ubuntu").write([ubuntu])
        try FileManager.default.copyItem(
            at: tmp.url.appending(path: "blocks-ubuntu.json"),
            to: tmp.url.appending(path: "blocks-ubuntu.sync-conflict-20261028-120000-ABCDEFG.json")
        )

        #expect(tmp.syncFolder().readOthers() == [ubuntu])
    }

    @Test func aMalformedBlockIsSkippedNotTheWholeFile() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let valid = textBlock("valid")
        var malformed = try jsonObject(textBlock("no modifiedAt"))
        malformed["modifiedAt"] = nil
        let file: [String: Any] = ["schema": 2, "device": "mac", "blocks": [malformed, try jsonObject(valid)]]
        let folder = tmp.syncFolder()
        try JSONSerialization.data(withJSONObject: file).write(to: folder.ownFileURL)

        #expect(try folder.readOwn() == [valid])
    }
}

fileprivate func inode(of url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
}

fileprivate func jsonObject(_ block: Block) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String: Any])
}
