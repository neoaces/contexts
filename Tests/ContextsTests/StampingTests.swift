import Foundation
import Testing
@testable import Contexts

/// How a `BlockStore` stamps its own changes: user edits win merges, automatic ones don't.
@MainActor
@Suite struct StampingTests {
    @Test func updateStampsNowAndThisDevice() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let seeded = textBlock("old", modifiedAt: 1_000, modifiedBy: "ubuntu")
        let store = try storeSeeded(with: [seeded], in: tmp)

        let before = Millis.now
        store.update(seeded.id, content: .text([TextRun(text: "new")]))
        let after = Millis.now

        let updated = try #require(store.block(seeded.id))
        #expect(updated.modifiedAt >= before)
        #expect(updated.modifiedAt <= after)
        #expect(updated.modifiedAt > seeded.modifiedAt)
        #expect(updated.modifiedBy == "mac")
    }

    /// So a block being edited isn't auto-archived.
    @Test func updateMarksTheBlockUsed() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let seeded = textBlock("old", modifiedAt: 1_000, modifiedBy: "ubuntu")
        let store = try storeSeeded(with: [seeded], in: tmp)

        let before = Millis.now
        store.update(seeded.id, content: .text([TextRun(text: "new")]))
        let after = Millis.now

        let updated = try #require(store.block(seeded.id))
        #expect(updated.lastUsed >= before)
        #expect(updated.lastUsed <= after)
    }

    @Test func updateStampsPreviousPlusOneWhenPreviousIsInTheFuture() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let future: Millis = 4_000_000_000_000  // year 2096
        let seeded = textBlock("from a fast clock", modifiedAt: future, modifiedBy: "ubuntu")
        try tmp.syncFolder(device: "ubuntu").write([seeded])
        let store = BlockStore(folder: tmp.syncFolder(), legacyFileURL: nil)

        store.update(seeded.id, content: .text([TextRun(text: "edited on the mac")]))

        let updated = try #require(store.block(seeded.id))
        #expect(updated.modifiedAt == future + 1)
        #expect(updated.modifiedBy == "mac")
    }

    @Test func archiveStampsPreviousPlusOneNotNow() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let seeded = unusedBlock(modifiedAt: 5_000)
        let store = try storeSeeded(with: [seeded], in: tmp)

        store.archiveBlocks(unusedSince: 2_000)

        let archived = try #require(store.block(seeded.id))
        #expect(archived.modifiedAt == 5_001)
    }

    @Test func archiveSetsArchivedAtToNowAndModifiedByToThisDevice() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let seeded = unusedBlock(modifiedAt: 5_000)
        let store = try storeSeeded(with: [seeded], in: tmp)

        let before = Millis.now
        store.archiveBlocks(unusedSince: 2_000)
        let after = Millis.now

        let archived = try #require(store.block(seeded.id))
        let archivedAt = try #require(archived.archivedAt)
        #expect(archivedAt >= before)
        #expect(archivedAt <= after)
        #expect(archived.modifiedBy == "mac")
    }

    @Test func markUsedChangesLastUsedOnly() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        var seeded = textBlock("opened", modifiedAt: 5_000, modifiedBy: "ubuntu")
        seeded.surfacedAt = 1_000
        seeded.lastUsed = 2_000
        seeded.archivedAt = 3_000
        let store = try storeSeeded(with: [seeded], in: tmp)

        let before = Millis.now
        store.markUsed(seeded.id)
        let after = Millis.now

        let used = try #require(store.block(seeded.id))
        #expect(used.lastUsed >= before)
        #expect(used.lastUsed <= after)
        var expected = seeded
        expected.lastUsed = used.lastUsed
        #expect(used == expected)
    }
}

/// A store whose own file already holds `blocks`, so every stamp starts from a known value.
@MainActor
fileprivate func storeSeeded(with blocks: [Block], in tmp: TempFolder) throws -> BlockStore {
    try tmp.syncFolder().write(blocks)
    return BlockStore(folder: tmp.syncFolder(), legacyFileURL: nil)
}

/// A block last used and changed long ago (by another device), due for auto-archive.
fileprivate func unusedBlock(modifiedAt: Millis) -> Block {
    var block = textBlock("stale", modifiedAt: modifiedAt, modifiedBy: "ubuntu")
    block.lastUsed = 1_000
    return block
}
