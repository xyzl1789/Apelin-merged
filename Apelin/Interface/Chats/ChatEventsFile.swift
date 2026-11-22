import ApelinCore
import ApelinProtocol
import Foundation

/// A conversation's events on disk, beside its record: `Chats/<id>.events.jsonl`,
/// one event per line, appended as they come. The record itself,
/// `Chats/<id>.json`, keeps the conversation's summary, draft and pending
/// sends and says how many events there are, so launching reads a few hundred
/// bytes per chat instead of the megabytes its history can be
/// (`Documents/Plan/Memory.md`).
///
/// A record written before the split still carries its events inline; `load`
/// moves them out once, and a record that cannot be moved keeps working as it
/// was.
///
/// The `seq` of the lines is not a cursor: a reopened session's task replays
/// the history under its own numbering, so a conversation's file holds one
/// ascending run of `seq` per task, each starting below the last. Only the
/// order of the lines is the history.
enum ChatEventsFile {
    static func url(for id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(id.uuidString + ".events.jsonl")
    }

    /// Every event the file holds. A line that does not decode — a write cut
    /// short, or a line an earlier version appended twice — is dropped rather
    /// than thrown: one damaged line in the middle of a conversation's file
    /// used to make the whole conversation unopenable, which is far worse than
    /// losing the one line. The count that comes back is what the file really
    /// holds, and `ChatStore` writes it into the head.
    static func read(_ id: UUID, in folder: URL) throws -> [TaskEvent] {
        let url = url(for: id, in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONCoding.decoder()
        var events: [TaskEvent] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let event = try? decoder.decode(TaskEvent.self, from: Data(line)) else { continue }
            events.append(event)
        }
        return events
    }

    /// The events of one kind a saved conversation holds, read for a scan that
    /// must not keep the history: restoring the lineage between chats needs the
    /// events that opened another, and nothing else (`ChatRuntime.scanLineage`).
    /// Only a line that mentions the kind is decoded, so a history costs a
    /// pass over its bytes rather than an event in memory each. A line that
    /// does not decode is dropped, as `read` drops it: a scan that threw would
    /// take the whole launch with it over one damaged line.
    static func scan(_ kind: String, for id: UUID, in folder: URL) throws -> [TaskEvent] {
        let url = url(for: id, in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let needle = Data(kind.utf8)
        let decoder = JSONCoding.decoder()
        var events: [TaskEvent] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.range(of: needle) != nil else { continue }
            guard let event = try? decoder.decode(TaskEvent.self, from: Data(line)) else { continue }
            if event.kind == kind { events.append(event) }
        }
        return events
    }

    /// Replaces the file with `events`, atomically: a compaction, a rewind or an
    /// edit rewrites the history, and a reader never sees it half written. No
    /// events leaves no file, rather than an empty one per conversation.
    static func write(_ events: [TaskEvent], for id: UUID, in folder: URL) throws {
        guard !events.isEmpty else {
            remove(id, in: folder)
            return
        }
        let encoder = JSONCoding.encoder()
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        let destination = url(for: id, in: folder)
        let temporary = folder.appendingPathComponent(".\(id.uuidString).events.\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600],
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Adds the events the conversation gained, one line each. The caller has
    /// already made sure they are not in the file (`holds(_:count:)`); this
    /// filters nothing, because a line's `seq` cannot say whether it is new.
    static func append(_ events: [TaskEvent], for id: UUID, in folder: URL) throws {
        guard !events.isEmpty else { return }
        let destination = url(for: id, in: folder)
        // A line the last write left half written would swallow this one.
        trimTornLine(destination)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard FileManager.default.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600],
            ) else { throw CocoaError(.fileWriteUnknown) }
        }
        let encoder = JSONCoding.encoder()
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Whether the file's last event is `events[count - 1]` — that is, whether
    /// the file holds exactly the `count` events the caller believes it does.
    ///
    /// Appending `events[count...]` is only right then. A save cut off before
    /// it wrote the head leaves the count behind the file, and appending from
    /// it wrote lines the file already held: a history grown to several copies
    /// of itself, which no longer decodes and left the conversation
    /// unopenable. `count` 0 asks whether the file holds nothing at all.
    static func holds(_ events: [TaskEvent], count: Int, for id: UUID, in folder: URL) -> Bool {
        let url = url(for: id, in: folder)
        guard count > 0 else {
            // No file at all is the empty history `count` 0 describes.
            guard FileManager.default.fileExists(atPath: url.path) else { return true }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int
            else { return false }
            return size == 0
        }
        guard count <= events.count else { return false }
        return lastLine(of: url) == (try? JSONCoding.encoder().encode(events[count - 1]))
    }

    static func remove(_ id: UUID, in folder: URL) {
        unlink(url(for: id, in: folder).path)
    }

    /// The last line the file holds, as it was written — the bytes are what
    /// this compares, since a `TaskEvent` read back and encoded again is not
    /// guaranteed to be the same value (`Date` keeps sub-second time in memory
    /// and ISO 8601 does not).
    ///
    /// Read from the tail: a conversation's file can be tens of megabytes, and
    /// a save must not read all of it to find out whether its own count is
    /// still true.
    private static func lastLine(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        // A line of a conversation's events is far shorter than this in the
        // overwhelming majority; a longer one is found by growing the window.
        let window: UInt64 = 64 * 1024
        var length = min(size, window)
        var data = Data()
        while true {
            guard (try? handle.seek(toOffset: size - length)) != nil,
                  let chunk = try? handle.read(upToCount: Int(length))
            else { return nil }
            data = chunk
            if data.lastIndex(of: 0x0A) != nil || length == size { break }
            length = min(size, length * 4)
        }
        // The trailing newline leaves an empty last line; the event is the one
        // before it, and the window may start mid-line.
        guard let line = data.split(separator: 0x0A, omittingEmptySubsequences: true).last else { return nil }
        return Data(line)
    }

    /// Cuts a last line with no newline after it, which the read drops anyway.
    private static func trimTornLine(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return }
        do { try handle.seek(toOffset: size - 1) } catch { return }
        guard let last = try? handle.read(upToCount: 1), last == Data([0x0A]) else {
            // Find the last newline and cut the file there.
            guard let whole = try? Data(contentsOf: url) else { return }
            if let index = whole.lastIndex(of: 0x0A) {
                truncate(url.path, off_t(index + 1))
            } else {
                truncate(url.path, 0)
            }
            return
        }
    }
}
