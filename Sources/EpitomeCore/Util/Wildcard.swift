import Foundation

/// Byte-level wildcard matching (`*` = any run, `?` = one character).
public enum Wildcard {
    @inline(__always)
    static func nextScalar(_ t: UnsafePointer<UInt8>, _ n: Int, _ i: Int) -> Int {
        var j = i + 1
        while j < n && (t[j] & 0xC0) == 0x80 { j += 1 }
        return j
    }

    /// Whole-string match. When `ci` is true the pattern must already be folded
    /// to lower case; text bytes are folded on the fly.
    public static func match(_ pat: UnsafePointer<UInt8>, _ m: Int,
                             _ txt: UnsafePointer<UInt8>, _ n: Int, ci: Bool) -> Bool {
        var p = 0, t = 0
        var starP = -1, starT = 0
        let low = Fold.lower
        while t < n {
            if p < m {
                let pc = pat[p]
                if pc == 42 { // '*'
                    starP = p
                    p += 1
                    starT = t
                    continue
                }
                if pc == 63 { // '?'
                    t = nextScalar(txt, n, t)
                    p += 1
                    continue
                }
                let tc = ci ? low[Int(txt[t])] : txt[t]
                if pc == tc {
                    p += 1
                    t += 1
                    continue
                }
            }
            if starP >= 0 {
                p = starP + 1
                starT = nextScalar(txt, n, starT)
                t = starT
                continue
            }
            return false
        }
        while p < m && pat[p] == 42 { p += 1 }
        return p == m
    }

    /// True if `s` contains wildcard characters.
    public static func hasWildcards(_ s: String) -> Bool {
        s.utf8.contains(42) || s.utf8.contains(63)
    }

    /// Path-aware match: `*` and `?` stop at "/", `**` crosses separators.
    public static func matchPath(_ p: UnsafePointer<UInt8>, _ pi0: Int, _ m: Int,
                                 _ t: UnsafePointer<UInt8>, _ ti0: Int, _ n: Int, ci: Bool) -> Bool {
        var pi = pi0, ti = ti0
        let low = Fold.lower
        while pi < m {
            let c = p[pi]
            if c == 42 {
                let double = pi + 1 < m && p[pi + 1] == 42
                var np = pi + 1
                while np < m && p[np] == 42 { np += 1 }
                if np == m {
                    if double { return true }
                    var k = ti
                    while k < n { if t[k] == 47 { return false }; k += 1 }
                    return true
                }
                var k = ti
                while true {
                    if matchPath(p, np, m, t, k, n, ci: ci) { return true }
                    if k >= n { return false }
                    if !double && t[k] == 47 { return false }
                    k = nextScalar(t, n, k)
                }
            } else if c == 63 {
                if ti >= n || t[ti] == 47 { return false }
                ti = nextScalar(t, n, ti)
                pi += 1
            } else {
                if ti >= n { return false }
                let tc = ci ? low[Int(t[ti])] : t[ti]
                if tc != c { return false }
                pi += 1
                ti += 1
            }
        }
        return ti == n
    }

    /// Matches a path pattern. Absolute patterns ("/…" or starting with "**")
    /// must match the whole path; relative ones match a trailing run of
    /// components (`Documents/*.pdf` matches `…/Documents/x.pdf`).
    public static func matchPathPattern(_ p: UnsafePointer<UInt8>, _ m: Int,
                                        _ t: UnsafePointer<UInt8>, _ n: Int, ci: Bool) -> Bool {
        if m > 0 && (p[0] == 47 || (m > 1 && p[0] == 42 && p[1] == 42)) {
            return matchPath(p, 0, m, t, 0, n, ci: ci)
        }
        var i = 0
        while i < n {
            if t[i] == 47 && matchPath(p, 0, m, t, i + 1, n, ci: ci) { return true }
            i += 1
        }
        return false
    }
}

/// A compiled wildcard pattern (used by exclude lists and filters).
public struct WildcardPattern: Sendable {
    public let source: String
    public let bytes: [UInt8]
    public let caseSensitive: Bool
    public let matchesPath: Bool

    public init(_ s: String, caseSensitive: Bool = false) {
        source = s
        self.caseSensitive = caseSensitive
        matchesPath = s.contains("/")
        bytes = Fold.fold(s, caseSensitive: caseSensitive, diacriticSensitive: true)
    }

    public func matches(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        bytes.withUnsafeBufferPointer { b in
            Wildcard.match(b.baseAddress ?? UnsafePointer(bitPattern: 1)!, b.count, p, n, ci: !caseSensitive)
        }
    }

    public func matches(_ s: String) -> Bool {
        let folded = Fold.fold(s, caseSensitive: caseSensitive, diacriticSensitive: true)
        return folded.withUnsafeBufferPointer { matches($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
    }

    /// Splits "a;b;c" lists used throughout the options.
    public static func list(_ s: String, caseSensitive: Bool = false) -> [WildcardPattern] {
        s.split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { WildcardPattern($0, caseSensitive: caseSensitive) }
    }
}
