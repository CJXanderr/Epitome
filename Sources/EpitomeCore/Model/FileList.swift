import Foundation

/// File lists (.efu): a CSV of full paths with optional size, dates and attributes.
///
/// Columns: Filename, Size, Date Modified, Date Created, Attributes.
/// Dates are Windows FILETIME values (100 ns ticks since 1601-01-01 UTC) so lists
/// exchange cleanly with other tools that use this format; attributes use the
/// usual numeric bits (1 read-only, 2 hidden, 4 system, 16 folder, 32 archive ...).
public struct FileList: Sendable {
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var size: Int64?
        public var mtime: Int64?   // ns since 1970
        public var ctime: Int64?
        public var attributes: UInt32?

        public init(path: String, size: Int64? = nil, mtime: Int64? = nil, ctime: Int64? = nil, attributes: UInt32? = nil) {
            self.path = path
            self.size = size
            self.mtime = mtime
            self.ctime = ctime
            self.attributes = attributes
        }

        public var isFolder: Bool { (attributes ?? 0) & 16 != 0 }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public enum ParseError: Error, CustomStringConvertible {
        case empty
        public var description: String { "The file list is empty" }
    }

    static let filetimeEpochOffset: Int64 = 116_444_736_000_000_000 // 1601→1970 in 100 ns ticks

    public static func filetimeToNanos(_ ft: Int64) -> Int64 { (ft - filetimeEpochOffset) &* 100 }
    public static func nanosToFiletime(_ ns: Int64) -> Int64 { ns / 100 + filetimeEpochOffset }

    /// Windows-style attribute bits from index flags.
    public static func attributes(fromFlags f: UInt32) -> UInt32 {
        var a: UInt32 = 0
        if f & EntryFlag.readOnly != 0 { a |= 1 }
        if f & EntryFlag.hidden != 0 { a |= 2 }
        if f & EntryFlag.system != 0 { a |= 4 }
        if f & EntryFlag.directory != 0 { a |= 16 }
        if f & EntryFlag.archive != 0 { a |= 32 }
        if f & EntryFlag.symlink != 0 { a |= 1024 }
        if f & EntryFlag.compressed != 0 { a |= 2048 }
        if f & EntryFlag.offline != 0 { a |= 4096 }
        if a == 0 { a = 128 } // normal
        return a
    }

    public static func flags(fromAttributes a: UInt32) -> UInt32 {
        var f: UInt32 = 0
        if a & 1 != 0 { f |= EntryFlag.readOnly }
        if a & 2 != 0 { f |= EntryFlag.hidden }
        if a & 4 != 0 { f |= EntryFlag.system }
        if a & 16 != 0 { f |= EntryFlag.directory }
        if a & 32 != 0 { f |= EntryFlag.archive }
        if a & 1024 != 0 { f |= EntryFlag.symlink }
        if a & 2048 != 0 { f |= EntryFlag.compressed }
        if a & 4096 != 0 { f |= EntryFlag.offline }
        return f
    }

    /// Splits one CSV record (handles quotes and doubled quotes).
    static func csvFields(_ line: Substring) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQ = false
        var it = line.makeIterator()
        var pending: Character? = nil
        while true {
            let ch: Character
            if let p = pending { ch = p; pending = nil } else if let c = it.next() { ch = c } else { break }
            if inQ {
                if ch == "\"" {
                    if let nx = it.next() {
                        if nx == "\"" { cur.append("\"") } else { inQ = false; pending = nx }
                    } else { inQ = false }
                } else {
                    cur.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQ = true
                case ",": out.append(cur); cur = ""
                default: cur.append(ch)
                }
            }
        }
        out.append(cur)
        return out
    }

    /// Splits text into records, keeping newlines inside quotes.
    static func records(_ text: String) -> [Substring] {
        var out: [Substring] = []
        var start = text.startIndex
        var inQ = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" { inQ.toggle() }
            if !inQ && (c == "\n" || c == "\r\n" || c == "\r") {
                out.append(text[start..<i])
                start = text.index(after: i)
            }
            i = text.index(after: i)
        }
        if start < text.endIndex { out.append(text[start...]) }
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public static func parse(_ text: String) throws -> FileList {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        let recs = records(t)
        guard let first = recs.first else { throw ParseError.empty }
        let header = csvFields(first).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var col: [String: Int] = [:]
        var body = recs[...]
        if header.contains("filename") || header.contains("path") || header.contains("name") {
            for (i, h) in header.enumerated() { col[h] = i }
            body = recs.dropFirst()
        } else {
            col["filename"] = 0
        }
        let fi = col["filename"] ?? col["path"] ?? col["name"] ?? 0
        var entries: [Entry] = []
        entries.reserveCapacity(body.count)
        for r in body {
            let f = csvFields(r)
            guard fi < f.count else { continue }
            var path = f[fi]
            if path.isEmpty { continue }
            path = path.replacingOccurrences(of: "\\", with: "/")
            func num(_ key: String) -> Int64? {
                guard let i = col[key], i < f.count else { return nil }
                return Int64(f[i].trimmingCharacters(in: .whitespaces))
            }
            var e = Entry(path: path)
            e.size = num("size")
            if let ft = num("date modified"), ft > 0 { e.mtime = filetimeToNanos(ft) }
            if let ft = num("date created"), ft > 0 { e.ctime = filetimeToNanos(ft) }
            if let a = num("attributes") { e.attributes = UInt32(truncatingIfNeeded: a) }
            if path.hasSuffix("/") && path.count > 1 {
                e.path.removeLast()
                e.attributes = (e.attributes ?? 0) | 16
            }
            entries.append(e)
        }
        return FileList(entries: entries)
    }

    public static func load(_ url: URL) throws -> FileList {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return try parse(text)
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func write(_ list: FileList) -> String {
        var out = "Filename,Size,Date Modified,Date Created,Attributes\n"
        out.reserveCapacity(list.entries.count * 80)
        for e in list.entries {
            out += quote(e.path)
            out += ","
            if let s = e.size, !e.isFolder { out += String(s) }
            out += ","
            if let m = e.mtime, m != kUnknownTime { out += String(nanosToFiletime(m)) }
            out += ","
            if let c = e.ctime, c != kUnknownTime { out += String(nanosToFiletime(c)) }
            out += ","
            if let a = e.attributes { out += String(a) }
            out += "\n"
        }
        return out
    }

    /// Builds a file list from index entries.
    public static func from(ids: [UInt32], index: FileIndex) -> FileList {
        index.lock.read {
            FileList(entries: ids.map { id in
                let i = Int(id)
                let f = index.flags[i]
                return Entry(path: index.path(id),
                             size: f & EntryFlag.directory != 0 ? nil : index.size[i],
                             mtime: index.mtime[i] == kUnknownTime ? nil : index.mtime[i],
                             ctime: index.ctime[i] == kUnknownTime ? nil : index.ctime[i],
                             attributes: attributes(fromFlags: f))
            })
        }
    }

    /// Creates a list by walking a folder on disk.
    public static func create(fromFolder folder: String, options: ScanOptions = ScanOptions()) -> FileList {
        let idx = FileIndex()
        let res = ParallelScanner(options: options).scan(root: folder)
        idx.mutate { ix in
            let r = ix.addRoot(SourceInfo(kind: .folder, path: folder, name: (folder as NSString).lastPathComponent),
                               meta: res.rootMeta ?? EntryMeta(flags: EntryFlag.directory))
            ix.importScan(res, attachTo: r)
        }
        idx.rebuildOrders()
        let ids: [UInt32] = idx.lock.read {
            guard let o = idx.orders[.path] ?? idx.orders[.name] else { return [] }
            return o.toArray().filter { !idx.isRoot($0) }
        }
        return from(ids: ids, index: idx)
    }
}

/// Puts file-list entries into an index as their own root.
public enum FileListLoader {
    /// Adds `list` as a new root (call inside `index.mutate`). Returns the root ID.
    @discardableResult
    public static func add(_ list: FileList, named name: String, path: String?, to ix: FileIndex) -> EntryID {
        let info = SourceInfo(kind: .fileList, path: "/", name: name, monitored: false, fileListPath: path)
        let root = ix.addRoot(info, meta: EntryMeta(flags: EntryFlag.directory))
        ix.flags[Int(root)] |= EntryFlag.hiddenFromResults
        var folderCache: [String: EntryID] = ["": root]

        func folder(_ comps: ArraySlice<Substring>) -> EntryID {
            let key = comps.joined(separator: "/")
            if let id = folderCache[key] { return id }
            let parentID = folder(comps.dropLast())
            let nm = String(comps.last!)
            var id = ix.lookupChild(parentID, name: nm)
            if id == kNoEntry {
                id = ix.add(parent: parentID, name: nm, meta: EntryMeta(flags: EntryFlag.directory | EntryFlag.synthetic))
            }
            folderCache[key] = id
            return id
        }

        for e in list.entries {
            let comps = e.path.split(separator: "/", omittingEmptySubsequences: true)
            guard let last = comps.last else { continue }
            let parentID = folder(comps.dropLast())
            let nm = String(last)
            let flags = FileList.flags(fromAttributes: e.attributes ?? 0)
            let meta = EntryMeta(flags: flags, size: e.isFolder ? kUnknownSize : (e.size ?? kUnknownSize),
                                 mtime: e.mtime ?? kUnknownTime, ctime: e.ctime ?? kUnknownTime)
            let existing = ix.lookupChild(parentID, name: nm)
            if existing != kNoEntry {
                ix.flags[Int(existing)] &= ~EntryFlag.synthetic
                ix.update(existing, meta: meta)
                if e.isFolder { folderCache[comps.joined(separator: "/")] = existing }
            } else {
                let id = ix.add(parent: parentID, name: nm, meta: meta)
                if e.isFolder { folderCache[comps.joined(separator: "/")] = id }
            }
        }
        return root
    }

    /// A standalone index holding only this list (File → Open File List).
    public static func makeIndex(_ list: FileList, named name: String, path: String?) -> FileIndex {
        let ix = FileIndex()
        _ = ix.mutate { add(list, named: name, path: path, to: $0) }
        ix.rebuildOrders()
        return ix
    }
}
