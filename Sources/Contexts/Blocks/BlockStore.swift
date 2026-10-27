import Foundation
import Observation
import os

/// Every block this device knows, merged from all devices' files in the sync
/// folder. Each change is stamped (`modifiedAt`, `modifiedBy`) so that, per
/// block, the newest change wins everywhere.
@MainActor @Observable
final class BlockStore {
    /// Includes deleted blocks (tombstones) and kinds this build can't show.
    private(set) var blocks: [Block]

    /// While a block is edited here, remote versions of it are ignored. When
    /// editing ends, everything is merged again by the usual newest-wins rule.
    @ObservationIgnored var editingBlockID: Block.ID? {
        didSet {
            guard let oldValue, oldValue != editingBlockID else { return }
            folderSignature = [:]
            mergeFolder()
        }
    }
    @ObservationIgnored let device: String
    @ObservationIgnored private let folder: SyncFolder
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var folderSignature: [String: String] = [:]
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    private static let log = Logger(subsystem: "Contexts", category: "BlockStore")
    nonisolated private static let tombstoneLifetime: Millis = 90 * 24 * 60 * 60 * 1000

    init(folder: SyncFolder = .standard, legacyFileURL: URL? = BlockStore.legacyFileURL) {
        self.folder = folder
        device = folder.device
        blocks = []
        blocks = loadOwnBlocks(migratingFrom: legacyFileURL)
        mergeFolder()
        startWatching()
    }

    var recent: [Block] {
        blocks.filter { $0.isShown && !$0.isArchived }.sorted { $0.surfacedAt > $1.surfacedAt }
    }

    var history: [Block] {
        blocks.filter { $0.isShown && $0.isArchived }.sorted { $0.archivedAt! > $1.archivedAt! }
    }

    func block(_ id: Block.ID) -> Block? {
        blocks.first { $0.id == id }
    }

    func insert(_ block: Block) {
        blocks.append(stamped(block))
        changed()
    }

    /// Replaces the stored block with the same id (state changes, tombstones, undo).
    func put(_ block: Block) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[index] = stamped(block)
        changed()
    }

    /// Cheap enough to call per keystroke: writes to disk only once typing pauses.
    func update(_ id: Block.ID, content: Block.Content) {
        guard var block = block(id) else { return }
        block.content = content
        block.lastUsed = .now
        put(block)
    }

    /// Not stamped: opening a block isn't a change worth winning a merge with.
    func markUsed(_ id: Block.ID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].lastUsed = .now
        changed()
    }

    /// Stamped by the minimum, so any real edit made elsewhere (that may not
    /// have arrived yet) still beats an automatic archive.
    func archiveBlocks(unusedSince cutoff: Millis) {
        let now = Millis.now
        for block in blocks where block.isShown && !block.isArchived && block.lastUsed < cutoff {
            var archived = block
            archived.archivedAt = now
            archived.modifiedAt = block.modifiedAt + 1
            archived.modifiedBy = device
            replace(archived)
        }
        saveIfNeeded()
    }

    /// Folds in whatever is on disk first (a file copied in, a peer's latest),
    /// so a save never overwrites a change it hadn't seen.
    func saveIfNeeded() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasUnsavedChanges else { return }
        let others = folder.readOthers()
        let onDisk = ((try? folder.readOwn()) ?? nil ?? []) + others
        let settled = Self.pruned(Self.merge(blocks, with: onDisk, protecting: editingBlockID), keepingLiveIn: others)
        if settled != Self.ordered(blocks) { blocks = settled }
        do {
            try folder.write(blocks)
            hasUnsavedChanges = false
            folderSignature = folder.signature()
        } catch {
            Self.log.error("Saving blocks failed: \(error, privacy: .public)")
        }
    }

    // MARK: Merging

    /// Per block, the newer change wins. Pure, so it can be tested on its own.
    nonisolated static func merge(_ local: [Block], with remote: [Block], protecting protectedID: Block.ID? = nil) -> [Block] {
        var merged = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { $1.supersedes($0) ? $1 : $0 })
        for block in remote where block.id != protectedID {
            if let current = merged[block.id], !block.supersedes(current) { continue }
            merged[block.id] = block
        }
        return ordered(Array(merged.values))
    }

    /// A tombstone past its lifetime is dropped only once no other device still
    /// holds the block live; otherwise that copy would bring it back.
    nonisolated static func pruned(_ blocks: [Block], keepingLiveIn others: [Block], now: Millis = .now) -> [Block] {
        let cutoff = now - tombstoneLifetime
        guard blocks.contains(where: { ($0.deletedAt ?? .max) < cutoff }) else { return blocks }
        let liveElsewhere = Set(others.filter { !$0.isDeleted }.map(\.id))
        return blocks.filter { ($0.deletedAt ?? .max) >= cutoff || liveElsewhere.contains($0.id) }
    }

    nonisolated private static func ordered(_ blocks: [Block]) -> [Block] {
        blocks.sorted { ($0.surfacedAt, $0.id.uuidString) > ($1.surfacedAt, $1.id.uuidString) }
    }

    /// Pulls in every file's changes (other devices', and this device's own if
    /// it was replaced on disk), then writes the merged view so all files converge.
    private func mergeFolder() {
        let signature = folder.signature()
        guard signature != folderSignature else { return }
        folderSignature = signature
        let onDisk = ((try? folder.readOwn()) ?? nil ?? []) + folder.readOthers()
        let merged = Self.merge(blocks, with: onDisk, protecting: editingBlockID)
        guard merged != Self.ordered(blocks) else { return }
        blocks = merged
        changed()
    }

    /// The folder can be replaced (copied over, deleted and re-created, re-shared);
    /// the watcher then follows the new one and the store re-syncs with it.
    private func startWatching() {
        try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        watcher = FolderWatcher(
            url: folder.url,
            onChange: { [weak self] in self?.mergeFolder() },
            onGone: { [weak self] in
                guard let self else { return }
                watcher = nil
                folderSignature = [:]
                startWatching()
                mergeFolder()
                hasUnsavedChanges = true
                saveIfNeeded()
            }
        )
    }

    // MARK: Private

    private func replace(_ block: Block) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[index] = block
        changed()
    }

    /// `modifiedAt` always moves forward, even if this clock is behind the last writer's.
    private func stamped(_ block: Block) -> Block {
        var block = block
        let previous = self.block(block.id)?.modifiedAt ?? 0
        block.modifiedAt = max(.now, previous + 1)
        block.modifiedBy = device
        return block
    }

    private func changed() {
        hasUnsavedChanges = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveIfNeeded()
        }
    }

    /// An unreadable own file is set aside rather than silently overwritten.
    /// With no own file yet, version 1's store is migrated once.
    private func loadOwnBlocks(migratingFrom legacyURL: URL?) -> [Block] {
        do {
            if let own = try folder.readOwn() { return own }
        } catch {
            Self.log.error("Loading blocks failed: \(error, privacy: .public)")
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = folder.ownFileURL.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: folder.ownFileURL, to: backup)
            return []
        }
        guard let legacyURL, let migrated = LegacyStore.migrate(legacyURL, device: device) else { return [] }
        hasUnsavedChanges = true
        do {
            try folder.write(migrated)
            hasUnsavedChanges = false
            try? FileManager.default.moveItem(at: legacyURL, to: legacyURL.deletingLastPathComponent().appending(path: "blocks.v1-backup.json"))
        } catch {
            Self.log.error("Writing migrated blocks failed: \(error, privacy: .public)")
        }
        return migrated
    }

    nonisolated static var legacyFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Contexts/blocks.json")
    }
}

/// Version 1 kept one JSON array in Application Support, rich text as RTF,
/// newest block first.
private enum LegacyStore {
    struct LegacyBlock: Decodable {
        enum Content: Decodable {
            case richText(rtf: Data)
            case math(latex: String)
        }

        var id: UUID
        var content: Content
        var lastUsed: Date?
        var archivedAt: Date?
    }

    static func migrate(_ url: URL, device: String) -> [Block]? {
        guard let data = try? Data(contentsOf: url),
              let legacy = try? JSONDecoder().decode([LegacyBlock].self, from: data) else { return nil }
        let now = Millis.now
        return legacy.enumerated().map { index, old in
            let content: Block.Content = switch old.content {
            case .richText(let rtf): .text(RichText.runs(fromLegacyRTF: rtf))
            case .math(let latex): .math(latex: latex)
            }
            var block = Block(content: content, device: device, at: now)
            block.id = old.id
            block.surfacedAt = now - Millis(index)  // keeps the old newest-first order
            block.lastUsed = old.lastUsed.map(Millis.init(date:)) ?? now
            block.archivedAt = old.archivedAt.map(Millis.init(date:))
            return block
        }.filter { !$0.isBlank }
    }
}
