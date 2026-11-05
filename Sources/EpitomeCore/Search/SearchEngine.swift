import Foundation

/// Where folders go relative to files in the results.
public enum FoldersFirst: String, Codable, CaseIterable, Sendable {
    case ascending   // folders first when sorting ascending, last when descending
    case always
    case never
}

/// A filter's search plus its own match options.
public struct FilterSpec: Equatable, Sendable {
    public var text: String
    public var options: SearchOptions
    public init(text: String, options: SearchOptions = SearchOptions()) {
        self.text = text
        self.options = options
    }
}

public struct SearchRequest: Sendable {
    public var text: String
    public var options: SearchOptions
    public var filter: FilterSpec?
    public var sort: SortKey
    public var ascending: Bool
    public var foldersFirst: FoldersFirst
    public var syntax: SyntaxSettings
    /// Optional window (CLI / HTTP paging is applied after sorting).
    public var offset: Int = 0
    public var limit: Int? = nil
    /// Return nothing for an empty search (Options → Results).
    public var hideWhenEmpty = false

    public init(text: String, options: SearchOptions = SearchOptions(), filter: FilterSpec? = nil,
                sort: SortKey = .name, ascending: Bool = true, foldersFirst: FoldersFirst = .ascending,
                syntax: SyntaxSettings = SyntaxSettings()) {
        self.text = text
        self.options = options
        self.filter = filter
        self.sort = sort
        self.ascending = ascending
        self.foldersFirst = foldersFirst
        self.syntax = syntax
    }

    public var isEmptySearch: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The outcome of one search: entry IDs in display order.
public final class SearchResults: @unchecked Sendable {
    public let index: FileIndex
    public let generation: UInt64
    public let ids: [UInt32]
    /// Total matches before offset/limit were applied.
    public let totalCount: Int
    public let highlights: [HighlightTerm]
    public let errors: [String]
    public let elapsed: Double
    public let request: SearchRequest
    public let program: QueryProgram?

    init(index: FileIndex, generation: UInt64, ids: [UInt32], totalCount: Int, highlights: [HighlightTerm],
         errors: [String], elapsed: Double, request: SearchRequest, program: QueryProgram?) {
        self.index = index
        self.generation = generation
        self.ids = ids
        self.totalCount = totalCount
        self.highlights = highlights
        self.errors = errors
        self.elapsed = elapsed
        self.request = request
        self.program = program
    }

    public var count: Int { ids.count }

    public static func empty(_ index: FileIndex, _ request: SearchRequest) -> SearchResults {
        SearchResults(index: index, generation: index.generation, ids: [], totalCount: 0, highlights: [],
                      errors: [], elapsed: 0, request: request, program: nil)
    }
}

public enum SearchEngine {
    static let chunkSize = 16_384

    /// Runs a search. Returns nil if cancelled.
    public static func run(_ req: SearchRequest, index: FileIndex, services: SearchServices,
                           cancel: CancelToken? = nil) -> SearchResults? {
        let started = Clock.now
        if req.hideWhenEmpty && req.isEmptySearch && (req.filter?.text.isEmpty ?? true) {
            return SearchResults.empty(index, req)
        }
        index.lock.readLock()
        var locked = true
        defer { if locked { index.lock.unlock() } }

        let program = QueryCompiler.compile(req.text, options: req.options, syntax: req.syntax, services: services,
                                            index: index, filter: req.filter.map { (text: $0.text, options: $0.options) })
        if program.needsRunHistory || req.sort == .runCount || req.sort == .dateRun {
            bindRunHistory(program, index: index, services: services)
        }
        let generation = index.generation
        var effective = req
        if let s = program.post.sortOverride { effective.sort = s }
        if let a = program.post.ascendingOverride { effective.ascending = a }
        if let f = program.post.foldersFirstOverride { effective.foldersFirst = f }

        // Iteration order: a presorted order when available.
        let sortKey = effective.sort
        let presorted = sortKey.indexable ? index.orders[sortKey] : nil
        guard let order = presorted ?? index.orders[.name] else {
            return SearchResults.empty(index, req)
        }
        let needsSort = presorted == nil
        let reverse = !effective.ascending && !needsSort

        // Folder path caches for path-matching terms, and whole-index pre-passes.
        for v in program.pathVariants { program.folderPaths[v] = FolderPathCache.get(index, variant: v) }
        if !program.derived.isEmpty, let nameOrder = index.orders[.name] {
            program.computeDerived(IndexView(index), order: nameOrder.base, count: nameOrder.count)
        }

        var ids: [UInt32]
        let n = order.count
        let ob = order.base

        if program.isTriviallyTrue {
            ids = [UInt32](unsafeUninitializedCapacity: n) { buf, c in
                if reverse {
                    for i in 0..<n { buf[i] = ob[n - 1 - i] }
                } else if n > 0 {
                    buf.baseAddress!.update(from: ob, count: n)
                }
                c = n
            }
        } else if !program.hasExpensive {
            guard let r = scan(program, index, ob, n, reverse, cancel) else { return nil }
            ids = r
        } else {
            // Pass 1 (locked): definite matches and candidates.
            guard let (tagged, maybes) = scanTri(program, index, ob, n, reverse, cancel) else { return nil }
            // Collect candidate paths, then release the lock for the slow part.
            var paths: [(UInt32, String, Bool)] = []
            paths.reserveCapacity(maybes.count)
            for id in maybes { paths.append((id, index.path(id), index.isDirectory(id))) }
            index.lock.unlock()
            locked = false
            computeExpensive(program, paths, cancel)
            if cancel?.isCancelled == true { return nil }
            index.lock.readLock()
            locked = true
            let view = IndexView(index)
            program.folderPaths.removeAll()
            for v in program.pathVariants { program.folderPaths[v] = FolderPathCache.get(index, variant: v) }
            var ctx = EvalCtx(view, caches: program.folderPaths)
            defer { ctx.release() }
            var out: [UInt32] = []
            out.reserveCapacity(tagged.count)
            for t in tagged {
                let id = t & 0x7FFF_FFFF
                if t & 0x8000_0000 == 0 { out.append(id); continue }
                if index.isDeleted(id) { continue }
                if program.eval(program.root, Int(id), &ctx) { out.append(id) }
            }
            ids = out
        }
        if cancel?.isCancelled == true { return nil }

        if !program.post.dupes.isEmpty {
            ids = applyDupes(ids, program.post.dupes, mode: program.post.dupeMode, index: index, program: program)
        }
        if needsSort {
            sortResults(&ids, key: sortKey, ascending: effective.ascending, index: index, program: program)
        }
        ids = applyFoldersFirst(ids, effective, index: index)
        if let lim = program.post.countLimit, ids.count > lim { ids = Array(ids.prefix(lim)) }

        let total = ids.count
        if req.offset > 0 || req.limit != nil {
            let lo = Swift.min(req.offset, ids.count)
            let hi = req.limit.map { Swift.min(ids.count, lo + $0) } ?? ids.count
            ids = Array(ids[lo..<hi])
        }
        return SearchResults(index: index, generation: generation, ids: ids, totalCount: total,
                             highlights: program.highlights, errors: program.errors,
                             elapsed: Clock.now - started, request: req, program: program)
    }

    static func bindRunHistory(_ program: QueryProgram, index: FileIndex, services: SearchServices) {
        guard let h = services.runHistory else { return }
        var map: [UInt32: (Int64, Int64)] = [:]
        for (path, rec) in h.all() {
            let id = index.lookup(path: path)
            if id != kNoEntry { map[id] = (Int64(rec.count), Int64(rec.last * 1_000_000_000)) }
        }
        program.runCounts = map
    }

    // MARK: - Scanning

    static func scan(_ program: QueryProgram, _ index: FileIndex, _ ob: UnsafeMutablePointer<UInt32>, _ n: Int,
                     _ reverse: Bool, _ cancel: CancelToken?) -> [UInt32]? {
        let chunks = (n + chunkSize - 1) / chunkSize
        if chunks == 0 { return [] }
        let view = IndexView(index)
        let partial = UnsafeMutablePointer<[UInt32]>.allocate(capacity: chunks)
        partial.initialize(repeating: [], count: chunks)
        defer {
            partial.deinitialize(count: chunks)
            partial.deallocate()
        }
        let root = program.root
        var cancelled = false
        let cancelFlag = AtomicCounter()
        let caches = program.folderPaths
        Parallel.forEach(chunks) { c in
            if cancelFlag.value != 0 { return }
            if let t = cancel, t.isCancelled { cancelFlag.value = 1; return }
            var ctx = EvalCtx(view, caches: caches)
            defer { ctx.release() }
            let lo = c * chunkSize
            let hi = Swift.min(n, lo + chunkSize)
            var local: [UInt32] = []
            local.reserveCapacity(256)
            var i = lo
            while i < hi {
                let id = reverse ? ob[n - 1 - i] : ob[i]
                if program.eval(root, Int(id), &ctx) { local.append(id) }
                i += 1
            }
            partial[c] = local
        }
        cancelled = cancelFlag.value != 0
        if cancelled { return nil }
        var total = 0
        for c in 0..<chunks { total += partial[c].count }
        var out: [UInt32] = []
        out.reserveCapacity(total)
        for c in 0..<chunks { out.append(contentsOf: partial[c]) }
        return out
    }

    /// Returns (ordered list with bit31 set for "maybe" entries, the maybe IDs).
    static func scanTri(_ program: QueryProgram, _ index: FileIndex, _ ob: UnsafeMutablePointer<UInt32>, _ n: Int,
                        _ reverse: Bool, _ cancel: CancelToken?) -> ([UInt32], [UInt32])? {
        let chunks = (n + chunkSize - 1) / chunkSize
        if chunks == 0 { return ([], []) }
        let view = IndexView(index)
        let partial = UnsafeMutablePointer<[UInt32]>.allocate(capacity: chunks)
        partial.initialize(repeating: [], count: chunks)
        defer {
            partial.deinitialize(count: chunks)
            partial.deallocate()
        }
        let root = program.root
        let cancelFlag = AtomicCounter()
        let caches = program.folderPaths
        Parallel.forEach(chunks) { c in
            if cancelFlag.value != 0 { return }
            if let t = cancel, t.isCancelled { cancelFlag.value = 1; return }
            var ctx = EvalCtx(view, caches: caches)
            defer { ctx.release() }
            let lo = c * chunkSize
            let hi = Swift.min(n, lo + chunkSize)
            var local: [UInt32] = []
            var i = lo
            while i < hi {
                let id = reverse ? ob[n - 1 - i] : ob[i]
                switch program.tri(root, Int(id), &ctx) {
                case .yes: local.append(id)
                case .maybe: local.append(id | 0x8000_0000)
                case .no: break
                }
                i += 1
            }
            partial[c] = local
        }
        if cancelFlag.value != 0 { return nil }
        var tagged: [UInt32] = []
        var maybes: [UInt32] = []
        for c in 0..<chunks {
            for t in partial[c] {
                tagged.append(t)
                if t & 0x8000_0000 != 0 { maybes.append(t & 0x7FFF_FFFF) }
            }
        }
        return (tagged, maybes)
    }

    static func computeExpensive(_ program: QueryProgram, _ paths: [(UInt32, String, Bool)], _ cancel: CancelToken?) {
        let nExp = program.expensive.count
        var results = [Set<UInt32>](repeating: [], count: nExp)
        let m = Mutex()
        let chunk = 64
        let chunks = (paths.count + chunk - 1) / chunk
        Parallel.forEach(chunks) { c in
            if cancel?.isCancelled == true { return }
            var local = [[UInt32]](repeating: [], count: nExp)
            let lo = c * chunk, hi = Swift.min(paths.count, lo + chunk)
            for i in lo..<hi {
                let (id, path, isDir) = paths[i]
                for e in 0..<nExp where program.evaluateExpensive(e, path: path, isDir: isDir, cancel: cancel) {
                    local[e].append(id)
                }
            }
            m.sync { for e in 0..<nExp { results[e].formUnion(local[e]) } }
        }
        program.expensiveResults = results
    }

    // MARK: - Post-processing

    struct DupeKey: Hashable {
        var a: Int64
        var b: Int64
        var s: String
    }

    static func dupeKey(_ id: UInt32, _ kinds: [PostProcessing.Dupe], index: FileIndex, program: QueryProgram) -> DupeKey {
        var k = DupeKey(a: 0, b: 0, s: "")
        for d in kinds {
            switch d {
            case .name:
                let (p, l) = index.key(id, .cidi)
                k.s += String(decoding: UnsafeBufferPointer(start: p, count: l), as: UTF8.self).lowercased() + "\u{0}"
            case .namePart:
                let nm = index.name(id).lowercased()
                k.s += ((nm as NSString).deletingPathExtension) + "\u{0}"
            case .ext:
                k.s += index.extensionString(id).lowercased() + "\u{0}"
            case .path:
                let p = index.parent[Int(id)]
                k.b = Int64(p)
            case .size: k.a = index.size[Int(id)]
            case .dateModified: k.b = index.mtime[Int(id)]
            case .dateCreated: k.b = index.ctime[Int(id)]
            case .dateAccessed: k.b = index.atime[Int(id)]
            case .attributes: k.a = Int64(index.flags[Int(id)] & EntryFlag.attributeMask)
            case .type: k.s += program.typeName(forID: id, index: index) + "\u{0}"
            }
        }
        return k
    }

    static func applyDupes(_ ids: [UInt32], _ kinds: [PostProcessing.Dupe], mode: PostProcessing.DupeMode,
                           index: FileIndex, program: QueryProgram) -> [UInt32] {
        var counts: [DupeKey: Int] = [:]
        var keys: [DupeKey] = []
        keys.reserveCapacity(ids.count)
        for id in ids {
            let k = dupeKey(id, kinds, index: index, program: program)
            keys.append(k)
            counts[k, default: 0] += 1
        }
        switch mode {
        case .unique:
            return ids.enumerated().filter { counts[keys[$0.offset], default: 0] == 1 }.map(\.element)
        case .distinct:
            var seen = Set<DupeKey>()
            var out: [UInt32] = []
            for (i, id) in ids.enumerated() where seen.insert(keys[i]).inserted { out.append(id) }
            return out
        case .duplicates:
            break
        }
        // Keep duplicates, grouped by key in order of first appearance.
        var groupOrder: [DupeKey: Int] = [:]
        var tagged: [(Int, Int, UInt32)] = []
        for (i, id) in ids.enumerated() {
            let k = keys[i]
            guard counts[k, default: 0] > 1 else { continue }
            let g: Int
            if let x = groupOrder[k] { g = x } else { g = groupOrder.count; groupOrder[k] = g }
            tagged.append((g, i, id))
        }
        tagged.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return tagged.map(\.2)
    }

    static func sortResults(_ ids: inout [UInt32], key: SortKey, ascending: Bool, index: FileIndex, program: QueryProgram) {
        let ord = index.makeOrdering()
        switch key {
        case .type:
            var types: [UInt32: String] = [:]
            for id in ids { types[id] = program.typeName(forID: id, index: index).lowercased() }
            ids.sort { a, b in
                let ta = types[a]!, tb = types[b]!
                if ta != tb { return ascending ? ta < tb : ta > tb }
                return ascending ? ord.compareName(a, b) < 0 : ord.compareName(a, b) > 0
            }
        case .runCount, .dateRun:
            let rc = program.runCounts
            ids.sort { a, b in
                let va = key == .runCount ? (rc[a]?.0 ?? 0) : (rc[a]?.1 ?? kUnknownTime)
                let vb = key == .runCount ? (rc[b]?.0 ?? 0) : (rc[b]?.1 ?? kUnknownTime)
                if va != vb { return ascending ? va < vb : va > vb }
                return ord.compareName(a, b) < 0
            }
        case .fileListFilename:
            var names: [UInt32: String] = [:]
            for id in ids {
                let s = index.source(of: id)
                names[id] = s?.1.kind == .fileList ? ((s?.1.fileListPath ?? "") as NSString).lastPathComponent.lowercased() : ""
            }
            ids.sort { a, b in
                let x = names[a]!, y = names[b]!
                if x != y { return ascending ? x < y : x > y }
                return ord.compareName(a, b) < 0
            }
        default:
            ids.withUnsafeMutableBufferPointer { buf in
                if ascending {
                    Parallel.sort(buf) { ord.compare(key, $0, $1) < 0 }
                } else {
                    Parallel.sort(buf) { ord.compare(key, $0, $1) > 0 }
                }
            }
        }
    }

    static func applyFoldersFirst(_ ids: [UInt32], _ req: SearchRequest, index: FileIndex) -> [UInt32] {
        let mode = req.foldersFirst
        if mode == .never { return ids }
        let foldersFirst = mode == .always || req.ascending
        var folders: [UInt32] = []
        var files: [UInt32] = []
        folders.reserveCapacity(ids.count / 8)
        files.reserveCapacity(ids.count)
        let fl = index.flags.base
        for id in ids {
            if fl[Int(id)] & EntryFlag.directory != 0 { folders.append(id) } else { files.append(id) }
        }
        if folders.isEmpty || files.isEmpty { return ids }
        return foldersFirst ? folders + files : files + folders
    }
}
