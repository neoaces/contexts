import Foundation
@testable import Contexts

/// A fresh, empty folder under the system temp directory, removed by `remove()`.
struct TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "ContextsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func syncFolder(device: String = "mac") -> SyncFolder {
        SyncFolder(url: url, device: device)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The repo root, found from this file rather than from bundle resources.
let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // ContextsTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()

/// A text block with fixed stamps, so tests control every field the merge reads.
func textBlock(
    _ text: String,
    id: UUID = UUID(),
    modifiedAt: Millis = 1_000,
    modifiedBy: String = "mac",
    deletedAt: Millis? = nil
) -> Block {
    var block = Block(content: .text([TextRun(text: text)]), device: modifiedBy, at: modifiedAt)
    block.id = id
    block.deletedAt = deletedAt
    return block
}
