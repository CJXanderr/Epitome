import Foundation

/// Built-in web server: search the index from a browser, browse folders,
/// download files, and get JSON results (`?search=…&json=1`).
public final class HTTPServer: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var port: UInt16 = 8080
        public var bind = ""
        public var username = ""
        public var password = ""
        public var allowDownload = true
        public var logging = true
        public var logPath = ""
        public var logMaxKB = 4096
        public var defaultPage = ""
        public var servePagesFrom = ""
        public var title = "Epitome"
        public init() {}
    }

    let manager: IndexManager
    private var listener: Listener?
    public private(set) var config = Config()
    private let logLock = Mutex()
    public var filters: () -> [String: FilterSpec] = { [:] }
    public var isRunning: Bool { listener != nil }
    public var boundPort: UInt16 { listener?.port ?? 0 }

    public init(manager: IndexManager) {
        self.manager = manager
    }

    public func start(_ cfg: Config) throws {
        stop()
        config = cfg
        let l = try Listener.tcp(port: cfg.port, bind: cfg.bind)
        listener = l
        l.serve { [weak self] c in self?.serveConnection(c) }
    }

    public func stop() {
        listener?.close()
        listener = nil
    }

    // MARK: - Request handling

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var version: String
    }

    func serveConnection(_ c: SocketConnection) {
        c.timeoutSeconds = 30
        defer { c.close() }
        while let line = c.readLine(max: 16_384), !line.isEmpty {
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return }
            var headers: [String: String] = [:]
            while let h = c.readLine(max: 16_384), !h.isEmpty {
                if let colon = h.firstIndex(of: ":") {
                    headers[h[..<colon].lowercased()] = h[h.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            if let len = headers["content-length"].flatMap(Int.init), len > 0, len < 1 << 20 { _ = c.readBytes(len) }
            let target = String(parts[1])
            var path = target
            var qs = ""
            if let q = target.firstIndex(of: "?") {
                path = String(target[..<q])
                qs = String(target[target.index(after: q)...])
            }
            let req = Request(method: String(parts[0]).uppercased(), path: HTTPServer.percentDecode(path),
                              query: HTTPServer.parseQuery(qs), headers: headers,
                              version: parts.count > 2 ? String(parts[2]) : "HTTP/1.0")
            let keep = respond(req, c)
            let wantsClose = headers["connection"]?.lowercased() == "close" || (req.version == "HTTP/1.0" && headers["connection"]?.lowercased() != "keep-alive")
            if !keep || wantsClose { return }
        }
    }

    static func percentDecode(_ s: String) -> String {
        (s.replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding) ?? s
    }

    static func parseQuery(_ qs: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in qs.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
            out[k.lowercased()] = v
        }
        return out
    }

    static func encodePath(_ p: String) -> String {
        p.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;"))) ?? String($0)
        }.joined(separator: "/")
    }

    static func encodeQuery(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    func log(_ c: SocketConnection, _ req: Request, _ status: Int) {
        guard config.logging, !config.logPath.isEmpty else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(c.peer) \(req.method) \(req.path) \(status)\n"
        logLock.sync {
            let url = URL(fileURLWithPath: config.logPath)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                let size = h.offsetInFile
                h.closeFile()
                if size > UInt64(config.logMaxKB) * 1024, let d = try? Data(contentsOf: url) {
                    try? d.suffix(d.count / 2).write(to: url)
                }
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    func send(_ c: SocketConnection, status: Int, type: String, body: Data, extra: [String: String] = [:], head: Bool = false) -> Bool {
        let reason: [Int: String] = [200: "OK", 206: "Partial Content", 301: "Moved Permanently", 304: "Not Modified", 400: "Bad Request",
                                     401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 416: "Range Not Satisfiable", 500: "Internal Server Error"]
        var h = "HTTP/1.1 \(status) \(reason[status] ?? "OK")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nServer: Epitome/\(EpitomeVersion.string)\r\n"
        for (k, v) in extra { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        guard c.write(h) else { return false }
        return head ? true : c.write(body)
    }

    func authorized(_ req: Request) -> Bool {
        if config.username.isEmpty && config.password.isEmpty { return true }
        guard let auth = req.headers["authorization"], auth.lowercased().hasPrefix("basic "),
              let d = Data(base64Encoded: String(auth.dropFirst(6))), let s = String(data: d, encoding: .utf8) else { return false }
        return s == config.username + ":" + config.password
    }

    /// Returns false when the connection should be closed.
    func respond(_ req: Request, _ c: SocketConnection) -> Bool {
        let head = req.method == "HEAD"
        guard req.method == "GET" || head else {
            log(c, req, 400)
            return send(c, status: 400, type: "text/plain", body: Data("Only GET is supported\n".utf8))
        }
        guard authorized(req) else {
            log(c, req, 401)
            return send(c, status: 401, type: "text/html", body: Data("<h1>Authentication required</h1>".utf8),
                        extra: ["WWW-Authenticate": "Basic realm=\"\(config.title)\""])
        }
        if req.path.hasPrefix("/__epitome/") {
            let name = String(req.path.dropFirst("/__epitome/".count))
            if let asset = HTTPAssets.files[name] {
                log(c, req, 200)
                return send(c, status: 200, type: asset.0, body: Data(asset.1.utf8), extra: ["Cache-Control": "max-age=86400"], head: head)
            }
        }
        if !config.servePagesFrom.isEmpty, req.path.hasPrefix("/__pages/") {
            let rel = String(req.path.dropFirst("/__pages/".count))
            let base = URL(fileURLWithPath: (config.servePagesFrom as NSString).expandingTildeInPath)
            let f = base.appendingPathComponent(rel).standardized
            if f.path.hasPrefix(base.standardized.path), let d = try? Data(contentsOf: f) {
                log(c, req, 200)
                return send(c, status: 200, type: HTTPServer.mimeType(f.path), body: d, head: head)
            }
        }
        let q = req.query
        let hasSearch = q["search"] != nil || q["s"] != nil || q["q"] != nil
        let json = (q["json"] ?? q["j"]).map { $0 != "0" && !$0.isEmpty } ?? false
        if req.path == "/" || req.path.isEmpty || hasSearch && req.path == "/" {
            if !hasSearch && !json {
                if !config.defaultPage.isEmpty, let d = try? Data(contentsOf: URL(fileURLWithPath: (config.defaultPage as NSString).expandingTildeInPath)) {
                    log(c, req, 200)
                    return send(c, status: 200, type: "text/html; charset=utf-8", body: d, head: head)
                }
                log(c, req, 200)
                return send(c, status: 200, type: "text/html; charset=utf-8", body: Data(homePage().utf8), head: head)
            }
            return searchResponse(req, c, json: json, head: head)
        }
        // A path: folder listing or file download.
        let ix = manager.index
        var p = req.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        let id: EntryID = ix.lock.read { ix.lookup(path: p) }
        let isDir: Bool = id != kNoEntry ? ix.lock.read { ix.isDirectory(id) } : false
        var isDirOnDisk: ObjCBool = false
        let existsOnDisk = FileManager.default.fileExists(atPath: p, isDirectory: &isDirOnDisk)
        if (id != kNoEntry && isDir) || (id == kNoEntry && existsOnDisk && isDirOnDisk.boolValue && hasRootBelow(p)) {
            if !req.path.hasSuffix("/") {
                log(c, req, 301)
                return send(c, status: 301, type: "text/plain", body: Data(), extra: ["Location": HTTPServer.encodePath(p == "/" ? "/" : p + "/")])
            }
            return folderResponse(req, c, folderPath: p, id: id, json: json, head: head)
        }
        if id != kNoEntry || existsOnDisk {
            guard config.allowDownload else {
                log(c, req, 403)
                return send(c, status: 403, type: "text/plain", body: Data("Downloads are disabled\n".utf8))
            }
            guard id != kNoEntry else {
                log(c, req, 404)
                return send(c, status: 404, type: "text/plain", body: Data("Not in the index\n".utf8))
            }
            return fileResponse(req, c, path: p, head: head)
        }
        log(c, req, 404)
        return send(c, status: 404, type: "text/html; charset=utf-8", body: Data(page(title: "Not found", body: "<p class=\"empty\">Nothing at \(HTTPServer.html(p)).</p>").utf8), head: head)
    }

    func hasRootBelow(_ p: String) -> Bool {
        let ix = manager.index
        return ix.lock.read { ix.roots.contains { (ix.sources[$0]?.path ?? "").hasPrefix(p == "/" ? "/" : p + "/") } }
    }

    // MARK: - Search

    func request(from q: [String: String]) -> SearchRequest {
        func flag(_ a: String, _ b: String) -> Bool { (q[a] ?? q[b]).map { $0 != "0" && !$0.isEmpty } ?? false }
        let s = manager.settings
        var o = SearchOptions()
        o.matchCase = flag("case", "i")
        o.matchWholeWord = flag("wholeword", "w") || flag("whole_word", "ww")
        o.matchPath = flag("path", "p")
        o.regex = flag("regex", "r")
        o.matchDiacritics = flag("diacritics", "m")
        let sortName = (q["sort"] ?? "name").lowercased()
        let key = SortKey.parse(sortName) ?? .name
        let asc = q["ascending"].map { $0 != "0" } ?? true
        var r = SearchRequest(text: q["search"] ?? q["s"] ?? q["q"] ?? "", options: o, sort: key, ascending: asc,
                              foldersFirst: s.foldersFirst, syntax: s.syntax)
        if let f = q["filter"]?.lowercased(), let spec = filters()[f] { r.filter = spec }
        return r
    }

    func searchResponse(_ req: Request, _ c: SocketConnection, json: Bool, head: Bool) -> Bool {
        let q = req.query
        var r = request(from: q)
        let offset = Int(q["offset"] ?? q["o"] ?? "0") ?? 0
        let count = Int(q["count"] ?? q["c"] ?? "") ?? (json ? Int.max : 32)
        r.offset = Swift.max(0, offset)
        r.limit = count == Int.max ? nil : Swift.max(0, count)
        let ix = manager.index
        guard let res = SearchEngine.run(r, index: ix, services: manager.services) else {
            return send(c, status: 500, type: "text/plain", body: Data("cancelled".utf8))
        }
        if json {
            func on(_ k: String) -> Bool { q[k].map { $0 != "0" && !$0.isEmpty } ?? false }
            let items: [[String: Any]] = ix.lock.read {
                res.ids.map { id in
                    var d: [String: Any] = ["type": ix.isDirectory(id) ? "folder" : "file", "name": ix.name(id)]
                    if on("path_column") { d["path"] = ix.parentPath(id) }
                    if on("size_column") && ix.size[Int(id)] >= 0 { d["size"] = String(ix.size[Int(id)]) }
                    if on("date_modified_column") && ix.mtime[Int(id)] != kUnknownTime { d["date_modified"] = String(FileList.nanosToFiletime(ix.mtime[Int(id)])) }
                    if on("date_created_column") && ix.ctime[Int(id)] != kUnknownTime { d["date_created"] = String(FileList.nanosToFiletime(ix.ctime[Int(id)])) }
                    if on("attributes_column") { d["attributes"] = String(FileList.attributes(fromFlags: ix.flags[Int(id)])) }
                    return d
                }
            }
            let obj: [String: Any] = ["totalResults": res.totalCount, "results": items]
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
            log(c, req, 200)
            return send(c, status: 200, type: "application/json; charset=utf-8", body: data, extra: ["Access-Control-Allow-Origin": "*"], head: head)
        }
        let body = resultsTable(res, query: q, offset: r.offset, count: count, folderMode: false)
        log(c, req, 200)
        return send(c, status: 200, type: "text/html; charset=utf-8",
                    body: Data(page(title: r.text.isEmpty ? config.title : "\(r.text) - \(config.title)", body: body, search: r.text).utf8), head: head)
    }

    func folderResponse(_ req: Request, _ c: SocketConnection, folderPath: String, id: EntryID, json: Bool, head: Bool) -> Bool {
        let ix = manager.index
        let q = req.query
        let key = SortKey.parse(q["sort"] ?? "name") ?? .name
        let asc = q["ascending"].map { $0 != "0" } ?? true
        let ids: [EntryID] = ix.lock.read {
            var kids = id == kNoEntry ? [] : ix.children(of: id)
            let prefix = folderPath == "/" ? "/" : folderPath + "/"
            for r in ix.roots where !ix.isDeleted(r) {
                guard let s = ix.sources[r], s.kind != .fileList, s.path.hasPrefix(prefix), s.path != folderPath else { continue }
                if !s.path.dropFirst(prefix.count).contains("/") { kids.append(r) }
            }
            let ord = ix.makeOrdering()
            kids.sort { a, b in
                let da = ix.isDirectory(a), db = ix.isDirectory(b)
                if da != db { return da }
                let cmp = ord.compare(key, a, b)
                return asc ? cmp < 0 : cmp > 0
            }
            return kids
        }
        if json {
            let items: [[String: Any]] = ix.lock.read {
                ids.map { e in
                    var d: [String: Any] = ["type": ix.isDirectory(e) ? "folder" : "file", "name": ix.name(e), "path": folderPath]
                    if ix.size[Int(e)] >= 0 { d["size"] = String(ix.size[Int(e)]) }
                    if ix.mtime[Int(e)] != kUnknownTime { d["date_modified"] = String(FileList.nanosToFiletime(ix.mtime[Int(e)])) }
                    return d
                }
            }
            let data = (try? JSONSerialization.data(withJSONObject: ["totalResults": ids.count, "results": items])) ?? Data()
            log(c, req, 200)
            return send(c, status: 200, type: "application/json; charset=utf-8", body: data, head: head)
        }
        let fake = SearchResults(index: ix, generation: ix.generation, ids: ids, totalCount: ids.count, highlights: [],
                                 errors: [], elapsed: 0, request: SearchRequest(text: ""), program: nil)
        var crumbs = "<a href=\"/\">⌂</a>"
        var acc = ""
        for comp in folderPath.split(separator: "/") {
            acc += "/" + comp
            crumbs += " / <a href=\"\(HTTPServer.encodePath(acc))/\">\(HTTPServer.html(String(comp)))</a>"
        }
        let body = "<nav class=\"crumbs\">\(crumbs)</nav>" + resultsTable(fake, query: q, offset: 0, count: Int.max, folderMode: true)
        log(c, req, 200)
        return send(c, status: 200, type: "text/html; charset=utf-8", body: Data(page(title: "\(folderPath) - \(config.title)", body: body).utf8), head: head)
    }

    func fileResponse(_ req: Request, _ c: SocketConnection, path: String, head: Bool) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            log(c, req, 404)
            return send(c, status: 404, type: "text/plain", body: Data("Cannot open file\n".utf8))
        }
        defer { fh.closeFile() }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.int64Value ?? 0)
        var start: Int64 = 0
        var end: Int64 = size - 1
        var status = 200
        if let range = req.headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 {
                if parts[0].isEmpty, let suffix = Int64(parts[1]) { start = Swift.max(0, size - suffix) }
                else {
                    start = Int64(parts[0]) ?? 0
                    if let e = Int64(parts[1]) { end = Swift.min(e, size - 1) }
                }
                if start > end || start >= size {
                    log(c, req, 416)
                    return send(c, status: 416, type: "text/plain", body: Data(), extra: ["Content-Range": "bytes */\(size)"])
                }
                status = 206
            }
        }
        let length = size == 0 ? 0 : end - start + 1
        var h = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\nContent-Type: \(HTTPServer.mimeType(path))\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\nServer: Epitome/\(EpitomeVersion.string)\r\n"
        if status == 206 { h += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        let fname = (path as NSString).lastPathComponent
        h += "Content-Disposition: inline; filename*=UTF-8''\(HTTPServer.encodeQuery(fname))\r\n\r\n"
        guard c.write(h) else { return false }
        log(c, req, status)
        if head { return true }
        fh.seek(toFileOffset: UInt64(start))
        var remaining = length
        while remaining > 0 {
            let chunk = fh.readData(ofLength: Int(Swift.min(remaining, 256 * 1024)))
            if chunk.isEmpty { return false }
            if !c.write(chunk) { return false }
            remaining -= Int64(chunk.count)
        }
        return true
    }

    static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "txt", "log", "md", "swift", "c", "h", "py", "sh", "csv", "efu": return "text/plain; charset=utf-8"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    // MARK: - HTML

    func page(title: String, body: String, search: String = "") -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(HTTPServer.html(title))</title><link rel="stylesheet" href="/__epitome/style.css"></head>
        <body><header><a class="brand" href="/">\(HTTPServer.html(config.title))</a>
        <form action="/" method="get"><input type="search" name="search" value="\(HTTPServer.html(search))" placeholder="Search" autofocus>
        <button type="submit">Search</button></form></header><main>\(body)</main></body></html>
        """
    }

    func homePage() -> String {
        let ix = manager.index
        let rows: String = ix.lock.read {
            ix.roots.compactMap { r -> String? in
                guard let s = ix.sources[r], s.kind != .fileList, !ix.isDeleted(r) else { return nil }
                let href = HTTPServer.encodePath(s.path == "/" ? "/" : s.path + "/")
                return "<tr><td class=\"name\"><span class=\"icon folder\"></span><a href=\"\(href)\">\(HTTPServer.html(s.name))</a></td><td class=\"path\">\(HTTPServer.html(s.path))</td></tr>"
            }.joined()
        }
        return page(title: config.title, body: "<h2>Indexed volumes and folders</h2><table class=\"results\"><thead><tr><th>Name</th><th>Location</th></tr></thead><tbody>\(rows)</tbody></table>")
    }

    func resultsTable(_ res: SearchResults, query q: [String: String], offset: Int, count: Int, folderMode: Bool) -> String {
        let ix = res.index
        let fmt = ValueFormatter(settings: manager.settings)
        let sortKey = (q["sort"] ?? "name").lowercased()
        let asc = q["ascending"].map { $0 != "0" } ?? true
        func headerLink(_ title: String, _ key: String, defaultAsc: Bool) -> String {
            var qq = q
            qq["sort"] = key
            let nowAsc = sortKey == key ? !asc : defaultAsc
            qq["ascending"] = nowAsc ? "1" : "0"
            qq["offset"] = "0"
            let link = "?" + qq.map { "\(HTTPServer.encodeQuery($0.key))=\(HTTPServer.encodeQuery($0.value))" }.sorted().joined(separator: "&")
            let arrow = sortKey == key ? (asc ? " ▲" : " ▼") : ""
            return "<th><a href=\"\(link)\">\(title)\(arrow)</a></th>"
        }
        var html = ""
        if !folderMode {
            let n = res.totalCount
            html += "<p class=\"count\">\(fmt.grouped(Int64(n))) result\(n == 1 ? "" : "s")</p>"
        }
        html += "<table class=\"results\"><thead><tr>"
        html += headerLink("Name", "name", defaultAsc: true)
        if !folderMode { html += headerLink("Path", "path", defaultAsc: true) }
        html += headerLink("Size", "size", defaultAsc: false)
        html += headerLink("Date Modified", "date_modified", defaultAsc: false)
        html += "</tr></thead><tbody>"
        ix.lock.read {
            for id in res.ids {
                let isDir = ix.isDirectory(id)
                let full = ix.path(id)
                let name = ix.isRoot(id) ? (ix.sources[id]?.name ?? ix.name(id)) : ix.name(id)
                let href = HTTPServer.encodePath(full) + (isDir && full != "/" ? "/" : "")
                let parent = ix.parentPath(id)
                html += "<tr><td class=\"name\"><span class=\"icon \(isDir ? "folder" : "file")\"></span><a href=\"\(href)\">\(HTTPServer.html(name))</a></td>"
                if !folderMode {
                    html += "<td class=\"path\"><a href=\"\(HTTPServer.encodePath(parent.isEmpty ? "/" : parent + "/"))\">\(HTTPServer.html(parent))</a></td>"
                }
                html += "<td class=\"size\">\(isDir && ix.size[Int(id)] < 0 ? "" : fmt.size(ix.size[Int(id)]))</td><td class=\"date\">\(fmt.date(ix.mtime[Int(id)]))</td></tr>"
            }
        }
        html += "</tbody></table>"
        if res.ids.isEmpty { html += "<p class=\"empty\">No results.</p>" }
        if !folderMode && count != Int.max && res.totalCount > count {
            var nav = "<nav class=\"pages\">"
            func link(_ off: Int, _ label: String) -> String {
                var qq = q
                qq["offset"] = String(off)
                return "<a href=\"?" + qq.map { "\(HTTPServer.encodeQuery($0.key))=\(HTTPServer.encodeQuery($0.value))" }.sorted().joined(separator: "&") + "\">\(label)</a>"
            }
            if offset > 0 { nav += link(Swift.max(0, offset - count), "← Previous") }
            let pageNo = offset / Swift.max(1, count) + 1
            let pages = (res.totalCount + count - 1) / Swift.max(1, count)
            nav += "<span>Page \(pageNo) of \(pages)</span>"
            if offset + count < res.totalCount { nav += link(offset + count, "Next →") }
            html += nav + "</nav>"
        }
        return html
    }
}

enum HTTPAssets {
    static let css = """
    :root{--bg:#fbfbfd;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--accent:#5b4cdb;--row:#f2f1fb}
    @media (prefers-color-scheme:dark){:root{--bg:#161618;--fg:#f2f2f7;--muted:#9a9aa0;--line:#2c2c30;--accent:#9d93ff;--row:#22212b}}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
    header{position:sticky;top:0;display:flex;gap:16px;align-items:center;padding:12px 20px;background:var(--bg);border-bottom:1px solid var(--line);z-index:2}
    .brand{font-weight:700;font-size:17px;letter-spacing:.2px;color:var(--fg);text-decoration:none}
    .brand::before{content:"";display:inline-block;width:14px;height:14px;margin-right:8px;border-radius:4px;background:linear-gradient(135deg,var(--accent),#ff8a5b);vertical-align:-2px}
    form{display:flex;flex:1;gap:8px;max-width:760px}input[type=search]{flex:1;padding:8px 12px;border:1px solid var(--line);border-radius:8px;background:transparent;color:var(--fg);font-size:15px}
    input[type=search]:focus{outline:2px solid var(--accent);outline-offset:-1px}button{padding:8px 14px;border:0;border-radius:8px;background:var(--accent);color:#fff;font-weight:600;cursor:pointer}
    main{padding:12px 20px 40px}h2{font-size:15px;color:var(--muted);font-weight:600}.count,.crumbs{color:var(--muted);margin:6px 0 10px}
    .crumbs a{color:var(--fg)}table.results{width:100%;border-collapse:collapse;table-layout:auto}
    th{text-align:left;font-weight:600;color:var(--muted);border-bottom:1px solid var(--line);padding:6px 8px;white-space:nowrap}th a{color:inherit;text-decoration:none}
    td{padding:5px 8px;border-bottom:1px solid var(--line);vertical-align:top}tr:hover td{background:var(--row)}
    td.name a{color:var(--fg);text-decoration:none;font-weight:500}td.path a{color:var(--muted);text-decoration:none}td.size,td.date{white-space:nowrap;color:var(--muted)}td.size{text-align:right}
    .icon{display:inline-block;width:16px;height:16px;margin-right:8px;vertical-align:-3px;background-size:contain;background-repeat:no-repeat}
    .icon.folder{background-image:url(/__epitome/folder.svg)}.icon.file{background-image:url(/__epitome/file.svg)}
    .pages{display:flex;gap:16px;align-items:center;margin-top:16px}.pages a{color:var(--accent)}.empty{color:var(--muted)}
    @media (max-width:640px){td.path,th:nth-child(2){display:none}header{flex-wrap:wrap}}
    """
    static let folder = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><path fill='#5b8def' d='M1 3.5A1.5 1.5 0 0 1 2.5 2h3.6l1.4 1.5h6A1.5 1.5 0 0 1 15 5v7.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 1 12.5z'/></svg>"
    static let file = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><path fill='#9aa0aa' d='M3 1.5A1.5 1.5 0 0 1 4.5 0H10l4 4v10.5a1.5 1.5 0 0 1-1.5 1.5h-8A1.5 1.5 0 0 1 3 14.5z'/><path fill='#d7dae0' d='M10 0v3a1 1 0 0 0 1 1h3z'/></svg>"
    static let files: [String: (String, String)] = [
        "style.css": ("text/css; charset=utf-8", css),
        "folder.svg": ("image/svg+xml", folder),
        "file.svg": ("image/svg+xml", file),
    ]
}
