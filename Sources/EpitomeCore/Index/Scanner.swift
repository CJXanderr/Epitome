import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What to skip while walking a volume or folder.
public struct ScanOptions: Sendable {
    /// Absolute folder paths (may contain wildcards) or folder-name patterns.
    public var excludeFolders: [String] = []
    /// File-name wildcard patterns to leave out.
    public var excludeFiles: [String] = []
    /// When non-empty, only files matching one of these are indexed.
    public var includeOnlyFiles: [String] = []
    public var excludeHidden = false
    public var excludeSystem = false
    public var indexAccessTime = false
    public var crossMountPoints = false
    public var indexPackageContents = true
    /// Worker threads (0 = automatic).
    public var threads = 0

    public init() {}
}

/// Pre-compiled exclusion rules.
public struct ScanFilter: Sendable {
    let absolute: [[UInt8]]                 // lower-cased absolute paths without wildcards
    let absolutePatterns: [WildcardPattern] // absolute paths with wildcards
    let folderNames: [WildcardPattern]
    let files: [WildcardPattern]
    let includeOnly: [WildcardPattern]
    public let options: ScanOptions

    public init(_ o: ScanOptions) {
        options = o
        var abs: [[UInt8]] = []
        var absPat: [WildcardPattern] = []
        var names: [WildcardPattern] = []
        for raw in o.excludeFolders {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            if s.hasPrefix("~") { s = (s as NSString).expandingTildeInPath }
            if s.hasPrefix("/") {
                if Wildcard.hasWildcards(s) { absPat.append(WildcardPattern(s)) } else { abs.append(Fold.fold(s, caseSensitive: false, diacriticSensitive: true)) }
            } else {
                names.append(WildcardPattern(s))
            }
        }
        absolute = abs
        absolutePatterns = absPat
        folderNames = names
        files = o.excludeFiles.flatMap { WildcardPattern.list($0) }
        includeOnly = o.includeOnlyFiles.flatMap { WildcardPattern.list($0) }
    }

    public var isTrivial: Bool {
        absolute.isEmpty && absolutePatterns.isEmpty && folderNames.isEmpty && files.isEmpty && includeOnly.isEmpty &&
            !options.excludeHidden && !options.excludeSystem
    }

    @inline(__always)
    func excludesFolder(path: UnsafePointer<UInt8>, _ pn: Int, name: UnsafePointer<UInt8>, _ nn: Int) -> Bool {
        for p in folderNames where p.matches(name, nn) { return true }
        if absolute.isEmpty && absolutePatterns.isEmpty { return false }
        for a in absolute where a.count == pn {
            if a.withUnsafeBufferPointer({ Fold.compareCI($0.baseAddress!, $0.count, path, pn) == 0 }) { return true }
        }
        for p in absolutePatterns where p.matches(path, pn) { return true }
        return false
    }

    public func excludesFolder(path: String) -> Bool {
        var p = path
        let name = (path as NSString).lastPathComponent
        var nm = name
        return p.withUTF8 { pb in nm.withUTF8 { nb in
            excludesFolder(path: pb.baseAddress ?? UnsafePointer(bitPattern: 1)!, pb.count,
                           name: nb.baseAddress ?? UnsafePointer(bitPattern: 1)!, nb.count)
        } }
    }

    @inline(__always)
    func excludesFile(name: UnsafePointer<UInt8>, _ nn: Int) -> Bool {
        for p in files where p.matches(name, nn) { return true }
        if !includeOnly.isEmpty {
            for p in includeOnly where p.matches(name, nn) { return false }
            return true
        }
        return false
    }

    public func excludesFile(name: String) -> Bool {
        var n = name
        return n.withUTF8 { excludesFile(name: $0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
    }

    @inline(__always)
    func excludesByFlags(_ f: UInt32) -> Bool {
        if options.excludeHidden && f & EntryFlag.hidden != 0 { return true }
        if options.excludeSystem && f & EntryFlag.system != 0 { return true }
        return false
    }

    /// Full check used by live updates.
    public func excludes(path: String, name: String, meta: EntryMeta) -> Bool {
        if excludesByFlags(meta.flags) { return true }
        if meta.isDirectory { return excludesFolder(path: path) }
        return excludesFile(name: name)
    }
}

/// Entries produced by one scanner worker. Parent references point either at
/// the scan root (`rootRef`) or at (worker << 32 | local index).
public final class ScanBuffer: @unchecked Sendable {
    public static let rootRef: UInt64 = .max

    public let parentRef = PODArray<UInt64>(capacity: 1 << 12)
    public let nameOff = PODArray<UInt32>(capacity: 1 << 12)
    public let nameLen = PODArray<UInt16>(capacity: 1 << 12)
    public let names = ByteArena(capacity: 1 << 16)
    public let flags = PODArray<UInt32>(capacity: 1 << 12)
    public let size = PODArray<Int64>(capacity: 1 << 12)
    public let mtime = PODArray<Int64>(capacity: 1 << 12)
    public let ctime = PODArray<Int64>(capacity: 1 << 12)
    public let atime = PODArray<Int64>(capacity: 1 << 12)

    public init() {}

    public var count: Int { parentRef.count }

    @inline(__always)
    @discardableResult
    func append(parentRef r: UInt64, name: UnsafePointer<UInt8>, length n: Int, meta: EntryMeta) -> Int {
        let idx = parentRef.count
        parentRef.append(r)
        nameOff.append(UInt32(truncatingIfNeeded: names.count))
        nameLen.append(UInt16(truncatingIfNeeded: n))
        names.append(name, count: n)
        flags.append(meta.flags)
        size.append(meta.size)
        mtime.append(meta.mtime)
        ctime.append(meta.ctime)
        atime.append(meta.atime)
        return idx
    }
}

public final class ScanResult: @unchecked Sendable {
    public let buffers: [ScanBuffer]
    public var rootMeta: EntryMeta?
    public var errors = 0
    public var cancelled = false
    public var seconds: Double = 0

    init(buffers: [ScanBuffer]) { self.buffers = buffers }

    public var count: Int { buffers.reduce(0) { $0 + $1.count } }
}

/// One listed directory entry.
public struct ListedEntry {
    public var name: String
    public var meta: EntryMeta
    public var isMountPoint: Bool
}

// MARK: - Package (bundle) folders

public enum Packages {
    static let extensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "kext", "xpc", "prefpane", "saver", "qlgenerator",
        "mdimporter", "component", "vst", "vst3", "aaxplugin", "photoslibrary", "photolibrary", "musiclibrary",
        "tvlibrary", "fcpbundle", "logicx", "band", "rtfd", "pages", "numbers", "key", "xcodeproj",
        "xcworkspace", "playground", "dsym", "docset", "scptd", "workflow", "action", "sparsebundle",
        "mpkg", "pkg", "lproj_none", "wdgt", "systemextension", "driver", "imovielibrary", "theater",
    ]

    @inline(__always)
    static func isPackage(_ name: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var j = n - 1
        while j > 0 && name[j] != 46 { j -= 1 }
        guard j > 0, n - j - 1 <= 16, n - j - 1 >= 2 else { return false }
        var ext = [UInt8]()
        ext.reserveCapacity(n - j - 1)
        for k in (j + 1)..<n { ext.append(Fold.lower[Int(name[k])]) }
        return extensions.contains(String(decoding: ext, as: UTF8.self))
    }
}

// MARK: - Platform directory listing

#if os(macOS)

private let kATTR_CMN_NAME: UInt32 = 0x0000_0001
private let kATTR_CMN_OBJTYPE: UInt32 = 0x0000_0008
private let kATTR_CMN_CRTIME: UInt32 = 0x0000_0200
private let kATTR_CMN_MODTIME: UInt32 = 0x0000_0400
private let kATTR_CMN_ACCTIME: UInt32 = 0x0000_1000
private let kATTR_CMN_ACCESSMASK: UInt32 = 0x0002_0000
private let kATTR_CMN_FLAGS: UInt32 = 0x0004_0000
private let kATTR_CMN_ERROR: UInt32 = 0x2000_0000
private let kATTR_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
private let kATTR_DIR_MOUNTSTATUS: UInt32 = 0x0000_0004
private let kATTR_FILE_DATALENGTH: UInt32 = 0x0000_0200
private let kDIR_MNTSTATUS_MNTPOINT: UInt32 = 0x0000_0001
private let kDIR_MNTSTATUS_TRIGGER: UInt32 = 0x0000_0002
private let kVREG: UInt32 = 1
private let kVDIR: UInt32 = 2
private let kVLNK: UInt32 = 5

// BSD file flags
let kUF_IMMUTABLE: UInt32 = 0x0000_0002
let kUF_COMPRESSED: UInt32 = 0x0000_0020
let kUF_HIDDEN: UInt32 = 0x0000_8000
let kSF_ARCHIVED: UInt32 = 0x0001_0000
let kSF_IMMUTABLE: UInt32 = 0x0002_0000
let kSF_RESTRICTED: UInt32 = 0x0008_0000
let kSF_DATALESS: UInt32 = 0x4000_0000

@inline(__always)
func attributeFlags(objType: UInt32, bsd: UInt32, mode: UInt32, name: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
    var f: UInt32 = 0
    if objType == kVDIR { f |= EntryFlag.directory } else if objType == kVLNK { f |= EntryFlag.symlink }
    if bsd & kUF_HIDDEN != 0 || (n > 0 && name[0] == 46) { f |= EntryFlag.hidden }
    if bsd & kSF_RESTRICTED != 0 { f |= EntryFlag.system }
    if bsd & (kUF_IMMUTABLE | kSF_IMMUTABLE) != 0 || mode & 0o200 == 0 { f |= EntryFlag.readOnly }
    if bsd & kSF_ARCHIVED != 0 { f |= EntryFlag.archive }
    if bsd & kUF_COMPRESSED != 0 { f |= EntryFlag.compressed }
    if bsd & kSF_DATALESS != 0 { f |= EntryFlag.offline }
    if objType == kVREG && mode & 0o111 != 0 { f |= EntryFlag.executable }
    if objType == kVDIR && Packages.isPackage(name, n) { f |= EntryFlag.package }
    return f
}

/// Directory lister built on getattrlistbulk(2): one syscall returns the
/// names and metadata of many entries.
final class DirectoryLister {
    private let bufSize = 256 * 1024
    private let buf: UnsafeMutableRawPointer
    private var attrs = attrlist()
    private let wantAccess: Bool

    init(indexAccessTime: Bool) {
        wantAccess = indexAccessTime
        buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        attrs.bitmapcount = 5
        var common = kATTR_CMN_RETURNED_ATTRS | kATTR_CMN_NAME | kATTR_CMN_ERROR | kATTR_CMN_OBJTYPE |
            kATTR_CMN_CRTIME | kATTR_CMN_MODTIME | kATTR_CMN_ACCESSMASK | kATTR_CMN_FLAGS
        if indexAccessTime { common |= kATTR_CMN_ACCTIME }
        attrs.commonattr = common
        attrs.dirattr = kATTR_DIR_MOUNTSTATUS
        attrs.fileattr = kATTR_FILE_DATALENGTH
    }

    deinit { buf.deallocate() }

    /// Calls `body(namePtr, nameLen, meta, isMountPoint)` per entry. Returns 0 or errno.
    @inline(__always)
    func list(_ path: UnsafePointer<CChar>,
              _ body: (UnsafePointer<UInt8>, Int, EntryMeta, Bool) -> Void) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return errno }
        defer { close(fd) }
        while true {
            let n = getattrlistbulk(fd, &attrs, buf, bufSize, 0)
            if n < 0 { return errno }
            if n == 0 { break }
            var entry = UnsafeRawPointer(buf)
            for _ in 0..<Int(n) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let rCommon = field.loadUnaligned(as: UInt32.self)
                let rDir = field.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
                let rFile = field.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                field += 20
                var err: UInt32 = 0
                if rCommon & kATTR_CMN_ERROR != 0 { err = field.loadUnaligned(as: UInt32.self); field += 4 }
                var namePtr: UnsafePointer<UInt8>? = nil
                var nameLen = 0
                if rCommon & kATTR_CMN_NAME != 0 {
                    let off = Int(field.loadUnaligned(as: Int32.self))
                    let len = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                    namePtr = (field + off).assumingMemoryBound(to: UInt8.self)
                    nameLen = Swift.max(0, len - 1)
                    field += 8
                }
                var objType: UInt32 = 0
                if rCommon & kATTR_CMN_OBJTYPE != 0 { objType = field.loadUnaligned(as: UInt32.self); field += 4 }
                var ct = kUnknownTime, mt = kUnknownTime, at = kUnknownTime
                if rCommon & kATTR_CMN_CRTIME != 0 {
                    ct = Int64(field.loadUnaligned(as: Int.self)) &* 1_000_000_000 &+ Int64(field.loadUnaligned(fromByteOffset: 8, as: Int.self))
                    field += 16
                }
                if rCommon & kATTR_CMN_MODTIME != 0 {
                    mt = Int64(field.loadUnaligned(as: Int.self)) &* 1_000_000_000 &+ Int64(field.loadUnaligned(fromByteOffset: 8, as: Int.self))
                    field += 16
                }
                if rCommon & kATTR_CMN_ACCTIME != 0 {
                    at = Int64(field.loadUnaligned(as: Int.self)) &* 1_000_000_000 &+ Int64(field.loadUnaligned(fromByteOffset: 8, as: Int.self))
                    field += 16
                }
                var mode: UInt32 = 0o644
                if rCommon & kATTR_CMN_ACCESSMASK != 0 { mode = field.loadUnaligned(as: UInt32.self); field += 4 }
                var bsd: UInt32 = 0
                if rCommon & kATTR_CMN_FLAGS != 0 { bsd = field.loadUnaligned(as: UInt32.self); field += 4 }
                var mount: UInt32 = 0
                if rDir & kATTR_DIR_MOUNTSTATUS != 0 { mount = field.loadUnaligned(as: UInt32.self); field += 4 }
                var dataLen: Int64 = kUnknownSize
                if rFile & kATTR_FILE_DATALENGTH != 0 { dataLen = field.loadUnaligned(as: Int64.self); field += 8 }

                if err == 0, let np = namePtr, nameLen > 0 {
                    let f = attributeFlags(objType: objType, bsd: bsd, mode: mode, name: np, nameLen)
                    let isDir = f & EntryFlag.directory != 0
                    let meta = EntryMeta(flags: f, size: isDir ? kUnknownSize : Swift.max(0, dataLen),
                                         mtime: mt, ctime: ct, atime: at)
                    body(np, nameLen, meta, isDir && mount & (kDIR_MNTSTATUS_MNTPOINT | kDIR_MNTSTATUS_TRIGGER) != 0)
                }
                entry += length
            }
        }
        return 0
    }
}

/// lstat-based metadata for a single path (live updates).
public func statEntry(_ path: String) -> (EntryMeta, Int32)? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    let name = (path as NSString).lastPathComponent
    var nm = name
    let objType: UInt32
    switch st.st_mode & S_IFMT {
    case S_IFDIR: objType = kVDIR
    case S_IFLNK: objType = kVLNK
    case S_IFREG: objType = kVREG
    default: objType = 0
    }
    let f = nm.withUTF8 { attributeFlags(objType: objType, bsd: st.st_flags, mode: UInt32(st.st_mode), name: $0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
    let isDir = f & EntryFlag.directory != 0
    func ns(_ t: timespec) -> Int64 { Int64(t.tv_sec) &* 1_000_000_000 &+ Int64(t.tv_nsec) }
    let meta = EntryMeta(flags: f, size: isDir ? kUnknownSize : Int64(st.st_size),
                         mtime: ns(st.st_mtimespec), ctime: ns(st.st_birthtimespec), atime: ns(st.st_atimespec))
    return (meta, Int32(bitPattern: UInt32(st.st_dev)))
}

#else

/// Portable lister (Linux): readdir + fstatat. Used for tests and the CLI on Linux.
final class DirectoryLister {
    private let wantAccess: Bool
    init(indexAccessTime: Bool) { wantAccess = indexAccessTime }

    func list(_ path: UnsafePointer<CChar>,
              _ body: (UnsafePointer<UInt8>, Int, EntryMeta, Bool) -> Void) -> Int32 {
        guard let dir = opendir(path) else { return errno }
        defer { closedir(dir) }
        let dfd = dirfd(dir)
        var parentStat = stat()
        fstat(dfd, &parentStat)
        while let ent = readdir(dir) {
            var nameTuple = ent.pointee.d_name
            let handled: Void = withUnsafePointer(to: &nameTuple) { tp in
                tp.withMemoryRebound(to: UInt8.self, capacity: 256) { np in
                    let n = strlen(UnsafeRawPointer(np).assumingMemoryBound(to: CChar.self))
                    if n == 0 || (n == 1 && np[0] == 46) || (n == 2 && np[0] == 46 && np[1] == 46) { return }
                    var st = stat()
                    if fstatat(dfd, UnsafeRawPointer(np).assumingMemoryBound(to: CChar.self), &st, AT_SYMLINK_NOFOLLOW) != 0 { return }
                    let meta = linuxMeta(st, np, n)
                    let isMount = meta.isDirectory && st.st_dev != parentStat.st_dev
                    body(np, n, meta, isMount)
                }
            }
            _ = handled
        }
        return 0
    }
}

func linuxMeta(_ st: stat, _ name: UnsafePointer<UInt8>, _ n: Int) -> EntryMeta {
    var f: UInt32 = 0
    let fmt = st.st_mode & S_IFMT
    if fmt == S_IFDIR { f |= EntryFlag.directory } else if fmt == S_IFLNK { f |= EntryFlag.symlink }
    if n > 0 && name[0] == 46 { f |= EntryFlag.hidden }
    if st.st_mode & 0o200 == 0 { f |= EntryFlag.readOnly }
    if fmt == S_IFREG && st.st_mode & 0o111 != 0 { f |= EntryFlag.executable }
    if fmt == S_IFDIR && Packages.isPackage(name, n) { f |= EntryFlag.package }
    func ns(_ t: timespec) -> Int64 { Int64(t.tv_sec) &* 1_000_000_000 &+ Int64(t.tv_nsec) }
    let isDir = fmt == S_IFDIR
    return EntryMeta(flags: f, size: isDir ? kUnknownSize : Int64(st.st_size),
                     mtime: ns(st.st_mtim), ctime: ns(st.st_ctim), atime: ns(st.st_atim))
}

public func statEntry(_ path: String) -> (EntryMeta, Int32)? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    var name = (path as NSString).lastPathComponent
    let meta = name.withUTF8 { linuxMeta(st, $0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
    return (meta, Int32(truncatingIfNeeded: st.st_dev))
}

#endif

/// lstat() result code for a path: 0 when it exists, else errno (ENOENT, EACCES …).
public func lstatErrno(_ path: String) -> Int32 {
    var st = stat()
    if lstat(path, &st) == 0 { return 0 }
    return errno
}

/// Lists one directory (used to reconcile a folder against the index).
public func listDirectory(_ path: String, indexAccessTime: Bool = false) -> (entries: [ListedEntry], error: Int32) {
    let lister = DirectoryLister(indexAccessTime: indexAccessTime)
    var out: [ListedEntry] = []
    let err = path.withCString { cp in
        lister.list(cp) { np, n, meta, mount in
            out.append(ListedEntry(name: String(decoding: UnsafeBufferPointer(start: np, count: n), as: UTF8.self),
                                   meta: meta, isMountPoint: mount))
        }
    }
    return (out, err)
}

// MARK: - Parallel scanner

/// Walks a directory tree with several threads and returns the entries in
/// per-worker buffers (merged into the index by `FileIndex.importScan`).
public final class ParallelScanner: @unchecked Sendable {
    public let filter: ScanFilter

    public init(options: ScanOptions) {
        filter = ScanFilter(options)
    }

    private struct Task {
        var path: [UInt8] // NUL-terminated
        var ref: UInt64
    }

    private final class Queue: @unchecked Sendable {
        let cond = Condition()
        var stack: [Task] = []
        var active = 0
    }

    /// Scans everything below `root` (the root itself is not included).
    public func scan(root: String, progress: AtomicCounter? = nil, cancel: CancelToken? = nil) -> ScanResult {
        let started = Clock.now
        let o = filter.options
        let workers = o.threads > 0 ? o.threads : Swift.max(2, Swift.min(16, Parallel.coreCount * 2))
        let buffers = (0..<workers).map { _ in ScanBuffer() }
        let result = ScanResult(buffers: buffers)
        if let (meta, _) = statEntry(root) { result.rootMeta = meta }
        let q = Queue()
        var rootBytes = Array(root.utf8)
        while rootBytes.count > 1 && rootBytes.last == 47 { rootBytes.removeLast() }
        rootBytes.append(0)
        q.stack.append(Task(path: rootBytes, ref: ScanBuffer.rootRef))
        let errors = AtomicCounter()
        let filter = self.filter
        let trivial = filter.isTrivial

        DispatchQueue.concurrentPerform(iterations: workers) { w in
            let lister = DirectoryLister(indexAccessTime: o.indexAccessTime)
            let buf = buffers[w]
            var newTasks: [Task] = []
            var childPath = [UInt8]()
            childPath.reserveCapacity(1024)
            var sinceReport = 0
            while true {
                q.cond.mutex.lock()
                while q.stack.isEmpty && q.active > 0 { q.cond.wait() }
                if q.stack.isEmpty || (cancel?.isCancelled ?? false) {
                    q.cond.broadcast()
                    q.cond.mutex.unlock()
                    break
                }
                let task = q.stack.removeLast()
                q.active += 1
                q.cond.mutex.unlock()

                newTasks.removeAll(keepingCapacity: true)
                let parentLen = task.path.count - 1
                let isSlashRoot = parentLen == 1 && task.path[0] == 47
                let before = buf.count
                let err: Int32 = task.path.withUnsafeBufferPointer { pp in
                    let cpath = UnsafeRawPointer(pp.baseAddress!).assumingMemoryBound(to: CChar.self)
                    return lister.list(cpath) { np, n, meta, isMount in
                        if !trivial && filter.excludesByFlags(meta.flags) { return }
                        if meta.isDirectory {
                            if isMount && !o.crossMountPoints { return }
                            childPath.removeAll(keepingCapacity: true)
                            if !isSlashRoot { childPath.append(contentsOf: pp[0..<parentLen]) }
                            childPath.append(47)
                            childPath.append(contentsOf: UnsafeBufferPointer(start: np, count: n))
                            if !trivial {
                                let excluded = childPath.withUnsafeBufferPointer { cb in
                                    filter.excludesFolder(path: cb.baseAddress!, cb.count, name: np, n)
                                }
                                if excluded { return }
                            }
                            let li = buf.append(parentRef: task.ref, name: np, length: n, meta: meta)
                            if meta.flags & EntryFlag.package != 0 && !o.indexPackageContents { return }
                            childPath.append(0)
                            newTasks.append(Task(path: childPath, ref: (UInt64(w) << 32) | UInt64(li)))
                        } else {
                            if !trivial && filter.excludesFile(name: np, n) { return }
                            buf.append(parentRef: task.ref, name: np, length: n, meta: meta)
                        }
                    }
                }
                if err != 0 { errors.add(1) }
                sinceReport += buf.count - before
                if sinceReport > 4096 { progress?.add(sinceReport); sinceReport = 0 }

                q.cond.mutex.lock()
                q.active -= 1
                if !newTasks.isEmpty { q.stack.append(contentsOf: newTasks.reversed()) }
                if !newTasks.isEmpty || (q.stack.isEmpty && q.active == 0) { q.cond.broadcast() }
                q.cond.mutex.unlock()
            }
            if sinceReport > 0 { progress?.add(sinceReport) }
        }
        result.errors = errors.value
        result.cancelled = cancel?.isCancelled ?? false
        result.seconds = Clock.now - started
        return result
    }
}
