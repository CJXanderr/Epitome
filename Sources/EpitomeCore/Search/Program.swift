import Foundation

/// Three-valued result used when some predicates (content, media properties)
/// are evaluated in a second pass outside the index lock.
public enum Tri: UInt8 { case no, yes, maybe }

/// Raw-pointer snapshot of the index columns used by the evaluator.
/// Valid only while the caller holds the index read lock.
public struct IndexView {
    public let count: Int
    let nameOff: UnsafeMutablePointer<UInt32>
    let nameLen: UnsafeMutablePointer<UInt16>
    public let parent: UnsafeMutablePointer<UInt32>
    public let flags: UnsafeMutablePointer<UInt32>
    let keyOff: UnsafeMutablePointer<UInt32>
    public let size: UnsafeMutablePointer<Int64>
    public let mtime: UnsafeMutablePointer<Int64>
    public let ctime: UnsafeMutablePointer<Int64>
    public let atime: UnsafeMutablePointer<Int64>
    public let rctime: UnsafeMutablePointer<Int64>
    let firstChild: UnsafeMutablePointer<UInt32>
    let nextSibling: UnsafeMutablePointer<UInt32>
    let names: UnsafeMutablePointer<UInt8>
    let keys: UnsafeMutablePointer<UInt8>
    let rootIDs: [UInt32]
    let rootPrefix: [[[UInt8]]]
    public unowned let index: FileIndex

    public init(_ ix: FileIndex) {
        index = ix
        count = ix.count
        nameOff = ix.nameOff.base
        nameLen = ix.nameLen.base
        parent = ix.parent.base
        flags = ix.flags.base
        keyOff = ix.keyOff.base
        size = ix.size.base
        mtime = ix.mtime.base
        ctime = ix.ctime.base
        atime = ix.atime.base
        rctime = ix.rctime.base
        firstChild = ix.firstChild.base
        nextSibling = ix.nextSibling.base
        names = ix.names.base
        keys = ix.keys.base
        var ids: [UInt32] = []
        var pref: [[[UInt8]]] = []
        for r in ix.roots {
            ids.append(r)
            pref.append([ix.rootPrefixBytes(r, variant: nil), ix.rootPrefixBytes(r, variant: .cs),
                         ix.rootPrefixBytes(r, variant: .ci), ix.rootPrefixBytes(r, variant: .csdi),
                         ix.rootPrefixBytes(r, variant: .cidi)])
        }
        rootIDs = ids
        rootPrefix = pref
    }

    @inline(__always)
    public func key(_ i: Int, _ v: KeyVariant) -> (UnsafePointer<UInt8>, Int) {
        if flags[i] & EntryFlag.nonASCII == 0 {
            return (UnsafePointer(names + Int(nameOff[i])), Int(nameLen[i]))
        }
        return FileIndex.keyVariant(keys + Int(keyOff[i]), v)
    }

    @inline(__always)
    public func rawName(_ i: Int) -> (UnsafePointer<UInt8>, Int) {
        (UnsafePointer(names + Int(nameOff[i])), Int(nameLen[i]))
    }

    @inline(__always)
    public func isDir(_ i: Int) -> Bool { flags[i] & EntryFlag.directory != 0 }

    public func rootSlot(_ root: UInt32) -> Int {
        for (k, r) in rootIDs.enumerated() where r == root { return k }
        return -1
    }

    /// Appends the full path of `id`, folding components with `v` (nil = display bytes).
    @inline(__always)
    public func appendPath(_ id: Int, _ v: KeyVariant?, _ buf: inout ByteBuf, _ chain: UnsafeMutablePointer<UInt32>) {
        var depth = 0
        var cur = UInt32(id)
        while cur != kNoEntry && depth < 4096 {
            chain[depth] = cur
            depth += 1
            cur = parent[Int(cur)]
        }
        let root = chain[depth - 1]
        let slot = rootSlot(root)
        let vi = v.map { $0.rawValue + 1 } ?? 0
        if slot >= 0 {
            let pre = rootPrefix[slot][vi]
            if depth == 1 {
                if pre.isEmpty { buf.append(47) } else { pre.withUnsafeBufferPointer { buf.append($0.baseAddress!, $0.count) } }
                return
            }
            if !pre.isEmpty { pre.withUnsafeBufferPointer { buf.append($0.baseAddress!, $0.count) } }
        } else if depth == 1 {
            let (p, n) = rawName(id)
            buf.append(p, n)
            return
        }
        var k = depth - 2
        while k >= 0 {
            buf.append(47)
            let e = Int(chain[k])
            let (p, n) = v.map { key(e, $0) } ?? rawName(e)
            buf.append(p, n)
            k -= 1
        }
    }

    /// Depth = number of folders above the entry (a volume root has depth 0).
    @inline(__always)
    public func depth(_ id: Int) -> Int {
        var d = 0
        var cur = parent[id]
        while cur != kNoEntry { d += 1; cur = parent[Int(cur)] }
        return d
    }
}

/// Raw view of a folder-path cache for one key variant.
public struct PathCacheView {
    var off: UnsafeMutablePointer<UInt32>
    var len: UnsafeMutablePointer<UInt32>
    var bytes: UnsafeMutablePointer<UInt8>
    var count: Int
    var valid: Bool
}

/// Per-thread evaluation scratch space.
public struct EvalCtx {
    public let v: IndexView
    var buf: ByteBuf
    var cachedID = -1
    var cachedVariant = -2
    let chain: UnsafeMutablePointer<UInt32>
    /// Slot 0 = display bytes, 1…4 = KeyVariant 0…3.
    let pcs: UnsafeMutablePointer<PathCacheView>

    public init(_ v: IndexView) {
        self.init(v, caches: [:])
    }

    init(_ v: IndexView, caches: [Int: FolderPathCache]) {
        self.v = v
        buf = ByteBuf(capacity: 4096)
        chain = .allocate(capacity: 4096)
        pcs = .allocate(capacity: 5)
        for slot in 0..<5 {
            if let c = caches[slot - 1] {
                pcs[slot] = PathCacheView(off: c.off, len: c.len, bytes: c.bytes.base, count: c.count, valid: true)
            } else {
                pcs[slot] = PathCacheView(off: chain, len: chain, bytes: buf.p, count: 0, valid: false)
            }
        }
    }

    public func release() {
        buf.deallocate()
        chain.deallocate()
        pcs.deallocate()
    }

    @inline(__always)
    public mutating func path(_ id: Int, _ variant: KeyVariant?) -> (UnsafePointer<UInt8>, Int) {
        let vr = variant?.rawValue ?? -1
        if id == cachedID && vr == cachedVariant { return (UnsafePointer(buf.p), buf.count) }
        let pc = pcs[vr + 1]
        if pc.valid && id < pc.count {
            let p = Int(v.parent[id])
            if p != Int(kNoEntry) && p < pc.count && pc.len[p] != UInt32.max {
                buf.reset()
                buf.append(pc.bytes + Int(pc.off[p]), Int(pc.len[p]))
                buf.append(47)
                let (np, nl) = variant.map { v.key(id, $0) } ?? v.rawName(id)
                buf.append(np, nl)
                cachedID = id
                cachedVariant = vr
                return (UnsafePointer(buf.p), buf.count)
            }
        }
        buf.reset()
        v.appendPath(id, variant, &buf, chain)
        cachedID = id
        cachedVariant = vr
        return (UnsafePointer(buf.p), buf.count)
    }

    public mutating func pathString(_ id: Int, _ variant: KeyVariant? = nil) -> String {
        let (p, n) = path(id, variant)
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }
}

/// Byte-level text matchers used by the evaluator.
public enum Match {
    @inline(__always)
    public static func substring(_ h: UnsafePointer<UInt8>, _ n: Int, _ p: UnsafePointer<UInt8>, _ m: Int, _ ci: Bool) -> Bool {
        if m == 0 { return true }
        if m > n { return false }
        let first = p[0]
        let last = n - m
        var i = 0
        if ci {
            let low = Fold.lower
            while i <= last {
                if low[Int(h[i])] == first {
                    var k = 1
                    while k < m && low[Int(h[i + k])] == p[k] { k += 1 }
                    if k == m { return true }
                }
                i += 1
            }
        } else {
            while i <= last {
                if h[i] == first && memcmp(h + i, p, m) == 0 { return true }
                i += 1
            }
        }
        return false
    }

    @inline(__always)
    static func equalAt(_ h: UnsafePointer<UInt8>, _ p: UnsafePointer<UInt8>, _ m: Int, _ ci: Bool) -> Bool {
        if !ci { return memcmp(h, p, m) == 0 }
        let low = Fold.lower
        var k = 0
        while k < m {
            if low[Int(h[k])] != p[k] { return false }
            k += 1
        }
        return true
    }

    @inline(__always)
    public static func wholeWord(_ h: UnsafePointer<UInt8>, _ n: Int, _ p: UnsafePointer<UInt8>, _ m: Int, _ ci: Bool) -> Bool {
        if m == 0 || m > n { return m == 0 }
        let w = Fold.word
        let pStartsWord = w[Int(p[0])]
        let pEndsWord = w[Int(p[m - 1])]
        var i = 0
        while i <= n - m {
            if equalAt(h + i, p, m, ci) {
                let before = i == 0 || !pStartsWord || !w[Int(h[i - 1])]
                let after = i + m == n || !pEndsWord || !w[Int(h[i + m])]
                if before && after { return true }
            }
            i += 1
        }
        return false
    }

    /// Searches a buffer for `p`, case-insensitively for ASCII when `ci`.
    @inline(__always)
    public static func find(_ h: UnsafePointer<UInt8>, _ n: Int, _ p: UnsafePointer<UInt8>, _ m: Int, _ ci: Bool) -> Bool {
        substring(h, n, p, m, ci)
    }
}
