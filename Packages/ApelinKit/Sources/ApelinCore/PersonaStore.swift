import Darwin
import Foundation

/// One persona the reader keeps in Settings ▸ Prompt Injection. Its `body`
/// is prepended to the system prompt, ahead of every other section, when this
/// persona is the one in force.
///
/// `matchMode` decides how it is selected: `.manual` is chosen by the
/// `activeID` on the store, `.automatic` competes with every other automatic
/// persona whose `modelPatterns` match the conversation's model. `priority`
/// breaks ties, then `name`, then `id`, so the choice is always stable.
public struct Persona: Codable, Equatable, Identifiable, Sendable {
    public enum MatchMode: String, Codable, Sendable {
        case manual
        case automatic
    }

    public let id: String
    public var name: String
    public var body: String
    public var matchMode: MatchMode
    /// Lowercased regular expressions matched against the model identifier.
    /// Ignored for `.manual`; an automatic persona with no pattern matches
    /// nothing.
    public var modelPatterns: [String]
    /// Higher wins when several automatic personas match the same model.
    public var priority: Int
    /// Pinned personas sort first in the settings list.
    public var pinned: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        body: String,
        matchMode: MatchMode = .manual,
        modelPatterns: [String] = [],
        priority: Int = 0,
        pinned: Bool = false,
    ) {
        self.id = id
        self.name = name
        self.body = body
        self.matchMode = matchMode
        self.modelPatterns = modelPatterns
        self.priority = priority
        self.pinned = pinned
    }
}

/// The whole persona collection on disk plus the app-level choices: whether
/// any injection is enabled, and which manual persona is in force.
public struct PersonaSnapshot: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var activeID: String?
    public var personas: [Persona]

    public init(enabled: Bool = false, activeID: String? = nil, personas: [Persona] = []) {
        self.enabled = enabled
        self.activeID = activeID
        self.personas = personas
    }
}

/// Reads and writes `Personas/personas.json` under the app's data folder. One
/// disk authority, no cached snapshot: every mutation locks, rereads, then
/// writes a fresh file by rename. A corrupt or over-large file is reported,
/// never silently replaced with an empty collection — the reader's personas
/// are not thrown away because one write went wrong.
public struct PersonaStore: Sendable {
    public static let maximumPersonas = 64
    public static let maximumBodyCharacters = 16 * 1024
    private static let maximumFileBytes = 4 * 1024 * 1024
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var file: URL {
        root.appendingPathComponent("Personas", isDirectory: true)
            .appendingPathComponent("personas.json")
    }

    public func read() throws -> PersonaSnapshot {
        try locked { directory in try read(in: directory) }
    }

    @discardableResult
    public func save(_ snapshot: PersonaSnapshot) throws -> PersonaSnapshot {
        try locked { directory in
            try validate(snapshot)
            try write(snapshot, in: directory)
            return snapshot
        }
    }

    /// Makes the directory as mobile first (`DataFolder.app.makeLevels`), then
    /// writes. The folder the package made is the only ancestor that exists.
    @discardableResult
    public func createRootIfNeeded(folder: DataFolder) throws -> PersonaSnapshot {
        try folder.makeLevels(to: root.appendingPathComponent("Personas", isDirectory: true))
        return try save(read())
    }

    private func validate(_ snapshot: PersonaSnapshot) throws {
        guard snapshot.personas.count <= Self.maximumPersonas else { throw PersonaStoreError.full }
        var ids = Set<String>()
        for persona in snapshot.personas {
            guard !persona.id.isEmpty, !persona.name.isEmpty,
                  persona.name.utf8.count <= 255,
                  persona.body.count <= Self.maximumBodyCharacters,
                  !persona.name.utf8.contains(0), !persona.body.utf8.contains(0),
                  ids.insert(persona.id).inserted
            else { throw PersonaStoreError.invalidContent }
            for pattern in persona.modelPatterns {
                // A pattern is either empty (ignored) or a usable regex. Bad
                // regexes are rejected here rather than at prompt time, where
                // they would silently drop a persona.
                if !pattern.isEmpty {
                    guard (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil else {
                        throw PersonaStoreError.invalidContent
                    }
                }
            }
        }
        if let activeID = snapshot.activeID {
            guard snapshot.personas.contains(where: { $0.id == activeID }) else {
                throw PersonaStoreError.invalidContent
            }
        }
    }

    private func locked<T>(_ operation: (Int32) throws -> T) throws -> T {
        let directoryPath = root.path
        var info = stat()
        if lstat(directoryPath, &info) != 0 {
            // No personas folder yet: an empty snapshot, and no file written
            // until the reader changes something.
            return try operation(-1)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw PersonaStoreError.unsafeFile }
        guard let canonical = CanonicalPath.resolve(directoryPath) else { throw PersonaStoreError.unsafeFile }
        let directory = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        var opened = stat()
        guard fstat(directory, &opened) == 0, info.st_dev == opened.st_dev, info.st_ino == opened.st_ino else {
            throw PersonaStoreError.unsafeFile
        }
        let lock = openat(directory, "personas.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw posixError() }
        defer { close(lock) }
        try checkRegular(lock)
        guard flock(lock, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(lock, LOCK_UN) }
        return try operation(directory)
    }

    private func read(in directory: Int32) throws -> PersonaSnapshot {
        guard directory >= 0 else { return PersonaSnapshot() }
        let descriptor = openat(directory, "personas.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return PersonaSnapshot() }
            throw posixError()
        }
        defer { close(descriptor) }
        try checkRegular(descriptor)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw PersonaStoreError.full }
        let snapshot = try JSONDecoder().decode(PersonaSnapshot.self, from: data)
        try validate(snapshot)
        return snapshot
    }

    private func write(_ snapshot: PersonaSnapshot, in directory: Int32) throws {
        guard directory >= 0 else { throw PersonaStoreError.unsafeFile }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumFileBytes else { throw PersonaStoreError.full }
        let temporary = ".personas-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0,
              renameat(directory, temporary, directory, "personas.json") == 0,
              fsync(directory) == 0
        else { throw posixError() }
    }

    private func checkRegular(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0
        else { throw PersonaStoreError.unsafeFile }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

public enum PersonaStoreError: Error, Equatable {
    case full
    case invalidContent
    case unsafeFile
}
