import Foundation

public typealias EntryID = UInt32
public let kNoEntry: EntryID = 0xFFFF_FFFF
public let kUnknownTime: Int64 = .min
public let kUnknownSize: Int64 = -1
private let kTombstone: UInt32 = 0xFFFF_FFFE

/// Per-entry flag bits. The low 16 bits are user-visible attributes.
public enum EntryFlag {
    public static let directory: UInt32 = 1 << 0
    public static let symlink: UInt32 = 1 << 1
    public static let hidden: UInt32 = 1 << 2
    public static let system: UInt32 = 1 << 3
    public static let readOnly: UInt32 = 1 << 4
    public static let archive: UInt32 = 1 << 5
    public static let compressed: UInt32 = 1 << 6
    public static let offline: UInt32 = 1 << 7
    public static let executable: UInt32 = 1 << 8
    public static let package: UInt32 = 1 << 9
    public static let attributeMask: UInt32 = 0xFFFF

    public static let deleted: UInt32 = 1 << 16
    public static let root: UInt32 = 1 << 17
    public static let nonASCII: UInt32 = 1 << 18
    public static let unreadable: UInt32 = 1 << 19
    /// Synthesised folder (file-list trees) – shown, but has no real counterpart.
    public static let synthetic: UInt32 = 1 << 20
    /// Never reported in results (internal roots of file lists).
    public static let hiddenFromResults: UInt32 = 1 << 21
}

/// Metadata supplied when inserting / updating an entry.
public struct EntryMeta: Equatable {
    public var flags: UInt32
    public var size: Int64
    public var mtime: Int64
    public var ctime: Int64
    public var atime: Int64

    public init(flags: UInt32 = 0, size: Int64 = kUnknownSize, mtime: Int64 = kUnknownTime,
                ctime: Int64 = kUnknownTime, atime: Int64 = kUnknownTime) {
        self.flags = flags
        self.size = size
        self.mtime = mtime
        self.ctime = ctime
        self.atime = atime
    }

    public var isDirectory: Bool { flags & EntryFlag.directory != 0 }
}

/// Which pre-folded form of a name a matcher compares against.
public enum KeyVariant: Int, Sendable {
    case cs = 0      // case-sensitive, diacritic-sensitive (NFC)
    case ci = 1      // case-insensitive, diacritic-sensitive
    case csdi = 2    // case-sensitive, diacritic-insensitive
    case cidi = 3    // case-insensitive, diacritic-insensitive (default)

    public static func of(caseSensitive: Bool, diacriticSensitive: Bool) -> KeyVariant {
        switch (caseSensitive, diacriticSensitive) {
        case (true, true): return .cs
        case (false, true): return .ci
        case (true, false): return .csdi
        case (false, false): return .cidi
        }
    }

    public var caseSensitive: Bool { self == .cs || self == .csdi }
}

/// Sort columns. Some are maintained as presorted orders inside the index
/// ("fast sort"); the rest are sorted per query.
public enum SortKey: String, Codable, CaseIterable, Sendable {
    case name
    case path
    case size
    case ext = "extension"
    case type
    case dateModified = "date-modified"
    case dateCreated = "date-created"
    case dateAccessed = "date-accessed"
    case attributes
    case dateRecentlyChanged = "date-recently-changed"
    case runCount = "run-count"
    case dateRun = "date-run"
    case fileListFilename = "file-list-filename"

    /// Keys whose order depends only on index columns and can be presorted.
    public var indexable: Bool {
        switch self {
        case .type, .runCount, .dateRun, .fileListFilename: return false
        default: return true
        }
    }

    public var title: String {
        switch self {
        case .name: return "Name"
        case .path: return "Path"
        case .size: return "Size"
        case .ext: return "Extension"
        case .type: return "Type"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .dateAccessed: return "Date Accessed"
        case .attributes: return "Attributes"
        case .dateRecentlyChanged: return "Date Recently Changed"
        case .runCount: return "Run Count"
        case .dateRun: return "Date Run"
        case .fileListFilename: return "File List Filename"
        }
    }

    /// Default direction when a column is first clicked (dates/sizes newest/largest first).
    public var defaultAscending: Bool {
        switch self {
        case .size, .dateModified, .dateCreated, .dateAccessed, .dateRecentlyChanged, .runCount, .dateRun:
            return false
        default:
            return true
        }
    }

    /// Parses names used by the command line, HTTP server and bookmarks.
    public static func parse(_ s: String) -> SortKey? {
        let k = s.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        if let v = SortKey(rawValue: k) { return v }
        switch k {
        case "ext": return .ext
        case "dm", "modified", "date-modified", "datemodified": return .dateModified
        case "dc", "created", "datecreated": return .dateCreated
        case "da", "accessed", "dateaccessed": return .dateAccessed
        case "rc", "recent-change", "recentchange", "date-recent-change": return .dateRecentlyChanged
        case "dr", "run", "daterun": return .dateRun
        case "runcount": return .runCount
        case "attrib", "attribute", "attr": return .attributes
        case "full-path", "fullpath", "path-and-name", "full-path-and-name": return .path
        case "filename", "file-name": return .name
        case "file-list", "filelist": return .fileListFilename
        default: return nil
        }
    }
}

/// Where an index root came from.
public enum SourceKind: String, Codable, Sendable {
    case volume, folder, fileList
}

/// Persistent description of one index root.
public struct SourceInfo: Codable, Sendable {
    public var kind: SourceKind
    /// Absolute path of the root ("/" for the boot volume).
    public var path: String
    /// Display name of the root entry.
    public var name: String
    public var fsType: String?
    public var volumeUUID: String?
    public var eventsUUID: String?
    public var lastEventID: UInt64
    public var lastScan: Double?
    public var monitored: Bool
    /// For file lists: the .efu file the entries were loaded from.
    public var fileListPath: String?

    public init(kind: SourceKind, path: String, name: String, fsType: String? = nil, volumeUUID: String? = nil,
                eventsUUID: String? = nil, lastEventID: UInt64 = 0, lastScan: Double? = nil,
                monitored: Bool = true, fileListPath: String? = nil) {
        self.kind = kind
        self.path = path
        self.name = name
        self.fsType = fsType
        self.volumeUUID = volumeUUID
        self.eventsUUID = eventsUUID
        self.lastEventID = lastEventID
        self.lastScan = lastScan
        self.monitored = monitored
        self.fileListPath = fileListPath
    }

    /// Prefix used when building child paths ("" for "/").
    public var childPrefix: String { path == "/" ? "" : path }
}

/// The in-memory file database.
///
/// Storage is a struct of arrays indexed by `EntryID`. Entries are never moved;
/// deleting marks a tombstone, so IDs held by stale result lists stay readable
/// until the next compaction (database save/load).
///
/// Thread safety: readers take `lock.read`, mutators `lock.write`. All
/// mutation goes through `beginBatch`/`endBatch` so presorted orders are
/// updated once per batch.
public final class FileIndex: @unchecked Sendable {
    public let lock = RWLock()

    // MARK: columns
    public let nameOff = PODArray<UInt32>()
    public let nameLen = PODArray<UInt16>()
    public let parent = PODArray<UInt32>()
    public let flags = PODArray<UInt32>()
    public let size = PODArray<Int64>()
    public let mtime = PODArray<Int64>()
    public let ctime = PODArray<Int64>()
    public let atime = PODArray<Int64>()
    public let rctime = PODArray<Int64>()
    public let keyOff = PODArray<UInt32>()
    public let firstChild = PODArray<UInt32>()
    public let nextSibling = PODArray<UInt32>()
    public let prevSibling = PODArray<UInt32>()
    public let folderRank = PODArray<UInt32>()
    public let names = ByteArena(capacity: 1 << 16)
    public let keys = ByteArena(capacity: 1 << 12)

    // MARK: roots
    public private(set) var roots: [EntryID] = []
    public private(set) var sources: [EntryID: SourceInfo] = [:]
    /// [display path, cs, ci, csdi, cidi] child-prefix bytes per root.
    private var rootPrefix: [EntryID: [[UInt8]]] = [:]

    public private(set) var liveCount = 0
    public private(set) var generation: UInt64 = 0
    /// Bumped when entry IDs are renumbered (compaction / rebuild).
    public let instanceID = UUID()

    // MARK: options
    public var maintainedOrders: Set<SortKey> = [.name, .path, .size, .dateModified]
    public var folderSizesEnabled = false
    public var naturalSort = false
    public var journal: IndexJournal?

    // MARK: hash table (parent, name) -> id
    private var table = PODArray<UInt32>()
    private var tableMask = -1
    private var tableUsed = 0
    private var tableLive = 0

    // MARK: orders
    public private(set) var orders: [SortKey: PODArray<UInt32>] = [:]
    private var ranksValid = false
    private let mark = PODArray<UInt8>()

    // MARK: batch state
    private var batchDepth = 0
    private var batchAffected: [EntryID] = []
    private var batchStructural = false
    private var batchMovedDirs: [EntryID] = []
    private var batchFolderSizeTouched: [EntryID] = []

    public init() {}

    public var count: Int { nameOff.count }

    // MARK: - Basic accessors (call with at least a read lock)

    @inline(__always) public func isDeleted(_ id: EntryID) -> Bool { flags[Int(id)] & EntryFlag.deleted != 0 }
    @inline(__always) public func isDirectory(_ id: EntryID) -> Bool { flags[Int(id)] & EntryFlag.directory != 0 }
    @inline(__always) public func isRoot(_ id: EntryID) -> Bool { flags[Int(id)] & EntryFlag.root != 0 }
    @inline(__always) public func parentOf(_ id: EntryID) -> EntryID { parent[Int(id)] }

    @inline(__always)
    public func nameBytes(_ id: EntryID) -> UnsafeBufferPointer<UInt8> {
        let i = Int(id)
        return UnsafeBufferPointer(start: names.base + Int(nameOff[i]), count: Int(nameLen[i]))
    }

    public func name(_ id: EntryID) -> String {
        String(decoding: nameBytes(id), as: UTF8.self)
    }

    /// Pointer + length of the requested key variant of an entry's name.
    @inline(__always)
    public func key(_ id: EntryID, _ v: KeyVariant) -> (UnsafePointer<UInt8>, Int) {
        let i = Int(id)
        if flags[i] & EntryFlag.nonASCII == 0 {
            return (UnsafePointer(names.base + Int(nameOff[i])), Int(nameLen[i]))
        }
        return FileIndex.keyVariant(keys.base + Int(keyOff[i]), v)
    }

    @inline(__always)
    static func keyVariant(_ start: UnsafeMutablePointer<UInt8>, _ v: KeyVariant) -> (UnsafePointer<UInt8>, Int) {
        var p = start
        var k = 0
        while true {
            let len = Int(p[0]) | (Int(p[1]) << 8)
            if k == v.rawValue { return (UnsafePointer(p + 2), len) }
            p += 2 + len
            k += 1
        }
    }

    public func source(of id: EntryID) -> (EntryID, SourceInfo)? {
        var cur = id
        var guardCount = 0
        while parent[Int(cur)] != kNoEntry && guardCount < 4096 { cur = parent[Int(cur)]; guardCount += 1 }
        guard let s = sources[cur] else { return nil }
        return (cur, s)
    }

    public func rootID(of id: EntryID) -> EntryID {
        var cur = id
        while parent[Int(cur)] != kNoEntry { cur = parent[Int(cur)] }
        return cur
    }

    public func depth(_ id: EntryID) -> Int {
        var d = 0
        var cur = parent[Int(id)]
        while cur != kNoEntry { d += 1; cur = parent[Int(cur)] }
        return d
    }

    /// Byte range of the extension inside the name (empty for folders' leading-dot names).
    @inline(__always)
    public func extRange(_ id: EntryID) -> (UnsafePointer<UInt8>, Int) {
        let i = Int(id)
        let p = UnsafePointer(names.base + Int(nameOff[i]))
        let n = Int(nameLen[i])
        var j = n - 1
        while j > 0 {
            if p[j] == 46 { return (p + j + 1, n - j - 1) }
            j -= 1
        }
        return (p + n, 0)
    }

    public func extensionString(_ id: EntryID) -> String {
        let (p, n) = extRange(id)
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }

    public func rootPrefixBytes(_ root: EntryID, variant: KeyVariant?) -> [UInt8] {
        guard let v = rootPrefix[root] else { return [] }
        return v[variant.map { $0.rawValue + 1 } ?? 0]
    }

    // MARK: - Paths

    /// Appends the full path of `id` (display form, or folded with `variant`).
    public func appendPath(_ id: EntryID, variant: KeyVariant?, into buf: inout ByteBuf,
                           chain: UnsafeMutablePointer<UInt32>, chainCapacity: Int) {
        var depth = 0
        var cur = id
        while cur != kNoEntry && depth < chainCapacity {
            chain[depth] = cur
            depth += 1
            cur = parent[Int(cur)]
        }
        let root = chain[depth - 1]
        if let pref = rootPrefix[root] {
            let bytes = pref[variant.map { $0.rawValue + 1 } ?? 0]
            if depth == 1 {
                if bytes.isEmpty { buf.append(47) } else { bytes.withUnsafeBufferPointer { buf.append($0.baseAddress!, $0.count) } }
                return
            }
            bytes.withUnsafeBufferPointer { b in if b.count > 0 { buf.append(b.baseAddress!, b.count) } }
        } else if depth == 1 {
            let nb = nameBytes(root)
            buf.append(nb.baseAddress!, nb.count)
            return
        }
        var k = depth - 2
        while k >= 0 {
            buf.append(47) // '/'
            let e = chain[k]
            if let v = variant {
                let (p, n) = key(e, v)
                buf.append(p, n)
            } else {
                let nb = nameBytes(e)
                if nb.count > 0 { buf.append(nb.baseAddress!, nb.count) }
            }
            k -= 1
        }
    }

    /// Full path as a String (display form).
    public func path(_ id: EntryID) -> String {
        var buf = ByteBuf(capacity: 512)
        defer { buf.deallocate() }
        let chain = UnsafeMutablePointer<UInt32>.allocate(capacity: 1024)
        defer { chain.deallocate() }
        appendPath(id, variant: nil, into: &buf, chain: chain, chainCapacity: 1024)
        return buf.string
    }

    /// The "Path" column: the folder that contains the entry.
    public func parentPath(_ id: EntryID) -> String {
        let p = parent[Int(id)]
        if p == kNoEntry {
            // A root: show the folder that contains the mount point / folder.
            guard let src = sources[id] else { return "" }
            if src.path == "/" { return "" }
            let parentDir = (src.path as NSString).deletingLastPathComponent
            return parentDir
        }
        return path(p)
    }

    // MARK: - Lookup

    /// Finds the child of `parent` with exactly these name bytes.
    public func lookupChild(_ parentID: EntryID, _ p: UnsafePointer<UInt8>, _ n: Int) -> EntryID {
        guard tableMask >= 0 else { return kNoEntry }
        let h = FileIndex.hash(parentID, p, n)
        var i = Int(truncatingIfNeeded: h) & tableMask
        let tb = table.base
        while true {
            let v = tb[i]
            if v == kNoEntry { return kNoEntry }
            if v != kTombstone {
                let e = Int(v)
                if parent[e] == parentID && Int(nameLen[e]) == n && memcmp(names.base + Int(nameOff[e]), p, n) == 0 {
                    return v
                }
            }
            i = (i + 1) & tableMask
        }
    }

    public func lookupChild(_ parentID: EntryID, name: String) -> EntryID {
        var s = name
        return s.withUTF8 { lookupChild(parentID, $0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
    }

    /// Case-/normalisation-insensitive fallback: linear scan of the children.
    public func lookupChildLoose(_ parentID: EntryID, name: String) -> EntryID {
        let want = Fold.fold(name, caseSensitive: false, diacriticSensitive: true)
        var c = firstChild[Int(parentID)]
        while c != kNoEntry {
            let (p, n) = key(c, .ci)
            if n == want.count && want.withUnsafeBufferPointer({ Fold.compareCI(p, n, $0.baseAddress!, $0.count) == 0 }) {
                return c
            }
            c = nextSibling[Int(c)]
        }
        return kNoEntry
    }

    /// The filesystem root (volume / folder source) that owns `path`, plus the remaining components.
    public func resolveRoot(forPath path: String, includeFileLists: Bool = false) -> (EntryID, [Substring])? {
        var best: EntryID = kNoEntry
        var bestLen = -1
        for r in roots where !isDeleted(r) {
            guard let s = sources[r] else { continue }
            if s.kind == .fileList && !includeFileLists { continue }
            let rp = s.path
            if rp == "/" {
                if path.hasPrefix("/") && 0 > bestLen { best = r; bestLen = 0 }
            } else if path == rp || path.hasPrefix(rp + "/") {
                if rp.count > bestLen { best = r; bestLen = rp.count }
            }
        }
        guard best != kNoEntry, let s = sources[best] else { return nil }
        let rest = s.path == "/" ? Substring(path) : path.dropFirst(s.path.count)
        return (best, rest.split(separator: "/", omittingEmptySubsequences: true))
    }

    /// Resolves an absolute path to an entry, or kNoEntry.
    public func lookup(path: String) -> EntryID {
        guard let (root, comps) = resolveRoot(forPath: path) else { return kNoEntry }
        var cur = root
        for c in comps {
            var nxt = lookupChild(cur, name: String(c))
            if nxt == kNoEntry { nxt = lookupChildLoose(cur, name: String(c)) }
            if nxt == kNoEntry { return kNoEntry }
            cur = nxt
        }
        return cur
    }

    public func children(of id: EntryID) -> [EntryID] {
        var out: [EntryID] = []
        var c = firstChild[Int(id)]
        while c != kNoEntry {
            if !isDeleted(c) { out.append(c) }
            c = nextSibling[Int(c)]
        }
        return out
    }

    /// Visits every live descendant of `id` (not including `id`).
    public func forEachDescendant(_ id: EntryID, _ body: (EntryID) -> Void) {
        var stack: [EntryID] = []
        var c = firstChild[Int(id)]
        while c != kNoEntry { stack.append(c); c = nextSibling[Int(c)] }
        while let e = stack.popLast() {
            body(e)
            var k = firstChild[Int(e)]
            while k != kNoEntry { stack.append(k); k = nextSibling[Int(k)] }
        }
    }

    // MARK: - Hashing

    @inline(__always)
    static func hash(_ parentID: UInt32, _ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ (UInt64(parentID) &* 0x9E37_79B9_7F4A_7C15)
        var i = 0
        while i < n {
            h = (h ^ UInt64(p[i])) &* 0x0000_0100_0000_01B3
            i += 1
        }
        return h ^ (h >> 31)
    }

    @inline(__always)
    private func hashOf(_ id: EntryID) -> UInt64 {
        let i = Int(id)
        return FileIndex.hash(parent[i], names.base + Int(nameOff[i]), Int(nameLen[i]))
    }

    private func tableInsert(_ id: EntryID) {
        if tableMask < 0 || (tableUsed + 1) * 2 > tableMask + 1 {
            rehash(minimum: Swift.max(1024, (tableLive + 1) * 3))
        }
        var i = Int(truncatingIfNeeded: hashOf(id)) & tableMask
        let tb = table.base
        while true {
            let v = tb[i]
            if v == kNoEntry { tb[i] = id; tableUsed += 1; tableLive += 1; return }
            if v == kTombstone { tb[i] = id; tableLive += 1; return }
            i = (i + 1) & tableMask
        }
    }

    private func tableRemove(_ id: EntryID) {
        guard tableMask >= 0 else { return }
        var i = Int(truncatingIfNeeded: hashOf(id)) & tableMask
        let tb = table.base
        while true {
            let v = tb[i]
            if v == kNoEntry { return }
            if v == id { tb[i] = kTombstone; tableLive -= 1; return }
            i = (i + 1) & tableMask
        }
    }

    private func rehash(minimum: Int) {
        var cap = 1024
        while cap < minimum * 2 { cap <<= 1 }
        table = PODArray<UInt32>(repeating: kNoEntry, count: cap)
        tableMask = cap - 1
        tableUsed = 0
        tableLive = 0
        let tb = table.base
        let n = count
        var id = 0
        while id < n {
            let f = flags[id]
            if f & (EntryFlag.deleted | EntryFlag.root) == 0 {
                var i = Int(truncatingIfNeeded: hashOf(EntryID(id))) & tableMask
                while tb[i] != kNoEntry { i = (i + 1) & tableMask }
                tb[i] = EntryID(id)
                tableUsed += 1
                tableLive += 1
            }
            id += 1
        }
    }

    // MARK: - Children links

    @inline(__always)
    private func link(_ id: EntryID, to p: EntryID) {
        let i = Int(id)
        let head = firstChild[Int(p)]
        nextSibling[i] = head
        prevSibling[i] = kNoEntry
        if head != kNoEntry { prevSibling[Int(head)] = id }
        firstChild[Int(p)] = id
    }

    @inline(__always)
    private func unlink(_ id: EntryID) {
        let i = Int(id)
        let p = parent[i]
        let n = nextSibling[i]
        let pr = prevSibling[i]
        if pr != kNoEntry { nextSibling[Int(pr)] = n } else if p != kNoEntry { firstChild[Int(p)] = n }
        if n != kNoEntry { prevSibling[Int(n)] = pr }
        nextSibling[i] = kNoEntry
        prevSibling[i] = kNoEntry
    }

    // MARK: - Raw append (no links / hash). Used by bulk loads.

    @inline(__always)
    private func appendRaw(parent p: EntryID, name: UnsafePointer<UInt8>, length n: Int, meta: EntryMeta) -> EntryID {
        let id = EntryID(count)
        let off = names.count
        names.append(name, count: n)
        nameOff.append(UInt32(truncatingIfNeeded: off))
        nameLen.append(UInt16(truncatingIfNeeded: n))
        parent.append(p)
        var f = meta.flags & ~(EntryFlag.deleted | EntryFlag.nonASCII)
        if Fold.isASCII(name, n) {
            keyOff.append(0)
        } else {
            f |= EntryFlag.nonASCII
            keyOff.append(storeKeys(name, n))
        }
        flags.append(f)
        size.append(meta.size)
        mtime.append(meta.mtime)
        ctime.append(meta.ctime)
        atime.append(meta.atime)
        rctime.append(kUnknownTime)
        firstChild.append(kNoEntry)
        nextSibling.append(kNoEntry)
        prevSibling.append(kNoEntry)
        folderRank.append(0)
        liveCount += 1
        return id
    }

    private func storeKeys(_ name: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
        let s = String(decoding: UnsafeBufferPointer(start: name, count: n), as: UTF8.self)
        let off = keys.count
        for v in Fold.variants(s) {
            let len = Swift.min(v.count, 0xFFFF)
            keys.append(UInt8(len & 0xFF))
            keys.append(UInt8(len >> 8))
            v.withUnsafeBufferPointer { keys.append($0.baseAddress!, count: len) }
        }
        return UInt32(truncatingIfNeeded: off)
    }

    // MARK: - Batches

    public func beginBatch() { batchDepth += 1 }

    public func endBatch() {
        batchDepth -= 1
        if batchDepth == 0 { commitBatch() }
    }

    /// Runs `body` as one batch under the write lock.
    public func mutate<R>(_ body: (FileIndex) throws -> R) rethrows -> R {
        try lock.write {
            beginBatch()
            defer { endBatch() }
            return try body(self)
        }
    }

    private func touch(_ id: EntryID) { batchAffected.append(id) }

    // MARK: - Mutation API (write lock + batch required)

    /// Adds a new root (volume, folder source or file list).
    @discardableResult
    public func addRoot(_ info: SourceInfo, meta: EntryMeta) -> EntryID {
        var nm = info.name
        let id: EntryID = nm.withUTF8 { b in
            appendRaw(parent: kNoEntry, name: b.baseAddress ?? UnsafePointer(bitPattern: 1)!, length: b.count,
                      meta: EntryMeta(flags: meta.flags | EntryFlag.directory | EntryFlag.root, size: meta.size,
                                      mtime: meta.mtime, ctime: meta.ctime, atime: meta.atime))
        }
        flags[Int(id)] |= EntryFlag.root
        roots.append(id)
        sources[id] = info
        setRootPrefix(id, info)
        touch(id)
        batchStructural = true
        return id
    }

    private func setRootPrefix(_ id: EntryID, _ info: SourceInfo) {
        let pref = info.childPrefix
        var v: [[UInt8]] = [Array(pref.utf8)]
        v.append(contentsOf: Fold.variants(pref))
        rootPrefix[id] = v
    }

    public func updateSource(_ id: EntryID, _ body: (inout SourceInfo) -> Void) {
        guard var s = sources[id] else { return }
        let oldPath = s.path
        body(&s)
        sources[id] = s
        if s.path != oldPath { setRootPrefix(id, s) }
    }

    /// Removes a root and everything under it.
    public func removeRoot(_ id: EntryID) {
        guard isRoot(id), !isDeleted(id) else { return }
        remove(id)
        roots.removeAll { $0 == id }
        sources[id] = nil
        rootPrefix[id] = nil
    }

    /// Inserts a child entry. The caller ensures no sibling with the same name exists.
    @discardableResult
    public func add(parent p: EntryID, name: UnsafePointer<UInt8>, length n: Int, meta: EntryMeta) -> EntryID {
        let id = appendRaw(parent: p, name: name, length: n, meta: meta)
        link(id, to: p)
        tableInsert(id)
        touch(id)
        if meta.isDirectory { batchStructural = true }
        if folderSizesEnabled && !meta.isDirectory && meta.size > 0 { propagateSize(from: p, delta: meta.size) }
        if meta.isDirectory && folderSizesEnabled { size[Int(id)] = 0 }
        journal?.record(.created, self, id)
        return id
    }

    @discardableResult
    public func add(parent p: EntryID, name: String, meta: EntryMeta) -> EntryID {
        var s = name
        return s.withUTF8 { add(parent: p, name: $0.baseAddress ?? UnsafePointer(bitPattern: 1)!, length: $0.count, meta: meta) }
    }

    /// Updates metadata; returns true if anything visible changed.
    @discardableResult
    public func update(_ id: EntryID, meta: EntryMeta, recentChange: Int64? = nil) -> Bool {
        let i = Int(id)
        let isDir = flags[i] & EntryFlag.directory != 0
        let newAttr = meta.flags & EntryFlag.attributeMask
        let oldAttr = flags[i] & EntryFlag.attributeMask
        let sizeChanged = !isDir && size[i] != meta.size
        let changed = sizeChanged || mtime[i] != meta.mtime || ctime[i] != meta.ctime ||
            (meta.atime != kUnknownTime && atime[i] != meta.atime) || newAttr != oldAttr
        guard changed else { return false }
        if sizeChanged {
            if folderSizesEnabled {
                let old = Swift.max(0, size[i]), new = Swift.max(0, meta.size)
                if new != old { propagateSize(from: parent[i], delta: new - old) }
            }
            size[i] = meta.size
        }
        mtime[i] = meta.mtime
        ctime[i] = meta.ctime
        if meta.atime != kUnknownTime { atime[i] = meta.atime }
        flags[i] = (flags[i] & ~EntryFlag.attributeMask) | newAttr
        if let rc = recentChange { rctime[i] = rc }
        touch(id)
        journal?.record(.modified, self, id)
        return true
    }

    public func setRecentChange(_ id: EntryID, _ t: Int64) {
        rctime[Int(id)] = t
        touch(id)
    }

    /// Deletes an entry and its whole subtree.
    public func remove(_ id: EntryID) {
        let i = Int(id)
        guard flags[i] & EntryFlag.deleted == 0 else { return }
        if folderSizesEnabled && parent[i] != kNoEntry {
            let s = size[i]
            if s > 0 { propagateSize(from: parent[i], delta: -s) }
        }
        journal?.record(.deleted, self, id)
        unlink(id)
        var stack: [EntryID] = [id]
        while let e = stack.popLast() {
            let ei = Int(e)
            var c = firstChild[ei]
            while c != kNoEntry { stack.append(c); c = nextSibling[Int(c)] }
            if flags[ei] & EntryFlag.root == 0 { tableRemove(e) }
            if flags[ei] & EntryFlag.directory != 0 { batchStructural = true }
            flags[ei] |= EntryFlag.deleted
            liveCount -= 1
            touch(e)
        }
    }

    /// Renames and/or moves an entry (its subtree comes along).
    public func move(_ id: EntryID, to newParent: EntryID, name: UnsafePointer<UInt8>, length n: Int) {
        let i = Int(id)
        guard flags[i] & (EntryFlag.deleted | EntryFlag.root) == 0 else { return }
        let oldParent = parent[i]
        let sameName = Int(nameLen[i]) == n && memcmp(names.base + Int(nameOff[i]), name, n) == 0
        if oldParent == newParent && sameName { return }
        let s = folderSizesEnabled ? Swift.max(0, size[i]) : 0
        if s > 0 { propagateSize(from: oldParent, delta: -s) }
        tableRemove(id)
        unlink(id)
        if !sameName {
            let off = names.count
            names.append(name, count: n)
            nameOff[i] = UInt32(truncatingIfNeeded: off)
            nameLen[i] = UInt16(truncatingIfNeeded: n)
            if Fold.isASCII(name, n) {
                flags[i] &= ~EntryFlag.nonASCII
            } else {
                flags[i] |= EntryFlag.nonASCII
                keyOff[i] = storeKeys(name, n)
            }
        }
        parent[i] = newParent
        link(id, to: newParent)
        tableInsert(id)
        if s > 0 { propagateSize(from: newParent, delta: s) }
        touch(id)
        if flags[i] & EntryFlag.directory != 0 {
            batchStructural = true
            batchMovedDirs.append(id)
        }
        journal?.record(.renamed, self, id)
    }

    public func move(_ id: EntryID, to newParent: EntryID, name: String) {
        var s = name
        s.withUTF8 { move(id, to: newParent, name: $0.baseAddress ?? UnsafePointer(bitPattern: 1)!, length: $0.count) }
    }

    private func propagateSize(from start: EntryID, delta: Int64) {
        var cur = start
        while cur != kNoEntry {
            let c = Int(cur)
            if size[c] < 0 { size[c] = 0 }
            size[c] += delta
            batchFolderSizeTouched.append(cur)
            cur = parent[c]
        }
    }

    // MARK: - Bulk scan import

    /// Imports a scanner result below `attachTo` (an existing directory or root).
    /// Uses raw appends, then links/hashes everything in one pass.
    public func importScan(_ result: ScanResult, attachTo: EntryID) {
        let first = count
        var bases: [Int] = []
        var total = 0
        for w in result.buffers { bases.append(total); total += w.count }
        guard total > 0 else { return }
        nameOff.reserve(first + total); nameLen.reserve(first + total); parent.reserve(first + total)
        flags.reserve(first + total); size.reserve(first + total); mtime.reserve(first + total)
        ctime.reserve(first + total); atime.reserve(first + total); rctime.reserve(first + total)
        keyOff.reserve(first + total); firstChild.reserve(first + total); nextSibling.reserve(first + total)
        prevSibling.reserve(first + total); folderRank.reserve(first + total)
        var nameBytes = 0
        for w in result.buffers { nameBytes += w.names.count }
        names.reserve(names.count + nameBytes)

        for (wi, w) in result.buffers.enumerated() {
            let nb = w.names.base
            for k in 0..<w.count {
                let ref = w.parentRef[k]
                let p: EntryID
                if ref == ScanBuffer.rootRef {
                    p = attachTo
                } else {
                    let pw = Int(ref >> 32), pl = Int(ref & 0xFFFF_FFFF)
                    p = EntryID(first + bases[pw] + pl)
                }
                _ = appendRaw(parent: p, name: nb + Int(w.nameOff[k]), length: Int(w.nameLen[k]),
                              meta: EntryMeta(flags: w.flags[k], size: w.size[k], mtime: w.mtime[k],
                                              ctime: w.ctime[k], atime: w.atime[k]))
                _ = wi
            }
        }
        let end = count
        if tableMask < 0 || (tableUsed + total) * 2 > tableMask + 1 {
            rehash(minimum: tableLive + total + 1024)
        } else {
            for id in first..<end { tableInsert(EntryID(id)) }
        }
        // rehash() already inserted the new entries; link children now.
        for id in first..<end {
            let p = parent[id]
            link(EntryID(id), to: p)
            batchAffected.append(EntryID(id))
            if flags[id] & EntryFlag.directory != 0 {
                batchStructural = true
                if folderSizesEnabled { size[id] = 0 }
            }
        }
        if folderSizesEnabled {
            var addedToAttach: Int64 = 0
            for id in first..<end where flags[id] & EntryFlag.directory == 0 {
                let s = size[id]
                if s <= 0 { continue }
                var cur = parent[id]
                while cur != kNoEntry && Int(cur) >= first {
                    size[Int(cur)] += s
                    cur = parent[Int(cur)]
                }
                addedToAttach += s
            }
            if addedToAttach > 0 { propagateSize(from: attachTo, delta: addedToAttach) }
        }
        if journal != nil && first > 0 {
            for id in first..<end { journal?.record(.created, self, EntryID(id)) }
        }
    }

    // MARK: - Folder sizes

    /// Recomputes every folder's size from scratch.
    public func recomputeFolderSizes() {
        let n = count
        for i in 0..<n where flags[i] & EntryFlag.directory != 0 { size[i] = 0 }
        for i in 0..<n {
            let f = flags[i]
            if f & (EntryFlag.directory | EntryFlag.deleted) != 0 { continue }
            let s = size[i]
            if s <= 0 { continue }
            var cur = parent[i]
            while cur != kNoEntry { size[Int(cur)] += s; cur = parent[Int(cur)] }
        }
    }

    public func clearFolderSizes() {
        for i in 0..<count where flags[i] & EntryFlag.directory != 0 { size[i] = kUnknownSize }
    }

    // MARK: - Commit / orders

    private func commitBatch() {
        let structural = batchStructural
        if batchAffected.isEmpty && !structural && batchFolderSizeTouched.isEmpty { return }
        generation &+= 1
        if structural || !ranksValid { recomputeFolderRanks() }
        if !batchFolderSizeTouched.isEmpty {
            batchAffected.append(contentsOf: batchFolderSizeTouched)
        }
        for key in maintainedOrders where key.indexable {
            guard orders[key] != nil else { continue }
            var affected = batchAffected
            if key == .path || key == .name {
                if !batchMovedDirs.isEmpty {
                    var extra = 0
                    for d in batchMovedDirs {
                        forEachDescendant(d) { e in affected.append(e); extra += 1 }
                        if extra > count / 4 { break }
                    }
                    if extra > count / 4 { rebuildOrder(key); continue }
                }
            }
            mergeOrder(key, affected: affected)
        }
        batchAffected.removeAll(keepingCapacity: true)
        batchMovedDirs.removeAll(keepingCapacity: true)
        batchFolderSizeTouched.removeAll(keepingCapacity: true)
        batchStructural = false
    }

    /// Builds all maintained orders from scratch (after a bulk import / load).
    public func rebuildOrders() {
        lock.write {
            recomputeFolderRanks()
            orders.removeAll()
            for key in maintainedOrders where key.indexable { rebuildOrder(key) }
            generation &+= 1
        }
    }

    public func setMaintainedOrders(_ keys: Set<SortKey>) {
        lock.write {
            maintainedOrders = keys.union([.name])
            for k in orders.keys where !maintainedOrders.contains(k) { orders[k] = nil }
            if !ranksValid { recomputeFolderRanks() }
            for k in maintainedOrders where k.indexable && orders[k] == nil { rebuildOrder(k) }
        }
    }

    /// Installs an order loaded from disk (must be a valid permutation of live entries).
    public func installOrder(_ key: SortKey, _ ids: PODArray<UInt32>) {
        orders[key] = ids
    }

    @inline(__always)
    private func includeInOrders(_ i: Int) -> Bool {
        flags[i] & (EntryFlag.deleted | EntryFlag.hiddenFromResults) == 0
    }

    private func rebuildOrder(_ key: SortKey) {
        let ids = PODArray<UInt32>(capacity: liveCount + 16)
        for i in 0..<count where includeInOrders(i) { ids.append(UInt32(i)) }
        let ord = makeOrdering()
        let less = ord.lessFunction(key)
        Parallel.sort(ids.buffer, by: less)
        orders[key] = ids
    }

    private func mergeOrder(_ key: SortKey, affected: [EntryID]) {
        guard let old = orders[key] else { return }
        let n = count
        if mark.count < n { mark.resize(n, fill: 0) }
        let mk = mark.base
        var adds: [UInt32] = []
        adds.reserveCapacity(affected.count)
        for id in affected where mk[Int(id)] == 0 {
            mk[Int(id)] = 1
            if includeInOrders(Int(id)) { adds.append(id) }
        }
        // keep everything not affected
        let kept = PODArray<UInt32>(capacity: old.count + adds.count)
        kept.resizeUninitialized(0)
        do {
            let ob = old.base
            var j = 0
            let oc = old.count
            let kb = kept.base
            var k = 0
            while j < oc {
                let v = ob[j]
                if mk[Int(v)] == 0 { kb[k] = v; k += 1 }
                j += 1
            }
            kept.resizeUninitialized(k)
        }
        for id in affected { mk[Int(id)] = 0 }
        if adds.isEmpty { orders[key] = kept; return }
        let ord = makeOrdering()
        let less = ord.lessFunction(key)
        adds.sort(by: less)
        // Merge by binary-searching each add's position.
        let out = PODArray<UInt32>(capacity: kept.count + adds.count)
        let kb = kept.base
        let kc = kept.count
        var lo = 0
        for a in adds {
            var l = lo, h = kc
            while l < h {
                let m = (l + h) >> 1
                if less(a, kb[m]) { h = m } else { l = m + 1 }
            }
            if l > lo { out.append(kb + lo, count: l - lo) }
            out.append(a)
            lo = l
        }
        if lo < kc { out.append(kb + lo, count: kc - lo) }
        orders[key] = out
    }

    private func recomputeFolderRanks() {
        let n = count
        if folderRank.count < n { folderRank.resize(n, fill: 0) }
        let ord = makeOrdering()
        var rank: UInt32 = 1
        let liveRoots = roots.filter { !isDeleted($0) }.sorted { (sources[$0]?.path ?? "") < (sources[$1]?.path ?? "") }
        var stack: [EntryID] = liveRoots.reversed()
        var kids: [EntryID] = []
        while let d = stack.popLast() {
            folderRank[Int(d)] = rank
            rank &+= 1
            kids.removeAll(keepingCapacity: true)
            var c = firstChild[Int(d)]
            while c != kNoEntry {
                if flags[Int(c)] & (EntryFlag.directory | EntryFlag.deleted) == EntryFlag.directory { kids.append(c) }
                c = nextSibling[Int(c)]
            }
            if kids.count > 1 { kids.sort { ord.compareNameKeys($0, $1) < 0 } }
            var k = kids.count - 1
            while k >= 0 { stack.append(kids[k]); k -= 1 }
        }
        ranksValid = true
    }

    /// Raw-pointer comparator bundle. Only valid while the index is not mutated.
    public func makeOrdering() -> Ordering {
        Ordering(nameOff: nameOff.base, nameLen: nameLen.base, flags: flags.base, keyOff: keyOff.base,
                 names: names.base, keys: keys.base, parent: parent.base, size: size.base, mtime: mtime.base,
                 ctime: ctime.base, atime: atime.base, rctime: rctime.base, folderRank: folderRank.base,
                 natural: naturalSort)
    }

    // MARK: - Compaction support

    /// Returns old→new ID mapping (kNoEntry for dropped entries) for live entries in ID order.
    public func compactionMap() -> PODArray<UInt32> {
        let map = PODArray<UInt32>(repeating: kNoEntry, count: count)
        var next: UInt32 = 0
        for i in 0..<count where flags[i] & EntryFlag.deleted == 0 {
            map[i] = next
            next += 1
        }
        return map
    }

    // MARK: - Statistics

    public struct Stats {
        public var entries: Int
        public var folders: Int
        public var files: Int
        public var deleted: Int
        public var nameBytes: Int
        public var memoryBytes: Int
    }

    public func stats() -> Stats {
        var folders = 0, deleted = 0
        for i in 0..<count {
            let f = flags[i]
            if f & EntryFlag.deleted != 0 { deleted += 1; continue }
            if f & EntryFlag.directory != 0 { folders += 1 }
        }
        let perEntry = 4 + 2 + 4 + 4 + 8 * 5 + 4 + 4 * 4
        var mem = count * perEntry + names.capacity + keys.capacity + table.capacity * 4
        for (_, o) in orders { mem += o.capacity * 4 }
        return Stats(entries: liveCount, folders: folders, files: liveCount - folders, deleted: deleted,
                     nameBytes: names.count, memoryBytes: mem)
    }

    /// Load support: append a fully specified entry without links (links rebuilt by `finishLoad`).
    func loadAppend(parent p: EntryID, name: UnsafePointer<UInt8>, length n: Int, flags f: UInt32,
                    size s: Int64, mtime m: Int64, ctime c: Int64, atime a: Int64, rctime r: Int64) {
        let id = appendRaw(parent: p, name: name, length: n,
                           meta: EntryMeta(flags: f, size: s, mtime: m, ctime: c, atime: a))
        rctime[Int(id)] = r
        if f & EntryFlag.root != 0 { flags[Int(id)] |= EntryFlag.root }
    }

    func loadRoot(_ id: EntryID, _ info: SourceInfo) {
        roots.append(id)
        sources[id] = info
        setRootPrefix(id, info)
    }

    /// After a load: link children and build the hash table.
    func finishLoad() {
        rehash(minimum: liveCount + 1024)
        for i in 0..<count {
            let p = parent[i]
            if p != kNoEntry && flags[i] & EntryFlag.deleted == 0 { link(EntryID(i), to: p) }
        }
        ranksValid = false
        recomputeFolderRanks()
    }

    public func clearBatchStateAfterLoad() {
        batchAffected.removeAll()
        batchMovedDirs.removeAll()
        batchFolderSizeTouched.removeAll()
        batchStructural = false
    }
}

/// Comparator bundle over raw column pointers (no ARC in the hot path).
public struct Ordering {
    let nameOff: UnsafeMutablePointer<UInt32>
    let nameLen: UnsafeMutablePointer<UInt16>
    let flags: UnsafeMutablePointer<UInt32>
    let keyOff: UnsafeMutablePointer<UInt32>
    let names: UnsafeMutablePointer<UInt8>
    let keys: UnsafeMutablePointer<UInt8>
    let parent: UnsafeMutablePointer<UInt32>
    let size: UnsafeMutablePointer<Int64>
    let mtime: UnsafeMutablePointer<Int64>
    let ctime: UnsafeMutablePointer<Int64>
    let atime: UnsafeMutablePointer<Int64>
    let rctime: UnsafeMutablePointer<Int64>
    let folderRank: UnsafeMutablePointer<UInt32>
    let natural: Bool

    @inline(__always)
    func sortKey(_ id: UInt32) -> (UnsafePointer<UInt8>, Int) {
        let i = Int(id)
        if flags[i] & EntryFlag.nonASCII != 0 { return FileIndex.keyVariant(keys + Int(keyOff[i]), .cidi) }
        return (UnsafePointer(names + Int(nameOff[i])), Int(nameLen[i]))
    }

    /// Compares folded names, then raw names. No tie-break on location.
    @inline(__always)
    public func compareNameKeys(_ a: UInt32, _ b: UInt32) -> Int {
        let (pa, la) = sortKey(a)
        let (pb, lb) = sortKey(b)
        var c = natural ? Fold.compareNatural(pa, la, pb, lb) : Fold.compareCI(pa, la, pb, lb)
        if c != 0 { return c }
        let ia = Int(a), ib = Int(b)
        c = Fold.compare(names + Int(nameOff[ia]), Int(nameLen[ia]), names + Int(nameOff[ib]), Int(nameLen[ib]))
        return c
    }

    @inline(__always)
    func parentRank(_ id: UInt32) -> UInt32 {
        let p = parent[Int(id)]
        return p == kNoEntry ? 0 : folderRank[Int(p)]
    }

    /// Full name ordering with a deterministic location tie-break.
    @inline(__always)
    public func compareName(_ a: UInt32, _ b: UInt32) -> Int {
        let c = compareNameKeys(a, b)
        if c != 0 { return c }
        let ra = parentRank(a), rb = parentRank(b)
        if ra != rb { return ra < rb ? -1 : 1 }
        return a == b ? 0 : (a < b ? -1 : 1)
    }

    @inline(__always)
    func extKey(_ id: UInt32) -> (UnsafePointer<UInt8>, Int) {
        let i = Int(id)
        if flags[i] & EntryFlag.directory != 0 { return (UnsafePointer(names), 0) }
        let p = UnsafePointer(names + Int(nameOff[i]))
        let n = Int(nameLen[i])
        var j = n - 1
        while j > 0 {
            if p[j] == 46 { return (p + j + 1, n - j - 1) }
            j -= 1
        }
        return (p + n, 0)
    }

    public func compare(_ key: SortKey, _ a: UInt32, _ b: UInt32) -> Int {
        let ia = Int(a), ib = Int(b)
        switch key {
        case .name:
            return compareName(a, b)
        case .path:
            let ra = parentRank(a), rb = parentRank(b)
            if ra != rb { return ra < rb ? -1 : 1 }
            return compareName(a, b)
        case .size:
            let x = size[ia], y = size[ib]
            if x != y { return x < y ? -1 : 1 }
            return compareName(a, b)
        case .dateModified:
            let x = mtime[ia], y = mtime[ib]
            if x != y { return x < y ? -1 : 1 }
            return compareName(a, b)
        case .dateCreated:
            let x = ctime[ia], y = ctime[ib]
            if x != y { return x < y ? -1 : 1 }
            return compareName(a, b)
        case .dateAccessed:
            let x = atime[ia], y = atime[ib]
            if x != y { return x < y ? -1 : 1 }
            return compareName(a, b)
        case .dateRecentlyChanged:
            let x = rctime[ia], y = rctime[ib]
            if x != y { return x < y ? -1 : 1 }
            return compareName(a, b)
        case .attributes:
            let x = flags[ia] & EntryFlag.attributeMask, y = flags[ib] & EntryFlag.attributeMask
            if x != y { return x < y ? -1 : 1 }
            return compareName(a, b)
        case .ext:
            let (pa, la) = extKey(a), (pb, lb) = extKey(b)
            let c = Fold.compareCI(pa, la, pb, lb)
            if c != 0 { return c }
            return compareName(a, b)
        default:
            return compareName(a, b)
        }
    }

    public func lessFunction(_ key: SortKey) -> (UInt32, UInt32) -> Bool {
        let o = self
        switch key {
        case .name: return { o.compareName($0, $1) < 0 }
        case .path: return { a, b in
            let ra = o.parentRank(a), rb = o.parentRank(b)
            if ra != rb { return ra < rb }
            return o.compareName(a, b) < 0
        }
        case .size: return { a, b in
            let x = o.size[Int(a)], y = o.size[Int(b)]
            if x != y { return x < y }
            return o.compareName(a, b) < 0
        }
        case .dateModified: return { a, b in
            let x = o.mtime[Int(a)], y = o.mtime[Int(b)]
            if x != y { return x < y }
            return o.compareName(a, b) < 0
        }
        default:
            return { o.compare(key, $0, $1) < 0 }
        }
    }
}
