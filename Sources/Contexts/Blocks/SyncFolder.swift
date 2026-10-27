import Foundation
import os

/// The folder shared between devices (e.g. via Syncthing). Every device writes
/// only its own `blocks-<device>.json` and reads everyone's, so no file ever has
/// two writers and the sync tool never has to resolve a conflict.
struct SyncFolder {
    static let schema = 2
    private static let log = Logger(subsystem: "Contexts", category: "SyncFolder")

    let url: URL
    let device: String

    /// `~/Contexts` as device "mac", unless overridden with
    /// `defaults write local.contexts syncFolder <path>` / `deviceName <name>`.
    static var standard: SyncFolder {
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: "syncFolder") ?? "~/Contexts"
        return SyncFolder(
            url: URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory),
            device: defaults.string(forKey: "deviceName") ?? "mac"
        )
    }

    var ownFileURL: URL { url.appending(path: "blocks-\(device).json") }

    /// nil when this device has no file yet; throws when it exists but can't be read.
    func readOwn() throws -> [Block]? {
        guard FileManager.default.fileExists(atPath: ownFileURL.path) else { return nil }
        return try Self.decode(Data(contentsOf: ownFileURL))
    }

    /// Other devices' blocks. An unreadable file is skipped (and left alone): it
    /// is someone else's, possibly mid-sync.
    func readOthers() -> [Block] {
        otherFileURLs().flatMap { file -> [Block] in
            do {
                return try Self.decode(Data(contentsOf: file))
            } catch {
                Self.log.error("Skipping \(file.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                return []
            }
        }
    }

    /// Size and modification date of every device file (this one's included),
    /// to tell real changes apart from this device's own writes.
    func signature() -> [String: String] {
        Dictionary(uniqueKeysWithValues: (otherFileURLs() + [ownFileURL]).map { file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return (file.lastPathComponent, "\(stamp)-\(values?.fileSize ?? 0)")
        })
    }

    /// Writes a predictable temp file, then renames it over the real one, so
    /// readers (and Syncthing) only ever see a complete file.
    func write(_ blocks: [Block]) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(BlockFile(schema: Self.schema, device: device, blocks: blocks))
        let temp = url.appending(path: ".blocks-\(device).json.tmp")
        try data.write(to: temp)
        // Flush to disk before the rename, so a crash can't leave an empty file in place.
        let handle = try FileHandle(forWritingTo: temp)
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 { try handle.synchronize() }
        try handle.close()
        guard rename(temp.path, ownFileURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: ownFileURL.path])
        }
    }

    private func otherFileURLs() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names
            .filter { $0.hasPrefix("blocks-") && $0.hasSuffix(".json") && !$0.contains(".sync-conflict-") }
            .filter { $0 != ownFileURL.lastPathComponent }
            .map { url.appending(path: $0) }
    }

    private static func decode(_ data: Data) throws -> [Block] {
        try JSONDecoder().decode(BlockFile.self, from: data).blocks
    }
}

private struct BlockFile: Codable {
    var schema: Int
    var device: String
    var blocks: [Block]

    init(schema: Int, device: String, blocks: [Block]) {
        self.schema = schema
        self.device = device
        self.blocks = blocks
    }

    /// One malformed block doesn't take the whole file down with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        device = try container.decode(String.self, forKey: .device)
        blocks = try container.decode([Lossy].self, forKey: .blocks).compactMap(\.block)
    }

    private struct Lossy: Decodable {
        let block: Block?
        init(from decoder: Decoder) throws { block = try? Block(from: decoder) }
    }
}

/// Calls back (debounced, on the main queue) when anything in the folder changes,
/// and right away when the folder itself is deleted or moved, since it then
/// needs watching anew. Watches the directory rather than files: sync tools
/// replace files by renaming.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(url: URL, onChange: @escaping @MainActor () -> Void, onGone: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                pending?.cancel()
                MainActor.assumeIsolated { onGone() }
                return
            }
            pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
