import Foundation
import EpitomeCore

// Engine self-tests. Run with `epitome-selftest` (add `--scan <dir>` to time a real scan).

var failures = 0
var passes = 0

func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if cond { passes += 1 } else { failures += 1; print("FAIL [\(line)]: \(msg)") }
}

let calendar = Calendar(identifier: .gregorian)
let nowDate = Date()
func ns(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1e9) }
func daysAgo(_ n: Double) -> Int64 { ns(nowDate.addingTimeInterval(-n * 86_400)) }
func date(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
    ns(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!)
}

// MARK: - Build a synthetic index

let index = FileIndex()
var ids: [String: EntryID] = [:]
let dir = EntryFlag.directory
index.mutate { ix in
    let root = ix.addRoot(SourceInfo(kind: .volume, path: "/", name: "Macintosh HD"), meta: EntryMeta(flags: dir))
    ids["/"] = root
    func add(_ path: String, _ flags: UInt32 = 0, size: Int64 = 0, mtime: Int64 = daysAgo(400), ctime: Int64 = daysAgo(500)) {
        let parentPath = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let p = ids[parentPath]!
        let isDir = flags & dir != 0
        ids[path] = ix.add(parent: p, name: name, meta: EntryMeta(flags: flags, size: isDir ? kUnknownSize : size, mtime: mtime, ctime: ctime))
    }
    add("/Users", dir)
    add("/Users/bob", dir)
    add("/Users/bob/Documents", dir)
    add("/Users/bob/Documents/report.docx", size: 25 * 1024, mtime: date(2024, 3, 15))
    add("/Users/bob/Documents/Report Final.pdf", size: 2 * 1024 * 1024, mtime: daysAgo(1.0))
    add("/Users/bob/Documents/notes.txt", size: 500, mtime: daysAgo(0.01))
    add("/Users/bob/Documents/Café menu.txt", size: 1200)
    add("/Users/bob/Music", dir)
    add("/Users/bob/Music/song.mp3", size: 5 * 1024 * 1024)
    add("/Users/bob/Music/Song2.MP3", size: 3 * 1024 * 1024)
    add("/Users/bob/Music/Playlists", dir)
    add("/Users/bob/Pictures", dir)
    add("/Users/bob/Pictures/IMG_0001.JPG", size: 2 * 1024 * 1024)
    add("/Users/bob/Pictures/photo.png", size: 300 * 1024)
    add("/Users/bob/.hidden_file", EntryFlag.hidden, size: 10)
    add("/Users/bob/a.txt", size: 7)
    add("/Applications", dir)
    add("/Applications/Safari.app", dir | EntryFlag.package)
    add("/Applications/Safari.app/Contents", dir)
    add("/Applications/Safari.app/Contents/Info.plist", size: 4000)
    add("/tmp", dir)
    add("/tmp/a.txt", size: 9)
    add("/tmp/file10.log", size: 1)
    add("/tmp/file2.log", size: 1)
}
index.rebuildOrders()

let services = SearchServices()
services.macros["audio"] = "ext:mp3;wav;flac"
services.macros["pic"] = "ext:jpg;png;gif"

func search(_ q: String, sort: SortKey = .name, ascending: Bool = true, options: SearchOptions = SearchOptions(),
            folders: FoldersFirst = .never, filter: FilterSpec? = nil) -> [String] {
    var req = SearchRequest(text: q, options: options, filter: filter, sort: sort, ascending: ascending, foldersFirst: folders)
    req.syntax = SyntaxSettings()
    guard let r = SearchEngine.run(req, index: index, services: services) else { return ["<cancelled>"] }
    return index.lock.read { r.ids.map { index.path($0) } }
}

func names(_ q: String, sort: SortKey = .name, ascending: Bool = true, options: SearchOptions = SearchOptions(),
           folders: FoldersFirst = .never, filter: FilterSpec? = nil) -> [String] {
    search(q, sort: sort, ascending: ascending, options: options, folders: folders, filter: filter).map { ($0 as NSString).lastPathComponent }
}

func expect(_ q: String, _ want: [String], sort: SortKey = .name, ascending: Bool = true,
            options: SearchOptions = SearchOptions(), folders: FoldersFirst = .never, filter: FilterSpec? = nil,
            ordered: Bool = false, line: Int = #line) {
    let got = names(q, sort: sort, ascending: ascending, options: options, folders: folders, filter: filter)
    let ok = ordered ? got == want : Set(got) == Set(want) && got.count == want.count
    check(ok, "\(q) → \(got) (expected \(want))", line: line)
}

// MARK: - Parser

do {
    let ast = QueryParser.parse("a b|c")
    if case .and(let items) = ast, items.count == 2, case .or = items[1] { passes += 1 } else { failures += 1; print("FAIL precedence: \(ast)") }
    let toks = QueryParser.tokenize("size:>1mb <a|b> \"x y\"")
    check(toks.count == 7, "tokenize count \(toks)")
}

// MARK: - Text matching

expect("report", ["report.docx", "Report Final.pdf"])
expect("case:Report", ["Report Final.pdf"])
expect("Report", ["Report Final.pdf"], options: SearchOptions(matchCase: true))
expect("*.mp3", ["song.mp3", "Song2.MP3"])
expect("song*", ["song.mp3", "Song2.MP3"])
expect("*.mp3 !song2", ["song.mp3"])
expect("report | notes", ["report.docx", "Report Final.pdf", "notes.txt"])
expect("\"report final\"", ["Report Final.pdf"])
expect("report final", ["Report Final.pdf"])
expect("ww:song", ["song.mp3"])
expect("wfn:notes.txt", ["notes.txt"])
expect("regex:^song\\d", ["Song2.MP3"])
expect("startwith:rep", ["report.docx", "Report Final.pdf"])
expect("endwith:.pdf", ["Report Final.pdf"])
expect("cafe", ["Café menu.txt"])
expect("CAFÉ", ["Café menu.txt"])
expect("diacritics:cafe", [])
expect("diacritics:café", ["Café menu.txt"])
expect("<song|img> ext:mp3", ["song.mp3", "Song2.MP3"])
expect("bob/music", ["Music", "song.mp3", "Song2.MP3", "Playlists"])
expect("bob\\pictures\\", ["IMG_0001.JPG", "photo.png"])
expect("path:music", ["Music", "song.mp3", "Song2.MP3", "Playlists"])
expect("!a !e !i !o !u", ["tmp"])
expect("nowildcards:*.mp3", [])
expect("quot:x", [])

// MARK: - Modifiers and functions

expect("folder:", ["/", "Users", "bob", "Documents", "Music", "Playlists", "Pictures", "Applications", "Safari.app", "Contents", "tmp"])
expect("folder:music", ["Music"])
expect("file:music", [])
expect("ext:mp3;jpg", ["song.mp3", "Song2.MP3", "IMG_0001.JPG"])
expect("ext:app", ["Safari.app"])
expect("audio:", ["song.mp3", "Song2.MP3"])
expect("pic:img", ["IMG_0001.JPG"])
expect("size:>1mb", ["Report Final.pdf", "song.mp3", "Song2.MP3", "IMG_0001.JPG"])
expect("size:<=500", ["notes.txt", ".hidden_file", "a.txt", "a.txt", "file10.log", "file2.log"])
expect("size:1mb..4mb", ["Report Final.pdf", "Song2.MP3", "IMG_0001.JPG"])
expect("size:small", ["report.docx"])
expect("size:medium", ["photo.png"])
expect("size:large", ["Report Final.pdf", "song.mp3", "Song2.MP3", "IMG_0001.JPG"])
expect("size:tiny ext:txt", ["notes.txt", "Café menu.txt", "a.txt", "a.txt"])
expect("parent:/Users/bob/Music", ["song.mp3", "Song2.MP3", "Playlists"])
expect("infolder:~/nothing", [])
expect("empty:", ["Playlists"])
expect("dupe:", ["a.txt", "a.txt"])
expect("dupe:a", ["a.txt", "a.txt"])
expect("root:", ["/"])
expect("attrib:H", [".hidden_file"])
expect("childcount:3 folder:", ["/", "Music", "tmp"])
expect("childfoldercount:3", ["bob", "/"])
expect("depth:2 folder:", ["bob", "Safari.app"].filter { $0 == "bob" } + ["Safari.app"])
expect("len:9 file:", ["file2.log", "notes.txt", "photo.png", "Song2.MP3"])
expect("child:info.plist", ["Contents"])
expect("child:*.mp3", ["Music"])
expect("dm:today", ["notes.txt"])
expect("dm:2024", ["report.docx"])
expect("dm:2024-03", ["report.docx"])
expect("dm:2024-03-15", ["report.docx"])
expect("dm:pastweek file:", ["Report Final.pdf", "notes.txt"])
expect("dm:>=2024 dm:<2025", ["report.docx"])
expect("dm:2024..2024", ["report.docx"])
expect("filelist:\"notes.txt|photo.png\"", ["notes.txt", "photo.png"])
expect("count:2 ext:txt", ["a.txt", "a.txt"])
expect("type:mp3", ["song.mp3", "Song2.MP3"])
expect("content:abc", [])

// MARK: - Filters, sorting

expect("", ["song.mp3", "Song2.MP3"], filter: FilterSpec(text: "ext:mp3"))
expect("song2", ["Song2.MP3"], filter: FilterSpec(text: "audio:"))
expect("ext:log", ["file10.log", "file2.log"], ordered: true)
expect("ext:mp3", ["Song2.MP3", "song.mp3"], sort: .size, ascending: true, ordered: true)
expect("ext:mp3", ["song.mp3", "Song2.MP3"], sort: .size, ascending: false, ordered: true)
expect("ext:mp3;jpg", ["IMG_0001.JPG", "song.mp3", "Song2.MP3"], sort: .name, ordered: true)
expect("ext:mp3;jpg", ["Song2.MP3", "song.mp3", "IMG_0001.JPG"], sort: .name, ascending: false, ordered: true)
expect("bob/music", ["Music", "Playlists", "song.mp3", "Song2.MP3"], folders: .ascending, ordered: true)
expect("ext:txt", ["a.txt", "a.txt", "Café menu.txt", "notes.txt"], sort: .ext)
_ = 0


// MARK: - Newer semantics (1.5 rules)

expect("size:1kb", ["Café menu.txt"])
expect("size:=1200", ["Café menu.txt"])
expect("size:>=1kb size:<2kb", ["Café menu.txt"])
expect("^song\\d", ["Song2.MP3"], options: SearchOptions(regex: true))
expect("music/*", ["song.mp3", "Song2.MP3", "Playlists"])
expect("/users/bob/*", ["Documents", "Music", "Pictures", ".hidden_file", "a.txt"])
expect("bob/** ext:mp3", ["song.mp3", "Song2.MP3"])
expect("ancestor:/Users/bob ext:mp3", ["song.mp3", "Song2.MP3"])
expect("stem:report", ["report.docx", "Report Final.pdf"])
expect("extension:pd", ["Report Final.pdf"])
expect("location:bob/music", ["song.mp3", "Song2.MP3", "Playlists"])
expect("parentname:music", ["song.mp3", "Song2.MP3", "Playlists"])
expect("ancestorname:safari", ["Contents", "Info.plist"])
expect("descendant:*.mp3", ["/", "Users", "bob", "Music"])
expect("sibling:notes.txt", ["report.docx", "Report Final.pdf", "Café menu.txt"])
expect("vol:macintosh ext:mp3", ["song.mp3", "Song2.MP3"])
expect("unique: ext:txt", ["notes.txt", "Café menu.txt"])
expect("distinct: ext:txt", ["a.txt", "notes.txt", "Café menu.txt"])
expect("dupe:size", ["file10.log", "file2.log", "Report Final.pdf", "IMG_0001.JPG"])
expect("sort:size-descending ext:mp3", ["song.mp3", "Song2.MP3"], ordered: true)
expect("runcount:", [])
expect("&sp:", ["Report Final.pdf", "Café menu.txt", "/"])
expect("dm:3weeks..2weeks", [])
expect("type:folder", ["/", "Users", "bob", "Documents", "Music", "Playlists", "Pictures", "Applications", "Contents", "tmp"])
expect("content:<abc 123>", [])
expect("a.txt | notes.txt", ["a.txt", "a.txt", "notes.txt"])
do {
    let ast = QueryParser.parse("a b|c d", options: ParserOptions(andPrecedence: true))
    if case .or(let alts) = ast, alts.count == 2 { passes += 1 } else { failures += 1; print("FAIL and-precedence: \(ast)") }
    let dv = DateValue(now: nowDate, calendar: calendar, dayFirst: false)
    if let r = dv.parse("last2weeks") { check(r.hi == .max, "last2weeks open-ended") }
    if let r = dv.parse("previous2weeks"), let w = dv.parse("thisweek") { check(r.hi == w.lo, "previous2weeks ends at this week") }
    check(dv.parse("2days") != nil, "bare duration")
    check(dv.parse("ytd") != nil, "ytd")
    check(dv.parse("20240315") != nil, "compact date")
    check(dv.parse("lasthour") != nil, "lasthour")
}

// MARK: - Dates parser

do {
    let dv = DateValue(now: nowDate, calendar: calendar, dayFirst: true)
    check(dv.parse("2024") != nil, "year")
    check(dv.parse("15/03/2024") != nil, "dd/mm/yyyy")
    check(dv.parse("2024-03-15T10:30") != nil, "iso time")
    check(dv.parse("lastweek") != nil, "lastweek")
    check(dv.parse("past3days") != nil, "past3days")
    check(dv.parse("thismonth") != nil, "thismonth")
    check(dv.parse("january") != nil, "january")
    check(dv.parse("monday") != nil, "monday")
    check(dv.parse("bogus") == nil, "bogus date")
    if let y = dv.parse("yesterday"), let t = dv.parse("today") { check(y.hi == t.lo, "yesterday ends where today starts") }
}

// MARK: - Live mutations keep orders valid

index.mutate { ix in
    let music = ids["/Users/bob/Music"]!
    _ = ix.add(parent: music, name: "aaa.mp3", meta: EntryMeta(size: 1))
    ix.move(ids["/Users/bob/Music/song.mp3"]!, to: ids["/tmp"]!, name: "zzz.mp3")
    ix.remove(ids["/Users/bob/Pictures"]!)
}
expect("ext:mp3", ["aaa.mp3", "Song2.MP3", "zzz.mp3"], ordered: true)
expect("parent:/tmp ext:mp3", ["zzz.mp3"])
expect("img", [])
check(index.lookup(path: "/tmp/zzz.mp3") != kNoEntry, "lookup moved")
check(index.lookup(path: "/Users/bob/Music/song.mp3") == kNoEntry, "old path gone")

// MARK: - Database round trip

do {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("epitome-selftest.db")
    try Database.save(index, to: url)
    let loaded = try Database.load(from: url)!
    check(loaded.liveCount == index.liveCount, "db live count \(loaded.liveCount) vs \(index.liveCount)")
    let r = SearchEngine.run(SearchRequest(text: "ext:mp3"), index: loaded, services: services)!
    check(r.count == 3, "db search count \(r.count)")
    check(loaded.lookup(path: "/Users/bob/Documents/Café menu.txt") != kNoEntry, "db lookup non-ascii")
} catch {
    failures += 1
    print("FAIL db: \(error)")
}

// MARK: - File lists

do {
    let efu = "Filename,Size,Date Modified,Date Created,Attributes\n\"/Volumes/Old/Photos/beach.jpg\",1234,133000000000000000,,0\n\"/Volumes/Old/Photos\",,,,16\n\"C:\\\\Docs\\\\plan.txt\",10,,,32\n"
    let list = try FileList.parse(efu)
    check(list.entries.count == 3, "efu entries \(list.entries.count)")
    check(list.entries.first?.path == "/Volumes/Old/Photos/beach.jpg", "efu path")
    let text = FileList.write(list)
    check(text.hasPrefix("Filename,Size"), "efu write header")
    index.mutate { ix in FileListLoader.add(list, named: "old.efu", path: "/tmp/old.efu", to: ix) }
    expect("beach", ["beach.jpg"])
    expect("filelistfilename:old.efu", ["Volumes", "Old", "Photos", "beach.jpg", "Docs", "plan.txt", "C:"].filter { _ in true })
} catch {
    failures += 1
    print("FAIL efu: \(error)")
}


// MARK: - Servers (HTTP, ETP, IPC) against the synthetic index

do {
    ignoreSIGPIPE()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("epitome-selftest-\(getpid())")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let mgr = IndexManager(dataDirectory: tmp, settings: AppSettings(), noDatabase: true)
    mgr.adopt(index)
    let http = HTTPServer(manager: mgr)
    var hc = HTTPServer.Config()
    hc.port = 0
    hc.bind = "127.0.0.1"
    try http.start(hc)
    func get(_ path: String) -> String {
        guard let c = Connector.tcp(host: "127.0.0.1", port: http.boundPort) else { return "" }
        c.write("GET \(path) HTTP/1.0\r\nHost: x\r\n\r\n")
        var out = ""
        while let l = c.readLine() { out += l + "\n" }
        return out
    }
    let j = get("/?search=report&json=1&path_column=1&size_column=1")
    check(j.contains("\"totalResults\":2"), "http json: \(j.suffix(200))")
    let h = get("/?search=ext:mp3")
    check(h.contains("Song2.MP3") && h.contains("<table"), "http html")
    let f = get("/Users/bob/Music/")
    check(f.contains("Song2.MP3"), "http folder listing")
    http.stop()

    let etp = ETPServer(manager: mgr)
    var ec = ETPServer.Config()
    ec.port = 0
    ec.bind = "127.0.0.1"
    try etp.start(ec)
    let client = ETPClient(host: "127.0.0.1", port: etp.boundPort)
    check(client.connect(), "etp connect \(client.lastError)")
    if let (total, rows) = client.search("ext:mp3", options: SearchOptions(), filter: nil, sort: .name, ascending: true, offset: 0, count: 10) {
        check(total == 3 && rows.count == 3, "etp search \(total) \(rows.map(\.name))")
    } else { failures += 1; print("FAIL etp search: \(client.lastError)") }
    client.close()
    etp.stop()

    let sock = tmp.appendingPathComponent("t.sock").path
    let ipc = try IPCServer(path: sock, manager: mgr)
    ipc.start()
    var r = IPCRequest(cmd: "search")
    r.query = "ext:mp3"
    r.fields = ["name", "size"]
    var got = 0
    _ = IPCClient.send(r, socketPath: sock) { obj in
        if obj is [Any] { got += 1 }
        return true
    }
    check(got == 3, "ipc rows \(got)")
    ipc.stop()
} catch {
    failures += 1
    print("FAIL servers: \(error)")
}

// MARK: - Performance (synthetic)

do {
    let big = FileIndex()
    let n = CommandLine.arguments.contains("--big") ? 3_000_000 : 300_000
    let words = ["alpha", "beta", "gamma", "delta", "report", "photo", "IMG", "song", "data", "cache", "log", "index"]
    let exts = ["txt", "jpg", "png", "mp3", "pdf", "swift", "json", "log", "dat", "html"]
    var rng = SystemRandomNumberGenerator()
    big.mutate { ix in
        let root = ix.addRoot(SourceInfo(kind: .volume, path: "/", name: "HD"), meta: EntryMeta(flags: dir))
        var folders: [EntryID] = [root]
        for i in 0..<n {
            let w = words[Int(rng.next() % UInt64(words.count))]
            let isDir = i % 10 == 0
            let p = folders[Int(rng.next() % UInt64(folders.count))]
            let name = isDir ? "\(w)_\(i)" : "\(w)-\(i).\(exts[i % exts.count])"
            let id = ix.add(parent: p, name: name, meta: EntryMeta(flags: isDir ? dir : 0, size: isDir ? kUnknownSize : Int64(rng.next() % 50_000_000), mtime: daysAgo(Double(rng.next() % 2000))))
            if isDir { folders.append(id) }
        }
    }
    var t = Clock.now
    big.rebuildOrders()
    print(String(format: "perf: %d entries, orders built in %.2fs", n, Clock.now - t))
    for q in ["report", "*.jpg", "ext:mp3;jpg", "size:>40mb", "dm:pastyear", "alpha/beta", "alpha/bet", "gamma/", "song !log", "regex:^img-\\d+5\\.", "", "ww:gamma file:"] {
        t = Clock.now
        let r = SearchEngine.run(SearchRequest(text: q), index: big, services: services)!
        print(String(format: "perf: %-28@ %8d results %7.1f ms", "\"\(q)\"" as NSString, r.count, (Clock.now - t) * 1000))
    }
    t = Clock.now
    let r = SearchEngine.run(SearchRequest(text: "report", sort: .size, ascending: false), index: big, services: services)!
    print(String(format: "perf: report by size desc %d results %.1f ms", r.count, (Clock.now - t) * 1000))
    t = Clock.now
    let r2 = SearchEngine.run(SearchRequest(text: "photo", sort: .type), index: big, services: services)!
    print(String(format: "perf: photo by type %d results %.1f ms", r2.count, (Clock.now - t) * 1000))
}

// MARK: - Optional real scan

if let i = CommandLine.arguments.firstIndex(of: "--scan"), i + 1 < CommandLine.arguments.count {
    let root = CommandLine.arguments[i + 1]
    let res = ParallelScanner(options: ScanOptions()).scan(root: root)
    print(String(format: "scan %@: %d entries in %.2fs (%d errors)", root, res.count, res.seconds, res.errors))
}

print("selftest: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
