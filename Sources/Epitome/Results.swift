import AppKit
import EpitomeCore

/// One displayed result (built lazily for visible rows).
struct Row {
    var name: String
    var parent: String
    var fullPath: String
    var isDir: Bool
    var isPackage: Bool
    var isRoot: Bool
    var size: Int64
    var mtime: Int64
    var ctime: Int64
    var atime: Int64
    var rctime: Int64
    var flags: UInt32
    var ext: String
    var entry: EntryID
    var fileListName: String
    var typeName: String?
}

/// What a window is searching.
enum IndexSource {
    case local
    case fileList(FileIndex, String)
    case remote(ETPClient)

    var label: String? {
        switch self {
        case .local: return nil
        case .fileList(_, let path): return (path as NSString).lastPathComponent
        case .remote(let c): return c.label
        }
    }
}

/// The current result set of a window.
final class ResultsModel {
    enum Kind {
        case none
        case local(SearchResults)
        case remote(total: Int, rows: [RemoteRow], highlights: [HighlightTerm])
    }

    let kind: Kind
    private var cache: [Int: Row] = [:]
    let services: SearchServices

    init(_ kind: Kind, services: SearchServices) {
        self.kind = kind
        self.services = services
    }

    static func empty(_ s: SearchServices) -> ResultsModel { ResultsModel(.none, services: s) }

    var count: Int {
        switch kind {
        case .none: return 0
        case .local(let r): return r.count
        case .remote(_, let rows, _): return rows.count
        }
    }

    var totalCount: Int {
        switch kind {
        case .none: return 0
        case .local(let r): return r.totalCount
        case .remote(let t, _, _): return t
        }
    }

    var highlights: [HighlightTerm] {
        switch kind {
        case .none: return []
        case .local(let r): return r.highlights
        case .remote(_, _, let h): return h
        }
    }

    var errors: [String] {
        if case .local(let r) = kind { return r.errors }
        return []
    }

    var localResults: SearchResults? {
        if case .local(let r) = kind { return r }
        return nil
    }

    var index: FileIndex? { localResults?.index }

    func entry(_ i: Int) -> EntryID? {
        guard case .local(let r) = kind, i >= 0, i < r.count else { return nil }
        return r.ids[i]
    }

    func row(_ i: Int) -> Row? {
        if let r = cache[i] { return r }
        guard i >= 0, i < count else { return nil }
        let row: Row
        switch kind {
        case .none:
            return nil
        case .local(let res):
            let ix = res.index
            let id = res.ids[i]
            row = ix.lock.read {
                let n = Int(id)
                let f = ix.flags[n]
                let isRoot = f & EntryFlag.root != 0
                let name = isRoot ? (ix.sources[id]?.name ?? ix.name(id)) : ix.name(id)
                var flName = ""
                if let (_, s) = ix.source(of: id), s.kind == .fileList { flName = ((s.fileListPath ?? s.name) as NSString).lastPathComponent }
                let isDir = f & EntryFlag.directory != 0
                return Row(name: name, parent: ix.parentPath(id), fullPath: ix.path(id), isDir: isDir,
                           isPackage: f & EntryFlag.package != 0, isRoot: isRoot, size: ix.size[n], mtime: ix.mtime[n],
                           ctime: ix.ctime[n], atime: ix.atime[n], rctime: ix.rctime[n], flags: f,
                           ext: isDir && f & EntryFlag.package == 0 ? "" : ix.extensionString(id), entry: id, fileListName: flName)
            }
        case .remote(_, let rows, _):
            let r = rows[i]
            let isDir = r.isFolder
            row = Row(name: r.name, parent: r.path, fullPath: r.fullPath, isDir: isDir, isPackage: false, isRoot: false,
                      size: r.size, mtime: r.mtime, ctime: r.ctime, atime: kUnknownTime, rctime: kUnknownTime,
                      flags: r.attributes | (isDir ? EntryFlag.directory : 0), ext: isDir ? "" : (r.name as NSString).pathExtension,
                      entry: UInt32(i), fileListName: "")
        }
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[i] = row
        return row
    }

    func typeName(_ i: Int) -> String {
        guard var r = row(i) else { return "" }
        if let t = r.typeName { return t }
        let t: String
        if case .local(let res) = kind, let p = res.program {
            t = res.index.lock.read { p.typeName(forID: r.entry, index: res.index) }
        } else {
            t = services.typeName(r.ext.lowercased(), r.isDir, r.isPackage)
        }
        r.typeName = t
        cache[i] = r
        return t
    }

    func path(_ i: Int) -> String? { row(i)?.fullPath }

    /// Finds rows for entry IDs (selection restore after a refresh).
    func rows(for ids: Set<EntryID>) -> IndexSet {
        var out = IndexSet()
        guard !ids.isEmpty, case .local(let r) = kind else { return out }
        for (i, id) in r.ids.enumerated() where ids.contains(id) {
            out.insert(i)
            if out.count == ids.count { break }
        }
        return out
    }
}

/// Bolds the matched parts of names and paths.
enum Highlighter {
    static func ranges(in text: String, terms: [HighlightTerm], pathColumn: Bool, parentLength: Int?) -> [NSRange] {
        guard !terms.isEmpty, !text.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        for t in terms {
            if pathColumn && !t.path { continue }
            var opts: NSString.CompareOptions = []
            if !t.caseSensitive { opts.insert(.caseInsensitive) }
            if !t.diacriticSensitive { opts.insert(.diacriticInsensitive) }
            switch t.kind {
            case .regex:
                guard let re = try? NSRegularExpression(pattern: t.text, options: t.caseSensitive ? [] : [.caseInsensitive]) else { continue }
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 { out.append(m.range) }
            case .wildcard:
                // highlight the literal pieces in order
                var pos = 0
                for piece in t.text.components(separatedBy: CharacterSet(charactersIn: "*?")) where !piece.isEmpty {
                    let p = piece.replacingOccurrences(of: "\\", with: "/")
                    let comps = p.split(separator: "/").map(String.init).filter { !$0.isEmpty }
                    for c in comps {
                        let r = ns.range(of: c, options: opts, range: NSRange(location: pos, length: ns.length - pos))
                        if r.location != NSNotFound { out.append(r); pos = r.location + r.length }
                    }
                }
            case .prefix:
                let r = ns.range(of: t.text, options: opts.union(.anchored))
                if r.location != NSNotFound { out.append(r) }
            case .suffix:
                let r = ns.range(of: t.text, options: opts.union([.anchored, .backwards]))
                if r.location != NSNotFound { out.append(r) }
            default:
                // path terms: highlight each component separately so "bob/music" lights up in both columns
                let pieces = t.path ? t.text.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init) : [t.text]
                for piece in pieces where !piece.isEmpty {
                    var search = NSRange(location: 0, length: ns.length)
                    while search.length > 0 {
                        let r = ns.range(of: piece, options: opts, range: search)
                        if r.location == NSNotFound { break }
                        if t.kind == .wholeWord {
                            let before = r.location == 0 || !isWord(ns.character(at: r.location - 1))
                            let after = r.location + r.length >= ns.length || !isWord(ns.character(at: r.location + r.length))
                            if before && after { out.append(r) }
                        } else if t.kind == .exact {
                            if r.length == ns.length { out.append(r) }
                        } else {
                            out.append(r)
                        }
                        let next = r.location + Swift.max(1, r.length)
                        search = NSRange(location: next, length: ns.length - next)
                    }
                }
            }
        }
        return out
    }

    static func isWord(_ c: unichar) -> Bool {
        guard let u = Unicode.Scalar(c) else { return true }
        return CharacterSet.alphanumerics.contains(u)
    }

    static func attributed(_ text: String, ranges: [NSRange], font: NSFont, color: NSColor, bold: Bool, highlightColor: NSColor?,
                           lineBreak: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
        // Styled text wraps by default; keep result rows on a single, truncated line.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = lineBreak
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        guard !ranges.isEmpty else { return s }
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for r in ranges where r.location + r.length <= s.length {
            if bold { s.addAttribute(.font, value: boldFont, range: r) }
            if let hc = highlightColor { s.addAttribute(.foregroundColor, value: hc, range: r) }
        }
        return s
    }
}
