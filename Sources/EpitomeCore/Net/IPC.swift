import Foundation

/// Local IPC between the `ep` command-line tool (or any client) and the running app.
///
/// Transport: a Unix-domain socket (mode 0600) in the app's support folder.
/// Protocol: one JSON request line; the reply is one JSON header line, then for
/// searches one JSON array per result (raw values), then `{"end":true}`.
public struct IPCRequest: Codable, Sendable {
    public var cmd: String
    public var query: String?
    public var matchCase: Bool?
    public var wholeWord: Bool?
    public var matchPath: Bool?
    public var diacritics: Bool?
    public var regex: Bool?
    public var sort: String?
    public var ascending: Bool?
    public var offset: Int?
    public var count: Int?
    public var fields: [String]?
    public var filter: String?
    public var highlight: Bool?
    public var path: String?
    public var value: Int?
    public var args: [String]?
    public var hideEmpty: Bool?
    public var since: Double?

    public init(cmd: String) { self.cmd = cmd }
}

public enum IPCPaths {
    /// Support folder for an instance ("" = default instance).
    public static func supportDirectory(instance: String = "") -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #else
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        #endif
        let name = instance.isEmpty ? "Epitome" : "Epitome-\(instance)"
        return base.appendingPathComponent(name, isDirectory: true)
    }

    public static func socketPath(instance: String = "") -> String {
        supportDirectory(instance: instance).appendingPathComponent("epitome.sock").path
    }
}

/// Serves IPC requests for the app.
public final class IPCServer: @unchecked Sendable {
    let listener: Listener
    let manager: IndexManager
    /// Filter definitions by lower-cased name (provided by the app).
    public var filters: () -> [String: FilterSpec] = { [:] }
    /// Handles `gui` / control commands; returns a short status text.
    public var control: (IPCRequest) -> String? = { _ in nil }

    public init(path: String, manager: IndexManager) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        listener = try Listener.unix(path: path)
        self.manager = manager
    }

    public func start() {
        listener.serve { [weak self] c in self?.handle(c) }
    }

    public func stop() { listener.close() }

    static func jsonLine(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{}\n" }
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    func handle(_ c: SocketConnection) {
        defer { c.close() }
        guard let line = c.readLine(), let data = line.data(using: .utf8),
              let req = try? JSONDecoder().decode(IPCRequest.self, from: data) else {
            c.write(IPCServer.jsonLine(["ok": false, "error": "bad request"]))
            return
        }
        switch req.cmd {
        case "version":
            c.write(IPCServer.jsonLine(["ok": true, "version": EpitomeVersion.string, "build": EpitomeVersion.build]))
        case "status":
            let st = manager.status
            let ix = manager.index
            c.write(IPCServer.jsonLine(["ok": true, "phase": st.phase.rawValue, "message": st.message,
                                        "entries": ix.liveCount, "loaded": st.phase != .loading && ix.liveCount > 0]))
        case "search":
            search(req, c)
        case "run-count":
            guard let p = req.path else { c.write(IPCServer.jsonLine(["ok": false, "error": "missing path"])); return }
            let rh = manager.runHistory
            if let v = req.value { rh.set(path: p, count: v) }
            if req.args?.contains("inc") == true { rh.recordRun(path: p) }
            c.write(IPCServer.jsonLine(["ok": true, "count": rh.record(for: p)?.count ?? 0]))
        case "folder-size":
            guard let p = req.path else { c.write(IPCServer.jsonLine(["ok": false, "error": "missing path"])); return }
            let ix = manager.index
            let size: Int64 = ix.lock.read {
                let id = ix.lookup(path: (p as NSString).standardizingPath)
                guard id != kNoEntry else { return -1 }
                if ix.folderSizesEnabled { return ix.size[Int(id)] }
                var total: Int64 = 0
                ix.forEachDescendant(id) { e in if !ix.isDirectory(e) { total += Swift.max(0, ix.size[Int(e)]) } }
                return total
            }
            c.write(IPCServer.jsonLine(["ok": size >= 0, "size": size]))
        case "journal":
            let since = Int64((req.since ?? 0) * 1e9)
            let recs = manager.journal.snapshot().filter { $0.time >= since }
            c.write(IPCServer.jsonLine(["ok": true, "count": recs.count]))
            let filterPat = req.query.flatMap { $0.isEmpty ? nil : WildcardPattern(Wildcard.hasWildcards($0) ? $0 : "*" + $0 + "*") }
            for r in recs {
                if let f = filterPat, !f.matches((r.path as NSString).lastPathComponent) && !f.matches(r.path) { continue }
                c.write(IPCServer.jsonLine([String(r.time), r.action.rawValue, r.isFolder ? "folder" : "file", r.path]))
            }
            c.write(IPCServer.jsonLine(["end": true]))
        case "reindex":
            manager.rebuild()
            c.write(IPCServer.jsonLine(["ok": true]))
        case "save-db":
            manager.save()
            c.write(IPCServer.jsonLine(["ok": true]))
        case "rescan-all":
            manager.rescanAllFolders()
            c.write(IPCServer.jsonLine(["ok": true]))
        default:
            if let msg = control(req) {
                c.write(IPCServer.jsonLine(["ok": true, "message": msg]))
            } else {
                c.write(IPCServer.jsonLine(["ok": false, "error": "unknown command \(req.cmd)"]))
            }
        }
    }

    func search(_ req: IPCRequest, _ c: SocketConnection) {
        let s = manager.settings
        var opts = SearchOptions()
        opts.matchCase = req.matchCase ?? false
        opts.matchWholeWord = req.wholeWord ?? false
        opts.matchPath = req.matchPath ?? false
        opts.matchDiacritics = req.diacritics ?? false
        opts.regex = req.regex ?? false
        let key = req.sort.flatMap(SortKey.parse) ?? .name
        var r = SearchRequest(text: req.query ?? "", options: opts, sort: key,
                              ascending: req.ascending ?? true, foldersFirst: s.foldersFirst, syntax: s.syntax)
        if let f = req.filter?.lowercased(), let spec = filters()[f] { r.filter = spec }
        r.offset = req.offset ?? 0
        r.limit = req.count
        r.hideWhenEmpty = req.hideEmpty ?? false
        let ix = manager.index
        guard let res = SearchEngine.run(r, index: ix, services: manager.services) else {
            c.write(IPCServer.jsonLine(["ok": false, "error": "cancelled"]))
            return
        }
        let fields = (req.fields ?? ["full-path"]).compactMap { Column(rawValue: $0) }
        let reader = RowReader(index: ix, program: res.program, services: manager.services, formatter: ValueFormatter())
        ix.lock.read {
            var files = 0, folders = 0
            var totalSize: Int64 = 0
            for id in res.ids {
                if ix.isDirectory(id) { folders += 1 } else {
                    files += 1
                    totalSize += Swift.max(0, ix.size[Int(id)])
                }
            }
            var header: [String: Any] = ["ok": true, "total": res.totalCount, "returned": res.count, "files": files,
                                         "folders": folders, "totalSize": totalSize, "fields": fields.map(\.rawValue),
                                         "elapsed": res.elapsed]
            if !res.errors.isEmpty { header["errors"] = res.errors }
            if req.highlight == true {
                header["highlights"] = res.highlights.map { ["text": $0.text, "path": $0.path, "case": $0.caseSensitive] }
            }
            c.write(IPCServer.jsonLine(header))
            var batch = ""
            batch.reserveCapacity(64 * 1024)
            for id in res.ids {
                let row: [Any] = [ix.isDirectory(id) ? 1 : 0] + fields.map { f -> Any in
                    let i = Int(id)
                    switch f {
                    case .size: return String(ix.size[i])
                    case .dateModified: return String(ix.mtime[i])
                    case .dateCreated: return String(ix.ctime[i])
                    case .dateAccessed: return String(ix.atime[i])
                    case .dateRecentlyChanged: return String(ix.rctime[i])
                    case .attributes: return String(ix.flags[i] & EntryFlag.attributeMask)
                    default: return reader.string(f, id)
                    }
                }
                batch += IPCServer.jsonLine(row)
                if batch.utf8.count > 60_000 {
                    if !c.write(batch) { return }
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { c.write(batch) }
        }
        c.write(IPCServer.jsonLine(["end": true]))
    }
}

/// Client side used by `ep` and by a second app launch forwarding its arguments.
public enum IPCClient {
    public static func send(_ req: IPCRequest, instance: String = "", socketPath: String? = nil, onLine: (Any) -> Bool) -> Bool {
        guard let c = Connector.unix(path: socketPath ?? IPCPaths.socketPath(instance: instance)) else { return false }
        defer { c.close() }
        guard let d = try? JSONEncoder().encode(req) else { return false }
        c.write(String(decoding: d, as: UTF8.self) + "\n")
        while let line = c.readLine(max: 64 << 20) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { continue }
            if let dict = obj as? [String: Any], dict["end"] as? Bool == true { break }
            if !onLine(obj) { break }
        }
        return true
    }

    /// Single-response convenience.
    public static func call(_ req: IPCRequest, instance: String = "") -> [String: Any]? {
        var out: [String: Any]?
        let ok = send(req, instance: instance) { obj in
            out = obj as? [String: Any]
            return false
        }
        return ok ? out : nil
    }

    public static func isRunning(instance: String = "") -> Bool {
        call(IPCRequest(cmd: "version"), instance: instance) != nil
    }
}
