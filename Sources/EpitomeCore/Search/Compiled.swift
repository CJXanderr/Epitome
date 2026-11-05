import Foundation

/// Media / document properties some functions read from files (width:, length:, artist: ...).
public enum MediaProperty: String, CaseIterable, Sendable {
    case width, height, bitDepth = "bitdepth", duration, album, artist, title, genre, comment, year, track
    case orientation, tags
}

public enum MediaValue: Sendable {
    case int(Int64)
    case text(String)
}

/// Hooks the app provides to the engine (file types, run history, macros, media metadata).
public final class SearchServices: @unchecked Sendable {
    /// Filter / bookmark macros: lower-cased name → search text.
    public var macros: [String: String] = [:]
    public var runHistory: RunHistory?
    /// Kind description for an extension ("JPEG image"). Args: extension, isFolder, isPackage.
    public var typeName: (String, Bool, Bool) -> String = { ext, dir, pkg in
        if dir { return pkg ? "Package" : "Folder" }
        return ext.isEmpty ? "File" : ext.uppercased() + " File"
    }
    /// Does an item with this extension belong to a kind ("image", "movie", "audio", "text", "app", ...)?
    public var kindMatches: (String, Bool, Bool, String) -> Bool = { ext, dir, pkg, kind in
        switch kind {
        case "folder", "folders", "directory": return dir && !pkg
        case "file", "files": return !dir
        case "package", "bundle": return pkg
        case "app", "application": return ext == "app"
        default: return false
        }
    }
    /// Reads a media property for a file path (nil if unknown).
    public var mediaProperty: ((String, MediaProperty) -> MediaValue?)?
    public var dayFirstDates: Bool?
    /// Maximum bytes read per file by content: searches (0 = unlimited).
    public var contentReadLimit: Int64 = 0
    /// Known folders for shell: (lower-cased name → absolute path).
    public var knownFolders: [String: String] = SearchServices.defaultKnownFolders()

    public init() {}

    public static func defaultKnownFolders() -> [String: String] {
        let home = NSHomeDirectory()
        var m: [String: String] = [
            "home": home, "profile": home, "user": home, "~": home,
            "desktop": home + "/Desktop", "documents": home + "/Documents", "personal": home + "/Documents",
            "mydocuments": home + "/Documents", "downloads": home + "/Downloads", "music": home + "/Music",
            "mymusic": home + "/Music", "pictures": home + "/Pictures", "mypictures": home + "/Pictures",
            "movies": home + "/Movies", "videos": home + "/Movies", "myvideo": home + "/Movies",
            "public": home + "/Public", "sites": home + "/Sites", "library": home + "/Library",
            "appdata": home + "/Library/Application Support", "applicationsupport": home + "/Library/Application Support",
            "localappdata": home + "/Library/Application Support", "caches": home + "/Library/Caches",
            "preferences": home + "/Library/Preferences", "fonts": home + "/Library/Fonts",
            "trash": home + "/.Trash", "recyclebin": home + "/.Trash", "bitbucket": home + "/.Trash",
            "icloud": home + "/Library/Mobile Documents/com~apple~CloudDocs",
            "applications": "/Applications", "programfiles": "/Applications", "apps": "/Applications",
            "userapplications": home + "/Applications", "system": "/System", "windows": "/System",
            "systemlibrary": "/System/Library", "commonappdata": "/Library/Application Support",
            "temp": NSTemporaryDirectory(), "tmp": "/private/tmp", "volumes": "/Volumes", "users": "/Users",
            "commondocuments": "/Users/Shared", "shared": "/Users/Shared", "startup": home + "/Library/LaunchAgents",
        ]
        for (k, v) in m { m[k] = v.hasSuffix("/") && v.count > 1 ? String(v.dropLast()) : v }
        return m
    }
}

enum NodeKind: UInt8 {
    case alwaysTrue, alwaysFalse, and, or, not
    case kind
    case substr, wild, exact, wholeWord, prefix, suffix, regex
    case size, date, int
    case ext, attrib, parent, parentPattern, child, empty, root, type, rootSet, nameList
    case ancestor, parentText, ancestorText, locationText, stemText, extText, pathLen
    case derived
    case expensive
}

enum DateField: UInt8 { case modified, created, accessed, recentChange, run }
enum IntField: UInt8 { case runCount, childCount, childFiles, childFolders, depth, len, fsi }

/// One compiled predicate. Plain data so the hot loop has no ARC traffic.
struct PNode {
    var kind: NodeKind
    var target: UInt8 = 0          // 0 = name, 1 = full path
    var variant: KeyVariant = .cidi
    var ci = true
    var kindMask: UInt8 = 0        // 0 any, 1 files only, 2 folders only
    var field: UInt8 = 0
    var child0: Int32 = 0
    var childN: Int32 = 0
    var pat: UnsafeMutablePointer<UInt8>? = nil
    var patLen = 0
    var test = RangeTest(op: .eq, a: ValueRange(lo: 0, hi: 0), unknownValue: 0)
    var side: Int32 = -1
    var a: Int64 = 0
    var b: Int64 = 0
    var cost: Int32 = 1

    init(_ k: NodeKind) { kind = k }
}

/// Slow-path part of an extension list (long extensions, wildcard items).
struct ExtSet {
    var long: [[UInt8]] = []
    var patterns: [WildcardPattern] = []

    @inline(__always)
    static func pack(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        var i = 0
        while i < n { v = (v << 8) | UInt64(Fold.lower[Int(p[i])]); i += 1 }
        return v | (UInt64(n) << 60)
    }

    func containsSlow(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        for l in long where l.count == n {
            if l.withUnsafeBufferPointer({ Fold.compareCI($0.baseAddress!, n, p, n) == 0 }) { return true }
        }
        for w in patterns where w.matches(p, n) { return true }
        return false
    }
}

/// Predicates evaluated outside the index lock (content, media properties).
struct ExpensiveSpec {
    enum Kind {
        case content(needles: [[UInt8]], ci: Bool)
        case mediaInt(MediaProperty, RangeTest)
        case mediaText(MediaProperty, WildcardPattern?, [UInt8], Bool) // property, wildcard, folded literal, ci
        case dimensions(RangeTest, RangeTest)
        case orientation(String)
    }
    var kind: Kind
    var filesOnly = true
}

/// Predicates that need a pass over the whole index first (descendant:, sibling:).
struct DerivedSpec {
    enum Kind { case descendant, sibling }
    var kind: Kind
    var inner: Int
}

/// What to do after matching: duplicates, result limits, sort overrides.
public struct PostProcessing: Sendable {
    public enum Dupe: String, Sendable {
        case name, namePart, size, dateModified, dateCreated, dateAccessed, attributes, path, type, ext
    }
    public enum DupeMode: Sendable { case duplicates, unique, distinct }
    public var dupes: [Dupe] = []
    public var dupeMode: DupeMode = .duplicates
    public var countLimit: Int? = nil
    public var sortOverride: SortKey? = nil
    public var ascendingOverride: Bool? = nil
    public var foldersFirstOverride: FoldersFirst? = nil
}

/// A compiled search: node table + side tables.
public final class QueryProgram: @unchecked Sendable {
    var nodes: [PNode] = []
    var children: [Int32] = []
    var root = 0
    /// Frozen copies of `nodes` / `children` used by the evaluator.
    var np: UnsafeMutablePointer<PNode> = .allocate(capacity: 1)
    var cp: UnsafeMutablePointer<Int32> = .allocate(capacity: 1)
    var arena: [UnsafeMutableRawPointer] = []
    var regexes: [NSRegularExpression] = []
    var extSets: [ExtSet] = []
    var patterns: [WildcardPattern] = []
    var nameSets: [Set<String>] = []
    var rootSets: [Set<UInt32>] = []
    var kindNames: [String] = []
    var expensive: [ExpensiveSpec] = []
    var derived: [DerivedSpec] = []
    /// Pre-pass results: per derived spec, one byte per entry (sibling uses 2 bits).
    var derivedMaps: [UnsafeMutablePointer<UInt8>] = []
    /// Results of the second pass: expensive node → matching entry IDs.
    var expensiveResults: [Set<UInt32>] = []
    /// Key variants that path-matching nodes use (for the folder path cache).
    public internal(set) var pathVariants: Set<Int> = []
    public internal(set) var highlights: [HighlightTerm] = []
    public internal(set) var post = PostProcessing()
    public internal(set) var errors: [String] = []
    public internal(set) var needsRunHistory = false
    public internal(set) var needsTypes = false
    public internal(set) var hasExpensive = false
    public internal(set) var isTriviallyTrue = false

    // Bound at execution time
    var runCounts: [UInt32: (Int64, Int64)] = [:]
    var services: SearchServices = SearchServices()
    var folderPaths: [Int: FolderPathCache] = [:]
    private var typeCache: [String: String] = [:]
    private var kindCache: [String: Bool] = [:]
    private let typeLock = Mutex()

    deinit {
        for p in arena { p.deallocate() }
        for m in derivedMaps { m.deallocate() }
        np.deallocate()
        cp.deallocate()
    }

    /// Copies the node tables into raw storage. Call once after compiling.
    func freeze() {
        np.deallocate()
        cp.deallocate()
        np = .allocate(capacity: Swift.max(1, nodes.count))
        cp = .allocate(capacity: Swift.max(1, children.count))
        nodes.withUnsafeBufferPointer { if $0.count > 0 { np.initialize(from: $0.baseAddress!, count: $0.count) } }
        children.withUnsafeBufferPointer { if $0.count > 0 { cp.initialize(from: $0.baseAddress!, count: $0.count) } }
    }

    func store(_ bytes: [UInt8]) -> (UnsafeMutablePointer<UInt8>, Int) {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Swift.max(8, bytes.count), alignment: 8)
        bytes.withUnsafeBytes { if $0.count > 0 { raw.copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        arena.append(raw)
        return (raw.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    func storeWords(_ words: [UInt64]) -> UnsafeMutablePointer<UInt8> {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Swift.max(8, words.count * 8), alignment: 8)
        words.withUnsafeBytes { if $0.count > 0 { raw.copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        arena.append(raw)
        return raw.assumingMemoryBound(to: UInt8.self)
    }

    func add(_ n: PNode) -> Int {
        nodes.append(n)
        return nodes.count - 1
    }

    public func typeName(forID id: UInt32, index: FileIndex) -> String {
        let f = index.flags[Int(id)]
        let isDir = f & EntryFlag.directory != 0
        let pkg = f & EntryFlag.package != 0
        let ext = isDir && !pkg ? "" : index.extensionString(id).lowercased()
        let k = (isDir ? (pkg ? "P:" : "D:") : "F:") + ext
        if let t = typeLock.sync({ typeCache[k] }) { return t }
        let t = services.typeName(ext, isDir, pkg)
        typeLock.sync { typeCache[k] = t }
        return t
    }

    func kindMatch(_ id: Int, _ c: inout EvalCtx, _ kind: String) -> Bool {
        let f = c.v.flags[id]
        let isDir = f & EntryFlag.directory != 0
        let pkg = f & EntryFlag.package != 0
        let (p, l) = extRange(id, c.v)
        let ext = String(decoding: UnsafeBufferPointer(start: p, count: l), as: UTF8.self).lowercased()
        let k = kind + "|" + (isDir ? (pkg ? "P" : "D") : "F") + ext
        if let v = typeLock.sync({ kindCache[k] }) { return v }
        let v = services.kindMatches(ext, isDir, pkg, kind)
        typeLock.sync { kindCache[k] = v }
        return v
    }

    // MARK: - Evaluation

    @inline(__always)
    func eval(_ k: Int, _ id: Int, _ c: inout EvalCtx) -> Bool {
        let n = UnsafePointer(np + k)
        switch n.pointee.kind {
        case .alwaysTrue:
            return true
        case .alwaysFalse:
            return false
        case .and:
            let s = Int(n.pointee.child0), e = s + Int(n.pointee.childN)
            var j = s
            while j < e {
                if !eval(Int(cp[j]), id, &c) { return false }
                j += 1
            }
            return true
        case .or:
            let s = Int(n.pointee.child0), e = s + Int(n.pointee.childN)
            var j = s
            while j < e {
                if eval(Int(cp[j]), id, &c) { return true }
                j += 1
            }
            return false
        case .not:
            return !eval(Int(cp[Int(n.pointee.child0)]), id, &c)
        case .kind:
            let dir = c.v.flags[id] & EntryFlag.directory != 0
            return n.pointee.kindMask == 1 ? !dir : dir
        case .substr, .wild, .exact, .wholeWord, .prefix, .suffix:
            return evalText(n, id, &c)
        case .regex:
            if !kindOK(n, id, c) { return false }
            let s: String
            if n.pointee.target == 0 {
                let (p, l) = c.v.key(id, .cs)
                s = String(decoding: UnsafeBufferPointer(start: p, count: l), as: UTF8.self)
            } else {
                s = c.pathString(id, .cs)
            }
            let re = regexes[Int(n.pointee.side)]
            return re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length)) != nil
        case .size:
            if !kindOK(n, id, c) { return false }
            return n.pointee.test.test(c.v.size[id])
        case .date:
            if !kindOK(n, id, c) { return false }
            let v: Int64
            switch DateField(rawValue: n.pointee.field)! {
            case .modified: v = c.v.mtime[id]
            case .created: v = c.v.ctime[id]
            case .accessed: v = c.v.atime[id]
            case .recentChange: v = c.v.rctime[id]
            case .run: v = runCounts[UInt32(id)]?.1 ?? kUnknownTime
            }
            return n.pointee.test.test(v)
        case .int:
            if !kindOK(n, id, c) { return false }
            return n.pointee.test.test(intField(n, id, &c))
        case .ext:
            if !kindOK(n, id, c) { return false }
            let f = c.v.flags[id]
            if f & EntryFlag.directory != 0 && f & EntryFlag.package == 0 { return false }
            let (p, l) = extRange(id, c.v)
            if l == 0 { return n.pointee.field & 1 != 0 }
            if l <= 7 {
                let v = ExtSet.pack(p, l)
                let base = UnsafeRawPointer(n.pointee.pat!)
                var k = 0
                while k < n.pointee.patLen {
                    if base.load(fromByteOffset: k &* 8, as: UInt64.self) == v { return true }
                    k += 1
                }
            }
            if n.pointee.field & 2 != 0 { return extSets[Int(n.pointee.side)].containsSlow(p, l) }
            return false
        case .attrib:
            let f = Int64(c.v.flags[id] & EntryFlag.attributeMask)
            let req = n.pointee.a
            if req == 0 { return f & ~Int64(EntryFlag.directory | EntryFlag.package | EntryFlag.executable) == 0 } // "normal"
            return f & req == req
        case .parent:
            return Int64(c.v.parent[id]) == n.pointee.a
        case .parentPattern:
            let p = c.v.parent[id]
            if p == kNoEntry { return false }
            let (pp, pl) = c.path(Int(p), n.pointee.variant)
            return Wildcard.matchPath(n.pointee.pat!, 0, n.pointee.patLen, pp, 0, pl, ci: n.pointee.ci)
        case .ancestor:
            var cur = c.v.parent[id]
            while cur != kNoEntry {
                if Int64(cur) == n.pointee.a { return true }
                cur = c.v.parent[Int(cur)]
            }
            return false
        case .child:
            guard c.v.flags[id] & EntryFlag.directory != 0 else { return false }
            var ch = c.v.firstChild[id]
            while ch != kNoEntry {
                let ci = Int(ch)
                let f = c.v.flags[ci]
                if f & EntryFlag.deleted == 0 {
                    let km = n.pointee.kindMask
                    let isDir = f & EntryFlag.directory != 0
                    if km == 0 || (km == 1 && !isDir) || (km == 2 && isDir) {
                        let (p, l) = c.v.key(ci, n.pointee.variant)
                        if matchBytes(n, p, l) { return true }
                    }
                }
                ch = c.v.nextSibling[ci]
            }
            return false
        case .empty:
            guard c.v.flags[id] & EntryFlag.directory != 0 else { return false }
            var ch = c.v.firstChild[id]
            while ch != kNoEntry {
                if c.v.flags[Int(ch)] & EntryFlag.deleted == 0 { return false }
                ch = c.v.nextSibling[Int(ch)]
            }
            return true
        case .root:
            return c.v.flags[id] & EntryFlag.root != 0
        case .type:
            if n.pointee.field == 2 { return kindMatch(id, &c, kindNames[Int(n.pointee.side)]) }
            let t = typeName(forID: UInt32(id), index: c.v.index)
            let pat = patterns[Int(n.pointee.side)]
            if n.pointee.field == 1 { return pat.matches(t) }
            let folded = Fold.fold(t, caseSensitive: false, diacriticSensitive: false)
            return folded.withUnsafeBufferPointer { Match.substring($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count, n.pointee.pat!, n.pointee.patLen, true) }
        case .rootSet:
            var cur = UInt32(id)
            while c.v.parent[Int(cur)] != kNoEntry { cur = c.v.parent[Int(cur)] }
            return rootSets[Int(n.pointee.side)].contains(cur)
        case .nameList:
            if n.pointee.field == 1 {
                let s = c.pathString(id, .cidi)
                return nameSets[Int(n.pointee.side)].contains(s)
            }
            let (p, l) = c.v.key(id, .cidi)
            var s = String(decoding: UnsafeBufferPointer(start: p, count: l), as: UTF8.self)
            if c.v.flags[id] & EntryFlag.nonASCII == 0 { s = s.lowercased() }
            return nameSets[Int(n.pointee.side)].contains(s)
        case .parentText:
            if !kindOK(n, id, c) { return false }
            let p = c.v.parent[id]
            if p == kNoEntry { return false }
            let (h, hl) = c.v.key(Int(p), n.pointee.variant)
            return matchBytes(n, h, hl)
        case .ancestorText:
            if !kindOK(n, id, c) { return false }
            var cur = c.v.parent[id]
            while cur != kNoEntry {
                let (h, hl) = c.v.key(Int(cur), n.pointee.variant)
                if matchBytes(n, h, hl) { return true }
                cur = c.v.parent[Int(cur)]
            }
            return false
        case .locationText:
            if !kindOK(n, id, c) { return false }
            let p = c.v.parent[id]
            if p == kNoEntry { return false }
            let (h, hl) = c.path(Int(p), n.pointee.variant)
            if n.pointee.field == 1 { return Wildcard.matchPathPattern(n.pointee.pat!, n.pointee.patLen, h, hl, ci: n.pointee.ci) }
            return matchBytes(n, h, hl)
        case .stemText:
            if !kindOK(n, id, c) { return false }
            let (h, hl) = c.v.key(id, n.pointee.variant)
            var j = hl - 1
            var stem = hl
            if c.v.flags[id] & EntryFlag.directory == 0 || c.v.flags[id] & EntryFlag.package != 0 {
                while j > 0 { if h[j] == 46 { stem = j; break }; j -= 1 }
            }
            return matchBytes(n, h, stem)
        case .extText:
            if !kindOK(n, id, c) { return false }
            let (h, hl) = extRange(id, c.v)
            return matchBytes(n, h, hl)
        case .pathLen:
            if !kindOK(n, id, c) { return false }
            let (h, hl) = c.path(id, .cs)
            var chars: Int64 = 0
            for i in 0..<hl where h[i] & 0xC0 != 0x80 { chars += 1 }
            return n.pointee.test.test(chars)
        case .derived:
            let spec = derived[Int(n.pointee.side)]
            let map = derivedMaps.isEmpty ? nil : derivedMaps[Int(n.pointee.side)]
            guard let m = map else { return false }
            switch spec.kind {
            case .descendant:
                return m[id] != 0
            case .sibling:
                let p = c.v.parent[id]
                if p == kNoEntry { return false }
                let v = m[Int(p)]
                if v >= 2 { return true }
                if v == 1 { return !eval(spec.inner, id, &c) }
                return false
            }
        case .expensive:
            return expensiveResults.isEmpty ? false : expensiveResults[Int(n.pointee.side)].contains(UInt32(id))
        }
    }

    /// Kleene evaluation for the first pass: expensive nodes are "maybe".
    func tri(_ k: Int, _ id: Int, _ c: inout EvalCtx) -> Tri {
        let n = np[k]
        switch n.kind {
        case .expensive:
            if expensive[Int(n.side)].filesOnly && c.v.flags[id] & EntryFlag.directory != 0 { return .no }
            return .maybe
        case .and:
            var sawMaybe = false
            for j in Int(n.child0)..<Int(n.child0 + n.childN) {
                switch tri(Int(cp[j]), id, &c) {
                case .no: return .no
                case .maybe: sawMaybe = true
                case .yes: break
                }
            }
            return sawMaybe ? .maybe : .yes
        case .or:
            var sawMaybe = false
            for j in Int(n.child0)..<Int(n.child0 + n.childN) {
                switch tri(Int(cp[j]), id, &c) {
                case .yes: return .yes
                case .maybe: sawMaybe = true
                case .no: break
                }
            }
            return sawMaybe ? .maybe : .no
        case .not:
            switch tri(Int(cp[Int(n.child0)]), id, &c) {
            case .yes: return .no
            case .no: return .yes
            case .maybe: return .maybe
            }
        default:
            return eval(k, id, &c) ? .yes : .no
        }
    }

    @inline(__always)
    func kindOK(_ n: UnsafePointer<PNode>, _ id: Int, _ c: EvalCtx) -> Bool {
        let m = n.pointee.kindMask
        if m == 0 { return true }
        let dir = c.v.flags[id] & EntryFlag.directory != 0
        return m == 1 ? !dir : dir
    }

    @inline(__always)
    func matchBytes(_ n: UnsafePointer<PNode>, _ h: UnsafePointer<UInt8>, _ hl: Int) -> Bool {
        switch n.pointee.field {
        case 1: return Wildcard.match(n.pointee.pat!, n.pointee.patLen, h, hl, ci: n.pointee.ci)
        case 2: return hl == n.pointee.patLen && Match.equalAt(h, n.pointee.pat!, hl, n.pointee.ci)
        default: return Match.substring(h, hl, n.pointee.pat!, n.pointee.patLen, n.pointee.ci)
        }
    }

    @inline(__always)
    func evalText(_ n: UnsafePointer<PNode>, _ id: Int, _ c: inout EvalCtx) -> Bool {
        if !kindOK(n, id, c) { return false }
        let path = n.pointee.target != 0
        let (h, hl) = path ? c.path(id, n.pointee.variant) : c.v.key(id, n.pointee.variant)
        let p = n.pointee.pat!, m = n.pointee.patLen, ci = n.pointee.ci
        switch n.pointee.kind {
        case .substr: return Match.substring(h, hl, p, m, ci)
        case .wild: return path ? Wildcard.matchPathPattern(p, m, h, hl, ci: ci) : Wildcard.match(p, m, h, hl, ci: ci)
        case .exact: return hl == m && Match.equalAt(h, p, m, ci)
        case .wholeWord: return Match.wholeWord(h, hl, p, m, ci)
        case .prefix: return hl >= m && Match.equalAt(h, p, m, ci)
        case .suffix: return hl >= m && Match.equalAt(h + (hl - m), p, m, ci)
        default: return false
        }
    }

    @inline(__always)
    func extRange(_ id: Int, _ v: IndexView) -> (UnsafePointer<UInt8>, Int) {
        let (p, n) = v.rawName(id)
        var j = n - 1
        while j > 0 {
            if p[j] == 46 { return (p + j + 1, n - j - 1) }
            j -= 1
        }
        return (p + n, 0)
    }

    @inline(__always)
    func intField(_ n: UnsafePointer<PNode>, _ id: Int, _ c: inout EvalCtx) -> Int64 {
        switch IntField(rawValue: n.pointee.field)! {
        case .runCount:
            return runCounts[UInt32(id)]?.0 ?? 0
        case .childCount, .childFiles, .childFolders:
            guard c.v.flags[id] & EntryFlag.directory != 0 else { return -1 }
            var files: Int64 = 0, dirs: Int64 = 0
            var ch = c.v.firstChild[id]
            while ch != kNoEntry {
                let f = c.v.flags[Int(ch)]
                if f & EntryFlag.deleted == 0 {
                    if f & EntryFlag.directory != 0 { dirs += 1 } else { files += 1 }
                }
                ch = c.v.nextSibling[Int(ch)]
            }
            switch IntField(rawValue: n.pointee.field)! {
            case .childFiles: return files
            case .childFolders: return dirs
            default: return files + dirs
            }
        case .depth:
            return Int64(c.v.depth(id))
        case .len:
            let (p, l) = c.v.key(id, .cs)
            var chars: Int64 = 0
            for i in 0..<l where p[i] & 0xC0 != 0x80 { chars += 1 }
            return chars
        case .fsi:
            var cur = UInt32(id)
            while c.v.parent[Int(cur)] != kNoEntry { cur = c.v.parent[Int(cur)] }
            return Int64(c.v.rootSlot(cur))
        }
    }

    // MARK: - Pre-pass for derived predicates (call with the read lock held)

    func computeDerived(_ v: IndexView, order: UnsafeMutablePointer<UInt32>, count n: Int) {
        for m in derivedMaps { m.deallocate() }
        derivedMaps = []
        for spec in derived {
            let map = UnsafeMutablePointer<UInt8>.allocate(capacity: Swift.max(1, v.count))
            map.initialize(repeating: 0, count: Swift.max(1, v.count))
            switch spec.kind {
            case .descendant:
                let chunks = (n + 16_383) / 16_384
                Parallel.forEach(chunks) { cIdx in
                    var ctx = EvalCtx(v)
                    defer { ctx.release() }
                    let lo = cIdx * 16_384, hi = Swift.min(n, lo + 16_384)
                    for i in lo..<hi {
                        let id = Int(order[i])
                        if self.eval(spec.inner, id, &ctx) {
                            var cur = v.parent[id]
                            while cur != kNoEntry && map[Int(cur)] == 0 {
                                map[Int(cur)] = 1
                                cur = v.parent[Int(cur)]
                            }
                        }
                    }
                }
            case .sibling:
                var ctx = EvalCtx(v)
                defer { ctx.release() }
                for i in 0..<n {
                    let id = Int(order[i])
                    if eval(spec.inner, id, &ctx) {
                        let p = v.parent[id]
                        if p != kNoEntry && map[Int(p)] < 2 { map[Int(p)] += 1 }
                    }
                }
            }
            derivedMaps.append(map)
        }
    }

    // MARK: - Second pass (outside the lock)

    /// Evaluates expensive predicate `side` for a file path.
    func evaluateExpensive(_ side: Int, path: String, isDir: Bool, cancel: CancelToken?) -> Bool {
        let spec = expensive[side]
        if spec.filesOnly && isDir { return false }
        switch spec.kind {
        case .content(let needles, let ci):
            return ContentSearch.fileContains(path, needles: needles, ci: ci, limit: services.contentReadLimit, cancel: cancel)
        case .mediaInt(let prop, let test):
            guard let v = services.mediaProperty?(path, prop) else { return false }
            switch v {
            case .int(let i): return test.test(i)
            case .text(let s): return Int64(s).map { test.test($0) } ?? false
            }
        case .mediaText(let prop, let wild, let lit, let ci):
            guard let v = services.mediaProperty?(path, prop) else { return false }
            let s: String
            switch v {
            case .int(let i): s = String(i)
            case .text(let t): s = t
            }
            if lit.isEmpty && wild == nil { return !s.isEmpty }
            let values = prop == .tags ? s.split(separator: ";").map(String.init) : [s]
            for value in values {
                if let w = wild { if w.matches(value) { return true }; continue }
                let folded = Fold.fold(value, caseSensitive: !ci, diacriticSensitive: false)
                let hit = folded.withUnsafeBufferPointer { b in
                    lit.withUnsafeBufferPointer { l in
                        Match.substring(b.baseAddress ?? UnsafePointer(bitPattern: 1)!, b.count, l.baseAddress ?? UnsafePointer(bitPattern: 1)!, l.count, ci)
                    }
                }
                if hit { return true }
            }
            return false
        case .dimensions(let wt, let ht):
            guard case .int(let w)? = services.mediaProperty?(path, .width),
                  case .int(let h)? = services.mediaProperty?(path, .height) else { return false }
            return wt.test(w) && ht.test(h)
        case .orientation(let o):
            guard case .int(let w)? = services.mediaProperty?(path, .width),
                  case .int(let h)? = services.mediaProperty?(path, .height) else { return false }
            switch o {
            case "landscape": return w > h
            case "portrait": return h > w
            case "square": return w == h
            default: return false
            }
        }
    }
}

/// Reads files for content: searches.
enum ContentSearch {
    static func fileContains(_ path: String, needles: [[UInt8]], ci: Bool, limit: Int64, cancel: CancelToken?) -> Bool {
        guard let f = fopen(path, "rb") else { return false }
        defer { fclose(f) }
        let chunk = 1 << 20
        let maxNeedle = needles.map(\.count).max() ?? 0
        if maxNeedle == 0 { return true }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk + maxNeedle)
        defer { buf.deallocate() }
        var carry = 0
        var total: Int64 = 0
        while true {
            if cancel?.isCancelled == true { return false }
            let got = fread(buf + carry, 1, chunk, f)
            if got <= 0 { break }
            let n = carry + got
            for nd in needles {
                let found = nd.withUnsafeBufferPointer { Match.substring(buf, n, $0.baseAddress!, $0.count, ci) }
                if found { return true }
            }
            total += Int64(got)
            if limit > 0 && total >= limit { break }
            carry = Swift.min(maxNeedle - 1, n)
            memmove(buf, buf + (n - carry), carry)
        }
        return false
    }
}

/// Full folded paths of every folder, so path matching copies one prefix
/// instead of walking the parent chain. Rebuilt when the index changes.
final class FolderPathCache: @unchecked Sendable {
    let instance: UUID
    let generation: UInt64
    let variant: Int
    let off: UnsafeMutablePointer<UInt32>
    let len: UnsafeMutablePointer<UInt32>
    let bytes: ByteArena
    let count: Int

    private static let lock = Mutex()
    private static var cache: [Int: FolderPathCache] = [:]

    init(index ix: FileIndex, variant v: Int) {
        instance = ix.instanceID
        generation = ix.generation
        variant = v
        count = ix.count
        off = .allocate(capacity: Swift.max(1, count))
        len = .allocate(capacity: Swift.max(1, count))
        off.initialize(repeating: 0, count: Swift.max(1, count))
        len.initialize(repeating: UInt32.max, count: Swift.max(1, count))
        bytes = ByteArena(capacity: 1 << 20)
        let view = IndexView(ix)
        let kv: KeyVariant? = v < 0 ? nil : KeyVariant(rawValue: v)
        var stack: [UInt32] = []
        for (slot, r) in view.rootIDs.enumerated() where ix.flags[Int(r)] & EntryFlag.deleted == 0 {
            let pre = view.rootPrefix[slot][v < 0 ? 0 : v + 1]
            off[Int(r)] = UInt32(bytes.count)
            pre.withUnsafeBufferPointer { if $0.count > 0 { bytes.append($0.baseAddress!, count: $0.count) } }
            len[Int(r)] = UInt32(pre.count)
            stack.append(r)
        }
        while let d = stack.popLast() {
            let po = Int(off[Int(d)]), pl = Int(len[Int(d)])
            var ch = view.firstChild[Int(d)]
            while ch != kNoEntry {
                let ci = Int(ch)
                if view.flags[ci] & (EntryFlag.directory | EntryFlag.deleted) == EntryFlag.directory {
                    let start = bytes.count
                    // copy parent prefix (may move on growth: copy via offset after reserve)
                    let (np, nl) = kv.map { view.key(ci, $0) } ?? view.rawName(ci)
                    bytes.reserve(start + pl + 1 + nl)
                    bytes.append(bytes.base + po, count: pl)
                    bytes.append(47)
                    bytes.append(np, count: nl)
                    off[ci] = UInt32(start)
                    len[ci] = UInt32(pl + 1 + nl)
                    stack.append(ch)
                }
                ch = view.nextSibling[ci]
            }
        }
    }

    deinit {
        off.deallocate()
        len.deallocate()
    }

    /// Returns a cache valid for the index's current generation (call under the read lock).
    static func get(_ ix: FileIndex, variant: Int) -> FolderPathCache {
        lock.lock()
        if let c = cache[variant], c.instance == ix.instanceID, c.generation == ix.generation, c.count == ix.count {
            lock.unlock()
            return c
        }
        lock.unlock()
        let c = FolderPathCache(index: ix, variant: variant)
        lock.sync { cache[variant] = c }
        return c
    }

    static func purge() { lock.sync { cache.removeAll() } }
}
