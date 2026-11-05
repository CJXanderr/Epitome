import Foundation

/// The per-search toggles from the Search menu.
public struct SearchOptions: Codable, Equatable, Hashable, Sendable {
    public var matchCase = false
    public var matchWholeWord = false
    public var matchPath = false
    public var matchDiacritics = false
    public var regex = false

    public init(matchCase: Bool = false, matchWholeWord: Bool = false, matchPath: Bool = false,
                matchDiacritics: Bool = false, regex: Bool = false) {
        self.matchCase = matchCase
        self.matchWholeWord = matchWholeWord
        self.matchPath = matchPath
        self.matchDiacritics = matchDiacritics
        self.regex = regex
    }
}

/// How the search text is interpreted (Options → Search).
public struct SyntaxSettings: Codable, Equatable, Sendable {
    /// A term containing a path separator is matched against the full path.
    public var autoPathOnSeparator = true
    /// A wildcard pattern must match the whole file name.
    public var wildcardsMatchWholeName = true
    /// Allow the words AND, OR, NOT as operators.
    public var literalOperators = false
    /// Allow ( ) for grouping as well as < >.
    public var roundBrackets = false
    /// Treat "\" like "/" (Windows habit).
    public var backslashIsSeparator = true
    /// Expand ~ at the start of a path term.
    public var expandTilde = true
    /// Expand $VAR and %VAR% environment variables.
    public var expandEnvironmentVariables = false
    /// AND binds tighter than OR (default: OR binds tighter).
    public var andPrecedence = false
    /// A single * also crosses "/" in path patterns (older behaviour).
    public var starCrossesSeparators = false
    /// Size units are powers of 1000 instead of 1024.
    public var metricSizes = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case autoPathOnSeparator, wildcardsMatchWholeName, literalOperators, roundBrackets, backslashIsSeparator
        case expandTilde, expandEnvironmentVariables, andPrecedence, starCrossesSeparators, metricSizes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? d }
        autoPathOnSeparator = v(.autoPathOnSeparator, true)
        wildcardsMatchWholeName = v(.wildcardsMatchWholeName, true)
        literalOperators = v(.literalOperators, false)
        roundBrackets = v(.roundBrackets, false)
        backslashIsSeparator = v(.backslashIsSeparator, true)
        expandTilde = v(.expandTilde, true)
        expandEnvironmentVariables = v(.expandEnvironmentVariables, false)
        andPrecedence = v(.andPrecedence, false)
        starCrossesSeparators = v(.starCrossesSeparators, false)
        metricSizes = v(.metricSizes, false)
    }

    var parserOptions: ParserOptions {
        ParserOptions(literalOperators: literalOperators, roundBrackets: roundBrackets, andPrecedence: andPrecedence)
    }
}

/// A positive text term, used to highlight matches in the results list.
public struct HighlightTerm: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case substring, wildcard, regex, exact, wholeWord, prefix, suffix }
    public var text: String
    public var kind: Kind
    public var caseSensitive: Bool
    public var diacriticSensitive: Bool
    public var path: Bool
}

struct Mods {
    var matchCase = false
    var diacritics = false
    var path = false
    var regex = false
    var wholeWord = false
    var wholeFilename = false
    var wildcards = true
    var kind: UInt8 = 0

    var variant: KeyVariant { .of(caseSensitive: matchCase, diacriticSensitive: diacritics) }
}

/// Turns search text into a `QueryProgram`.
public enum QueryCompiler {
    /// Canonical modifier names (hyphens removed).
    static let modifierNames: Set<String> = [
        "case", "nocase", "diacritics", "diac", "nodiacritics", "nodiac", "file", "files", "folder", "folders",
        "nofileonly", "nofolderonly", "nofile", "nofolder", "path", "nopath", "regex", "noregex",
        "wfn", "wholefilename", "exact", "whole", "entire", "nowfn", "nowholefilename", "nowhole",
        "ww", "wholeword", "wholewords", "noww", "nowholeword", "nowholewords",
        "wildcards", "nowildcards", "ascii", "utf8", "noascii", "noreorder", "nohighlight",
    ]

    /// Function name → canonical name (keys have hyphens/underscores removed).
    static let functionAliases: [String: String] = [
        "size": "size",
        "dm": "dm", "datemodified": "dm", "modified": "dm",
        "dc": "dc", "datecreated": "dc", "created": "dc",
        "da": "da", "dateaccessed": "da", "accessed": "da",
        "dr": "dr", "daterun": "dr",
        "rc": "rc", "recentchange": "rc", "daterecentlychanged": "rc", "recentlychanged": "rc",
        "runcount": "runcount",
        "ext": "ext",
        "extension": "extension",
        "type": "type", "kind": "kind",
        "attrib": "attrib", "attributes": "attrib", "attr": "attrib",
        "parent": "parent", "infolder": "parent", "nosubfolders": "parent", "parentpath": "parent",
        "ancestor": "ancestor", "shell": "shell",
        "child": "child", "childfile": "childfile", "childfolder": "childfolder",
        "descendant": "descendant", "descendantfile": "descendantfile", "descendantfolder": "descendantfolder",
        "sibling": "sibling", "siblingfile": "siblingfile", "siblingfolder": "siblingfolder",
        "childcount": "childcount", "children": "childcount",
        "childfilecount": "childfilecount", "childfiles": "childfilecount",
        "childfoldercount": "childfoldercount", "childfolders": "childfoldercount",
        "depth": "depth", "parents": "depth", "parentcount": "depth",
        "len": "len", "namelen": "len", "namelength": "len",
        "fullpathlen": "fullpathlen", "fullpathlength": "fullpathlen", "pathlen": "fullpathlen",
        "name": "name", "basename": "name", "stem": "stem",
        "fullpath": "fullpath", "location": "location", "loc": "location", "pathpart": "location",
        "parentname": "parentname", "ancestorname": "ancestorname",
        "empty": "empty", "root": "root",
        "vol": "volume", "volume": "volume", "volumelabel": "volume", "volumename": "volume",
        "dupe": "dupe", "namepartdupe": "namepartdupe", "stemdupe": "namepartdupe", "sizedupe": "sizedupe",
        "dmdupe": "dmdupe", "dcdupe": "dcdupe", "dadupe": "dadupe", "attribdupe": "attribdupe",
        "pathdupe": "pathdupe", "typedupe": "typedupe", "extdupe": "extdupe",
        "unique": "unique", "distinct": "distinct",
        "content": "content", "ansicontent": "ansicontent", "utf8content": "utf8content",
        "utf16content": "utf16content", "utf16lecontent": "utf16content", "utf16becontent": "utf16becontent",
        "startwith": "startwith", "startswith": "startwith", "endwith": "endwith", "endswith": "endwith",
        "filelist": "filelist", "filelistfilename": "filelistfilename",
        "fsi": "fsi", "count": "count",
        "sort": "sort", "sortascending": "sortascending", "sortdescending": "sortdescending",
        "foldersfirst": "foldersfirst", "nofoldersfirst": "nofoldersfirst",
        "foldersfirstascending": "foldersfirstascending", "foldersfirstdescending": "foldersfirstdescending",
        "width": "width", "wide": "width", "height": "height", "high": "height",
        "dimensions": "dimensions", "dimension": "dimensions",
        "orientation": "orientation", "bitdepth": "bitdepth", "bpp": "bitdepth",
        "length": "length", "duration": "length",
        "album": "album", "artist": "artist", "title": "title", "genre": "genre", "comment": "comment",
        "year": "year", "track": "track", "tag": "tags", "tags": "tags",
    ]

    public static var functionNames: [String] { Array(Set(functionAliases.values)).sorted() }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    }

    /// Compiles `text`, optionally AND-ed with a filter's own search and options.
    /// Call with the index read lock held when `index` is given (for parent: lookups).
    public static func compile(_ text: String, options: SearchOptions, syntax: SyntaxSettings = SyntaxSettings(),
                               services: SearchServices = SearchServices(), index: FileIndex? = nil,
                               filter: (text: String, options: SearchOptions)? = nil,
                               now: Date = Date()) -> QueryProgram {
        let c = Compiler(syntax: syntax, services: services, index: index, now: now)
        var roots: [Int] = []
        roots.append(c.compileSearch(text, options))
        if let f = filter, !f.text.trimmingCharacters(in: .whitespaces).isEmpty {
            c.highlightEnabled = false
            roots.append(c.compileSearch(f.text, f.options))
            c.highlightEnabled = true
        }
        let root = c.makeLogical(.and, roots)
        c.prog.root = root
        c.prog.isTriviallyTrue = c.prog.nodes[root].kind == .alwaysTrue
        c.prog.hasExpensive = !c.prog.expensive.isEmpty
        c.prog.services = services
        c.prog.freeze()
        return c.prog
    }
}

final class Compiler {
    let prog = QueryProgram()
    let syntax: SyntaxSettings
    let services: SearchServices
    let index: FileIndex?
    let dates: DateValue
    var macroDepth = 0
    var negated = 0
    var highlightEnabled = true

    init(syntax: SyntaxSettings, services: SearchServices, index: FileIndex?, now: Date) {
        self.syntax = syntax
        self.services = services
        self.index = index
        dates = DateValue(now: now, dayFirst: services.dayFirstDates)
    }

    static func mods(from o: SearchOptions) -> Mods {
        var m = Mods()
        m.matchCase = o.matchCase
        m.diacritics = o.matchDiacritics
        m.path = o.matchPath
        m.wholeWord = o.matchWholeWord
        return m
    }

    /// Compiles one search box (handles global regex mode).
    func compileSearch(_ text: String, _ o: SearchOptions) -> Int {
        let m = Compiler.mods(from: o)
        if o.regex {
            // Regex mode: the whole box is a single pattern; no other syntax.
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return constant(true) }
            var mm = m
            mm.regex = true
            return textNode(text, mm)
        }
        let ast = QueryParser.parse(text, options: syntax.parserOptions)
        return build(ast, m)
    }

    // MARK: - Node helpers

    func constant(_ v: Bool) -> Int { prog.add(PNode(v ? .alwaysTrue : .alwaysFalse)) }

    func makeLogical(_ kind: NodeKind, _ kids: [Int]) -> Int {
        var list: [Int] = []
        for k in kids {
            let kk = prog.nodes[k].kind
            if kind == .and {
                if kk == .alwaysTrue { continue }
                if kk == .alwaysFalse { return constant(false) }
            } else {
                if kk == .alwaysFalse { continue }
                if kk == .alwaysTrue { return constant(true) }
            }
            if kk == kind {
                let n = prog.nodes[k]
                for j in Int(n.child0)..<Int(n.child0 + n.childN) { list.append(Int(prog.children[j])) }
            } else {
                list.append(k)
            }
        }
        if list.isEmpty { return constant(kind == .and) }
        if list.count == 1 { return list[0] }
        list.sort { prog.nodes[$0].cost < prog.nodes[$1].cost }
        var n = PNode(kind)
        n.child0 = Int32(prog.children.count)
        n.childN = Int32(list.count)
        prog.children.append(contentsOf: list.map { Int32($0) })
        n.cost = list.reduce(0) { $0 + prog.nodes[$1].cost }
        return prog.add(n)
    }

    func makeNot(_ k: Int) -> Int {
        let kk = prog.nodes[k].kind
        if kk == .alwaysTrue { return constant(false) }
        if kk == .alwaysFalse { return constant(true) }
        var n = PNode(.not)
        n.child0 = Int32(prog.children.count)
        n.childN = 1
        prog.children.append(Int32(k))
        n.cost = prog.nodes[k].cost
        return prog.add(n)
    }

    func kindNode(_ m: UInt8) -> Int {
        if m == 0 { return constant(true) }
        var n = PNode(.kind)
        n.kindMask = m
        return prog.add(n)
    }

    func highlight(_ text: String, _ kind: HighlightTerm.Kind, _ m: Mods, path: Bool) {
        guard highlightEnabled, negated == 0, !text.isEmpty else { return }
        prog.highlights.append(HighlightTerm(text: text, kind: kind, caseSensitive: m.matchCase,
                                             diacriticSensitive: m.diacritics, path: path))
    }

    func fail(_ msg: String) -> Int {
        prog.errors.append(msg)
        return constant(false)
    }

    func usesPath(_ v: KeyVariant?) { prog.pathVariants.insert(v?.rawValue ?? -1) }

    /// Stores folded text in a node for name/path text predicates.
    func textPattern(_ n: inout PNode, _ text: String, _ m: Mods, wildcard: Bool? = nil) {
        let wild = wildcard ?? (m.wildcards && Wildcard.hasWildcards(text))
        n.field = wild ? 1 : (m.wholeFilename ? 2 : 0)
        let (p, l) = prog.store(Fold.fold(text, caseSensitive: m.matchCase, diacriticSensitive: m.diacritics))
        n.pat = p
        n.patLen = l
        n.ci = !m.matchCase
        n.variant = m.variant
    }

    // MARK: - AST

    func build(_ ast: QueryAST, _ m: Mods) -> Int {
        switch ast {
        case .empty:
            return constant(true)
        case .and(let items):
            return makeLogical(.and, items.map { build($0, m) })
        case .or(let items):
            return makeLogical(.or, items.map { build($0, m) })
        case .not(let inner):
            negated += 1
            defer { negated -= 1 }
            return makeNot(build(inner, m))
        case .term(let t):
            return term(t, m)
        case .prefixed(let t, let inner):
            var mm = m
            var macroNodes: [Int] = []
            var leftover: [TermSegment] = []
            var functionPrefix: String? = nil
            if let first = t.segments.first, !first.quoted, t.segments.count == 1 {
                var s = Substring(first.text)
                while let colon = s.firstIndex(of: ":") {
                    let name = QueryCompiler.normalize(String(s[..<colon]))
                    if applyModifier(name, &mm) {
                        s = s[s.index(after: colon)...]
                        continue
                    }
                    if let macro = services.macros[name], macroDepth < 8 {
                        macroDepth += 1
                        macroNodes.append(build(QueryParser.parse(macro, options: syntax.parserOptions), mm))
                        macroDepth -= 1
                        s = s[s.index(after: colon)...]
                        continue
                    }
                    if QueryCompiler.functionAliases[name] != nil && s.index(after: colon) == s.endIndex {
                        functionPrefix = String(s)
                        s = s[s.endIndex...]
                    }
                    break
                }
                if !s.isEmpty { leftover = [TermSegment(text: String(s), quoted: false)] }
            } else {
                leftover = t.segments
            }
            // `content:<abc 123>` → the function applied to each term of the group.
            if let fp = functionPrefix {
                return build(distribute(fp, inner), mm)
            }
            var parts = macroNodes
            if !leftover.isEmpty { parts.append(term(TermToken(segments: leftover), m)) }
            if mm.kind != 0 { parts.append(kindNode(mm.kind)) }
            parts.append(build(inner, mm))
            return makeLogical(.and, parts)
        }
    }

    /// Prefixes every term in `ast` with `prefix` (sub-expressions for functions).
    func distribute(_ prefix: String, _ ast: QueryAST) -> QueryAST {
        switch ast {
        case .term(var t):
            if t.segments.isEmpty { return ast }
            if t.segments[0].quoted {
                t.segments.insert(TermSegment(text: prefix, quoted: false), at: 0)
            } else {
                t.segments[0].text = prefix + t.segments[0].text
            }
            return .term(t)
        case .and(let x): return .and(x.map { distribute(prefix, $0) })
        case .or(let x): return .or(x.map { distribute(prefix, $0) })
        case .not(let x): return .not(distribute(prefix, x))
        case .prefixed(let t, let x): return .prefixed(t, distribute(prefix, x))
        case .empty: return .empty
        }
    }

    @discardableResult
    func applyModifier(_ name: String, _ m: inout Mods) -> Bool {
        switch name {
        case "case": m.matchCase = true
        case "nocase": m.matchCase = false
        case "diacritics", "diac": m.diacritics = true
        case "nodiacritics", "nodiac": m.diacritics = false
        case "file", "files": m.kind = 1
        case "folder", "folders": m.kind = 2
        case "nofileonly", "nofolderonly", "nofile", "nofolder": m.kind = 0
        case "path": m.path = true
        case "nopath": m.path = false
        case "regex": m.regex = true
        case "noregex": m.regex = false
        case "wfn", "wholefilename", "exact", "whole", "entire": m.wholeFilename = true
        case "nowfn", "nowholefilename", "nowhole": m.wholeFilename = false
        case "ww", "wholeword", "wholewords": m.wholeWord = true
        case "noww", "nowholeword", "nowholewords": m.wholeWord = false
        case "wildcards": m.wildcards = true
        case "nowildcards": m.wildcards = false
        case "ascii", "utf8", "noascii", "noreorder", "nohighlight": break
        default: return false
        }
        return true
    }

    static func charMacro(_ name: String) -> String? {
        switch name {
        case "quot": return "\""
        case "apos": return "'"
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return "\u{00A0}"
        default:
            if name.hasPrefix("#x"), let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { return String(Character(u)) }
            if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { return String(Character(u)) }
            return nil
        }
    }

    /// 1.5-style entities: &sp: &vert: &excl: &lt: &gt: &quot: &colon: &amp: &percent: &ast: &quest: &#n: &#xn:
    static func entity(_ name: String) -> String? {
        switch name {
        case "sp": return " "
        case "vert": return "|"
        case "excl": return "!"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "colon": return ":"
        case "amp": return "&"
        case "percent": return "%"
        case "ast": return "*"
        case "quest": return "?"
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default: return charMacro(name)
        }
    }

    static func isPrefixName(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "#" }
    }

    /// Replaces `&name:` entities in unquoted text with quoted literal segments.
    func expandEntities(_ segs: [TermSegment]) -> [TermSegment] {
        var out: [TermSegment] = []
        for seg in segs {
            if seg.quoted || !seg.text.contains("&") { out.append(seg); continue }
            var rest = Substring(seg.text)
            var buf = ""
            while let amp = rest.firstIndex(of: "&") {
                buf += rest[..<amp]
                let after = rest[rest.index(after: amp)...]
                if let colon = after.firstIndex(of: ":"), let lit = Compiler.entity(String(after[..<colon]).lowercased()) {
                    if !buf.isEmpty { out.append(TermSegment(text: buf, quoted: false)); buf = "" }
                    out.append(TermSegment(text: lit, quoted: true))
                    rest = after[after.index(after: colon)...]
                } else {
                    buf += "&"
                    rest = after
                }
            }
            buf += rest
            if !buf.isEmpty { out.append(TermSegment(text: buf, quoted: false)) }
        }
        return out
    }

    // MARK: - Terms

    func term(_ t: TermToken, _ mods: Mods) -> Int {
        var m = mods
        var segs = expandEntities(t.segments)
        var pre: [Int] = []
        while let first = segs.first, !first.quoted {
            let s = first.text
            guard let colon = s.firstIndex(of: ":") else { break }
            let nameSub = s[..<colon]
            guard Compiler.isPrefixName(nameSub) else { break }
            let name = QueryCompiler.normalize(String(nameSub))
            let rest = String(s[s.index(after: colon)...])
            if applyModifier(name, &m) {
                if rest.isEmpty { segs.removeFirst() } else { segs[0].text = rest }
                continue
            }
            if let canon = QueryCompiler.functionAliases[name] {
                var value = rest
                var quoted = false
                for sgm in segs.dropFirst() { value += sgm.text; if sgm.quoted { quoted = true } }
                return makeLogical(.and, pre + [function(canon, value, quotedValue: quoted, m)])
            }
            if let ch = Compiler.charMacro(name) {
                segs[0] = TermSegment(text: ch, quoted: true)
                if !rest.isEmpty { segs.insert(TermSegment(text: rest, quoted: false), at: 1) }
                break
            }
            if let macro = services.macros[name], macroDepth < 8 {
                macroDepth += 1
                pre.append(build(QueryParser.parse(macro, options: syntax.parserOptions), m))
                macroDepth -= 1
                if rest.isEmpty { segs.removeFirst() } else { segs[0].text = rest }
                continue
            }
            break
        }
        let text = segs.map(\.text).joined()
        if text.isEmpty {
            return makeLogical(.and, pre + [kindNode(m.kind)])
        }
        // A quoted term never gets wildcard treatment for its quoted parts? Everything treats
        // quotes as grouping only, so wildcards inside quotes still apply.
        return makeLogical(.and, pre + [textNode(text, m)])
    }

    func expandText(_ s: String) -> String {
        var t = s
        if syntax.backslashIsSeparator { t = t.replacingOccurrences(of: "\\", with: "/") }
        if syntax.expandTilde && (t == "~" || t.hasPrefix("~/")) {
            t = NSHomeDirectory() + t.dropFirst()
        }
        if syntax.expandEnvironmentVariables && t.contains("%") {
            let env = ProcessInfo.processInfo.environment
            for (k, v) in env where t.contains("%" + k + "%") {
                t = t.replacingOccurrences(of: "%" + k + "%", with: v)
            }
        }
        return t
    }

    func textNode(_ raw: String, _ m: Mods) -> Int {
        let ci = !m.matchCase
        let v = m.variant
        if m.regex {
            var opts: NSRegularExpression.Options = []
            if ci { opts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: raw, options: opts) else {
                return fail("Invalid regular expression: \(raw)")
            }
            prog.regexes.append(re)
            var n = PNode(.regex)
            n.side = Int32(prog.regexes.count - 1)
            n.target = m.path ? 1 : 0
            n.kindMask = m.kind
            n.cost = 80
            if m.path { usesPath(.cs) }
            highlight(raw, .regex, m, path: m.path)
            return prog.add(n)
        }
        let text = expandText(raw)
        let pathMode = m.path || (syntax.autoPathOnSeparator && text.contains("/"))
        var n: PNode
        var hk: HighlightTerm.Kind
        var pattern = text
        if m.wildcards && Wildcard.hasWildcards(text) {
            if pattern == "*.*" { pattern = "*" }
            let whole = syntax.wildcardsMatchWholeName || m.wholeFilename
            if !whole {
                if !pattern.hasPrefix("*") { pattern = "*" + pattern }
                if !pattern.hasSuffix("*") { pattern += "*" }
            }
            if pattern.allSatisfy({ $0 == "*" }) {
                return kindNode(m.kind)
            }
            if pathMode && syntax.starCrossesSeparators {
                pattern = pattern.replacingOccurrences(of: "**", with: "*").replacingOccurrences(of: "*", with: "**")
            }
            n = PNode(.wild)
            hk = .wildcard
        } else if m.wholeFilename {
            n = PNode(.exact)
            hk = .exact
        } else if m.wholeWord {
            n = PNode(.wholeWord)
            hk = .wholeWord
        } else {
            n = PNode(.substr)
            hk = .substring
        }
        let folded = Fold.fold(pattern, caseSensitive: m.matchCase, diacriticSensitive: m.diacritics)
        let (p, l) = prog.store(folded)
        n.pat = p
        n.patLen = l
        n.ci = ci
        n.variant = v
        n.target = pathMode ? 1 : 0
        n.kindMask = m.kind
        n.cost = pathMode ? 24 : (n.kind == .wild ? 6 : 4)
        if pathMode { usesPath(v) }
        highlight(text, hk, m, path: pathMode)
        return prog.add(n)
    }

    // MARK: - Functions

    func rangeTest(_ value: String, unknown: Int64, dashRange: Bool,
                   parse: (String) -> ValueRange?) -> RangeTest? {
        let lower = value.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.isEmpty {
            var t = RangeTest(op: .eq, a: ValueRange(lo: 0, hi: 0), unknownValue: unknown)
            t.matchNonZero = true
            return t
        }
        let cmp = Comparison.parse(lower, allowDashRange: dashRange)
        if cmp.first == "unknown" && cmp.second == nil {
            var t = RangeTest(op: (cmp.op == .ne || cmp.op == .notExact) ? .ne : .eq, a: ValueRange(lo: 0, hi: 0), unknownValue: unknown)
            t.matchUnknown = true
            return t
        }
        guard let a = parse(cmp.first) else { return nil }
        var b: ValueRange? = nil
        if let s = cmp.second {
            if s.isEmpty { b = ValueRange(lo: .max - 1, hi: .max) } else { guard let bb = parse(s) else { return nil }; b = bb }
        }
        return RangeTest(op: cmp.op, a: a, b: b, unknownValue: unknown)
    }

    func dupeKind(_ s: String) -> PostProcessing.Dupe? {
        switch QueryCompiler.normalize(s) {
        case "name", "filename": return .name
        case "namepart", "stem": return .namePart
        case "size": return .size
        case "dm", "datemodified": return .dateModified
        case "dc", "datecreated": return .dateCreated
        case "da", "dateaccessed": return .dateAccessed
        case "attrib", "attributes": return .attributes
        case "path", "location": return .path
        case "type": return .type
        case "ext", "extension": return .ext
        default: return nil
        }
    }

    func function(_ name: String, _ value: String, quotedValue: Bool, _ m: Mods) -> Int {
        switch name {
        case "size":
            let metric = syntax.metricSizes
            var constantA = false
            let lower = value.lowercased()
            let cmp = Comparison.parse(lower, allowDashRange: true)
            guard var t = rangeTest(value, unknown: kUnknownSize, dashRange: true, parse: { s in
                guard let (r, isConst) = SizeValue.parse(s, metric: metric) else { return nil }
                if s == cmp.first { constantA = isConst }
                return r
            }) else { return fail("Invalid size: \(value)") }
            // Comparisons and range endpoints use exact values; only `size:x` is a bucket.
            if !t.matchUnknown && !t.matchNonZero && !constantA && t.op != .eq && t.op != .ne {
                t.a = ValueRange.exact(t.a.lo)
                if let b = t.b, let bs = cmp.second, SizeValue.constant(bs) == nil { t.b = ValueRange.exact(b.lo) }
            }
            var n = PNode(.size)
            n.test = t
            n.kindMask = m.kind
            return prog.add(n)

        case "dm", "dc", "da", "rc", "dr":
            let d = dates
            guard var t = rangeTest(value, unknown: kUnknownTime, dashRange: false, parse: { d.parse($0) }) else {
                return fail("Invalid date: \(value)")
            }
            if t.op == .exact { t.op = .eq }
            if t.op == .notExact { t.op = .ne }
            t.openEndUsesStart = true
            var n = PNode(.date)
            n.test = t
            n.kindMask = m.kind
            switch name {
            case "dm": n.field = DateField.modified.rawValue
            case "dc": n.field = DateField.created.rawValue
            case "da": n.field = DateField.accessed.rawValue
            case "rc": n.field = DateField.recentChange.rawValue
            default:
                n.field = DateField.run.rawValue
                prog.needsRunHistory = true
            }
            return prog.add(n)

        case "runcount", "childcount", "childfilecount", "childfoldercount", "depth", "len", "fsi":
            guard let t = rangeTest(value, unknown: -1, dashRange: true, parse: NumberValue.parse) else {
                return fail("Invalid number: \(value)")
            }
            var n = PNode(.int)
            n.test = t
            n.kindMask = m.kind
            switch name {
            case "runcount": n.field = IntField.runCount.rawValue; prog.needsRunHistory = true
            case "childcount": n.field = IntField.childCount.rawValue; n.cost = 12
            case "childfilecount": n.field = IntField.childFiles.rawValue; n.cost = 12
            case "childfoldercount": n.field = IntField.childFolders.rawValue; n.cost = 12
            case "depth": n.field = IntField.depth.rawValue; n.cost = 3
            case "len": n.field = IntField.len.rawValue; n.cost = 2
            default: n.field = IntField.fsi.rawValue; n.cost = 3
            }
            return prog.add(n)

        case "fullpathlen":
            guard let t = rangeTest(value, unknown: -1, dashRange: true, parse: NumberValue.parse) else {
                return fail("Invalid number: \(value)")
            }
            var n = PNode(.pathLen)
            n.test = t
            n.kindMask = m.kind
            n.cost = 20
            usesPath(.cs)
            return prog.add(n)

        case "ext":
            var set = ExtSet()
            var words: [UInt64] = []
            var matchNone = false
            let items = value.split(whereSeparator: { $0 == ";" || $0 == "," }).map { String($0).trimmingCharacters(in: .whitespaces) }
            if items.isEmpty { matchNone = true }
            for raw in items {
                var e = raw
                if e.hasPrefix("*.") { e.removeFirst(2) }
                while e.hasPrefix(".") { e.removeFirst() }
                if e.isEmpty { matchNone = true; continue }
                if Wildcard.hasWildcards(e) { set.patterns.append(WildcardPattern(e)); continue }
                let b = Array(e.utf8)
                if b.count <= 7 {
                    words.append(b.withUnsafeBufferPointer { ExtSet.pack($0.baseAddress!, $0.count) })
                } else {
                    set.long.append(b.map { Fold.lower[Int($0)] })
                }
            }
            prog.extSets.append(set)
            var n = PNode(.ext)
            n.side = Int32(prog.extSets.count - 1)
            n.pat = prog.storeWords(words)
            n.patLen = words.count
            n.field = (matchNone ? 1 : 0) | ((!set.long.isEmpty || !set.patterns.isEmpty) ? 2 : 0)
            n.kindMask = (items.isEmpty || (items.count == 1 && matchNone)) ? 1 : m.kind
            n.cost = 3
            return prog.add(n)

        case "extension", "name", "stem", "parentname", "ancestorname":
            if value.isEmpty {
                if name == "extension" {
                    var n = PNode(.ext)
                    n.pat = prog.storeWords([])
                    n.field = 1
                    n.side = Int32(prog.extSets.count)
                    prog.extSets.append(ExtSet())
                    n.kindMask = 1
                    return prog.add(n)
                }
                return kindNode(m.kind)
            }
            if name == "name" { return textNode(value, m) }
            let kinds: [String: NodeKind] = ["extension": .extText, "stem": .stemText, "parentname": .parentText, "ancestorname": .ancestorText]
            var n = PNode(kinds[name]!)
            textPattern(&n, value, m)
            n.kindMask = m.kind
            n.cost = name == "ancestorname" ? 20 : 5
            highlight(value, n.field == 1 ? .wildcard : .substring, m, path: name != "stem" && name != "extension")
            return prog.add(n)

        case "fullpath":
            var mm = m
            mm.path = true
            return textNode(value, mm)

        case "location":
            var n = PNode(.locationText)
            let text = expandText(value)
            textPattern(&n, text, m)
            n.kindMask = m.kind
            n.cost = 24
            usesPath(m.variant)
            highlight(text, .substring, m, path: true)
            return prog.add(n)

        case "type":
            if value.isEmpty { return kindNode(m.kind) }
            prog.needsTypes = true
            var n = PNode(.type)
            prog.patterns.append(WildcardPattern(value))
            n.side = Int32(prog.patterns.count - 1)
            if Wildcard.hasWildcards(value) {
                n.field = 1
            } else {
                let (p, l) = prog.store(Fold.fold(value, caseSensitive: false, diacriticSensitive: false))
                n.pat = p
                n.patLen = l
            }
            n.kindMask = m.kind
            n.cost = 15
            return prog.add(n)

        case "kind":
            if value.isEmpty { return kindNode(m.kind) }
            var n = PNode(.type)
            n.field = 2
            prog.kindNames.append(value.lowercased())
            n.side = Int32(prog.kindNames.count - 1)
            n.cost = 15
            return makeLogical(.and, [prog.add(n), kindNode(m.kind)])

        case "attrib":
            var req: Int64 = 0
            var normal = false
            if let num = Int64(value) ?? (value.lowercased().hasPrefix("0x") ? Int64(value.dropFirst(2), radix: 16) : nil) {
                req = Int64(FileList.flags(fromAttributes: UInt32(truncatingIfNeeded: num)))
                if req == 0 { normal = true }
            } else {
                for ch in value.uppercased() {
                    switch ch {
                    case "A": req |= Int64(EntryFlag.archive)
                    case "C": req |= Int64(EntryFlag.compressed)
                    case "D": req |= Int64(EntryFlag.directory)
                    case "H": req |= Int64(EntryFlag.hidden)
                    case "L": req |= Int64(EntryFlag.symlink)
                    case "O": req |= Int64(EntryFlag.offline)
                    case "R": req |= Int64(EntryFlag.readOnly)
                    case "S": req |= Int64(EntryFlag.system)
                    case "X": req |= Int64(EntryFlag.executable)
                    case "P", "K": req |= Int64(EntryFlag.package)
                    case "N": normal = true
                    case "E", "I", "T", "V", "U", "M", "B": return constant(false)
                    default: break
                    }
                }
            }
            if req == 0 && !normal { return kindNode(m.kind) }
            var n = PNode(.attrib)
            n.a = normal ? 0 : req
            return makeLogical(.and, [prog.add(n), kindNode(m.kind)])

        case "parent", "ancestor", "shell":
            var p: String
            if name == "shell" {
                let key = QueryCompiler.normalize(value).replacingOccurrences(of: " ", with: "")
                guard let path = services.knownFolders[key] else { return fail("Unknown shell folder: \(value)") }
                p = path
            } else {
                p = expandText(value)
            }
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            if p.isEmpty { return constant(false) }
            if name == "parent" && Wildcard.hasWildcards(p) {
                var n = PNode(.parentPattern)
                let (pp, pl) = prog.store(Fold.fold(p, caseSensitive: m.matchCase, diacriticSensitive: m.diacritics))
                n.pat = pp
                n.patLen = pl
                n.ci = !m.matchCase
                n.variant = m.variant
                n.cost = 25
                usesPath(m.variant)
                return makeLogical(.and, [prog.add(n), kindNode(m.kind)])
            }
            guard let ix = index else { return constant(false) }
            let id = ix.lookup(path: p)
            var n = PNode(name == "parent" ? .parent : .ancestor)
            n.a = id == kNoEntry ? -2 : Int64(id)
            n.cost = name == "parent" ? 1 : 4
            highlight(p, .substring, m, path: true)
            return makeLogical(.and, [prog.add(n), kindNode(m.kind)])

        case "child", "childfile", "childfolder":
            if value.isEmpty {
                let nonEmpty = makeNot(emptyNode())
                return makeLogical(.and, [kindNode(2), nonEmpty])
            }
            var n = PNode(.child)
            textPattern(&n, value, m)
            n.kindMask = name == "childfile" ? 1 : (name == "childfolder" ? 2 : 0)
            n.cost = 30
            return makeLogical(.and, [prog.add(n), kindNode(m.kind)])

        case "descendant", "descendantfile", "descendantfolder", "sibling", "siblingfile", "siblingfolder":
            var inner = Mods()
            inner.matchCase = m.matchCase
            inner.diacritics = m.diacritics
            inner.kind = name.hasSuffix("file") ? 1 : (name.hasSuffix("folder") ? 2 : 0)
            let saveHL = highlightEnabled
            highlightEnabled = false
            let innerNode = value.isEmpty ? kindNode(inner.kind) : term(TermToken(segments: [TermSegment(text: value, quoted: quotedValue)]), inner)
            highlightEnabled = saveHL
            prog.derived.append(DerivedSpec(kind: name.hasPrefix("descendant") ? .descendant : .sibling, inner: innerNode))
            var n = PNode(.derived)
            n.side = Int32(prog.derived.count - 1)
            n.cost = 2
            return makeLogical(.and, [prog.add(n), kindNode(m.kind)])

        case "empty":
            return emptyNode()

        case "root":
            return prog.add(PNode(.root))

        case "volume":
            var roots = Set<UInt32>()
            if let ix = index {
                let pat = WildcardPattern(Wildcard.hasWildcards(value) ? value : "*" + value + "*")
                for r in ix.roots {
                    guard let s = ix.sources[r], s.kind != .fileList else { continue }
                    if value.isEmpty || pat.matches(s.name) || pat.matches(s.path) { roots.insert(r) }
                }
            }
            prog.rootSets.append(roots)
            var n = PNode(.rootSet)
            n.side = Int32(prog.rootSets.count - 1)
            n.cost = 4
            return makeLogical(.and, [prog.add(n), kindNode(m.kind)])

        case "dupe", "namepartdupe", "sizedupe", "dmdupe", "dcdupe", "dadupe", "attribdupe", "pathdupe", "typedupe", "extdupe", "unique", "distinct":
            var kinds: [PostProcessing.Dupe] = []
            switch name {
            case "namepartdupe": kinds = [.namePart]
            case "sizedupe": kinds = [.size]
            case "dmdupe": kinds = [.dateModified]
            case "dcdupe": kinds = [.dateCreated]
            case "dadupe": kinds = [.dateAccessed]
            case "attribdupe": kinds = [.attributes]
            case "pathdupe": kinds = [.path]
            case "typedupe": kinds = [.type]
            case "extdupe": kinds = [.ext]
            default: break
            }
            var restNode: Int? = nil
            if !value.isEmpty {
                let parts = value.split(separator: ";").map(String.init)
                let parsed = parts.compactMap(dupeKind)
                if parsed.count == parts.count && kinds.isEmpty {
                    kinds = parsed
                } else {
                    restNode = term(TermToken(segments: [TermSegment(text: value, quoted: quotedValue)]), m)
                }
            }
            if kinds.isEmpty { kinds = [.name] }
            if kinds.contains(.type) { prog.needsTypes = true }
            prog.post.dupes.append(contentsOf: kinds)
            if name == "unique" { prog.post.dupeMode = .unique }
            if name == "distinct" { prog.post.dupeMode = .distinct }
            let kindRestrict = kinds == [.size] ? kindNode(1) : kindNode(m.kind)
            return makeLogical(.and, [kindRestrict] + (restNode.map { [$0] } ?? []))

        case "content", "ansicontent", "utf8content", "utf16content", "utf16becontent":
            if value.isEmpty { return constant(true) }
            let ci = !m.matchCase
            func folded(_ b: [UInt8]) -> [UInt8] { ci ? b.map { Fold.lower[Int($0)] } : b }
            var needles: [[UInt8]] = []
            let utf8 = Array(value.utf8)
            let le: [UInt8] = value.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            let be: [UInt8] = value.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            let latin1: [UInt8]? = value.data(using: .isoLatin1).map { Array($0) }
            switch name {
            case "utf8content": needles = [utf8]
            case "utf16content": needles = [le]
            case "utf16becontent": needles = [be]
            case "ansicontent": needles = [latin1 ?? utf8]
            default:
                needles = [utf8, le, be]
                if let l = latin1, l != utf8 { needles.append(l) }
            }
            prog.expensive.append(ExpensiveSpec(kind: .content(needles: needles.map(folded), ci: ci), filesOnly: true))
            var n = PNode(.expensive)
            n.side = Int32(prog.expensive.count - 1)
            n.cost = 10_000
            return prog.add(n)

        case "startwith", "endwith":
            if value.isEmpty { return kindNode(m.kind) }
            let text = m.path ? expandText(value) : value
            var n = PNode(name == "startwith" ? .prefix : .suffix)
            let (p, l) = prog.store(Fold.fold(text, caseSensitive: m.matchCase, diacriticSensitive: m.diacritics))
            n.pat = p
            n.patLen = l
            n.ci = !m.matchCase
            n.variant = m.variant
            n.target = m.path ? 1 : 0
            n.kindMask = m.kind
            n.cost = m.path ? 20 : 3
            if m.path { usesPath(m.variant) }
            highlight(text, name == "startwith" ? .prefix : .suffix, m, path: m.path)
            return prog.add(n)

        case "filelist":
            let items = value.split(whereSeparator: { $0 == "|" || $0 == ";" || $0 == "\n" })
                .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var names: [String] = []
            var paths: [String] = []
            for it in items {
                let t = expandText(it)
                let f = String(decoding: Fold.fold(t, caseSensitive: false, diacriticSensitive: false), as: UTF8.self)
                if t.contains("/") { paths.append(f) } else { names.append(f) }
            }
            var parts: [Int] = []
            if !names.isEmpty {
                prog.nameSets.append(Set(names))
                var n = PNode(.nameList)
                n.side = Int32(prog.nameSets.count - 1)
                n.cost = 8
                parts.append(prog.add(n))
            }
            if !paths.isEmpty {
                prog.nameSets.append(Set(paths))
                var n = PNode(.nameList)
                n.side = Int32(prog.nameSets.count - 1)
                n.field = 1
                n.cost = 30
                usesPath(.cidi)
                parts.append(prog.add(n))
            }
            if parts.isEmpty { return constant(false) }
            return makeLogical(.and, [makeLogical(.or, parts), kindNode(m.kind)])

        case "filelistfilename":
            var roots = Set<UInt32>()
            let pat = WildcardPattern(Wildcard.hasWildcards(value) ? value : "*" + value + "*")
            if let ix = index {
                for r in ix.roots {
                    guard let s = ix.sources[r], s.kind == .fileList else { continue }
                    let fn = ((s.fileListPath ?? s.name) as NSString).lastPathComponent
                    if value.isEmpty || pat.matches(fn) || pat.matches(s.fileListPath ?? "") { roots.insert(r) }
                }
            }
            prog.rootSets.append(roots)
            var n = PNode(.rootSet)
            n.side = Int32(prog.rootSets.count - 1)
            n.cost = 4
            return prog.add(n)

        case "count":
            if let v = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: " =<"))), v >= 0 {
                prog.post.countLimit = Swift.min(prog.post.countLimit ?? .max, v)
            }
            return constant(true)

        case "sort", "sortascending", "sortdescending":
            var v = QueryCompiler.normalize(value.split(separator: ";").first.map(String.init) ?? "")
            var asc: Bool? = name == "sortascending" ? true : (name == "sortdescending" ? false : nil)
            if v.hasSuffix("descending") { asc = false; v = String(v.dropLast("descending".count)) }
            else if v.hasSuffix("ascending") { asc = true; v = String(v.dropLast("ascending".count)) }
            guard let key = SortKey.parse(v) ?? SortKey.allCases.first(where: { QueryCompiler.normalize($0.rawValue) == v }) else {
                return fail("Unknown sort: \(value)")
            }
            prog.post.sortOverride = key
            prog.post.ascendingOverride = asc ?? key.defaultAscending
            return constant(true)

        case "foldersfirst", "nofoldersfirst", "foldersfirstascending", "foldersfirstdescending":
            prog.post.foldersFirstOverride = name == "nofoldersfirst" ? .never : (name == "foldersfirst" ? .always : .ascending)
            return constant(true)

        case "width", "height", "bitdepth", "year", "track":
            guard let t = rangeTest(value, unknown: Int64.min, dashRange: true, parse: NumberValue.parse) else {
                return fail("Invalid number: \(value)")
            }
            let prop: MediaProperty = name == "width" ? .width : name == "height" ? .height :
                name == "bitdepth" ? .bitDepth : name == "year" ? .year : .track
            return expensiveNode(ExpensiveSpec(kind: .mediaInt(prop, t), filesOnly: true))

        case "length":
            guard let t = rangeTest(value, unknown: Int64.min, dashRange: false, parse: NumberValue.duration) else {
                return fail("Invalid duration: \(value)")
            }
            return expensiveNode(ExpensiveSpec(kind: .mediaInt(.duration, t), filesOnly: true))

        case "dimensions":
            let lower = value.lowercased()
            let cmp = Comparison.parse(lower, allowDashRange: false)
            let parts = cmp.first.split(separator: "x")
            guard parts.count == 2, let w = NumberValue.parse(String(parts[0])), let h = NumberValue.parse(String(parts[1])) else {
                return fail("Invalid dimensions: \(value) (use WIDTHxHEIGHT)")
            }
            var wt = RangeTest(op: cmp.op, a: w, unknownValue: Int64.min)
            var ht = RangeTest(op: cmp.op, a: h, unknownValue: Int64.min)
            if cmp.op == .range, let s = cmp.second {
                let p2 = s.split(separator: "x")
                if p2.count == 2, let w2 = NumberValue.parse(String(p2[0])), let h2 = NumberValue.parse(String(p2[1])) {
                    wt.b = w2
                    ht.b = h2
                }
            }
            return expensiveNode(ExpensiveSpec(kind: .dimensions(wt, ht), filesOnly: true))

        case "orientation":
            let o = value.lowercased()
            guard ["landscape", "portrait", "square"].contains(o) else { return fail("orientation: expects landscape, portrait or square") }
            return expensiveNode(ExpensiveSpec(kind: .orientation(o), filesOnly: true))

        case "album", "artist", "title", "genre", "comment", "tags":
            let prop = MediaProperty(rawValue: name)!
            let wild = Wildcard.hasWildcards(value) ? WildcardPattern(value, caseSensitive: m.matchCase) : nil
            let lit = Fold.fold(value, caseSensitive: m.matchCase, diacriticSensitive: false)
            return expensiveNode(ExpensiveSpec(kind: .mediaText(prop, wild, lit, !m.matchCase), filesOnly: prop != .tags))

        default:
            return textNode(name + ":" + value, m)
        }
    }

    func emptyNode() -> Int {
        var n = PNode(.empty)
        n.cost = 6
        return prog.add(n)
    }

    func expensiveNode(_ spec: ExpensiveSpec) -> Int {
        prog.expensive.append(spec)
        var n = PNode(.expensive)
        n.side = Int32(prog.expensive.count - 1)
        n.cost = 5_000
        return prog.add(n)
    }
}
