import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What the index is doing, for the status bar.
public struct IndexStatus: Sendable, Equatable {
    public enum Phase: String, Sendable { case idle, loading, scanning, updating, saving, ready, paused }
    public var phase: Phase
    public var message: String
    public var count: Int

    public static let idle = IndexStatus(phase: .idle, message: "", count: 0)
}

/// A mounted volume and how Epitome treats it.
public struct VolumeInfo: Sendable, Equatable {
    public enum Kind: String, Sendable { case boot, fixed, removable, network }
    public var path: String
    public var name: String
    public var uuid: String?
    public var fsType: String
    public var kind: Kind
    public var readOnly: Bool
    public var id: String { uuid ?? path }
}

/// Owns the live index: building, loading/saving, live updates, rescans.
public final class IndexManager: @unchecked Sendable {
    public let dataDirectory: URL
    public let journal = IndexJournal()
    public let services = SearchServices()
    public let runHistory: RunHistory
    public var log: (String) -> Void = { _ in }

    /// Called (on the main queue) whenever the active index changes.
    public var onChange: ((FileIndex) -> Void)?
    /// Called (on the main queue) when the status changes.
    public var onStatus: ((IndexStatus) -> Void)?

    private let m = Mutex()
    private var _index = FileIndex()
    private var _settings: AppSettings
    private var _status = IndexStatus.idle
    let queue = DispatchQueue(label: "app.epitome.index", qos: .utility)
    private var watcher: FSWatcher?
    private var paused = false
    private var pausedEvents: [FileEvent] = []
    private var dirty = false
    private var lastSave = Date()
    private var buildToken: CancelToken?
    private var notifyScheduled = false
    private var timer: DispatchSourceTimer?
    private var fileListStamps: [String: Date] = [:]
    private var lastProcessedEvent: UInt64 = 0
    private var replaying = false
    public private(set) var readOnly = false
    public private(set) var noDatabase = false
    public var databaseOverride: URL?

    public init(dataDirectory: URL, settings: AppSettings, readOnly: Bool = false, noDatabase: Bool = false) {
        self.dataDirectory = dataDirectory
        _settings = settings
        self.readOnly = readOnly
        self.noDatabase = noDatabase
        runHistory = RunHistory(url: dataDirectory.appendingPathComponent("RunHistory.json"))
        runHistory.enabled = settings.runHistoryEnabled
        services.runHistory = runHistory
        journal.enabled = settings.journalEnabled
    }

    public var index: FileIndex { m.sync { _index } }
    public var settings: AppSettings { m.sync { _settings } }
    public var status: IndexStatus { m.sync { _status } }

    public var databaseURL: URL {
        if let o = databaseOverride { return o }
        let s = settings
        if !s.databaseLocation.isEmpty {
            return URL(fileURLWithPath: (s.databaseLocation as NSString).expandingTildeInPath).appendingPathComponent("Epitome.db")
        }
        return dataDirectory.appendingPathComponent("Epitome.db")
    }

    func setStatus(_ phase: IndexStatus.Phase, _ msg: String, _ count: Int = 0) {
        let st = IndexStatus(phase: phase, message: msg, count: count)
        m.sync { _status = st }
        let cb = onStatus
        DispatchQueue.main.async { cb?(st) }
    }

    /// Coalesces change notifications to at most ~4 per second.
    func notifyChanged() {
        let shouldSchedule: Bool = m.sync {
            if notifyScheduled { return false }
            notifyScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.m.sync { self.notifyScheduled = false }
            self.onChange?(self.index)
        }
    }

    /// Makes `ix` the active index without scanning (tests, read-only databases).
    public func adopt(_ ix: FileIndex) { install(ix) }

    private func install(_ ix: FileIndex) {
        let s = settings
        ix.journal = journal
        ix.folderSizesEnabled = s.indexFolderSize
        ix.naturalSort = s.naturalSort
        m.sync { _index = ix }
        FolderPathCache.purge()
        notifyChanged()
    }

    // MARK: - Lifecycle

    /// Loads the saved database (or builds one), then starts live updates.
    public func start() {
        queue.async { [self] in
            if noDatabase {
                buildAll(reason: "Indexing")
                return
            }
            setStatus(.loading, "Loading database…")
            let t0 = Clock.now
            var loaded: FileIndex?
            do {
                loaded = try Database.load(from: databaseURL)
            } catch {
                log("database load failed: \(error)")
            }
            if let ix = loaded, databaseMatchesSettings(ix) {
                ix.naturalSort = settings.naturalSort
                if ix.naturalSort { ix.rebuildOrders() }
                ix.setMaintainedOrders(settings.fastSorts)
                install(ix)
                log(String(format: "loaded %d entries in %.2fs", ix.liveCount, Clock.now - t0))
                setStatus(.updating, "Updating…", ix.liveCount)
                catchUp(ix)
            } else {
                buildAll(reason: loaded == nil ? "Indexing" : "Rebuilding index")
            }
            scheduleTimer()
        }
    }

    /// Writes the database and stops monitoring.
    public func shutdown() {
        m.sync { buildToken?.cancel() }
        queue.sync {
            watcher?.stop()
            timer?.cancel()
            if !readOnly && !noDatabase { saveNow() }
            runHistory.save()
        }
    }

    // MARK: - Settings

    /// Applies new settings; rebuilds when sources or exclusions changed.
    public func applySettings(_ new: AppSettings) {
        let old = settings
        m.sync { _settings = new }
        runHistory.enabled = new.runHistoryEnabled
        journal.enabled = new.journalEnabled
        queue.async { [self] in
            let ix = index
            if old.naturalSort != new.naturalSort {
                ix.naturalSort = new.naturalSort
                ix.rebuildOrders()
            }
            if old.fastSorts != new.fastSorts { ix.setMaintainedOrders(new.fastSorts) }
            if old.indexFolderSize != new.indexFolderSize {
                ix.lock.write {
                    ix.folderSizesEnabled = new.indexFolderSize
                    if new.indexFolderSize { ix.recomputeFolderSizes() } else { ix.clearFolderSizes() }
                }
                ix.rebuildOrders()
            }
            let sourcesChanged = old.volumes != new.volumes || old.folders.map(\.path) != new.folders.map(\.path) ||
                old.fileLists.map(\.path) != new.fileLists.map(\.path) ||
                old.autoIncludeFixedVolumes != new.autoIncludeFixedVolumes ||
                old.autoIncludeRemovableVolumes != new.autoIncludeRemovableVolumes ||
                old.autoIncludeNetworkVolumes != new.autoIncludeNetworkVolumes
            let scanChanged = old.scanOptions.excludeFolders != new.scanOptions.excludeFolders ||
                old.excludeHidden != new.excludeHidden || old.excludeSystem != new.excludeSystem ||
                old.excludeFiles != new.excludeFiles || old.includeOnlyFiles != new.includeOnlyFiles ||
                old.excludeListEnabled != new.excludeListEnabled || old.indexDateAccessed != new.indexDateAccessed ||
                old.indexPackageContents != new.indexPackageContents
            if sourcesChanged || scanChanged {
                buildAll(reason: "Reindexing")
            } else {
                notifyChanged()
            }
        }
    }

    func databaseMatchesSettings(_ ix: FileIndex) -> Bool {
        let planned = plannedSources().map { $0.path + "|" + $0.kind.rawValue }.sorted()
        let have = ix.roots.compactMap { ix.sources[$0] }.map { $0.path + "|" + $0.kind.rawValue }.sorted()
        if planned != have { return false }
        if hasFullDiskAccess(), ix.sources.values.contains(where: { $0.kind == .volume && $0.volumeUUID == "nofda" }) { return false }
        return true
    }

    // MARK: - Sources

    /// Mounted volumes (boot volume first).
    public func availableVolumes() -> [VolumeInfo] {
        IndexManager.mountedVolumes()
    }

    public static func mountedVolumes() -> [VolumeInfo] {
        var out: [VolumeInfo] = []
        #if os(macOS)
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey,
                                      .volumeIsEjectableKey, .volumeUUIDStringKey, .volumeIsRootFileSystemKey,
                                      .volumeIsBrowsableKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for u in urls {
            let path = u.path
            if path.hasPrefix("/System/Volumes") || path.hasPrefix("/Volumes/.timemachine") || path.contains("/.timemachine/") ||
                path.hasPrefix("/private/var/") || path == "/dev" || path.hasPrefix("/Volumes/com.apple.TimeMachine") { continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.volumeIsBrowsable == false { continue }
            var sfs = statfs()
            var fsType = ""
            if statfs(path, &sfs) == 0 {
                fsType = withUnsafePointer(to: &sfs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
            }
            if ["devfs", "autofs", "nullfs", "lifs", "mtmfs"].contains(fsType) { continue }
            let isRoot = v.volumeIsRootFileSystem == true || path == "/"
            let local = v.volumeIsLocal ?? true
            let kind: VolumeInfo.Kind
            if isRoot { kind = .boot }
            else if !local || ["smbfs", "afpfs", "nfs", "webdav", "ftp"].contains(fsType) { kind = .network }
            else if (v.volumeIsInternal ?? false) && !(v.volumeIsRemovable ?? false) && !(v.volumeIsEjectable ?? false) { kind = .fixed }
            else { kind = .removable }
            let name = v.volumeName ?? (path as NSString).lastPathComponent
            if name == "Recovery" || name.hasPrefix("Backups of ") { continue }
            out.append(VolumeInfo(path: path, name: name, uuid: v.volumeUUIDString, fsType: fsType, kind: kind,
                                  readOnly: v.volumeIsReadOnly ?? false))
        }
        out.sort { a, b in a.kind == .boot ? true : (b.kind == .boot ? false : a.path < b.path) }
        if !out.contains(where: { $0.kind == .boot }) {
            out.insert(VolumeInfo(path: "/", name: "Macintosh HD", uuid: nil, fsType: "apfs", kind: .boot, readOnly: false), at: 0)
        }
        #else
        out.append(VolumeInfo(path: "/", name: "Root", uuid: nil, fsType: "ext4", kind: .boot, readOnly: false))
        #endif
        return out
    }

    /// Is this volume included under the current settings?
    public func includes(_ v: VolumeInfo) -> Bool {
        let s = settings
        if let vs = s.volumes.first(where: { $0.id == v.id || $0.path == v.path }) { return vs.include }
        switch v.kind {
        case .boot, .fixed: return s.autoIncludeFixedVolumes
        case .removable: return s.autoIncludeRemovableVolumes
        case .network: return s.autoIncludeNetworkVolumes
        }
    }

    struct PlannedSource {
        var kind: SourceKind
        var path: String
        var name: String
        var volume: VolumeInfo?
        var includeOnly: [String]
        var monitored: Bool
    }

    func plannedSources() -> [PlannedSource] {
        let s = settings
        var out: [PlannedSource] = []
        for v in IndexManager.mountedVolumes() where includes(v) {
            let vs = s.volumes.first { $0.id == v.id || $0.path == v.path }
            let only = (vs?.includeOnly ?? "").split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            out.append(PlannedSource(kind: .volume, path: v.path, name: v.name, volume: v, includeOnly: only,
                                     monitored: vs?.monitor ?? true))
        }
        // Volumes that are offline but configured to be kept are retained by catchUp (not rebuilt here).
        for f in s.folders {
            let p = (f.path as NSString).expandingTildeInPath
            out.append(PlannedSource(kind: .folder, path: p, name: (p as NSString).lastPathComponent, volume: nil,
                                     includeOnly: [], monitored: f.monitor))
        }
        for fl in s.fileLists {
            let p = (fl.path as NSString).expandingTildeInPath
            out.append(PlannedSource(kind: .fileList, path: "/", name: (p as NSString).lastPathComponent, volume: nil,
                                     includeOnly: [p], monitored: fl.monitor))
        }
        // file-list sources are identified by their list path
        return out.map { ps in
            var x = ps
            if x.kind == .fileList { x.path = "/" }
            return x
        }
    }

    // MARK: - Full build

    /// Scans every source into a fresh index and swaps it in.
    public func rebuild() {
        queue.async { [self] in buildAll(reason: "Rebuilding index") }
    }

    func buildAll(reason: String) {
        let token = CancelToken()
        m.sync {
            buildToken?.cancel()
            buildToken = token
        }
        watcher?.stop()
        let s = settings
        let startEvent = FSWatcher.currentEventID
        let ix = FileIndex()
        ix.folderSizesEnabled = s.indexFolderSize
        ix.naturalSort = s.naturalSort
        ix.maintainedOrders = s.fastSorts
        let fda = hasFullDiskAccess()
        let progress = AtomicCounter()
        let t0 = Clock.now
        for src in plannedSources() {
            if token.isCancelled { return }
            switch src.kind {
            case .fileList:
                guard let listPath = src.includeOnly.first else { continue }
                setStatus(.scanning, "Loading file list \(src.name)…", progress.value)
                if let list = try? FileList.load(URL(fileURLWithPath: listPath)) {
                    _ = ix.mutate { FileListLoader.add(list, named: src.name, path: listPath, to: $0) }
                    fileListStamps[listPath] = modificationDate(listPath)
                }
            case .volume, .folder:
                var info = SourceInfo(kind: src.kind, path: src.path, name: src.name, fsType: src.volume?.fsType,
                                      volumeUUID: src.volume?.uuid, eventsUUID: FSWatcher.eventsUUID(forPath: src.path),
                                      lastEventID: startEvent, lastScan: Date().timeIntervalSince1970, monitored: src.monitored)
                if src.kind == .volume && src.path == "/" && !fda { info.volumeUUID = "nofda" }
                let label = src.kind == .volume ? src.name : src.path
                let ticker = startTicker(label: "\(reason) \(label)…", progress: progress)
                let opts = s.scanOptions
                var results: [(String, ScanResult)] = []
                if src.includeOnly.isEmpty {
                    results.append((src.path, ParallelScanner(options: opts).scan(root: src.path, progress: progress, cancel: token)))
                } else {
                    for sub in src.includeOnly {
                        let full = sub.hasPrefix("/") ? sub : (src.path as NSString).appendingPathComponent(sub)
                        results.append((full, ParallelScanner(options: opts).scan(root: full, progress: progress, cancel: token)))
                    }
                }
                ticker.cancel()
                if token.isCancelled { return }
                let rootMeta = statEntry(src.path)?.0 ?? EntryMeta(flags: EntryFlag.directory)
                ix.mutate { x in
                    let r = x.addRoot(info, meta: rootMeta)
                    for (path, res) in results {
                        var attach = r
                        if path != src.path {
                            attach = ensureFolders(x, root: r, rootPath: src.path, path: path)
                        }
                        x.importScan(res, attachTo: attach)
                    }
                }
            }
        }
        if token.isCancelled { return }
        setStatus(.scanning, "Sorting…", ix.liveCount)
        ix.rebuildOrders()
        ix.clearBatchStateAfterLoad()
        install(ix)
        log(String(format: "indexed %d entries in %.1fs", ix.liveCount, Clock.now - t0))
        dirty = true
        if !readOnly && !noDatabase { saveNow() }
        startWatching(ix, since: startEvent)
        setStatus(.ready, "", ix.liveCount)
    }

    private func startTicker(label: String, progress: AtomicCounter) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 0.25)
        t.setEventHandler { [weak self] in self?.setStatus(.scanning, label, progress.value) }
        t.resume()
        return t
    }

    /// Creates (synthetic) folder entries from `root` down to `path`.
    private func ensureFolders(_ x: FileIndex, root: EntryID, rootPath: String, path: String) -> EntryID {
        let rel = rootPath == "/" ? path : String(path.dropFirst(rootPath.count))
        var cur = root
        var built = rootPath == "/" ? "" : rootPath
        for comp in rel.split(separator: "/") {
            built += "/" + comp
            var nxt = x.lookupChild(cur, name: String(comp))
            if nxt == kNoEntry {
                let meta = statEntry(built)?.0 ?? EntryMeta(flags: EntryFlag.directory)
                nxt = x.add(parent: cur, name: String(comp), meta: meta)
            }
            cur = nxt
        }
        return cur
    }

    // MARK: - Catch-up after load

    func catchUp(_ ix: FileIndex) {
        let planned = plannedSources()
        var since: UInt64 = .max
        var needsRescan: [EntryID] = []
        for r in ix.roots {
            guard let s = ix.sources[r], s.kind != .fileList else { continue }
            let uuid = FSWatcher.eventsUUID(forPath: s.path)
            if s.monitored && s.kind == .volume && uuid != nil && uuid == s.eventsUUID && s.lastEventID > 0 {
                since = Swift.min(since, s.lastEventID)
            } else if s.kind == .volume {
                needsRescan.append(r)
            }
        }
        _ = planned
        // Reload included file lists that changed while we were away.
        reloadChangedFileLists(ix)
        if !needsRescan.isEmpty {
            // History is gone for at least one volume: rebuild in the background
            // (the loaded index stays searchable meanwhile).
            for r in needsRescan { if let s = ix.sources[r] { log("history unavailable for \(s.path); reindexing") } }
            buildAll(reason: "Updating")
            return
        }
        replaying = since != .max
        startWatching(ix, since: since == .max ? nil : since)
        if !replaying { setStatus(.ready, "", ix.liveCount) }
    }

    // MARK: - Live updates

    func watchedPaths(_ ix: FileIndex) -> [String] {
        ix.lock.read {
            ix.roots.compactMap { ix.sources[$0] }.filter { $0.kind != .fileList && $0.monitored }.map(\.path)
        }
    }

    func startWatching(_ ix: FileIndex, since: UInt64?) {
        watcher?.stop()
        let paths = watchedPaths(ix)
        guard !paths.isEmpty else { return }
        let w = FSWatcher(queue: queue) { [weak self] events in self?.handle(events) }
        w.start(paths: paths, since: since)
        watcher = w
        lastProcessedEvent = since ?? FSWatcher.currentEventID
    }

    public func pauseMonitoring() {
        queue.async { [self] in
            paused = true
            setStatus(.paused, "Paused", index.liveCount)
        }
    }

    public func resumeMonitoring() {
        queue.async { [self] in
            paused = false
            let ev = pausedEvents
            pausedEvents = []
            if !ev.isEmpty { process(ev) }
            setStatus(.ready, "", index.liveCount)
        }
    }

    public var isPaused: Bool { queue.sync { paused } }

    /// Asks FSEvents to deliver pending events now (after our own file operations).
    public func flushEvents() {
        queue.async { [weak self] in self?.watcher?.flush() }
    }

    func handle(_ events: [FileEvent]) {
        if paused {
            pausedEvents.append(contentsOf: events)
            return
        }
        process(events)
    }

    private struct Planned {
        var path: String
        var exists: Bool
        var meta: EntryMeta?
        var isMount: Bool
        var scan: ScanResult?
        var subtreeRescan: Bool
    }

    func process(_ events: [FileEvent]) {
        let ix = index
        var maxID = lastProcessedEvent
        var paths: [String] = []
        var seen = Set<String>()
        var rescans: [String] = []
        var historyDone = false
        var volumesChanged = false
        var renames: [UInt64: [String]] = [:]
        for e in events {
            if e.id > maxID && e.id != UInt64.max { maxID = e.id }
            if e.flags & FileEvent.historyDone != 0 { historyDone = true; continue }
            if e.flags & (FileEvent.mount | FileEvent.unmount | FileEvent.rootChanged) != 0 { volumesChanged = true; continue }
            let p = normalizeEventPath(e.path)
            if e.flags & (FileEvent.mustScanSubDirs | FileEvent.userDropped | FileEvent.kernelDropped | FileEvent.idsWrapped) != 0 {
                rescans.append(p)
                continue
            }
            if e.flags & FileEvent.itemRenamed != 0, let ino = e.inode { renames[ino, default: []].append(p) }
            if seen.insert(p).inserted { paths.append(p) }
        }
        lastProcessedEvent = maxID
        if volumesChanged { checkVolumes() }
        if !paths.isEmpty || !rescans.isEmpty { applyPaths(ix, paths, renames: renames, rescans: rescans) }
        if historyDone || replaying {
            if historyDone { replaying = false }
            if historyDone { setStatus(.ready, "", ix.liveCount) }
        }
        // Remember progress so the next start replays from here.
        ix.lock.write {
            for r in ix.roots {
                if let s = ix.sources[r], s.kind != .fileList, s.monitored {
                    ix.updateSource(r) { $0.lastEventID = maxID }
                }
            }
        }
        dirty = true
    }

    /// Reconciles changed paths with the index (stat outside the lock, apply inside it).
    func applyPaths(_ ix: FileIndex, _ paths: [String], renames: [UInt64: [String]], rescans: [String]) {
        let s = settings
        let filter = ScanFilter(s.scanOptions)
        let now = Clock.wallNanos
        let rc: Int64? = s.indexRecentChanges ? now : nil
        // Detect moves (same inode, old path gone, new path present) to avoid rescanning subtrees.
        var moves: [(String, String)] = []
        var moved = Set<String>()
        for (_, ps) in renames where ps.count >= 2 {
            let gone = ps.filter { statEntry($0) == nil }
            let present = ps.filter { statEntry($0) != nil }
            if let a = gone.first, let b = present.first {
                moves.append((a, b))
                moved.insert(a)
                moved.insert(b)
            }
        }
        var plans: [Planned] = []
        let sorted = paths.sorted { $0.count < $1.count }
        for p in sorted where !moved.contains(p) {
            if let (meta, _) = statEntry(p) {
                var plan = Planned(path: p, exists: true, meta: meta, isMount: false, scan: nil, subtreeRescan: false)
                let name = (p as NSString).lastPathComponent
                if filter.excludes(path: p, name: name, meta: meta) {
                    plan.exists = false
                    plans.append(plan)
                    continue
                }
                if meta.isDirectory {
                    let known: Bool = ix.lock.read { ix.lookup(path: p) != kNoEntry }
                    if !known {
                        if isMountPoint(p) { plan.isMount = true } else {
                            plan.scan = ParallelScanner(options: s.scanOptions).scan(root: p)
                        }
                    }
                }
                plans.append(plan)
            } else {
                let err = lstatErrno(p)
                if err == ENOENT || err == ENOTDIR {
                    plans.append(Planned(path: p, exists: false, meta: nil, isMount: false, scan: nil, subtreeRescan: false))
                }
            }
        }
        var subtreeScans: [(String, ScanResult)] = []
        for r in rescans {
            let isRoot: Bool = ix.lock.read { ix.roots.contains { ix.sources[$0]?.path == r } }
            if isRoot || r == "/" {
                log("events dropped for \(r); reindexing")
                buildAll(reason: "Updating")
                return
            }
            if statEntry(r)?.0.isDirectory == true {
                subtreeScans.append((r, ParallelScanner(options: s.scanOptions).scan(root: r)))
            }
        }
        ix.mutate { x in
            for (a, b) in moves {
                let id = x.lookup(path: a)
                guard id != kNoEntry, let (root, comps) = x.resolveRoot(forPath: b), let last = comps.last else { continue }
                let parentPath = (b as NSString).deletingLastPathComponent
                let parentID = comps.count == 1 ? root : x.lookup(path: parentPath)
                if parentID == kNoEntry { continue }
                let existing = x.lookupChild(parentID, name: String(last))
                if existing != kNoEntry && existing != id { x.remove(existing) }
                x.move(id, to: parentID, name: String(last))
                if let (meta, _) = statEntry(b) { x.update(id, meta: meta, recentChange: rc) }
                if let r = rc { x.setRecentChange(id, r) }
            }
            for plan in plans {
                apply(plan, x, rc)
            }
            for (path, res) in subtreeScans {
                let id = x.lookup(path: path)
                if id != kNoEntry { mergeSubtree(x, id, res, rc) }
            }
        }
        notifyChanged()
    }

    private func apply(_ plan: Planned, _ x: FileIndex, _ rc: Int64?) {
        guard let (root, comps) = x.resolveRoot(forPath: plan.path) else { return }
        if comps.isEmpty {
            if let meta = plan.meta { x.update(root, meta: meta) }
            return
        }
        var cur = root
        let prefix = x.sources[root]?.childPrefix ?? ""
        for (i, c) in comps.dropLast().enumerated() {
            let n = x.lookupChild(cur, name: String(c))
            if n == kNoEntry {
                // Parent missing: create it so the child has somewhere to go.
                guard plan.exists else { return }
                let built = prefix + "/" + comps[0...i].joined(separator: "/")
                let meta = statEntry(built)?.0 ?? EntryMeta(flags: EntryFlag.directory)
                cur = x.add(parent: cur, name: String(c), meta: meta)
                continue
            }
            cur = n
        }
        let name = String(comps.last!)
        let existing = x.lookupChild(cur, name: name)
        if !plan.exists {
            if existing != kNoEntry { x.remove(existing) }
            return
        }
        guard let meta = plan.meta else { return }
        if plan.isMount { return }
        if existing != kNoEntry {
            if x.isDirectory(existing) != meta.isDirectory {
                x.remove(existing)
            } else {
                x.update(existing, meta: meta, recentChange: rc)
                if let r = rc { x.setRecentChange(existing, r) }
                return
            }
        }
        let id = x.add(parent: cur, name: name, meta: meta)
        if let r = rc { x.setRecentChange(id, r) }
        if let res = plan.scan { x.importScan(res, attachTo: id) }
    }

    /// Diffs a fresh scan of a folder against its indexed subtree.
    func mergeSubtree(_ x: FileIndex, _ dir: EntryID, _ res: ScanResult, _ rc: Int64?) {
        // Group scanned records by parent reference.
        var kids: [UInt64: [(Int, Int)]] = [:]
        for (w, b) in res.buffers.enumerated() {
            for k in 0..<b.count { kids[b.parentRef[k], default: []].append((w, k)) }
        }
        func recurse(_ id: EntryID, _ ref: UInt64) {
            let scanned = kids[ref] ?? []
            var names = Set<String>()
            for (w, k) in scanned {
                let b = res.buffers[w]
                let name = String(decoding: UnsafeBufferPointer(start: b.names.base + Int(b.nameOff[k]), count: Int(b.nameLen[k])), as: UTF8.self)
                names.insert(name)
                let meta = EntryMeta(flags: b.flags[k], size: b.size[k], mtime: b.mtime[k], ctime: b.ctime[k], atime: b.atime[k])
                var cid = x.lookupChild(id, name: name)
                if cid != kNoEntry && x.isDirectory(cid) != meta.isDirectory { x.remove(cid); cid = kNoEntry }
                if cid == kNoEntry {
                    cid = x.add(parent: id, name: name, meta: meta)
                    if let r = rc { x.setRecentChange(cid, r) }
                } else if x.update(cid, meta: meta, recentChange: rc) {
                    if let r = rc { x.setRecentChange(cid, r) }
                }
                if meta.isDirectory { recurse(cid, (UInt64(w) << 32) | UInt64(k)) }
            }
            for c in x.children(of: id) where !names.contains(x.name(c)) { x.remove(c) }
        }
        recurse(dir, ScanBuffer.rootRef)
    }

    func isMountPoint(_ p: String) -> Bool {
        #if os(macOS)
        var sfs = statfs()
        guard statfs(p, &sfs) == 0 else { return false }
        let mnt = withUnsafePointer(to: &sfs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
        return mnt == p && p != "/"
        #else
        return false
        #endif
    }

    // MARK: - Volumes, folders, file lists

    /// Adds newly mounted volumes / drops unmounted ones.
    public func checkVolumes() {
        let ix = index
        let mounted = IndexManager.mountedVolumes().filter { includes($0) }
        let current: [String: EntryID] = ix.lock.read {
            var d: [String: EntryID] = [:]
            for r in ix.roots { if let s = ix.sources[r], s.kind == .volume { d[s.path] = r } }
            return d
        }
        var changed = false
        for v in mounted where current[v.path] == nil {
            log("volume mounted: \(v.path)")
            let res = ParallelScanner(options: settings.scanOptions).scan(root: v.path)
            let info = SourceInfo(kind: .volume, path: v.path, name: v.name, fsType: v.fsType, volumeUUID: v.uuid,
                                  eventsUUID: FSWatcher.eventsUUID(forPath: v.path), lastEventID: FSWatcher.currentEventID,
                                  lastScan: Date().timeIntervalSince1970, monitored: true)
            ix.mutate { x in
                let r = x.addRoot(info, meta: statEntry(v.path)?.0 ?? EntryMeta(flags: EntryFlag.directory))
                x.importScan(res, attachTo: r)
            }
            changed = true
        }
        if settings.autoRemoveOfflineVolumes {
            let paths = Set(mounted.map(\.path))
            for (p, r) in current where !paths.contains(p) && p != "/" {
                log("volume gone: \(p)")
                ix.mutate { $0.removeRoot(r) }
                changed = true
            }
        }
        if changed {
            startWatching(ix, since: nil)
            notifyChanged()
        }
    }

    /// Rescans one root (volume or folder) in place.
    public func rescan(path: String) {
        queue.async { [self] in
            let ix = index
            let r: EntryID? = ix.lock.read { ix.roots.first { ix.sources[$0]?.path == path } }
            if let r { rescanSource(ix, root: r) }
        }
    }

    public func rescanAllFolders() {
        queue.async { [self] in
            let ix = index
            let roots: [EntryID] = ix.lock.read { ix.roots.filter { ix.sources[$0]?.kind == .folder } }
            for r in roots { rescanSource(ix, root: r) }
        }
    }

    func rescanSource(_ ix: FileIndex, root: EntryID) {
        guard let s = ix.lock.read({ ix.sources[root] }) else { return }
        guard FileManager.default.fileExists(atPath: s.path) else { return } // offline: keep as is
        setStatus(.scanning, "Rescanning \(s.path)…", ix.liveCount)
        let res = ParallelScanner(options: settings.scanOptions).scan(root: s.path)
        ix.mutate { x in
            mergeSubtree(x, root, res, settings.indexRecentChanges ? Clock.wallNanos : nil)
            x.updateSource(root) {
                $0.lastScan = Date().timeIntervalSince1970
                $0.eventsUUID = FSWatcher.eventsUUID(forPath: s.path)
            }
        }
        if s.kind == .folder {
            var st = settings
            if let i = st.folders.firstIndex(where: { ($0.path as NSString).expandingTildeInPath == s.path }) {
                st.folders[i].lastScan = Date().timeIntervalSince1970
                m.sync { _settings = st }
            }
        }
        dirty = true
        notifyChanged()
        setStatus(.ready, "", ix.liveCount)
    }

    func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func reloadChangedFileLists(_ ix: FileIndex) {
        for fl in settings.fileLists where fl.monitor {
            let p = (fl.path as NSString).expandingTildeInPath
            let stamp = modificationDate(p)
            if let old = fileListStamps[p], old == stamp { continue }
            if fileListStamps[p] == nil && stamp != nil {
                fileListStamps[p] = stamp
                continue
            }
            fileListStamps[p] = stamp
            guard let list = try? FileList.load(URL(fileURLWithPath: p)) else { continue }
            ix.mutate { x in
                if let r = x.roots.first(where: { x.sources[$0]?.fileListPath == p }) { x.removeRoot(r) }
                FileListLoader.add(list, named: (p as NSString).lastPathComponent, path: p, to: x)
            }
            notifyChanged()
        }
    }

    private func scheduleTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Once a minute: scheduled folder rescans, file list monitoring, periodic saves.
    func tick() {
        let s = settings
        let ix = index
        let now = Date()
        let cal = Calendar.current
        for f in s.folders {
            let p = (f.path as NSString).expandingTildeInPath
            let last = f.lastScan.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            var due = false
            switch f.schedule {
            case .never: due = false
            case .every(let minutes): due = now.timeIntervalSince(last) >= Double(Swift.max(1, minutes)) * 60
            case .daily(let hour, let weekday):
                let comps = cal.dateComponents([.hour, .weekday], from: now)
                let rightTime = comps.hour == hour && (weekday == nil || comps.weekday == weekday)
                due = (rightTime && now.timeIntervalSince(last) > 3600) || now.timeIntervalSince(last) > 8 * 86_400
            }
            if due, let r = ix.lock.read({ ix.roots.first { ix.sources[$0]?.path == p } }) { rescanSource(ix, root: r) }
        }
        reloadChangedFileLists(ix)
        if dirty && s.saveDatabaseEveryMinutes > 0 && now.timeIntervalSince(lastSave) > Double(s.saveDatabaseEveryMinutes) * 60 {
            saveNow()
        }
    }

    // MARK: - Saving

    public func save() {
        queue.async { [self] in saveNow() }
    }

    func saveNow() {
        guard !readOnly && !noDatabase else { return }
        let ix = index
        let prev = status
        setStatus(.saving, "Saving database…", ix.liveCount)
        do {
            try Database.save(ix, to: databaseURL)
            dirty = false
            lastSave = Date()
        } catch {
            log("database save failed: \(error)")
        }
        setStatus(prev.phase == .saving ? .ready : prev.phase, prev.message, ix.liveCount)
    }

    /// Replaces the index with a file list or another database (read-only use).
    public func loadDatabase(_ url: URL) throws {
        guard let ix = try Database.load(from: url) else { throw Database.DBError.io("not found") }
        queue.sync {
            watcher?.stop()
            install(ix)
        }
    }

    // MARK: - Privacy

    /// True when the app can read protected locations (Full Disk Access granted).
    public func hasFullDiskAccess() -> Bool {
        #if os(macOS)
        let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(probe, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno == ENOENT
        #else
        return true
        #endif
    }
}
