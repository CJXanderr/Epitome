import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Saves and loads the index so start-up doesn't need a rescan.
///
/// Layout (little endian):
///   "EPITOMEDB" 0x00, u32 version, u32 headerLength, header JSON,
///   then column blocks: nameLen u16[n], parent u32[n], flags u32[n],
///   size/mtime/ctime/atime/rctime i64[n] each, names u8[nameBytes],
///   then one u32[n] block per saved sort order.
/// Deleted entries are dropped on save (IDs are compacted).
public enum Database {
    public static let version: UInt32 = 3
    static let magic: [UInt8] = Array("EPITOMEDB".utf8) + [0]

    struct Header: Codable {
        var version: UInt32
        var count: Int
        var nameBytes: Int
        var saved: Double
        var roots: [RootRecord]
        var orders: [String]
        var folderSizes: Bool
    }

    struct RootRecord: Codable {
        var id: UInt32
        var info: SourceInfo
    }

    public enum DBError: Error, CustomStringConvertible {
        case io(String), format(String)
        public var description: String {
            switch self {
            case .io(let s): return "I/O error: \(s)"
            case .format(let s): return "Bad database: \(s)"
            }
        }
    }

    /// Writes `index` to `url` atomically. Takes the read lock while copying.
    public static func save(_ index: FileIndex, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        guard let f = fopen(tmp.path, "wb") else { throw DBError.io("cannot create \(tmp.path)") }
        var ok = true
        defer { if !ok { unlink(tmp.path) } }
        do {
            try index.lock.read {
                let map = index.compactionMap()
                let n = index.liveCount
                var nameBytes = 0
                for i in 0..<index.count where map[i] != kNoEntry { nameBytes += Int(index.nameLen[i]) }
                var roots: [RootRecord] = []
                for r in index.roots where !index.isDeleted(r) {
                    if let s = index.sources[r] { roots.append(RootRecord(id: map[Int(r)], info: s)) }
                }
                let orderKeys = index.orders.keys.map(\.rawValue).sorted()
                let header = Header(version: version, count: n, nameBytes: nameBytes, saved: Date().timeIntervalSince1970,
                                    roots: roots, orders: orderKeys, folderSizes: index.folderSizesEnabled)
                let json = try JSONEncoder().encode(header)
                var w = Writer(f)
                w.bytes(magic)
                w.u32(version)
                w.u32(UInt32(json.count))
                json.withUnsafeBytes { w.raw($0.baseAddress!, $0.count) }

                let total = index.count
                func column<T>(_ col: PODArray<T>, _ transform: ((T) -> T)? = nil) {
                    var chunk = [T]()
                    chunk.reserveCapacity(65_536)
                    for i in 0..<total where map[i] != kNoEntry {
                        chunk.append(transform?(col[i]) ?? col[i])
                        if chunk.count == 65_536 {
                            chunk.withUnsafeBytes { w.raw($0.baseAddress!, $0.count) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { chunk.withUnsafeBytes { w.raw($0.baseAddress!, $0.count) } }
                }
                column(index.nameLen)
                column(index.parent) { p in p == kNoEntry ? kNoEntry : map[Int(p)] }
                column(index.flags) { $0 & ~(EntryFlag.nonASCII) }
                column(index.size)
                column(index.mtime)
                column(index.ctime)
                column(index.atime)
                column(index.rctime)
                for i in 0..<total where map[i] != kNoEntry {
                    let nb = index.nameBytes(EntryID(i))
                    if nb.count > 0 { w.raw(UnsafeRawPointer(nb.baseAddress!), nb.count) }
                }
                for k in orderKeys {
                    guard let key = SortKey(rawValue: k), let ord = index.orders[key] else { continue }
                    var chunk = [UInt32]()
                    chunk.reserveCapacity(65_536)
                    var written = 0
                    for j in 0..<ord.count {
                        let m = map[Int(ord[j])]
                        if m == kNoEntry { continue }
                        chunk.append(m)
                        written += 1
                        if chunk.count == 65_536 {
                            chunk.withUnsafeBytes { w.raw($0.baseAddress!, $0.count) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { chunk.withUnsafeBytes { w.raw($0.baseAddress!, $0.count) } }
                    // pad so the block always has n entries
                    while written < n { w.u32(kNoEntry); written += 1 }
                }
                if w.failed { throw DBError.io("write failed") }
            }
        } catch {
            ok = false
            fclose(f)
            throw error
        }
        fflush(f)
        fsync(fileno(f))
        fclose(f)
        if rename(tmp.path, url.path) != 0 { ok = false; throw DBError.io("rename failed") }
    }

    /// Loads an index saved by `save`. Returns nil if the file does not exist.
    public static func load(from url: URL) throws -> FileIndex? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let f = fopen(url.path, "rb") else { throw DBError.io("cannot open \(url.path)") }
        defer { fclose(f) }
        let r = Reader(f)
        let m = r.bytes(magic.count)
        guard m == magic else { throw DBError.format("not an Epitome database") }
        let v = r.u32()
        guard v == version else { throw DBError.format("unsupported version \(v)") }
        let hl = Int(r.u32())
        guard hl > 0, hl < 64 << 20 else { throw DBError.format("bad header") }
        let hdata = Data(r.bytes(hl))
        let header = try JSONDecoder().decode(Header.self, from: hdata)
        let n = header.count
        guard n >= 0, n < 0x7FFF_FFFF else { throw DBError.format("bad count") }

        let nameLen = PODArray<UInt16>(capacity: n); nameLen.resizeUninitialized(n)
        let parent = PODArray<UInt32>(capacity: n); parent.resizeUninitialized(n)
        let flags = PODArray<UInt32>(capacity: n); flags.resizeUninitialized(n)
        let size = PODArray<Int64>(capacity: n); size.resizeUninitialized(n)
        let mt = PODArray<Int64>(capacity: n); mt.resizeUninitialized(n)
        let ct = PODArray<Int64>(capacity: n); ct.resizeUninitialized(n)
        let at = PODArray<Int64>(capacity: n); at.resizeUninitialized(n)
        let rc = PODArray<Int64>(capacity: n); rc.resizeUninitialized(n)
        let names = ByteArena(capacity: header.nameBytes); names.resizeUninitialized(header.nameBytes)
        guard r.into(nameLen.base, n * 2), r.into(parent.base, n * 4), r.into(flags.base, n * 4),
              r.into(size.base, n * 8), r.into(mt.base, n * 8), r.into(ct.base, n * 8),
              r.into(at.base, n * 8), r.into(rc.base, n * 8), r.into(names.base, header.nameBytes)
        else { throw DBError.format("truncated") }

        let index = FileIndex()
        index.folderSizesEnabled = header.folderSizes
        var off = 0
        let nb = names.base
        for i in 0..<n {
            let len = Int(nameLen[i])
            guard off + len <= header.nameBytes else { throw DBError.format("name overflow") }
            let p = parent[i]
            guard p == kNoEntry || Int(p) < n else { throw DBError.format("bad parent") }
            index.loadAppend(parent: p, name: nb + off, length: len, flags: flags[i], size: size[i],
                             mtime: mt[i], ctime: ct[i], atime: at[i], rctime: rc[i])
            off += len
        }
        for root in header.roots where Int(root.id) < n {
            index.loadRoot(root.id, root.info)
        }
        index.finishLoad()
        var keys = Set<SortKey>()
        for k in header.orders {
            let arr = PODArray<UInt32>(capacity: n)
            arr.resizeUninitialized(n)
            guard r.into(arr.base, n * 4) else { break }
            guard let key = SortKey(rawValue: k) else { continue }
            // validate
            var valid = true
            for j in 0..<n where arr[j] == kNoEntry || Int(arr[j]) >= n { valid = false; break }
            if valid { index.installOrder(key, arr); keys.insert(key) }
        }
        index.maintainedOrders = keys.union([.name])
        index.clearBatchStateAfterLoad()
        // Build any order that wasn't stored.
        let missing = index.maintainedOrders.filter { index.orders[$0] == nil }
        if !missing.isEmpty { index.rebuildOrders() }
        return index
    }

    // MARK: - Buffered I/O

    struct Writer {
        let f: UnsafeMutablePointer<FILE>
        var failed = false
        init(_ f: UnsafeMutablePointer<FILE>) { self.f = f }
        mutating func raw(_ p: UnsafeRawPointer, _ n: Int) {
            if n == 0 { return }
            if fwrite(p, 1, n, f) != n { failed = true }
        }
        mutating func bytes(_ b: [UInt8]) { b.withUnsafeBytes { raw($0.baseAddress!, $0.count) } }
        mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { raw($0.baseAddress!, 4) } }
    }

    struct Reader {
        let f: UnsafeMutablePointer<FILE>
        init(_ f: UnsafeMutablePointer<FILE>) { self.f = f }
        func bytes(_ n: Int) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: n)
            let got = b.withUnsafeMutableBytes { fread($0.baseAddress!, 1, n, f) }
            return got == n ? b : []
        }
        func u32() -> UInt32 {
            var x: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &x) { fread($0.baseAddress!, 1, 4, f) }
            return UInt32(littleEndian: x)
        }
        func into<T>(_ p: UnsafeMutablePointer<T>, _ bytes: Int) -> Bool {
            if bytes == 0 { return true }
            return fread(UnsafeMutableRawPointer(p), 1, bytes, f) == bytes
        }
    }
}
