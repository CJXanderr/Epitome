import Foundation

/// A result row coming from a remote Epitome (ETP) server.
public struct RemoteRow: Sendable, Equatable {
    public var isFolder: Bool
    public var path: String   // containing folder
    public var name: String
    public var size: Int64
    public var mtime: Int64
    public var ctime: Int64
    public var attributes: UInt32

    public var fullPath: String { path.isEmpty ? name : (path == "/" ? "/" + name : path + "/" + name) }
}

/// FTP server with a search extension ("ETP"): ordinary FTP clients can log
/// in, browse the indexed folders and download files; Epitome clients can also
/// search with `SITE EVERYTHING …` (alias `SITE EPITOME …`).
public final class ETPServer: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var port: UInt16 = 2121
        public var bind = ""
        public var username = ""
        public var password = ""
        public var allowDownload = true
        public var logging = true
        public var logPath = ""
        public var logMaxKB = 4096
        public var welcome = ""
        public init() {}
    }

    let manager: IndexManager
    private var listener: Listener?
    public private(set) var config = Config()
    public var filters: () -> [String: FilterSpec] = { [:] }
    private let logLock = Mutex()
    public var isRunning: Bool { listener != nil }
    public var boundPort: UInt16 { listener?.port ?? 0 }

    public init(manager: IndexManager) { self.manager = manager }

    public func start(_ cfg: Config) throws {
        stop()
        config = cfg
        let l = try Listener.tcp(port: cfg.port, bind: cfg.bind)
        listener = l
        l.serve { [weak self] c in self?.session(c) }
    }

    public func stop() {
        listener?.close()
        listener = nil
    }

    func log(_ c: SocketConnection, _ line: String) {
        guard config.logging, !config.logPath.isEmpty else { return }
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(c.peer) \(line)\n"
        logLock.sync {
            let url = URL(fileURLWithPath: config.logPath)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                let size = h.offsetInFile
                h.closeFile()
                if size > UInt64(config.logMaxKB) * 1024, let d = try? Data(contentsOf: url) { try? d.suffix(d.count / 2).write(to: url) }
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }

    final class Session {
        var user = ""
        var loggedIn = false
        var cwd = "/"
        var passive: Listener?
        var active: (String, UInt16)?
        var rest: Int64 = 0
        var renameFrom: String?
        // search state
        var search = ""
        var options = SearchOptions()
        var filterSearch = ""
        var filterOptions = SearchOptions()
        var sort: SortKey = .name
        var ascending = true
        var offset = 0
        var count = 100
        var hideEmpty = false
        var columns: Set<String> = ["path", "size", "date_modified"]
    }

    func reply(_ c: SocketConnection, _ code: Int, _ text: String) {
        c.write("\(code) \(text)\r\n")
    }

    func resolve(_ s: Session, _ arg: String) -> String {
        var p = arg.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return s.cwd }
        if !p.hasPrefix("/") { p = (s.cwd == "/" ? "/" : s.cwd + "/") + p }
        let std = (p as NSString).standardizingPath
        return std.isEmpty ? "/" : std
    }

    /// Children of a folder from the index (plus volume roots mounted below it).
    func listing(_ path: String) -> [EntryID]? {
        let ix = manager.index
        return ix.lock.read {
            let id = ix.lookup(path: path)
            var kids: [EntryID] = []
            if id != kNoEntry {
                guard ix.isDirectory(id) else { return nil }
                kids = ix.children(of: id)
            }
            let prefix = path == "/" ? "/" : path + "/"
            for r in ix.roots where !ix.isDeleted(r) {
                guard let src = ix.sources[r], src.kind != .fileList, src.path.hasPrefix(prefix), src.path != path,
                      !src.path.dropFirst(prefix.count).contains("/") else { continue }
                kids.append(r)
            }
            if id == kNoEntry && kids.isEmpty { return nil }
            let ord = ix.makeOrdering()
            kids.sort { a, b in ord.compareName(a, b) < 0 }
            return kids
        }
    }

    func openData(_ s: Session) -> SocketConnection? {
        if let l = s.passive {
            s.passive = nil
            defer { l.close() }
            var pfd = pollfd(fd: l.fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 20_000) > 0 else { return nil }
            return l.accept()
        }
        if let (h, p) = s.active {
            s.active = nil
            return Connector.tcp(host: h, port: p)
        }
        return nil
    }

    static func lsLine(_ ix: FileIndex, _ id: EntryID) -> String {
        let isDir = ix.isDirectory(id)
        let size = Swift.max(0, ix.size[Int(id)])
        let t = ix.mtime[Int(id)] == kUnknownTime ? Date() : Date(timeIntervalSince1970: Double(ix.mtime[Int(id)]) / 1e9)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Date().timeIntervalSince(t) > 180 * 86_400 ? "MMM dd  yyyy" : "MMM dd HH:mm"
        let name = ix.isRoot(id) ? ((ix.sources[id]?.path ?? "") as NSString).lastPathComponent : ix.name(id)
        let perms = isDir ? "drwxr-xr-x" : (ix.flags[Int(id)] & EntryFlag.readOnly != 0 ? "-r--r--r--" : "-rw-r--r--")
        return "\(perms) 1 owner group \(String(size).leftPad(13)) \(f.string(from: t)) \(name)\r\n"
    }

    static func mlsxFacts(_ ix: FileIndex, _ id: EntryID) -> String {
        let isDir = ix.isDirectory(id)
        var facts = "type=\(isDir ? "dir" : "file");"
        if !isDir { facts += "size=\(Swift.max(0, ix.size[Int(id)]));" }
        if ix.mtime[Int(id)] != kUnknownTime {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMddHHmmss"
            facts += "modify=\(f.string(from: Date(timeIntervalSince1970: Double(ix.mtime[Int(id)]) / 1e9)));"
        }
        return facts
    }

    static func escapeField(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    }

    func session(_ c: SocketConnection) {
        c.timeoutSeconds = 600
        defer { c.close() }
        let s = Session()
        let welcome = config.welcome.isEmpty ? "Epitome \(EpitomeVersion.string) ETP/FTP server ready" :
            config.welcome.replacingOccurrences(of: "%v", with: EpitomeVersion.string).replacingOccurrences(of: "%n", with: " ").replacingOccurrences(of: "%%", with: "%")
        reply(c, 220, welcome)
        log(c, "connected")
        while let line = c.readLine(max: 65_536) {
            let sp = line.firstIndex(of: " ")
            let cmd = (sp.map { String(line[..<$0]) } ?? line).uppercased()
            let arg = sp.map { String(line[line.index(after: $0)...]) } ?? ""
            if cmd != "PASS" { log(c, line) }
            if !s.loggedIn && !["USER", "PASS", "QUIT", "FEAT", "SYST", "OPTS", "AUTH", "NOOP"].contains(cmd) {
                reply(c, 530, "Please log in with USER and PASS")
                continue
            }
            switch cmd {
            case "USER":
                s.user = arg
                if config.username.isEmpty && config.password.isEmpty {
                    s.loggedIn = true
                    reply(c, 230, "Logged in")
                } else {
                    reply(c, 331, "Password required")
                }
            case "PASS":
                if (config.username.isEmpty || s.user == config.username) && (config.password.isEmpty || arg == config.password) {
                    s.loggedIn = true
                    reply(c, 230, "Logged in")
                } else {
                    reply(c, 530, "Login incorrect")
                }
            case "AUTH":
                reply(c, 502, "TLS is not supported")
            case "SYST":
                reply(c, 215, "UNIX Type: L8")
            case "FEAT":
                c.write("211-Features:\r\n UTF8\r\n SIZE\r\n MDTM\r\n MLST type*;size*;modify*;\r\n EPSV\r\n PASV\r\n REST STREAM\r\n SITE EVERYTHING\r\n211 End\r\n")
            case "OPTS":
                reply(c, 200, "OK")
            case "NOOP":
                reply(c, 200, "OK")
            case "PWD", "XPWD":
                reply(c, 257, "\"\(s.cwd)\" is the current directory")
            case "CWD", "XCWD":
                let p = resolve(s, arg)
                if listing(p) != nil { s.cwd = p; reply(c, 250, "OK") } else { reply(c, 550, "No such folder") }
            case "CDUP", "XCUP":
                s.cwd = s.cwd == "/" ? "/" : (s.cwd as NSString).deletingLastPathComponent
                reply(c, 250, "OK")
            case "TYPE", "MODE", "STRU":
                reply(c, 200, "OK")
            case "PASV":
                guard let l = try? Listener.tcp4(port: 0, host: "0.0.0.0") else { reply(c, 425, "Cannot open passive port"); break }
                s.passive = l
                let ip = (c.localIPv4 ?? "127.0.0.1").contains(":") ? "127.0.0.1" : (c.localIPv4 ?? "127.0.0.1")
                let parts = ip.split(separator: ".").joined(separator: ",")
                reply(c, 227, "Entering Passive Mode (\(parts),\(l.port >> 8),\(l.port & 0xFF))")
            case "EPSV":
                guard let l = try? Listener.tcp(port: 0, bind: "") else { reply(c, 425, "Cannot open passive port"); break }
                s.passive = l
                reply(c, 229, "Entering Extended Passive Mode (|||\(l.port)|)")
            case "PORT":
                let n = arg.split(separator: ",").compactMap { Int($0) }
                if n.count == 6 {
                    s.active = ("\(n[0]).\(n[1]).\(n[2]).\(n[3])", UInt16(n[4] * 256 + n[5]))
                    reply(c, 200, "OK")
                } else { reply(c, 501, "Bad PORT") }
            case "EPRT":
                let d = arg.first.map { String($0) } ?? "|"
                let f = arg.split(separator: Character(d), omittingEmptySubsequences: false).map(String.init)
                if f.count >= 4, let port = UInt16(f[3]) { s.active = (f[2], port); reply(c, 200, "OK") } else { reply(c, 501, "Bad EPRT") }
            case "LIST", "NLST", "MLSD":
                let a = arg.split(separator: " ").filter { !$0.hasPrefix("-") }.joined(separator: " ")
                let p = resolve(s, a)
                guard let kids = listing(p) else { reply(c, 550, "No such folder"); break }
                reply(c, 150, "Opening data connection")
                guard let data = openData(s) else { reply(c, 425, "Cannot open data connection"); break }
                let ix = manager.index
                ix.lock.read {
                    var out = ""
                    for k in kids {
                        switch cmd {
                        case "NLST": out += ix.name(k) + "\r\n"
                        case "MLSD": out += ETPServer.mlsxFacts(ix, k) + " " + (ix.isRoot(k) ? ((ix.sources[k]?.path ?? "") as NSString).lastPathComponent : ix.name(k)) + "\r\n"
                        default: out += ETPServer.lsLine(ix, k)
                        }
                        if out.utf8.count > 60_000 { data.write(out); out = "" }
                    }
                    data.write(out)
                }
                data.close()
                reply(c, 226, "Transfer complete")
            case "MLST":
                let p = resolve(s, arg)
                let ix = manager.index
                let id: EntryID = ix.lock.read { ix.lookup(path: p) }
                if id == kNoEntry { reply(c, 550, "Not found"); break }
                let facts = ix.lock.read { ETPServer.mlsxFacts(ix, id) }
                c.write("250-Listing \(p)\r\n \(facts) \(p)\r\n250 End\r\n")
            case "SIZE":
                let p = resolve(s, arg)
                let ix = manager.index
                let v: Int64 = ix.lock.read { let id = ix.lookup(path: p); return id == kNoEntry ? -1 : ix.size[Int(id)] }
                if v < 0 { reply(c, 550, "Not found") } else { reply(c, 213, String(v)) }
            case "MDTM":
                let p = resolve(s, arg)
                let ix = manager.index
                let t: Int64 = ix.lock.read { let id = ix.lookup(path: p); return id == kNoEntry ? kUnknownTime : ix.mtime[Int(id)] }
                if t == kUnknownTime { reply(c, 550, "Not found"); break }
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = "yyyyMMddHHmmss"
                reply(c, 213, f.string(from: Date(timeIntervalSince1970: Double(t) / 1e9)))
            case "REST":
                s.rest = Int64(arg) ?? 0
                reply(c, 350, "Restarting at \(s.rest)")
            case "RETR":
                guard config.allowDownload else { reply(c, 550, "Downloads are disabled"); break }
                let p = resolve(s, arg)
                let ix = manager.index
                let known: Bool = ix.lock.read { let id = ix.lookup(path: p); return id != kNoEntry && !ix.isDirectory(id) }
                guard known, let fh = FileHandle(forReadingAtPath: p) else { reply(c, 550, "Cannot open file"); break }
                reply(c, 150, "Opening data connection")
                guard let data = openData(s) else { fh.closeFile(); reply(c, 425, "Cannot open data connection"); break }
                if s.rest > 0 { fh.seek(toFileOffset: UInt64(s.rest)) }
                s.rest = 0
                var ok = true
                while true {
                    let chunk = fh.readData(ofLength: 256 * 1024)
                    if chunk.isEmpty { break }
                    if !data.write(chunk) { ok = false; break }
                }
                fh.closeFile()
                data.close()
                reply(c, ok ? 226 : 426, ok ? "Transfer complete" : "Transfer aborted")
            case "STOR", "APPE", "DELE", "RMD", "MKD", "RNFR", "RNTO", "XMKD", "XRMD":
                reply(c, 550, "This server is read-only")
            case "ABOR":
                reply(c, 226, "Aborted")
            case "STAT":
                reply(c, 211, "Epitome ETP server, \(manager.index.liveCount) items indexed")
            case "HELP":
                reply(c, 214, "Commands: USER PASS CWD CDUP PWD LIST NLST MLSD MLST RETR SIZE MDTM REST PASV EPSV PORT EPRT TYPE SITE QUIT")
            case "SITE":
                site(s, arg, c)
            case "QUIT":
                reply(c, 221, "Goodbye")
                return
            default:
                reply(c, 502, "Command not implemented")
            }
        }
    }

    func site(_ s: Session, _ arg: String, _ c: SocketConnection) {
        var parts = arg.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first?.uppercased(), head == "EVERYTHING" || head == "EPITOME" else {
            reply(c, 504, "Unknown SITE command")
            return
        }
        parts.removeFirst()
        guard let sub = parts.first?.uppercased() else { reply(c, 501, "Missing argument"); return }
        let value = parts.count > 1 ? parts[1] : ""
        let on = (Int(value) ?? 0) != 0
        switch sub {
        case "SEARCH": s.search = value
        case "CASE": s.options.matchCase = on
        case "WHOLE_WORD": s.options.matchWholeWord = on
        case "PATH": s.options.matchPath = on
        case "DIACRITICS": s.options.matchDiacritics = on
        case "REGEX": s.options.regex = on
        case "PREFIX", "SUFFIX", "IGNORE_PUNCTUATION", "IGNORE_WHITESPACE": break
        case "HIDE_EMPTY_SEARCH_RESULTS": s.hideEmpty = on
        case "FILTER_SEARCH": s.filterSearch = value
        case "FILTER_CASE": s.filterOptions.matchCase = on
        case "FILTER_WHOLE_WORD": s.filterOptions.matchWholeWord = on
        case "FILTER_PATH": s.filterOptions.matchPath = on
        case "FILTER_DIACRITICS": s.filterOptions.matchDiacritics = on
        case "FILTER_REGEX": s.filterOptions.regex = on
        case "FILTER_PREFIX", "FILTER_SUFFIX", "FILTER_IGNORE_PUNCTUATION", "FILTER_IGNORE_WHITESPACE": break
        case "SORT":
            let v = value.uppercased()
            s.ascending = !v.hasSuffix("_DESCENDING")
            let base = v.replacingOccurrences(of: "_DESCENDING", with: "").replacingOccurrences(of: "_ASCENDING", with: "")
            s.sort = SortKey.parse(base.lowercased()) ?? .name
        case "OFFSET": s.offset = Swift.max(0, Int(value) ?? 0)
        case "COUNT": s.count = Swift.max(0, Int(value) ?? 100)
        case "SIZE_COLUMN", "DATE_CREATED_COLUMN", "DATE_MODIFIED_COLUMN", "ATTRIBUTES_COLUMN", "PATH_COLUMN", "FILE_LIST_FILENAME_COLUMN":
            let key = sub.replacingOccurrences(of: "_COLUMN", with: "").lowercased()
            if on { s.columns.insert(key) } else { s.columns.remove(key) }
        case "QUERY":
            query(s, c)
            return
        default:
            reply(c, 501, "Unknown option \(sub)")
            return
        }
        reply(c, 200, "OK")
    }

    func query(_ s: Session, _ c: SocketConnection) {
        let st = manager.settings
        var r = SearchRequest(text: s.search, options: s.options, sort: s.sort, ascending: s.ascending,
                              foldersFirst: st.foldersFirst, syntax: st.syntax)
        if !s.filterSearch.isEmpty { r.filter = FilterSpec(text: s.filterSearch, options: s.filterOptions) }
        r.offset = s.offset
        r.limit = s.count
        r.hideWhenEmpty = s.hideEmpty
        let ix = manager.index
        guard let res = SearchEngine.run(r, index: ix, services: manager.services) else { reply(c, 451, "Search cancelled"); return }
        var out = "200-\(res.totalCount) \(res.count) \(s.offset)\r\n"
        ix.lock.read {
            for id in res.ids {
                let i = Int(id)
                let name = ix.isRoot(id) ? ((ix.sources[id]?.path ?? "") as NSString).lastPathComponent : ix.name(id)
                let fields = [ix.isDirectory(id) ? "D" : "F", ETPServer.escapeField(ix.parentPath(id)), ETPServer.escapeField(name),
                              String(ix.size[i]), String(ix.mtime[i]), String(ix.ctime[i]), String(ix.flags[i] & EntryFlag.attributeMask)]
                out += " " + fields.joined(separator: "\t") + "\r\n"
                if out.utf8.count > 60_000 { c.write(out); out = "" }
            }
        }
        out += "200 Query complete\r\n"
        c.write(out)
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}

/// Client for searching a remote Epitome over ETP.
public final class ETPClient: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let user: String
    public let password: String
    private var control: SocketConnection?
    private let m = Mutex()
    public private(set) var lastError = ""

    public init(host: String, port: UInt16 = 2121, user: String = "", password: String = "") {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
    }

    /// Parses "user:password@host:port".
    public convenience init?(link: String) {
        var rest = link
        var user = "", pass = ""
        if let at = rest.lastIndex(of: "@") {
            let cred = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
            if let colon = cred.firstIndex(of: ":") {
                user = String(cred[..<colon])
                pass = String(cred[cred.index(after: colon)...])
            } else { user = cred }
        }
        var host = rest
        var port: UInt16 = 2121
        if let colon = rest.lastIndex(of: ":"), let p = UInt16(rest[rest.index(after: colon)...]) {
            host = String(rest[..<colon])
            port = p
        }
        guard !host.isEmpty else { return nil }
        self.init(host: host, port: port, user: user, password: pass)
    }

    public var label: String { "\(host):\(port)" }

    func readReply(_ c: SocketConnection) -> (Int, [String])? {
        var lines: [String] = []
        guard let first = c.readLine() else { return nil }
        lines.append(first)
        guard first.count >= 3, let code = Int(first.prefix(3)) else { return nil }
        if first.count > 3 && first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            while let l = c.readLine() {
                lines.append(l)
                if l.hasPrefix("\(code) ") { break }
            }
        }
        return (code, lines)
    }

    func command(_ c: SocketConnection, _ cmd: String) -> (Int, [String])? {
        c.write(cmd + "\r\n")
        return readReply(c)
    }

    public func connect() -> Bool {
        m.sync {
            guard let c = Connector.tcp(host: host, port: port) else { lastError = "Cannot connect to \(label)"; return false }
            guard let (code, _) = readReply(c), code == 220 else { lastError = "Unexpected greeting"; return false }
            if let (uc, _) = command(c, "USER \(user.isEmpty ? "anonymous" : user)") {
                if uc == 331 {
                    guard let (pc, _) = command(c, "PASS \(password)"), pc == 230 else { lastError = "Login incorrect"; return false }
                } else if uc != 230 { lastError = "Login refused"; return false }
            }
            _ = command(c, "OPTS UTF8 ON")
            control = c
            return true
        }
    }

    public func close() {
        m.sync {
            if let c = control { _ = command(c, "QUIT"); c.close() }
            control = nil
        }
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let ch = it.next() {
            if ch == "\\", let n = it.next() {
                switch n {
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "r": out.append("\r")
                default: out.append(n)
                }
            } else { out.append(ch) }
        }
        return out
    }

    /// Runs a search. Returns (total, rows) or nil on failure.
    public func search(_ text: String, options: SearchOptions, filter: FilterSpec?, sort: SortKey, ascending: Bool,
                       offset: Int, count: Int) -> (Int, [RemoteRow])? {
        m.sync {
            guard let c = control else { return nil }
            func site(_ s: String) -> Bool { (command(c, "SITE EVERYTHING " + s)?.0 ?? 500) < 300 }
            guard site("SEARCH \(text)"), site("CASE \(options.matchCase ? 1 : 0)"), site("WHOLE_WORD \(options.matchWholeWord ? 1 : 0)"),
                  site("PATH \(options.matchPath ? 1 : 0)"), site("DIACRITICS \(options.matchDiacritics ? 1 : 0)"),
                  site("REGEX \(options.regex ? 1 : 0)"), site("FILTER_SEARCH \(filter?.text ?? "")"),
                  site("FILTER_CASE \(filter?.options.matchCase == true ? 1 : 0)"),
                  site("FILTER_PATH \(filter?.options.matchPath == true ? 1 : 0)"),
                  site("FILTER_REGEX \(filter?.options.regex == true ? 1 : 0)"),
                  site("SORT \(sort.rawValue.uppercased().replacingOccurrences(of: "-", with: "_"))_\(ascending ? "ASCENDING" : "DESCENDING")"),
                  site("OFFSET \(offset)"), site("COUNT \(count)") else { lastError = "Server refused the search"; return nil }
            guard let (code, lines) = command(c, "SITE EVERYTHING QUERY"), code == 200 else { lastError = "Query failed"; return nil }
            var total = 0
            var rows: [RemoteRow] = []
            for (i, l) in lines.enumerated() {
                if i == 0 {
                    let nums = l.dropFirst(4).split(separator: " ")
                    total = Int(nums.first ?? "0") ?? 0
                    continue
                }
                guard l.hasPrefix(" ") else { continue }
                let f = l.dropFirst().split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 7 else { continue }
                rows.append(RemoteRow(isFolder: f[0] == "D", path: ETPClient.unescape(f[1]), name: ETPClient.unescape(f[2]),
                                      size: Int64(f[3]) ?? -1, mtime: Int64(f[4]) ?? kUnknownTime, ctime: Int64(f[5]) ?? kUnknownTime,
                                      attributes: UInt32(f[6]) ?? 0))
            }
            return (total, rows)
        }
    }

    /// Downloads a file through the server to `dest`.
    public func download(_ remotePath: String, to dest: URL) -> Bool {
        m.sync {
            guard let c = control else { return false }
            _ = command(c, "TYPE I")
            guard let (code, lines) = command(c, "EPSV"), code == 229, let l = lines.first,
                  let open = l.firstIndex(of: "("), let close = l.lastIndex(of: ")") else { lastError = "Passive mode failed"; return false }
            let inner = l[l.index(after: open)..<close]
            let port = UInt16(inner.split(separator: "|").last ?? "") ?? 0
            guard port > 0, let data = Connector.tcp(host: host, port: port) else { lastError = "Data connection failed"; return false }
            c.write("RETR \(remotePath)\r\n")
            guard let (rc, _) = readReply(c), rc == 150 || rc == 125 else { data.close(); lastError = "Server refused the download"; return false }
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            guard let fh = try? FileHandle(forWritingTo: dest) else { data.close(); return false }
            var buf = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { recv(data.fd, $0.baseAddress, 256 * 1024, 0) }
                if n <= 0 { break }
                fh.write(Data(buf[0..<n]))
            }
            fh.closeFile()
            data.close()
            let ok = (readReply(c)?.0 ?? 0) == 226
            return ok
        }
    }
}
