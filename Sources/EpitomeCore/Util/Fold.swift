import Foundation

/// Case / diacritic folding used by both the index and the query compiler so
/// that names and search terms are always folded the same way.
///
/// Pure-ASCII names (the vast majority) are matched byte-wise with an on-the-fly
/// ASCII lowercase table. Names with any non-ASCII byte get four pre-folded key
/// variants stored in the index's key arena (see `KeyVariant`).
public enum Fold {
    /// ASCII lowercase table; bytes >= 0x80 map to themselves.
    public static let lower: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        for i in 0..<256 { p[i] = (i >= 65 && i <= 90) ? UInt8(i + 32) : UInt8(i) }
        return p
    }()

    /// Word characters for whole-word matching: letters, digits, and any
    /// non-ASCII byte (part of a multi-byte letter).
    public static let word: UnsafeMutablePointer<Bool> = {
        let p = UnsafeMutablePointer<Bool>.allocate(capacity: 256)
        for i in 0..<256 {
            let c = UInt8(i)
            p[i] = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 0x80
        }
        return p
    }()

    @inline(__always)
    public static func isASCII(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var i = 0
        while i + 8 <= n {
            let w = UnsafeRawPointer(p + i).loadUnaligned(as: UInt64.self)
            if w & 0x8080_8080_8080_8080 != 0 { return false }
            i += 8
        }
        while i < n {
            if p[i] >= 0x80 { return false }
            i += 1
        }
        return true
    }

    public static func isASCII(_ s: String) -> Bool {
        s.utf8.allSatisfy { $0 < 0x80 }
    }

    /// Folds `s` for the requested sensitivity, returning NFC UTF-8 bytes.
    public static func fold(_ s: String, caseSensitive: Bool, diacriticSensitive: Bool) -> [UInt8] {
        if isASCII(s) {
            return caseSensitive ? Array(s.utf8) : s.utf8.map { lower[Int($0)] }
        }
        var t = s
        if !diacriticSensitive && !caseSensitive {
            t = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        } else if !diacriticSensitive {
            t = t.folding(options: [.diacriticInsensitive], locale: nil)
        } else if !caseSensitive {
            t = t.folding(options: [.caseInsensitive], locale: nil)
        }
        let nfc = t.precomposedStringWithCanonicalMapping
        // ASCII letters may remain upper case in case-sensitive mode only.
        return caseSensitive ? Array(nfc.utf8) : nfc.utf8.map { lower[Int($0)] }
    }

    /// The four key variants (cs, ci, csdi, cidi) for a non-ASCII name.
    public static func variants(_ s: String) -> [[UInt8]] {
        [
            fold(s, caseSensitive: true, diacriticSensitive: true),
            fold(s, caseSensitive: false, diacriticSensitive: true),
            fold(s, caseSensitive: true, diacriticSensitive: false),
            fold(s, caseSensitive: false, diacriticSensitive: false),
        ]
    }

    /// Byte-wise comparison with ASCII case folding. Returns <0, 0, >0.
    @inline(__always)
    public static func compareCI(_ a: UnsafePointer<UInt8>, _ na: Int,
                                 _ b: UnsafePointer<UInt8>, _ nb: Int) -> Int {
        let n = na < nb ? na : nb
        var i = 0
        while i < n {
            let x = lower[Int(a[i])], y = lower[Int(b[i])]
            if x != y { return x < y ? -1 : 1 }
            i += 1
        }
        return na == nb ? 0 : (na < nb ? -1 : 1)
    }

    /// Plain byte-wise comparison.
    @inline(__always)
    public static func compare(_ a: UnsafePointer<UInt8>, _ na: Int,
                               _ b: UnsafePointer<UInt8>, _ nb: Int) -> Int {
        let n = na < nb ? na : nb
        let c = memcmp(a, b, n)
        if c != 0 { return c < 0 ? -1 : 1 }
        return na == nb ? 0 : (na < nb ? -1 : 1)
    }

    /// Natural comparison: runs of ASCII digits compare by numeric value.
    public static func compareNatural(_ a: UnsafePointer<UInt8>, _ na: Int,
                                      _ b: UnsafePointer<UInt8>, _ nb: Int) -> Int {
        var i = 0, j = 0
        while i < na && j < nb {
            let x = a[i], y = b[j]
            let dx = x >= 48 && x <= 57, dy = y >= 48 && y <= 57
            if dx && dy {
                // skip leading zeros
                var si = i; while si < na && a[si] == 48 { si += 1 }
                var sj = j; while sj < nb && b[sj] == 48 { sj += 1 }
                var ei = si; while ei < na && a[ei] >= 48 && a[ei] <= 57 { ei += 1 }
                var ej = sj; while ej < nb && b[ej] >= 48 && b[ej] <= 57 { ej += 1 }
                let li = ei - si, lj = ej - sj
                if li != lj { return li < lj ? -1 : 1 }
                var k = 0
                while k < li {
                    if a[si + k] != b[sj + k] { return a[si + k] < b[sj + k] ? -1 : 1 }
                    k += 1
                }
                i = ei; j = ej
                continue
            }
            let lx = lower[Int(x)], ly = lower[Int(y)]
            if lx != ly { return lx < ly ? -1 : 1 }
            i += 1; j += 1
        }
        let ra = na - i, rb = nb - j
        return ra == rb ? 0 : (ra < rb ? -1 : 1)
    }
}

/// A reusable, manually managed byte buffer for building paths in hot loops.
public struct ByteBuf {
    public private(set) var p: UnsafeMutablePointer<UInt8>
    public private(set) var count: Int = 0
    public private(set) var capacity: Int

    public init(capacity: Int = 1024) {
        self.capacity = capacity
        p = .allocate(capacity: capacity)
    }

    public func deallocate() { p.deallocate() }

    @inline(__always) public mutating func reset() { count = 0 }

    @inline(__always)
    public mutating func append(_ src: UnsafePointer<UInt8>, _ n: Int) {
        if count + n > capacity { grow(count + n) }
        (p + count).update(from: src, count: n)
        count += n
    }

    @inline(__always)
    public mutating func append(_ b: UInt8) {
        if count + 1 > capacity { grow(count + 1) }
        p[count] = b
        count += 1
    }

    private mutating func grow(_ need: Int) {
        var c = capacity * 2
        while c < need { c *= 2 }
        let np = UnsafeMutablePointer<UInt8>.allocate(capacity: c)
        np.update(from: p, count: count)
        p.deallocate()
        p = np
        capacity = c
    }

    public var string: String { String(decoding: UnsafeBufferPointer(start: p, count: count), as: UTF8.self) }
}
