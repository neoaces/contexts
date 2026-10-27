import Foundation
import Observation
import os

/// All blocks, live and archived, persisted as JSON in Application Support.
/// Array order is recency: live blocks are inserted and restored at the front.
@MainActor @Observable
final class BlockStore {
    private(set) var blocks: [Block]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    private static let log = Logger(subsystem: "Contexts", category: "BlockStore")

    init(fileURL: URL = BlockStore.defaultFileURL) {
        self.fileURL = fileURL
        blocks = Self.load(from: fileURL).filter { !$0.isBlank }
        // Writes back defaults filled in for older files (e.g. `lastUsed`) on the next save.
        hasUnsavedChanges = !blocks.isEmpty
    }

    var recent: [Block] { blocks.filter { !$0.isArchived } }

    var history: [Block] {
        blocks.filter(\.isArchived).sorted { $0.archivedAt! > $1.archivedAt! }
    }

    func block(_ id: Block.ID) -> Block? {
        blocks.first { $0.id == id }
    }

    func insert(_ block: Block, at index: Int = 0) {
        blocks.insert(block, at: min(index, blocks.count))
        hasUnsavedChanges = true
    }

    @discardableResult
    func remove(_ id: Block.ID) -> (block: Block, index: Int)? {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        let block = blocks.remove(at: index)
        hasUnsavedChanges = true
        saveIfNeeded()
        return (block, index)
    }

    /// Cheap enough to call per keystroke: writes to disk only once typing pauses.
    func update(_ id: Block.ID, content: Block.Content) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].content = content
        blocks[index].lastUsed = .now
        hasUnsavedChanges = true
        scheduleSave()
    }

    func markUsed(_ id: Block.ID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].lastUsed = .now
        hasUnsavedChanges = true
    }

    func archiveBlocks(unusedSince cutoff: Date) {
        let now = Date.now
        for index in blocks.indices where !blocks[index].isArchived && blocks[index].lastUsed < cutoff {
            blocks[index].archivedAt = now
            hasUnsavedChanges = true
        }
        saveIfNeeded()
    }

    func saveIfNeeded() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasUnsavedChanges else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(blocks).write(to: fileURL, options: .atomic)
            hasUnsavedChanges = false
        } catch {
            Self.log.error("Saving blocks failed: \(error, privacy: .public)")
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveIfNeeded()
        }
    }

    /// An unreadable file is set aside rather than silently overwritten by the next save.
    private static func load(from url: URL) -> [Block] {
        do {
            return try JSONDecoder().decode([Block].self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            log.error("Loading blocks failed: \(error, privacy: .public)")
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    nonisolated static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Contexts/blocks.json")
    }
}
