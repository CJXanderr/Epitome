import Foundation
import EpitomeCore

// ep — command-line search for Epitome. Talks to the running app over its local socket.
// Run `ep -help` for usage.

ignoreSIGPIPE()

enum Exit: Int32 {
    case ok = 0, outOfMemory = 3, missingArgument = 4, exportFailed = 5, unknownSwitch = 6, ipcFailed = 7, notRunning = 8, noResults = 9
}

func fail(_ code: Exit, _ msg: String) -> Never {
    FileHandle.standardError.write(Data(("ep: " + msg + "\n").utf8))
    exit(code.rawValue)
}

let usage = """
ep \(EpitomeVersion.string) — search the Epitome index from the command line.

Usage: ep [options] [search text]

Search options
  -r, -regex <pattern>     search with a regular expression
  -i, -case                match case
  -w, -ww, -whole-word     match whole words
  -p, -match-path          match the full path
  -a, -diacritics          match diacritics
  -o, -offset <n>          skip the first n results
  -n, -max-results <n>     show at most n results
  -path <path>             only results inside <path> (any depth)
  -parent-path <path>      only results inside the parent of <path>
  -parent <path>           only direct children of <path>
  -ad / -a-d               folders only / files only
  -a<letters>              attribute filter (R H S D A C L O X P), prefix a letter with - to exclude
  -filter <name>           apply a filter defined in the app (e.g. Audio)

Sorting
  -s                       sort by full path
  -sort <name>[-ascending|-descending]
                           name, path, size, extension, type, date-created, date-modified,
                           date-accessed, attributes, file-list-filename, run-count,
                           date-recently-changed, date-run
  -sort-ascending, -sort-descending
  -on -o-n -os -o-s -oe -o-e -od -o-d   DIR-style sorts (name, size, extension, date modified)

Columns (shown in the order given; default is the full path)
  -name -path-column -full-path-and-name -extension -size -date-created -date-modified
  -date-accessed -attributes -file-list-file-name -run-count -date-run -date-recently-changed

Display
  -highlight, -highlight-color <0xNN>   colour the matches
  -size-format <0 auto|1 bytes|2 KB|3 MB>
  -date-format <0 system|1 ISO-8601|2 FILETIME|3 ISO-8601 UTC|4 locale|5 ISO full|6 ISO UTC full>
  -no-digit-grouping  -size-leading-zero  -run-count-leading-zero  -double-quote
  -header  -footer  -hide-empty-search-results
  -csv -efu -json -m3u -m3u8 -tsv -txt          output format
  -export-csv|-export-efu|-export-json|-export-m3u|-export-m3u8|-export-tsv|-export-txt <file>
  -utf8-bom  -no-header  -no-folder-append-path-separator

Index journal
  -journal, -j [filter]    list recent index changes  (-from-today, -from-yesterday, -from-date <iso>)

Other
  -get-result-count  -get-total-size  -get-folder-size <folder>
  -set-run-count <file> <n>  -inc-run-count <file>  -get-run-count <file>
  -instance <name>  -timeout <ms>  -no-result-error
  -save-settings  -clear-settings  -version  -get-epitome-version
  -reindex  -save-db  -rescan-all  -exit
  -gui <switches…>         pass window switches to the app (e.g. -gui -search foo -filter Audio)
  -h, -help

Exit codes: 0 ok, 4 bad argument, 5 export failed, 6 unknown switch, 7 query failed,
8 Epitome is not running, 9 no results (with -no-result-error).
"""

// MARK: - Saved defaults

let defaultsURL = IPCPaths.supportDirectory().appendingPathComponent("ep-defaults.json")
var rawArgs = Array(CommandLine.arguments.dropFirst())
if !rawArgs.contains("-clear-settings"),
   let d = try? Data(contentsOf: defaultsURL), let saved = try? JSONDecoder().decode([String].self, from: d) {
    rawArgs = saved + rawArgs
}

// MARK: - Parse

var searchParts: [String] = []
var req = IPCRequest(cmd: "search")
var columns: [Column] = []
var instance = ""
var timeoutMs = 0
var highlight = false
var highlightColor = 0x0A
var sizeFormat = 1
var dateFormat = 0
var digitGrouping = true
var sizeLeadingZero = false
var runLeadingZero = false
var header = false
var footer = false
var doubleQuote = false
var format: ExportFormat? = nil
var exportPath: String? = nil
var bom = false
var noHeader = false
var folderSlash = true
var noResultError = false
var action = "search"
var actionArg: String? = nil
var actionArg2: String? = nil
var journalFilter = ""
var journalSince: Double = 0
var guiArgs: [String] = []
var saveSettings = false
var extraTerms: [String] = []

var it = rawArgs.makeIterator()
func next(_ sw: String) -> String {
    guard let v = it.next() else { fail(.missingArgument, "missing argument after \(sw)") }
    return v
}

let columnSwitches: [String: Column] = [
    "name": .name, "path-column": .path, "pathcolumn": .path, "full-path-and-name": .fullPath, "full-path": .fullPath,
    "filename-column": .fullPath, "extension": .ext, "ext": .ext, "size": .size, "date-created": .dateCreated, "dc": .dateCreated,
    "date-modified": .dateModified, "dm": .dateModified, "date-accessed": .dateAccessed, "da": .dateAccessed,
    "attributes": .attributes, "attribs": .attributes, "attrib": .attributes, "file-list-file-name": .fileListFilename,
    "run-count": .runCount, "date-run": .dateRun, "date-recently-changed": .dateRecentlyChanged, "rc": .dateRecentlyChanged,
]

var stopSwitches = false
while let a = it.next() {
    if stopSwitches || !a.hasPrefix("-") || a == "-" {
        searchParts.append(a)
        continue
    }
    var sw = String(a.dropFirst()).lowercased()
    if sw.hasPrefix("-") { sw.removeFirst() }
    if sw.isEmpty { stopSwitches = true; continue }
    let flat = sw.replacingOccurrences(of: "-", with: "")
    if let col = columnSwitches[sw] ?? columnSwitches[flat] {
        columns.append(col)
        continue
    }
    if sw.hasPrefix("no-"), columnSwitches[String(sw.dropFirst(3))] != nil {
        let c = columnSwitches[String(sw.dropFirst(3))]!
        columns.removeAll { $0 == c }
        continue
    }
    switch sw {
    case "h", "help", "?": print(usage); exit(0)
    case "r", "regex": req.regex = true; searchParts.append(next(a))
    case "i", "case": req.matchCase = true
    case "nocase", "no-case": req.matchCase = false
    case "w", "ww", "whole-word", "whole-words", "wholeword": req.wholeWord = true
    case "p", "match-path", "matchpath": req.matchPath = true
    case "a", "diacritics": req.diacritics = true
    case "o", "offset", "viewport-offset": req.offset = Int(next(a)) ?? 0
    case "n", "max-results", "count", "viewport-count": req.count = Int(next(a)) ?? 0
    case "path": extraTerms.append("\"\((next(a) as NSString).expandingTildeInPath)/\"")
    case "parent-path", "parentpath": extraTerms.append("\"" + (((next(a) as NSString).expandingTildeInPath as NSString).deletingLastPathComponent) + "/\"")
    case "parent": extraTerms.append("parent:\"\((next(a) as NSString).expandingTildeInPath)\"")
    case "filter": req.filter = next(a)
    case "ad": extraTerms.append("folder:")
    case "a-d": extraTerms.append("file:")
    case "s": req.sort = "path"; req.ascending = true
    case "sort":
        var v = next(a).lowercased()
        if v.hasSuffix("-descending") { req.ascending = false; v = String(v.dropLast(11)) }
        else if v.hasSuffix("-ascending") { req.ascending = true; v = String(v.dropLast(10)) }
        guard let k = SortKey.parse(v) else { fail(.missingArgument, "unknown sort \(v)") }
        req.sort = k.rawValue
        if req.ascending == nil { req.ascending = k.defaultAscending }
    case "sort-ascending": req.ascending = true
    case "sort-descending": req.ascending = false
    case "on": req.sort = "name"; req.ascending = true
    case "o-n": req.sort = "name"; req.ascending = false
    case "os": req.sort = "size"; req.ascending = true
    case "o-s": req.sort = "size"; req.ascending = false
    case "oe": req.sort = "extension"; req.ascending = true
    case "o-e": req.sort = "extension"; req.ascending = false
    case "od": req.sort = "date-modified"; req.ascending = true
    case "o-d": req.sort = "date-modified"; req.ascending = false
    case "highlight": highlight = true
    case "highlight-color": highlight = true; highlightColor = Int(next(a).replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x0A
    case "size-format": sizeFormat = Int(next(a)) ?? 1
    case "date-format": dateFormat = Int(next(a)) ?? 0
    case "no-digit-grouping", "nodigitgrouping": digitGrouping = false
    case "size-leading-zero": sizeLeadingZero = true
    case "run-count-leading-zero": runLeadingZero = true
    case "header": header = true
    case "footer": footer = true
    case "double-quote": doubleQuote = true
    case "hide-empty-search-results": req.hideEmpty = true
    case "empty-search-help": break
    case "csv", "efu", "json", "m3u", "m3u8", "tsv", "txt": format = ExportFormat(rawValue: sw)
    case "export-csv", "export-efu", "export-json", "export-m3u", "export-m3u8", "export-tsv", "export-txt":
        format = ExportFormat(rawValue: String(sw.dropFirst(7)))
        exportPath = next(a)
    case "utf8-bom": bom = true
    case "no-header": noHeader = true
    case "no-folder-append-path-separator": folderSlash = false
    case "journal", "j":
        action = "journal"
    case "from-today": journalSince = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    case "from-yesterday": journalSince = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 - 86_400
    case "from-now": journalSince = Date().timeIntervalSince1970
    case "from-date":
        let v = next(a)
        journalSince = (ISO8601DateFormatter().date(from: v) ?? DateFormatter().date(from: v) ?? Date.distantPast).timeIntervalSince1970
    case "instance": instance = next(a)
    case "timeout": timeoutMs = Int(next(a)) ?? 0
    case "no-result-error": noResultError = true
    case "get-result-count": action = "count"
    case "get-total-size": action = "total-size"
    case "get-folder-size": action = "folder-size"; actionArg = next(a)
    case "set-run-count": action = "set-run-count"; actionArg = next(a); actionArg2 = next(a)
    case "inc-run-count": action = "inc-run-count"; actionArg = next(a)
    case "get-run-count": action = "get-run-count"; actionArg = next(a)
    case "save-settings": saveSettings = true
    case "clear-settings": try? FileManager.default.removeItem(at: defaultsURL); print("Settings cleared."); exit(0)
    case "version": print(EpitomeVersion.string); exit(0)
    case "get-epitome-version", "get-everything-version": action = "app-version"
    case "exit", "quit": action = "exit"
    case "save-db": action = "save-db"
    case "reindex": action = "reindex"
    case "rescan-all": action = "rescan-all"
    case "gui":
        action = "gui"
        while let g = it.next() { guiArgs.append(g) }
    default:
        if sw.hasPrefix("sort-") {
            var v = String(sw.dropFirst(5))
            if v.hasSuffix("-descending") { req.ascending = false; v = String(v.dropLast(11)) }
            else if v.hasSuffix("-ascending") { req.ascending = true; v = String(v.dropLast(10)) }
            if let k = SortKey.parse(v) {
                req.sort = k.rawValue
                if req.ascending == nil { req.ascending = k.defaultAscending }
                continue
            }
        }
        if sw.hasPrefix("a") && sw.count > 1 {
            // -aRH-S style attribute filter
            var neg = false
            var plus = "", minus = ""
            for ch in sw.dropFirst().uppercased() {
                if ch == "-" { neg = true; continue }
                if neg { minus.append(ch) } else { plus.append(ch) }
                neg = false
            }
            if !plus.isEmpty { extraTerms.append("attrib:\(plus)") }
            for ch in minus { extraTerms.append("!attrib:\(ch)") }
            continue
        }
        fail(.unknownSwitch, "unknown switch \(a) (try ep -help)")
    }
}

if saveSettings {
    let toSave = Array(CommandLine.arguments.dropFirst()).filter { $0 != "-save-settings" }
    if let d = try? JSONEncoder().encode(toSave) {
        try? FileManager.default.createDirectory(at: defaultsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: defaultsURL)
    }
}

// MARK: - Connect

func waitForApp() {
    if !IPCClient.isRunning(instance: instance) {
        fail(.notRunning, "Epitome is not running" + (instance.isEmpty ? "" : " (instance \(instance))"))
    }
    if timeoutMs > 0 {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let st = IPCClient.call(IPCRequest(cmd: "status"), instance: instance), st["loaded"] as? Bool == true { return }
            usleep(100_000)
        }
    }
}

func simple(_ cmd: String, path: String? = nil, value: Int? = nil, args: [String]? = nil) -> [String: Any] {
    var r = IPCRequest(cmd: cmd)
    r.path = path
    r.value = value
    r.args = args
    guard let resp = IPCClient.call(r, instance: instance) else { fail(.ipcFailed, "query failed") }
    if resp["ok"] as? Bool == false { fail(.ipcFailed, resp["error"] as? String ?? "query failed") }
    return resp
}

waitForApp()

switch action {
case "app-version":
    print(simple("version")["version"] as? String ?? "?")
    exit(0)
case "exit", "save-db", "reindex", "rescan-all":
    _ = simple(action == "exit" ? "quit" : action)
    exit(0)
case "gui":
    _ = simple("gui", args: guiArgs)
    exit(0)
case "set-run-count":
    let n = Int(actionArg2 ?? "") ?? 0
    print(simple("run-count", path: (actionArg! as NSString).expandingTildeInPath, value: n)["count"] ?? 0)
    exit(0)
case "inc-run-count":
    print(simple("run-count", path: (actionArg! as NSString).expandingTildeInPath, args: ["inc"])["count"] ?? 0)
    exit(0)
case "get-run-count":
    print(simple("run-count", path: (actionArg! as NSString).expandingTildeInPath)["count"] ?? 0)
    exit(0)
case "folder-size":
    let r = simple("folder-size", path: (actionArg! as NSString).expandingTildeInPath)
    print(r["size"] ?? 0)
    exit(0)
case "journal":
    var jr = IPCRequest(cmd: "journal")
    jr.query = searchParts.joined(separator: " ")
    jr.since = journalSince
    var lines = 0
    let ok = IPCClient.send(jr, instance: instance) { obj in
        if let row = obj as? [String] , row.count == 4 {
            let t = Date(timeIntervalSince1970: (Double(row[0]) ?? 0) / 1e9)
            print("\(ISO8601DateFormatter().string(from: t))  \(row[1].padding(toLength: 8, withPad: " ", startingAt: 0)) \(row[2].padding(toLength: 6, withPad: " ", startingAt: 0)) \(row[3])")
            lines += 1
        }
        return true
    }
    if !ok { fail(.ipcFailed, "query failed") }
    exit(lines == 0 && noResultError ? Exit.noResults.rawValue : 0)
default:
    break
}

// MARK: - Search

req.query = (searchParts + extraTerms).joined(separator: " ")
if columns.isEmpty { columns = format == .efu ? [.fullPath, .size, .dateModified, .dateCreated, .attributes] : [.fullPath] }
req.fields = columns.map(\.rawValue)
if highlight { req.highlight = true }
if action == "count" || action == "total-size" { req.fields = ["size"]; req.count = nil }

var headerInfo: [String: Any] = [:]
var rows: [(Bool, [String])] = []
let ok = IPCClient.send(req, instance: instance) { obj in
    if let d = obj as? [String: Any] {
        if d["ok"] as? Bool == false { fail(.ipcFailed, d["error"] as? String ?? "query failed") }
        headerInfo = d
        return true
    }
    if let row = obj as? [Any], let first = row.first as? Int {
        rows.append((first == 1, row.dropFirst().map { "\($0)" }))
    }
    return true
}
if !ok { fail(.ipcFailed, "query failed") }
if let errs = headerInfo["errors"] as? [String], !errs.isEmpty {
    FileHandle.standardError.write(Data(("ep: " + errs.joined(separator: "; ") + "\n").utf8))
}

let total = headerInfo["total"] as? Int ?? rows.count
if action == "count" { print(total); exit(total == 0 && noResultError ? Exit.noResults.rawValue : 0) }
if action == "total-size" {
    let s = rows.reduce(Int64(0)) { $0 + Swift.max(0, Int64($1.1.first ?? "0") ?? 0) }
    print(s)
    exit(0)
}

// MARK: - Formatting

let numberFmt = NumberFormatter()
numberFmt.numberStyle = .decimal
numberFmt.usesGroupingSeparator = digitGrouping

func fmtSize(_ s: String, isDir: Bool) -> String {
    guard let v = Int64(s), v >= 0 else { return "" }
    switch sizeFormat {
    case 0: return ValueFormatter(sizeFormat: .auto).size(v)
    case 2: return (numberFmt.string(from: NSNumber(value: (v + 1023) / 1024)) ?? "") + " KB"
    case 3: return (numberFmt.string(from: NSNumber(value: (v + 1_048_575) / 1_048_576)) ?? "") + " MB"
    default:
        let t = numberFmt.string(from: NSNumber(value: v)) ?? String(v)
        return sizeLeadingZero ? String(repeating: "0", count: Swift.max(0, 15 - t.count)) + t : t
    }
}

let sysDate: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    return f
}()

func fmtDate(_ s: String) -> String {
    guard let ns = Int64(s), ns != kUnknownTime else { return "" }
    let d = Date(timeIntervalSince1970: Double(ns) / 1e9)
    switch dateFormat {
    case 1: let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]; return f.string(from: d)
    case 2: return String(FileList.nanosToFiletime(ns))
    case 3: let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    case 5: let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
    case 6: let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
    default: return sysDate.string(from: d)
    }
}

func display(_ col: Column, _ v: String, isDir: Bool) -> String {
    switch col {
    case .size: return isDir && (Int64(v) ?? -1) < 0 ? "" : fmtSize(v, isDir: isDir)
    case .dateModified, .dateCreated, .dateAccessed, .dateRecentlyChanged: return fmtDate(v)
    case .dateRun: return v
    case .attributes: return ValueFormatter.attributes(UInt32(v) ?? 0)
    case .runCount: return runLeadingZero && !v.isEmpty ? String(repeating: "0", count: Swift.max(0, 10 - v.count)) + v : v
    case .fullPath:
        var p = v
        if isDir && folderSlash && format != nil && p != "/" { p += "/" }
        return doubleQuote ? "\"\(p)\"" : p
    case .path, .name: return doubleQuote ? "\"\(v)\"" : v
    default: return v
    }
}

let highlights: [(String, Bool)] = (headerInfo["highlights"] as? [[String: Any]] ?? []).compactMap {
    guard let t = $0["text"] as? String else { return nil }
    return (t.replacingOccurrences(of: "*", with: ""), $0["case"] as? Bool ?? false)
}

func ansi(_ attr: Int) -> String {
    let fg = attr & 0x0F
    let map = [30, 34, 32, 36, 31, 35, 33, 37]
    let code = map[fg & 7] + ((fg & 8) != 0 ? 60 : 0)
    return "\u{1B}[\(code)m"
}

func highlighted(_ s: String) -> String {
    guard highlight, !highlights.isEmpty else { return s }
    var ranges: [Range<String.Index>] = []
    for (t, cs) in highlights where !t.isEmpty {
        var searchRange = s.startIndex..<s.endIndex
        while let r = s.range(of: t, options: cs ? [] : [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            ranges.append(r)
            searchRange = r.upperBound..<s.endIndex
        }
    }
    if ranges.isEmpty { return s }
    ranges.sort { $0.lowerBound < $1.lowerBound }
    var out = ""
    var cur = s.startIndex
    for r in ranges where r.lowerBound >= cur {
        out += s[cur..<r.lowerBound] + ansi(highlightColor) + s[r] + "\u{1B}[0m"
        cur = r.upperBound
    }
    out += s[cur...]
    return out
}

var output = ""
if let fmt = format {
    switch fmt {
    case .txt, .m3u, .m3u8:
        if fmt != .txt { output = "#EXTM3U\n" }
        for (isDir, vals) in rows {
            if fmt != .txt && isDir { continue }
            output += display(columns.first ?? .fullPath, vals.first ?? "", isDir: isDir) + "\n"
        }
    case .csv, .tsv:
        let sep = fmt == .csv ? "," : "\t"
        func q(_ s: String) -> String { fmt == .csv && (s.contains(",") || s.contains("\"")) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        if !noHeader { output += columns.map { q($0.title) }.joined(separator: sep) + "\n" }
        for (isDir, vals) in rows {
            output += zip(columns, vals).map { q(display($0.0, $0.1, isDir: isDir)) }.joined(separator: sep) + "\n"
        }
    case .efu:
        if !noHeader { output += "Filename,Size,Date Modified,Date Created,Attributes\n" }
        for (isDir, vals) in rows {
            var d: [Column: String] = [:]
            for (c, v) in zip(columns, vals) { d[c] = v }
            var path = d[.fullPath] ?? ""
            if isDir && folderSlash && path != "/" { path += "/" }
            let size = isDir ? "" : (d[.size].flatMap { Int64($0) }.map { $0 >= 0 ? String($0) : "" } ?? "")
            let dm = d[.dateModified].flatMap { Int64($0) }.map { $0 == kUnknownTime ? "" : String(FileList.nanosToFiletime($0)) } ?? ""
            let dc = d[.dateCreated].flatMap { Int64($0) }.map { $0 == kUnknownTime ? "" : String(FileList.nanosToFiletime($0)) } ?? ""
            let at = d[.attributes].flatMap { UInt32($0) }.map { String(FileList.attributes(fromFlags: $0 | (isDir ? EntryFlag.directory : 0))) } ?? ""
            output += "\"\(path.replacingOccurrences(of: "\"", with: "\"\""))\",\(size),\(dm),\(dc),\(at)\n"
        }
    case .json:
        var items: [[String: Any]] = []
        for (isDir, vals) in rows {
            var d: [String: Any] = ["type": isDir ? "folder" : "file"]
            for (c, v) in zip(columns, vals) { d[c.rawValue.replacingOccurrences(of: "-", with: "_")] = v }
            items.append(d)
        }
        let obj: [String: Any] = ["totalResults": total, "results": items]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) { output = String(decoding: data, as: UTF8.self) + "\n" }
    case .html:
        output = "<table>\n" + rows.map { r in "<tr>" + zip(columns, r.1).map { "<td>\(display($0.0, $0.1, isDir: r.0))</td>" }.joined() + "</tr>" }.joined(separator: "\n") + "\n</table>\n"
    }
} else {
    // Aligned table
    let table = rows.map { r in zip(columns, r.1).map { display($0.0, $0.1, isDir: r.0) } }
    var widths = columns.map { header ? $0.title.count : 0 }
    if columns.count > 1 {
        for row in table { for (i, v) in row.enumerated() where i < columns.count - 1 { widths[i] = Swift.max(widths[i], v.count) } }
    }
    func line(_ vals: [String]) -> String {
        var parts: [String] = []
        for (i, v) in vals.enumerated() {
            let c = columns[i]
            let last = i == vals.count - 1
            if last { parts.append(c == .name || c == .path || c == .fullPath ? highlighted(v) : v); break }
            let pad = String(repeating: " ", count: Swift.max(0, widths[i] - v.count))
            parts.append(c.rightAligned ? pad + v : (c == .name || c == .path || c == .fullPath ? highlighted(v) : v) + pad)
        }
        return parts.joined(separator: "  ")
    }
    if header { output += line(columns.map(\.title)) + "\n" }
    for r in table { output += line(r) + "\n" }
    if footer {
        let size = headerInfo["totalSize"] as? Int64 ?? Int64(headerInfo["totalSize"] as? Int ?? 0)
        output += "\(numberFmt.string(from: NSNumber(value: total)) ?? String(total)) result\(total == 1 ? "" : "s"), \(ValueFormatter(sizeFormat: .auto).size(size))\n"
    }
}

if let path = exportPath {
    var data = Data()
    if bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
    data.append(Data(output.utf8))
    do { try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) } catch { fail(.exportFailed, "cannot write \(path)") }
} else {
    if bom { FileHandle.standardOutput.write(Data([0xEF, 0xBB, 0xBF])) }
    FileHandle.standardOutput.write(Data(output.utf8))
}
exit(rows.isEmpty && noResultError ? Exit.noResults.rawValue : 0)
