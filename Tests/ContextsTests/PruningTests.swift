import Foundation
import Testing
@testable import Contexts

@Suite struct PruningTests {
    let lifetime: Millis = 90 * 24 * 60 * 60 * 1000
    let now: Millis = 1_800_000_000_000
    let id = UUID()

    private func tombstone(deletedAt: Millis) -> Block {
        textBlock("gone", id: id, modifiedAt: deletedAt, deletedAt: deletedAt)
    }

    @Test func tombstoneOlderThan90DaysIsDropped() {
        let old = tombstone(deletedAt: now - lifetime - 1)

        #expect(BlockStore.pruned([old], keepingLiveIn: [], now: now).isEmpty)
    }

    @Test func oldTombstoneIsKeptWhileAnotherDeviceHoldsTheBlockLive() {
        let old = tombstone(deletedAt: now - lifetime - 1)
        let liveElsewhere = textBlock("still here", id: id, modifiedAt: 1_000, modifiedBy: "ubuntu")

        #expect(BlockStore.pruned([old], keepingLiveIn: [liveElsewhere], now: now) == [old])
    }

    @Test func oldTombstoneIsDroppedWhenAnotherDeviceHoldsOnlyATombstone() {
        let old = tombstone(deletedAt: now - lifetime - 1)
        let deletedElsewhere = textBlock("gone", id: id, modifiedAt: 1_000, modifiedBy: "ubuntu", deletedAt: 1_000)

        #expect(BlockStore.pruned([old], keepingLiveIn: [deletedElsewhere], now: now).isEmpty)
    }

    @Test func tombstoneYoungerThan90DaysIsKept() {
        let young = tombstone(deletedAt: now - lifetime + 1)

        #expect(BlockStore.pruned([young], keepingLiveIn: [], now: now) == [young])
    }

    /// Alongside a tombstone past the cutoff, so the filter runs rather than the early return.
    @Test func tombstoneExactly90DaysOldIsKept() {
        let atCutoff = tombstone(deletedAt: now - lifetime)
        let pastCutoff = textBlock("gone", modifiedAt: now - lifetime - 1, deletedAt: now - lifetime - 1)

        #expect(BlockStore.pruned([atCutoff, pastCutoff], keepingLiveIn: [], now: now) == [atCutoff])
    }

    /// A tombstone touched since its delete (re-stamped by a merge, say) still ages from the delete.
    @Test func tombstoneAgeCountsFromDeletedAtNotModifiedAt() {
        let old = textBlock("gone", id: id, modifiedAt: now, deletedAt: now - lifetime - 1)

        #expect(BlockStore.pruned([old], keepingLiveIn: [], now: now).isEmpty)
    }

    @Test func liveBlocksAreNeverDropped() {
        let ancient = textBlock("ancient", id: id, modifiedAt: 0)
        let archived = {
            var block = textBlock("archived", modifiedAt: 0)
            block.archivedAt = 0
            return block
        }()
        let old = textBlock("gone", modifiedAt: 0, deletedAt: 0)

        let pruned = BlockStore.pruned([ancient, archived, old], keepingLiveIn: [], now: now)

        #expect(pruned == [ancient, archived])
    }
}
