import Foundation
import Testing
@testable import Contexts

/// What `BlockStore.saveIfNeeded` writes: the merge of what is on disk with this
/// device's changes, tombstones pruned, so a save never overwrites a change it hadn't seen.
@MainActor
@Suite struct SavingTests {
    let edited = textBlock("edited here", id: UUID(uuidString: "1A2B3C4D-5E6F-4A8B-9C0D-E1F2A3B4C5D6")!)
    let other = textBlock("changed elsewhere", id: UUID(uuidString: "6D5C4B3A-2F1E-4D9C-8B7A-F6E5D4C3B2A1")!)

    @Test func saveFoldsInAnotherDevicesNewerVersionFirst() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        try tmp.syncFolder().write([edited, other])
        let store = BlockStore(folder: tmp.syncFolder(), legacyFileURL: nil)
        let newer = textBlock("newer on ubuntu", id: other.id, modifiedAt: 2_000, modifiedBy: "ubuntu")
        try tmp.syncFolder(device: "ubuntu").write([newer])

        store.update(edited.id, content: .text([TextRun(text: "typed")]))
        store.saveIfNeeded()

        let saved = try #require(try tmp.syncFolder().readOwn())
        #expect(saved.first { $0.id == other.id } == newer)
    }

    /// The own file can be replaced from outside, e.g. copied over from another machine.
    @Test func saveFoldsInItsOwnFileReplacedOnDisk() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        try tmp.syncFolder().write([edited, other])
        let store = BlockStore(folder: tmp.syncFolder(), legacyFileURL: nil)
        let newer = textBlock("newer in the copy", id: other.id, modifiedAt: 2_000, modifiedBy: "mac")
        try tmp.syncFolder().write([edited, newer])

        store.update(edited.id, content: .text([TextRun(text: "typed")]))
        store.saveIfNeeded()

        let saved = try #require(try tmp.syncFolder().readOwn())
        #expect(saved.first { $0.id == other.id } == newer)
    }

    @Test func saveDropsTombstonesPastTheirLifetime() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let ancientTombstone = textBlock("gone", id: other.id, modifiedAt: 1_000, deletedAt: 1_000)
        try tmp.syncFolder().write([edited, ancientTombstone])
        let store = BlockStore(folder: tmp.syncFolder(), legacyFileURL: nil)

        store.update(edited.id, content: .text([TextRun(text: "typed")]))
        store.saveIfNeeded()

        let saved = try #require(try tmp.syncFolder().readOwn())
        #expect(saved.map(\.id) == [edited.id])
        #expect(store.block(other.id) == nil)
    }
}
