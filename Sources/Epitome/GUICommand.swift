import AppKit
import EpitomeCore

/// Window switches from the command line, `ep -gui …`, a second launch, or an
/// `epitome:` link (see Help → Command Line Options), parsed into one request.
struct GUICommand {
    var search: String?
    var searchPrefix: [String] = []
    var matchCase: Bool?
    var wholeWord: Bool?
    var matchPath: Bool?
    var diacritics: Bool?
    var regex: Bool?
    var filter: String?
    var bookmark: String?
    var home = false
    var sort: SortKey?
    var ascending: Bool?
    var view: ViewMode?
    var thumbnailSize: Int?
    var newWindow: Bool?
    var show = false
    var toggleWindow = false
    var close = false
    var closeAll = false
    var minimized: Bool?
    var maximized: Bool?
    var fullscreen: Bool?
    var onTop: Bool?
    var focus: String?
    var select: String?
    var fileList: String?
    var local = false
    var edit: String?
    var connect: String?
    var url: String?
    var frame = (x: Double?.none, y: Double?.none, w: Double?.none, h: Double?.none)
    var zoom: Int?
    var filterBar: Bool?
    var statusBar: Bool?
    var preview: Bool?
    var reindex = false
    var saveDB = false
    var rescanAll = false
    var rescan: [String] = []
    var monitorPause = false
    var monitorResume = false
    var showOptions = false
    var showDebug = false
    var showHelp = false
    var quit = false
    var restart = false
    var unknown: [String] = []

    /// True when the command only affects the app, not a window's search.
    var hasWindowContent: Bool {
        search != nil || !searchPrefix.isEmpty || matchCase != nil || wholeWord != nil || matchPath != nil || diacritics != nil ||
            regex != nil || filter != nil || bookmark != nil || home || sort != nil || ascending != nil || view != nil ||
            focus != nil || select != nil || fileList != nil || local || connect != nil || url != nil
    }

    static func parse(_ args: [String]) -> GUICommand {
        var c = GUICommand()
        var i = 0
        func next() -> String? {
            guard i + 1 < args.count else { return nil }
            i += 1
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            defer { i += 1 }
            if !a.hasPrefix("-") || a == "-" {
                // A positional argument: an EFU opens as a file list, a folder searches inside it, a file searches for it.
                let p = (a as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                if a.lowercased().hasPrefix("epitome:") || a.lowercased().hasPrefix("es:") { c.url = a; continue }
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
                    if !isDir.boolValue && (p as NSString).pathExtension.lowercased() == "efu" { c.fileList = p }
                    else if isDir.boolValue { c.searchPrefix.append(GUICommand.quote(p.hasSuffix("/") ? p : p + "/")) }
                    else { c.searchPrefix.append("path:wfn:" + GUICommand.quote(p)) }
                } else {
                    c.search = (c.search.map { $0 + " " } ?? "") + a
                }
                continue
            }
            let name = LaunchOptions.norm(a)
            switch name {
            case "s", "search":
                c.search = next() ?? ""
            case "s*", "search*":
                // The rest of the line is the search text, taken literally.
                c.search = args[(i + 1)...].joined(separator: " ")
                i = args.count
            case "filename":
                if let f = next() {
                    let p = (f as NSString).expandingTildeInPath
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                        c.searchPrefix.append(quote(p.hasSuffix("/") ? p : p + "/"))
                    } else {
                        c.searchPrefix.append("path:wfn:" + quote(p))
                    }
                }
            case "p", "path":
                if let p = next() {
                    let e = (p as NSString).expandingTildeInPath
                    c.searchPrefix.append(quote(e.hasSuffix("/") ? e : e + "/"))
                }
            case "parent":
                if let p = next() { c.searchPrefix.append("parent:" + quote((p as NSString).expandingTildeInPath)) }
            case "parentpath":
                if let p = next() {
                    let dir = ((p as NSString).expandingTildeInPath as NSString).deletingLastPathComponent
                    c.searchPrefix.append(quote(dir.hasSuffix("/") ? dir : dir + "/"))
                }
            case "namepart":
                if let p = next() { c.searchPrefix.append("wfn:" + quote((p as NSString).lastPathComponent)) }
            case "stem":
                if let p = next() { c.searchPrefix.append("stem:" + quote(((p as NSString).lastPathComponent as NSString).deletingPathExtension)) }
            case "extension":
                if let p = next() { c.searchPrefix.append("ext:" + (p as NSString).pathExtension) }
            case "searchfilelist":
                if let p = next(), let text = try? String(contentsOfFile: (p as NSString).expandingTildeInPath, encoding: .utf8) {
                    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if !lines.isEmpty { c.searchPrefix.append("filelist:" + quote(lines.joined(separator: "|"))) }
                }
            case "case": c.matchCase = true
            case "nocase": c.matchCase = false
            case "wholeword", "ww": c.wholeWord = true
            case "nowholeword", "noww": c.wholeWord = false
            case "matchpath": c.matchPath = true
            case "nomatchpath": c.matchPath = false
            case "diacritics": c.diacritics = true
            case "nodiacritics": c.diacritics = false
            case "regex": c.regex = true
            case "noregex": c.regex = false
            case "filter": c.filter = next()
            case "bookmark": c.bookmark = next()
            case "home": c.home = true
            case "l", "local": c.local = true
            case "url": c.url = next()
            case "sort":
                if let s = next() { c.sort = SortKey.parse(s) }
            case "sortascending": c.ascending = true
            case "sortdescending": c.ascending = false
            case "details": c.view = .details
            case "thumbnails": c.view = c.view == nil || c.view == .details ? .large : c.view
            case "thumbnailsize":
                if let s = next(), let n = Int(s) {
                    c.thumbnailSize = n
                    c.view = n <= 96 ? .medium : (n <= 192 ? .large : .extraLarge)
                }
            case "newwindow": c.newWindow = true
            case "nonewwindow": c.newWindow = false
            case "show": c.show = true
            case "togglewindow": c.toggleWindow = true
            case "close": c.close = true
            case "closeall": c.closeAll = true
            case "minimized", "minimize": c.minimized = true
            case "nominimized", "unminimize": c.minimized = false
            case "maximized", "maximize": c.maximized = true
            case "nomaximized", "nomaximize": c.maximized = false
            case "fullscreen": c.fullscreen = true
            case "nofullscreen": c.fullscreen = false
            case "ontop": c.onTop = true
            case "noontop": c.onTop = false
            case "focusresults": c.focus = "results"
            case "focussearch": c.focus = "search"
            case "focustopresult", "selecttopresult": c.focus = "top"
            case "focusbottomresult", "selectbottomresult": c.focus = "bottom"
            case "focusmostrunresult", "selectmostrunresult": c.focus = "most-run"
            case "focuslastrunresult", "selectlastrunresult": c.focus = "last-run"
            case "selectrandomresult": c.focus = "random"
            case "select": c.select = next().map { ($0 as NSString).expandingTildeInPath }
            case "f", "filelist": c.fileList = next().map { ($0 as NSString).expandingTildeInPath }
            case "edit", "filelisteditor": c.edit = next().map { ($0 as NSString).expandingTildeInPath } ?? ""
            case "connect": c.connect = next()
            case "x": c.frame.x = next().flatMap { Double($0) }
            case "y": c.frame.y = next().flatMap { Double($0) }
            case "width": c.frame.w = next().flatMap { Double($0) }
            case "height": c.frame.h = next().flatMap { Double($0) }
            case "zoom": c.zoom = next().flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
            case "filterbar": c.filterBar = true
            case "nofilterbar": c.filterBar = false
            case "statusbar": c.statusBar = true
            case "nostatusbar": c.statusBar = false
            case "preview": c.preview = true
            case "nopreview": c.preview = false
            case "reindex": c.reindex = true
            case "update", "savedb", "savedbnow": c.saveDB = true
            case "rescanall": c.rescanAll = true
            case "rescan": if let p = next() { c.rescan.append((p as NSString).expandingTildeInPath) }
            case "monitorpause", "monitorstop": c.monitorPause = true
            case "monitorresume", "monitorstart": c.monitorResume = true
            case "options", "preferences", "settings": c.showOptions = true
            case "debug", "console": c.showDebug = true
            case "help", "h", "?": c.showHelp = true
            case "exit", "quit": c.quit = true
            case "restart": c.restart = true
            case "startup", "instance", "config", "db", "readonly", "nodb", "debuglog", "firstinstance", "nofirstinstance":
                // Launch-time switches; a running instance ignores them (consume their value).
                if ["instance", "config", "db", "debuglog"].contains(name), i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
            default:
                c.unknown.append(a)
            }
        }
        return c
    }

    /// Parses `epitome:<search>[?key=value&…][#<file>]` (also `es:`).
    static func parse(url raw: String) -> GUICommand {
        var c = GUICommand()
        var s = raw
        for scheme in ["epitome://", "epitome:", "es://", "es:"] where s.lowercased().hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
            break
        }
        var fragment: String?
        if let h = s.firstIndex(of: "#") {
            fragment = String(s[s.index(after: h)...])
            s = String(s[..<h])
        }
        var query = ""
        if let q = s.firstIndex(of: "?") {
            query = String(s[s.index(after: q)...])
            s = String(s[..<q])
        }
        c.search = (s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s)
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            let key = LaunchOptions.norm(kv[0])
            let value = kv.count > 1 ? kv[1] : "1"
            let on = value != "0" && value.lowercased() != "false"
            switch key {
            case "sort":
                var v = value.lowercased()
                if v.hasSuffix("-descending") { c.ascending = false; v = String(v.dropLast(11)) }
                else if v.hasSuffix("-ascending") { c.ascending = true; v = String(v.dropLast(10)) }
                c.sort = SortKey.parse(v)
            case "ascending": c.ascending = on
            case "case", "matchcase": c.matchCase = on
            case "diacritics": c.diacritics = on
            case "path", "matchpath": c.matchPath = on
            case "regex": c.regex = on
            case "wholeword", "ww": c.wholeWord = on
            case "filter": c.filter = value
            case "bookmark": c.bookmark = value
            case "view":
                switch value.lowercased() {
                case "details": c.view = .details
                case "thumbnails", "large": c.view = .large
                case "medium": c.view = .medium
                case "extralarge", "extra-large": c.view = .extraLarge
                default: if let n = Int(value) { c.view = n <= 96 ? .medium : (n <= 192 ? .large : .extraLarge) }
                }
            case "thumbnailsize":
                if let n = Int(value) { c.view = n <= 96 ? .medium : (n <= 192 ? .large : .extraLarge) }
            case "newwindow", "newtab": c.newWindow = on
            default: break
            }
        }
        if let f = fragment, !f.isEmpty { c.select = f.removingPercentEncoding ?? f }
        return c
    }

    static func quote(_ s: String) -> String {
        s.contains(" ") || s.contains("|") || s.contains("<") || s.contains(">") ? "\"\(s)\"" : s
    }

    /// The search text this command asks for (prefix terms + search), or nil to keep the current text.
    var composedSearch: String? {
        if search == nil && searchPrefix.isEmpty { return nil }
        return (searchPrefix + [search ?? ""]).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension AppDelegate {
    /// Applies window switches (launch, second launch, `ep -gui`, URLs).
    func handleGUI(_ args: [String]) {
        apply(GUICommand.parse(args))
    }

    func apply(_ cmd: GUICommand) {
        let m = model.manager
        if cmd.quit { NSApp.terminate(nil); return }
        if cmd.restart { restart(); return }
        if cmd.reindex { m.rebuild() }
        if cmd.saveDB { m.save() }
        if cmd.rescanAll { m.rescanAllFolders() }
        for p in cmd.rescan { m.rescan(path: p) }
        if cmd.monitorPause { m.pauseMonitoring() }
        if cmd.monitorResume { m.resumeMonitoring() }
        if cmd.closeAll { closeAllWindows(); return }
        if cmd.close { frontController?.window?.performClose(nil); return }
        if cmd.showOptions { showOptions(nil) }
        if cmd.showDebug { showDebugConsole(nil) }
        if cmd.showHelp { showHelp(page: "index") }
        if let e = cmd.edit { showFileListEditor(path: e.isEmpty ? nil : e) }
        if !cmd.unknown.isEmpty { model.log.write("ignored switches: \(cmd.unknown.joined(separator: " "))") }
        if let u = cmd.url {
            var uc = GUICommand.parse(url: u)
            if uc.newWindow == nil { uc.newWindow = cmd.newWindow }
            apply(uc)
            return
        }
        if cmd.toggleWindow { toggleWindow(); return }
        let adminOnly = !cmd.hasWindowContent && !cmd.show && cmd.newWindow == nil && cmd.minimized == nil &&
            cmd.maximized == nil && cmd.fullscreen == nil && cmd.onTop == nil && cmd.frame.x == nil && cmd.frame.w == nil &&
            cmd.zoom == nil && cmd.filterBar == nil && cmd.statusBar == nil && cmd.preview == nil
        if adminOnly && (cmd.reindex || cmd.saveDB || cmd.rescanAll || !cmd.rescan.isEmpty || cmd.monitorPause ||
                         cmd.monitorResume || cmd.showOptions || cmd.showDebug || cmd.showHelp || cmd.edit != nil) { return }

        // Pick or create the window.
        let wantNew = cmd.newWindow ?? model.settings.newWindowOnLaunch
        let wc: SearchWindowController
        if !wantNew, let existing = frontController ?? windows.last {
            wc = existing
            wc.showWindow(nil)
        } else {
            wc = openSearchWindow()
        }
        NSApp.activate(ignoringOtherApps: true)

        // Index source.
        if let fl = cmd.fileList { wc.openFileList(path: fl) }
        if cmd.local { wc.closeFileList(nil) }
        if let link = cmd.connect { connectETP(link: link, window: wc) }

        if cmd.home { wc.goHome(nil) }
        if let b = cmd.bookmark {
            if let bm = model.bookmarks.current.first(where: { $0.name.caseInsensitiveCompare(b) == .orderedSame }) { wc.openBookmark(bm) }
            else { wc.statusBar.flash("No bookmark named “\(b)”") }
        }
        var changed = false
        if let t = cmd.composedSearch { wc.searchText = t; changed = true }
        if let v = cmd.matchCase { wc.options.matchCase = v; changed = true }
        if let v = cmd.wholeWord { wc.options.matchWholeWord = v; changed = true }
        if let v = cmd.matchPath { wc.options.matchPath = v; changed = true }
        if let v = cmd.diacritics { wc.options.matchDiacritics = v; changed = true }
        if let v = cmd.regex { wc.options.regex = v; changed = true }
        if let f = cmd.filter {
            if let flt = model.filter(named: f) { wc.filter = flt.isEverything ? nil : flt; wc.selectFilterInPopup() }
            else { wc.statusBar.flash("No filter named “\(f)”") }
            changed = true
        }
        if let s = cmd.sort {
            wc.sortKey = s
            wc.ascending = cmd.ascending ?? s.defaultAscending
            wc.table.updateSortIndicator()
            changed = true
        } else if let a = cmd.ascending {
            wc.ascending = a
            wc.table.updateSortIndicator()
            changed = true
        }
        if let v = cmd.view { wc.setViewMode(v) }
        if changed {
            wc.updateTitle()
            wc.runSearch(immediate: true)
        }

        // Window state.
        if let w = wc.window {
            if cmd.frame.x != nil || cmd.frame.y != nil || cmd.frame.w != nil || cmd.frame.h != nil {
                var f = w.frame
                let screenH = (w.screen ?? NSScreen.main)?.frame.height ?? f.maxY
                if let width = cmd.frame.w { f.size.width = width }
                if let height = cmd.frame.h { f.origin.y += f.height - height; f.size.height = height }
                if let x = cmd.frame.x { f.origin.x = x }
                if let y = cmd.frame.y { f.origin.y = screenH - y - f.height } // top-left origin like the original
                w.setFrame(f, display: true)
            }
            if let mz = cmd.maximized, mz != w.isZoomed { w.zoom(nil) }
            if let fs = cmd.fullscreen, fs != w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            if let mn = cmd.minimized { if mn { w.miniaturize(nil) } else { w.deminiaturize(nil) } }
        }
        if let ot = cmd.onTop { model.rememberState { $0.onTop = ot ? .always : .never }; wc.applyOnTop() }
        if let z = cmd.zoom { wc.zoom = CGFloat((z - 100) / 10); wc.table.applyFont() }
        if let v = cmd.filterBar, v != model.settings.showFilterBar { wc.toggleFilterBar(nil) }
        if let v = cmd.statusBar, v != model.settings.showStatusBar { wc.toggleStatusBar(nil) }
        if let v = cmd.preview, v != model.settings.showPreview { wc.togglePreview(nil) }

        // Focus / selection once the search has finished.
        if cmd.focus != nil || cmd.select != nil {
            let focus = cmd.focus, select = cmd.select
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak wc] in
                guard let wc else { return }
                wc.applyFocusRequest(focus, select: select)
            }
        }
    }
}

extension SearchWindowController {
    /// `-focus-*` / `-select` switches.
    func applyFocusRequest(_ focus: String?, select: String?) {
        if let path = select {
            if case .local(let res) = results.kind {
                let id = res.index.lock.read { res.index.lookup(path: path) }
                if id != kNoEntry {
                    let rows = results.rows(for: [id])
                    if let r = rows.first {
                        window?.makeFirstResponder(table)
                        selectRow(r)
                        return
                    }
                }
            }
            statusBar.flash("Not in the results: \((path as NSString).lastPathComponent)")
            return
        }
        guard let f = focus else { return }
        switch f {
        case "search": focusSearch(nil)
        case "results": focusResults(selectFirst: false)
        case "top":
            window?.makeFirstResponder(table)
            if results.count > 0 { selectRow(0) }
        case "bottom":
            window?.makeFirstResponder(table)
            if results.count > 0 { selectRow(results.count - 1) }
        case "most-run": focusResultsSelectingMostRun()
        case "last-run":
            let runs = model.manager.runHistory.all().sorted { $0.value.last > $1.value.last }
            if case .local(let res) = results.kind {
                for (p, _) in runs.prefix(200) {
                    let id = res.index.lock.read { res.index.lookup(path: p) }
                    if id != kNoEntry, let r = results.rows(for: [id]).first {
                        window?.makeFirstResponder(table)
                        selectRow(r)
                        return
                    }
                }
            }
        case "random":
            if results.count > 0 {
                window?.makeFirstResponder(table)
                selectRow(Int.random(in: 0..<results.count))
            }
        default: break
        }
    }
}
