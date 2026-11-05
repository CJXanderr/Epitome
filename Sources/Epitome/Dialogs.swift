import AppKit
import CoreServices
import EpitomeCore
import UniformTypeIdentifiers

// MARK: - Filter editor

/// Add to Filters… / Organize Filters → Edit.
enum FilterEditor {
    static func edit(_ filter: Filter, isNew: Bool, over parent: NSWindow?, done: @escaping (Filter?) -> Void) {
        let f = FormView(labelWidth: 110)
        let name = textField(filter.name, width: 320)
        let search = textField(filter.search, placeholder: "e.g. ext:mp3;flac", width: 320)
        search.isEnabled = !filter.isEverything
        let mc = checkbox("Match case", filter.options.matchCase)
        let ww = checkbox("Match whole word", filter.options.matchWholeWord)
        let mp = checkbox("Match path", filter.options.matchPath)
        let md = checkbox("Match diacritics", filter.options.matchDiacritics)
        let rx = checkbox("Regex", filter.options.regex)
        let macro = textField(filter.macro, placeholder: "e.g. audio  →  type audio: in a search", width: 200)
        let key = KeyRecorderButton(combo: filter.shortcut)
        f.row("Name", [name])
        f.row("Search", [search])
        f.row("", [vstack([hstack([mc, ww, mp]), hstack([md, rx])], spacing: 4)])
        f.row("Macro", [macro])
        f.row("Shortcut", [key, button("Clear") { key.combo = nil }])
        f.note("A filter is combined with whatever you type in the search box. Its macro works in any search: “\(filter.macro.isEmpty ? "macro" : filter.macro): report” searches inside the filter.")
        let panel = makeDialog(title: isNew ? "Add Filter" : "Edit Filter", content: f) { p in
            let n = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { NSSound.beep(); p.makeFirstResponder(name); return false }
            return true
        }
        runDialog(panel, over: parent) { r in
            guard r == .OK else { done(nil); return }
            var out = filter
            out.name = name.stringValue.trimmingCharacters(in: .whitespaces)
            out.search = search.stringValue
            out.macro = macro.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            out.shortcut = key.combo
            out.options = SearchOptions(matchCase: mc.state == .on, matchWholeWord: ww.state == .on, matchPath: mp.state == .on,
                                        matchDiacritics: md.state == .on, regex: rx.state == .on)
            done(out)
        }
    }
}

// MARK: - Bookmark editor

enum BookmarkEditor {
    static func edit(_ bm: Bookmark, isNew: Bool, over parent: NSWindow?, done: @escaping (Bookmark?) -> Void) {
        let f = FormView(labelWidth: 110)
        let name = textField(bm.name, width: 320)
        let folder = textField(bm.folder, placeholder: "(none) or Music/Live", width: 320)
        let search = textField(bm.search, width: 320)
        let o = bm.options
        let mc = checkbox("Match case", o.matchCase)
        let ww = checkbox("Match whole word", o.matchWholeWord)
        let mp = checkbox("Match path", o.matchPath)
        let md = checkbox("Match diacritics", o.matchDiacritics)
        let rx = checkbox("Regex", o.regex)
        let keepFilter = checkbox("Filter" + (bm.filter.map { " (\($0))" } ?? ""), bm.filter != nil)
        keepFilter.isEnabled = bm.filter != nil
        let keepSort = checkbox("Sort" + (bm.sort.map { " (\($0.title)\(bm.ascending == false ? ", descending" : ""))" } ?? ""), bm.sort != nil)
        keepSort.isEnabled = bm.sort != nil
        let keepView = checkbox("View", bm.view != nil)
        keepView.isEnabled = bm.view != nil
        let keepIndex = checkbox("Index" + (bm.index.map { " (\($0))" } ?? " (local)"), bm.index != nil)
        keepIndex.isEnabled = bm.index != nil
        let macro = textField(bm.macro, placeholder: "optional", width: 200)
        let key = KeyRecorderButton(combo: bm.shortcut)
        f.row("Name", [name])
        f.row("Folder", [folder])
        f.row("Search", [search])
        f.row("", [vstack([hstack([mc, ww, mp]), hstack([md, rx])], spacing: 4)])
        f.row("Also restore", [vstack([hstack([keepFilter, keepSort]), hstack([keepView, keepIndex])], spacing: 4)])
        f.row("Macro", [macro])
        f.row("Shortcut", [key, button("Clear") { key.combo = nil }])
        f.note("Opening a bookmark replaces the search box text and restores the chosen settings. A search starting with > runs a search command.")
        let panel = makeDialog(title: isNew ? "Add Bookmark" : "Edit Bookmark", content: f) { p in
            guard !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { NSSound.beep(); p.makeFirstResponder(name); return false }
            return true
        }
        runDialog(panel, over: parent) { r in
            guard r == .OK else { done(nil); return }
            var out = bm
            out.name = name.stringValue.trimmingCharacters(in: .whitespaces)
            out.folder = folder.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            out.search = search.stringValue
            out.options = SearchOptions(matchCase: mc.state == .on, matchWholeWord: ww.state == .on, matchPath: mp.state == .on,
                                        matchDiacritics: md.state == .on, regex: rx.state == .on)
            if keepFilter.state == .off { out.filter = nil }
            if keepSort.state == .off { out.sort = nil; out.ascending = nil }
            if keepView.state == .off { out.view = nil }
            if keepIndex.state == .off { out.index = nil }
            out.macro = macro.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            out.shortcut = key.combo
            done(out)
        }
    }
}

// MARK: - Organize filters / bookmarks

final class OrganizeWindowController: NSWindowController, NSWindowDelegate {
    enum Kind { case filters, bookmarks }
    let kind: Kind
    var model: AppModel { AppModel.shared }
    private var table: SimpleTable!

    init(kind: Kind) {
        self.kind = kind
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = kind == .filters ? "Organize Filters" : "Organize Bookmarks"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 300)
        super.init(window: w)
        w.delegate = self
        build()
        let n = kind == .filters ? AppModel.filtersChanged : AppModel.bookmarksChanged
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: n, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    var count: Int { kind == .filters ? model.filters.current.count : model.bookmarks.current.count }

    private func build() {
        guard let content = window?.contentView else { return }
        var cols: [SimpleTable.ColumnSpec] = [.init(id: "name", title: "Name", width: 160)]
        if kind == .bookmarks { cols.append(.init(id: "folder", title: "Folder", width: 100)) }
        cols += [.init(id: "search", title: "Search", width: 260), .init(id: "macro", title: "Macro", width: 70),
                 .init(id: "key", title: "Shortcut", width: 80)]
        let t = SimpleTable(cols)
        t.rowCount = { [unowned self] in self.count }
        t.value = { [unowned self] row, col in
            if self.kind == .filters {
                let f = self.model.filters.current[row]
                switch col {
                case "name": return f.name
                case "search": return f.isEverything ? "(everything)" : f.search
                case "macro": return f.macro.isEmpty ? "" : f.macro + ":"
                default: return f.shortcut?.display ?? ""
                }
            }
            let b = self.model.bookmarks.current[row]
            switch col {
            case "name": return b.name
            case "folder": return b.folder
            case "search": return b.search
            case "macro": return b.macro.isEmpty ? "" : b.macro + ":"
            default: return b.shortcut?.display ?? ""
            }
        }
        t.onDoubleClick = { [unowned self] row in
            if self.kind == .bookmarks, NSEvent.modifierFlags.contains(.option) { self.openBookmark(row) } else { self.edit(row) }
        }
        table = t
        let buttons: [NSView] = [
            button("Add…") { [unowned self] in self.add() },
            button("Edit…") { [unowned self] in if let r = self.table.selected.first { self.edit(r) } },
            button("Duplicate") { [unowned self] in self.duplicate() },
            button("Remove") { [unowned self] in self.remove() },
            button("Move Up") { [unowned self] in self.move(-1) },
            button("Move Down") { [unowned self] in self.move(1) },
        ]
        var right: [NSView] = [button("Import…") { [unowned self] in self.importCSV() }, button("Export…") { [unowned self] in self.exportCSV() }]
        if kind == .filters { right.insert(button("Restore Defaults") { [unowned self] in self.restoreDefaultFilters() }, at: 0) }
        if kind == .bookmarks { right.insert(button("Open") { [unowned self] in if let r = self.table.selected.first { self.openBookmark(r) } }, at: 0) }
        let flex = NSView()
        flex.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = hstack(buttons + [flex] + right)
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(t.scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            t.scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            t.scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            t.scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            bar.topAnchor.constraint(equalTo: t.scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    @objc func reload() { table.reload() }

    func add() {
        switch kind {
        case .filters:
            FilterEditor.edit(Filter(name: "", search: ""), isNew: true, over: window) { [weak self] f in
                guard let self, let f else { return }
                self.model.setFilters(self.model.filters.current + [f])
            }
        case .bookmarks:
            let wc = (NSApp.delegate as? AppDelegate)?.frontController
            let b = Bookmark(name: wc?.searchText ?? "", search: wc?.searchText ?? "", options: wc?.options ?? SearchOptions())
            BookmarkEditor.edit(b, isNew: true, over: window) { [weak self] nb in
                guard let self, let nb else { return }
                self.model.setBookmarks(self.model.bookmarks.current + [nb])
            }
        }
    }

    func edit(_ row: Int) {
        guard row >= 0, row < count else { return }
        switch kind {
        case .filters:
            let f = model.filters.current[row]
            FilterEditor.edit(f, isNew: false, over: window) { [weak self] nf in
                guard let self, let nf else { return }
                var list = self.model.filters.current
                if let i = list.firstIndex(where: { $0.id == nf.id }) { list[i] = nf }
                self.model.setFilters(list)
            }
        case .bookmarks:
            let b = model.bookmarks.current[row]
            BookmarkEditor.edit(b, isNew: false, over: window) { [weak self] nb in
                guard let self, let nb else { return }
                var list = self.model.bookmarks.current
                if let i = list.firstIndex(where: { $0.id == nb.id }) { list[i] = nb }
                self.model.setBookmarks(list)
            }
        }
    }

    func duplicate() {
        guard let r = table.selected.first, r < count else { return }
        switch kind {
        case .filters:
            var f = model.filters.current[r]
            guard !f.isEverything else { NSSound.beep(); return }
            f.id = UUID()
            f.name += " copy"
            f.shortcut = nil
            f.macro = ""
            var list = model.filters.current
            list.insert(f, at: r + 1)
            model.setFilters(list)
        case .bookmarks:
            var b = model.bookmarks.current[r]
            b.id = UUID()
            b.name += " copy"
            b.shortcut = nil
            b.macro = ""
            var list = model.bookmarks.current
            list.insert(b, at: r + 1)
            model.setBookmarks(list)
        }
    }

    func remove() {
        let rows = table.selected
        guard !rows.isEmpty else { return }
        switch kind {
        case .filters:
            var list = model.filters.current
            for i in rows.sorted(by: >) where i < list.count && !list[i].isEverything { list.remove(at: i) }
            model.setFilters(list)
        case .bookmarks:
            var list = model.bookmarks.current
            for i in rows.sorted(by: >) where i < list.count { list.remove(at: i) }
            model.setBookmarks(list)
        }
    }

    func move(_ d: Int) {
        guard let r = table.selected.first, r + d >= 0, r + d < count else { return }
        switch kind {
        case .filters:
            var list = model.filters.current
            list.swapAt(r, r + d)
            model.setFilters(list)
        case .bookmarks:
            var list = model.bookmarks.current
            list.swapAt(r, r + d)
            model.setBookmarks(list)
        }
        table.table.selectRowIndexes(IndexSet(integer: r + d), byExtendingSelection: false)
    }

    func restoreDefaultFilters() {
        guard alert("Restore the default filters?", "Your own filters are kept; the built-in ones get their original definitions back.",
                    style: .informational, buttons: ["Restore", "Cancel"]) == .alertFirstButtonReturn else { return }
        var list = model.filters.current
        for d in Filter.defaults {
            if let i = list.firstIndex(where: { $0.name == d.name }) {
                list[i].search = d.search
                list[i].macro = d.macro
                list[i].options = d.options
            } else {
                list.append(d)
            }
        }
        model.setFilters(list)
    }

    func openBookmark(_ row: Int) {
        guard row >= 0, row < model.bookmarks.current.count, let app = NSApp.delegate as? AppDelegate else { return }
        let wc = app.frontController ?? app.openSearchWindow()
        wc.openBookmark(model.bookmarks.current[row])
        wc.showWindow(nil)
    }

    // CSV import/export (Name, Search, Macro, Case, WholeWord, Path, Diacritics, Regex[, Folder])

    func exportCSV() {
        let p = NSSavePanel()
        p.nameFieldStringValue = kind == .filters ? "Filters.csv" : "Bookmarks.csv"
        p.allowedContentTypes = [.commaSeparatedText]
        guard p.runModal() == .OK, let url = p.url else { return }
        var lines: [[String]] = []
        func flags(_ o: SearchOptions) -> [String] {
            [o.matchCase, o.matchWholeWord, o.matchPath, o.matchDiacritics, o.regex].map { $0 ? "1" : "0" }
        }
        switch kind {
        case .filters:
            lines.append(["Name", "Search", "Macro", "Case", "Whole Word", "Path", "Diacritics", "Regex"])
            for f in model.filters.current where !f.isEverything { lines.append([f.name, f.search, f.macro] + flags(f.options)) }
        case .bookmarks:
            lines.append(["Name", "Search", "Macro", "Case", "Whole Word", "Path", "Diacritics", "Regex", "Folder", "Filter", "Sort"])
            for b in model.bookmarks.current {
                lines.append([b.name, b.search, b.macro] + flags(b.options) + [b.folder, b.filter ?? "", b.sort?.rawValue ?? ""])
            }
        }
        let text = lines.map { $0.map(CSV.escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSApp.presentError(error) }
    }

    func importCSV() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard p.runModal() == .OK, let url = p.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var rows = CSV.parse(text)
        guard !rows.isEmpty else { return }
        if rows[0].first?.lowercased() == "name" { rows.removeFirst() }
        func opts(_ r: [String]) -> SearchOptions {
            func b(_ i: Int) -> Bool { i < r.count && (r[i] == "1" || r[i].lowercased() == "true") }
            return SearchOptions(matchCase: b(3), matchWholeWord: b(4), matchPath: b(5), matchDiacritics: b(6), regex: b(7))
        }
        var added = 0
        switch kind {
        case .filters:
            var list = model.filters.current
            for r in rows where r.count >= 2 && !r[0].isEmpty {
                let f = Filter(name: r[0], search: r[1], macro: r.count > 2 ? r[2] : "", options: opts(r))
                if let i = list.firstIndex(where: { $0.name == f.name }) { list[i].search = f.search; list[i].macro = f.macro; list[i].options = f.options }
                else { list.append(f) }
                added += 1
            }
            model.setFilters(list)
        case .bookmarks:
            var list = model.bookmarks.current
            for r in rows where r.count >= 2 && !r[0].isEmpty {
                var b = Bookmark(name: r[0], search: r[1], options: opts(r), macro: r.count > 2 ? r[2] : "")
                if r.count > 8 { b.folder = r[8] }
                if r.count > 9, !r[9].isEmpty { b.filter = r[9] }
                if r.count > 10 { b.sort = SortKey(rawValue: r[10]) }
                list.append(b)
                added += 1
            }
            model.setBookmarks(list)
        }
        _ = alert("Imported \(added) \(kind == .filters ? "filters" : "bookmarks")", "", style: .informational)
    }
}

enum CSV {
    static func escape(_ s: String) -> String {
        s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQ = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return it.next()
        }
        while let c = nextChar() {
            if inQ {
                if c == "\"" {
                    if let n = nextChar() {
                        if n == "\"" { field.append("\"") } else { inQ = false; pending = n }
                    } else { inQ = false }
                } else { field.append(c) }
                continue
            }
            switch c {
            case "\"": inQ = true
            case ",": row.append(field); field = ""
            case "\r\n", "\n", "\r":
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            default: field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

// MARK: - Multi-file rename

/// Renames several items with an old/new format using %1, %2 … placeholders.
final class RenameDialog: NSObject {
    static var open: [RenameDialog] = []
    let paths: [String]
    var newNames: [String] = []
    var problems: [Int: String] = [:]
    var panel: NSPanel!
    let oldFormat: NSTextField
    let newFormat: NSTextField
    let matchCase: NSButton
    let regex: NSButton
    let table: SimpleTable
    let summary = NSTextField(labelWithString: "")
    var okButton: NSButton?

    static func show(paths: [String], over parent: NSWindow?) {
        let d = RenameDialog(paths: paths)
        open.append(d)
        d.update()
        runDialog(d.panel, over: parent) { r in
            if r == .OK { d.perform() }
            open.removeAll { $0 === d }
        }
    }

    init(paths: [String]) {
        self.paths = paths
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let (pre, suf) = RenameDialog.commonAffixes(names)
        let fmt = names.count > 1 ? RenameDialog.escapeFormat(pre) + "%1" + RenameDialog.escapeFormat(suf) : "%1"
        oldFormat = textField(fmt, width: 420)
        newFormat = textField(fmt, width: 420)
        matchCase = checkbox("Match case", false)
        regex = checkbox("Regex (old format is a regular expression; groups become %1, %2 …)", false)
        table = SimpleTable([.init(id: "old", title: "Old Name", width: 300), .init(id: "new", title: "New Name", width: 300)])
        let f = FormView(labelWidth: 100)
        super.init()
        table.rowCount = { [unowned self] in self.paths.count }
        table.value = { [unowned self] row, col in
            col == "old" ? names[row] : (self.problems[row].map { "⚠︎ " + $0 } ?? self.newNames[row])
        }
        table.table.allowsMultipleSelection = false
        table.scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        table.scroll.widthAnchor.constraint(equalToConstant: 620).isActive = true
        f.row("Old format", [oldFormat])
        f.row("New format", [newFormat])
        f.row("", [vstack([matchCase, regex], spacing: 4)])
        f.note("%1, %2 … stand for the parts that differ. Example: old “%1.jpeg”, new “%1.jpg” changes every extension; old “%1 (%2)%3”, new “%2 - %1%3” reorders.")
        f.add(table.scroll)
        f.add(summary)
        oldFormat.onTextChange { [unowned self] _ in self.update() }
        newFormat.onTextChange { [unowned self] _ in self.update() }
        matchCase.onAction { [unowned self] _ in self.update() }
        regex.onAction { [unowned self] _ in self.update() }
        panel = makeDialog(title: "Rename \(paths.count) Items", content: f, ok: "Rename") { [unowned self] _ in
            if !self.problems.isEmpty {
                NSSound.beep()
                return false
            }
            return true
        }
    }

    static func commonAffixes(_ names: [String]) -> (String, String) {
        guard var pre = names.first, var suf = names.first, names.count > 1 else { return ("", "") }
        for n in names.dropFirst() {
            while !n.hasPrefix(pre) { pre.removeLast() }
            while !n.hasSuffix(suf) { suf.removeFirst() }
        }
        // Keep the extension as the suffix rather than an accidental common tail.
        if let dot = suf.firstIndex(of: ".") { suf = String(suf[dot...]) } else { suf = "" }
        if pre.count + suf.count >= (names.map(\.count).min() ?? 0) { pre = "" }
        return (pre, suf)
    }

    static func escapeFormat(_ s: String) -> String { s.replacingOccurrences(of: "%", with: "%%") }

    /// Builds a regex from a format with %n placeholders.
    func pattern() -> NSRegularExpression? {
        let opts: NSRegularExpression.Options = matchCase.state == .on ? [] : [.caseInsensitive]
        if regex.state == .on { return try? NSRegularExpression(pattern: "^(?:" + oldFormat.stringValue + ")$", options: opts) }
        var p = "^"
        var literal = ""
        let chars = Array(oldFormat.stringValue)
        var i = 0
        var groups = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%", i + 1 < chars.count, chars[i + 1] == "%" { literal.append("%"); i += 2; continue }
            if c == "%", i + 1 < chars.count, chars[i + 1].isNumber {
                p += NSRegularExpression.escapedPattern(for: literal)
                literal = ""
                var j = i + 1
                while j < chars.count, chars[j].isNumber { j += 1 }
                groups += 1
                p += "(.*?)"
                i = j
                continue
            }
            literal.append(c)
            i += 1
        }
        p += NSRegularExpression.escapedPattern(for: literal) + "$"
        return try? NSRegularExpression(pattern: p, options: opts)
    }

    /// The group number each %n in the old format refers to (they may be out of order).
    func placeholderOrder() -> [Int] {
        if regex.state == .on { return [] }
        var order: [Int] = []
        let chars = Array(oldFormat.stringValue)
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 1 < chars.count, chars[i + 1] == "%" { i += 2; continue }
            if chars[i] == "%", i + 1 < chars.count, chars[i + 1].isNumber {
                var j = i + 1
                var n = 0
                while j < chars.count, let d = chars[j].wholeNumberValue { n = n * 10 + d; j += 1 }
                order.append(n)
                i = j
                continue
            }
            i += 1
        }
        return order
    }

    func update() {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        problems = [:]
        newNames = names
        guard let re = pattern() else {
            for i in names.indices { problems[i] = "invalid old format" }
            refreshTable()
            return
        }
        let order = placeholderOrder()
        let tmpl = Array(newFormat.stringValue)
        for (i, n) in names.enumerated() {
            let ns = n as NSString
            guard let m = re.firstMatch(in: n, range: NSRange(location: 0, length: ns.length)) else {
                problems[i] = "doesn’t match the old format"
                continue
            }
            // value for placeholder number k
            func value(_ k: Int) -> String {
                let group: Int
                if order.isEmpty { group = k } else if let pos = order.firstIndex(of: k) { group = pos + 1 } else { return "" }
                guard group < m.numberOfRanges else { return "" }
                let r = m.range(at: group)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            var out = ""
            var j = 0
            while j < tmpl.count {
                let c = tmpl[j]
                if c == "%", j + 1 < tmpl.count, tmpl[j + 1] == "%" { out.append("%"); j += 2; continue }
                if c == "%", j + 1 < tmpl.count, tmpl[j + 1].isNumber {
                    var k = j + 1
                    var num = 0
                    while k < tmpl.count, let d = tmpl[k].wholeNumberValue { num = num * 10 + d; k += 1 }
                    out += value(num)
                    j = k
                    continue
                }
                out.append(c)
                j += 1
            }
            if out.isEmpty { problems[i] = "empty name" }
            else if out.contains("/") { problems[i] = "a name can’t contain /" }
            newNames[i] = out
        }
        // Duplicate targets in the same folder.
        var seen: [String: Int] = [:]
        for (i, p) in paths.enumerated() where problems[i] == nil {
            let key = ((p as NSString).deletingLastPathComponent + "/" + newNames[i]).lowercased()
            if let other = seen[key] { problems[i] = "same new name as \(names[other])" } else { seen[key] = i }
        }
        refreshTable()
    }

    func refreshTable() {
        table.reload()
        let changed = zip(paths.map { ($0 as NSString).lastPathComponent }, newNames).filter { $0 != $1 }.count
        summary.stringValue = problems.isEmpty ? "\(changed) of \(paths.count) names change." : "\(problems.count) problem\(problems.count == 1 ? "" : "s") — fix the formats to continue."
        summary.textColor = problems.isEmpty ? .secondaryLabelColor : .systemRed
    }

    func perform() {
        let fm = FileManager.default
        var failures: [String] = []
        var renamed: [(String, String)] = []
        // Two passes avoid collisions when names swap (a→b, b→a).
        var temp: [(Int, String)] = []
        for (i, src) in paths.enumerated() {
            let oldName = (src as NSString).lastPathComponent
            guard newNames[i] != oldName else { continue }
            let dir = (src as NSString).deletingLastPathComponent
            let dst = (dir as NSString).appendingPathComponent(newNames[i])
            let caseOnly = dst.lowercased() == src.lowercased()
            if !caseOnly && fm.fileExists(atPath: dst) && !paths.contains(dst) {
                failures.append("\(oldName): “\(newNames[i])” already exists")
                continue
            }
            let t = (dir as NSString).appendingPathComponent(".epitome-rename-\(UUID().uuidString.prefix(8))-" + oldName)
            if Darwin.rename(src, t) == 0 { temp.append((i, t)) } else { failures.append("\(oldName): \(String(cString: strerror(errno)))") }
        }
        for (i, t) in temp {
            let src = paths[i]
            let dst = ((src as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newNames[i])
            if Darwin.rename(t, dst) == 0 {
                renamed.append((src, dst))
            } else {
                failures.append("\((src as NSString).lastPathComponent): \(String(cString: strerror(errno)))")
                _ = Darwin.rename(t, src)
            }
        }
        let m = AppModel.shared.manager
        for (a, b) in renamed { m.runHistory.renamed(from: a, to: b) }
        m.flushEvents()
        if !failures.isEmpty { _ = alert("Some items were not renamed", failures.prefix(30).joined(separator: "\n")) }
    }
}

// MARK: - Properties

/// Get Info for the selected results (⌘I / ⌥↩).
enum PropertiesPanel {
    static var panels: [NSPanel] = []

    static func show(_ rows: [Row], model: ResultsModel, over parent: NSWindow?) {
        guard !rows.isEmpty else { return }
        let fmt = AppModel.shared.formatter
        let content = vstack([], spacing: 16)
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        if rows.count > 1 {
            let files = rows.filter { !$0.isDir }.count
            let total = rows.reduce(Int64(0)) { $0 + Swift.max(0, $1.size) }
            content.addArrangedSubview(label("\(rows.count) items: \(files) files, \(rows.count - files) folders — \(fmt.size(total)) (\(fmt.grouped(total)) bytes)", bold: true))
        }
        for r in rows {
            content.addArrangedSubview(section(r, model: model))
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = rows.count == 1 ? "\(rows[0].name) Info" : "\(rows.count) Items Info"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let sv = scrolling(content)
        panel.contentView = sv
        let h = Swift.min(content.fittingSize.height + 8, 640)
        panel.setContentSize(NSSize(width: Swift.max(460, content.fittingSize.width + 20), height: h))
        if let p = parent {
            let f = p.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 30 - CGFloat(panels.count % 5) * 20, y: f.maxY - 60))
        } else {
            panel.center()
        }
        panels.append(panel)
        if panels.count > 20 { panels.removeFirst().close() }
        panel.makeKeyAndOrderFront(nil)
    }

    static func section(_ r: Row, model: ResultsModel) -> NSView {
        let fmt = AppModel.shared.formatter
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: r.fullPath))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let title = label(r.name, bold: true)
        title.lineBreakMode = .byTruncatingMiddle
        title.isSelectable = true
        let kind = model.services.typeName(r.ext.lowercased(), r.isDir, r.isPackage)
        let head = hstack([icon, vstack([title, label(kind, small: true, secondary: true)], spacing: 2)])
        head.alignment = .centerY

        var pairs: [(String, String)] = []
        pairs.append(("Where", r.parent.isEmpty ? "/" : r.parent))
        if r.size >= 0 {
            pairs.append(("Size", "\(fmt.size(r.size)) (\(fmt.grouped(r.size)) bytes)"))
        } else if r.isDir {
            pairs.append(("Size", "—"))
        }
        func date(_ t: Int64) -> String { t == kUnknownTime ? "—" : fmt.date(t) }
        pairs.append(("Created", date(r.ctime)))
        pairs.append(("Modified", date(r.mtime)))
        if r.atime != kUnknownTime { pairs.append(("Accessed", date(r.atime))) }
        if r.rctime != kUnknownTime { pairs.append(("Recently changed", date(r.rctime))) }
        pairs.append(("Attributes", attributeNames(r.flags)))
        if let rec = AppModel.shared.manager.runHistory.record(for: r.fullPath) {
            pairs.append(("Opened", "\(rec.count) time\(rec.count == 1 ? "" : "s"), last \(fmt.date(Int64(rec.last * 1_000_000_000)))"))
        }
        if !r.fileListName.isEmpty { pairs.append(("File list", r.fileListName)) }
        let url = URL(fileURLWithPath: r.fullPath)
        if let v = try? url.resourceValues(forKeys: [.tagNamesKey, .isAliasFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]) {
            if let tags = v.tagNames, !tags.isEmpty { pairs.append(("Tags", tags.joined(separator: ", "))) }
            if let a = v.totalFileAllocatedSize ?? v.fileAllocatedSize, !r.isDir { pairs.append(("On disk", "\(fmt.size(Int64(a))) (\(fmt.grouped(Int64(a))) bytes)")) }
        }
        let info = MediaReader.imageInfo(r.fullPath)
        if let w = info["w"] as? Int, let h = info["h"] as? Int { pairs.append(("Dimensions", "\(w) × \(h)")) }
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: r.fullPath) { pairs.append(("Link to", dest)) }
        if let item = MDItemCreate(nil, r.fullPath as CFString) {
            if let froms = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String], let first = froms.first { pairs.append(("Where from", first)) }
            if let d = MDItemCopyAttribute(item, kMDItemDurationSeconds) as? Double, d > 0 {
                pairs.append(("Duration", String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)))
            }
        }

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 4
        grid.columnSpacing = 10
        for (k, v) in pairs {
            let kl = NSTextField(labelWithString: k + ":")
            kl.textColor = .secondaryLabelColor
            kl.alignment = .right
            let vl = NSTextField(labelWithString: v)
            vl.isSelectable = true
            vl.lineBreakMode = .byTruncatingMiddle
            vl.preferredMaxLayoutWidth = 320
            vl.translatesAutoresizingMaskIntoConstraints = false
            vl.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
            grid.addRow(with: [kl, vl])
        }
        grid.column(at: 0).xPlacement = .trailing
        let buttons = hstack([
            button("Show in Finder") { FileActions.reveal([r.fullPath]) },
            button("Finder Info") { FileActions.finderGetInfo([r.fullPath]) },
            button("Copy Path") { FileActions.copyText(r.fullPath) },
        ])
        return vstack([head, grid, buttons], spacing: 10)
    }

    static func attributeNames(_ f: UInt32) -> String {
        var a: [String] = []
        if f & EntryFlag.directory != 0 { a.append(f & EntryFlag.package != 0 ? "package" : "folder") }
        if f & EntryFlag.symlink != 0 { a.append("symbolic link") }
        if f & EntryFlag.hidden != 0 { a.append("hidden") }
        if f & EntryFlag.system != 0 { a.append("system") }
        if f & EntryFlag.readOnly != 0 { a.append("read-only") }
        if f & EntryFlag.archive != 0 { a.append("archive") }
        if f & EntryFlag.compressed != 0 { a.append("compressed") }
        if f & EntryFlag.offline != 0 { a.append("offline") }
        if f & EntryFlag.executable != 0 { a.append("executable") }
        let letters = ValueFormatter.attributes(f)
        return (a.isEmpty ? "normal" : a.joined(separator: ", ")) + (letters.isEmpty ? "" : "  (\(letters))")
    }
}

// MARK: - Connect to ETP server

enum ConnectETPDialog {
    static func run(done: @escaping (String?) -> Void) {
        let f = FormView(labelWidth: 90)
        let host = NSComboBox()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let recent = AppModel.shared.settings.etpRecent
        host.addItems(withObjectValues: recent)
        host.placeholderString = "hostname or address"
        let port = textField("2121", width: 70)
        let user = textField("", placeholder: "(none)", width: 180)
        let pass = textField("", width: 180, secure: true)
        func fill(_ link: String) {
            guard let c = ETPClient(link: link) else { return }
            host.stringValue = c.host
            port.stringValue = String(c.port)
            user.stringValue = c.user
        }
        if let first = recent.first { fill(first) }
        let picker = ActionTrampoline { _ in
            let v = host.stringValue
            if v.contains("@") || v.contains(":") { fill(v) }
        }
        host.target = picker
        host.action = #selector(ActionTrampoline.fire(_:))
        f.row("Server", [host])
        f.row("Port", [port])
        f.row("Username", [user])
        f.row("Password", [pass])
        f.note("Searches another Mac running Epitome with its ETP/FTP server turned on (Settings → ETP/FTP Server). Opened files are downloaded first.")
        let panel = makeDialog(title: "Connect to ETP Server", content: f, ok: "Connect") { _ in
            !host.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
        runDialog(panel, over: nil) { r in
            _ = picker
            guard r == .OK else { done(nil); return }
            var link = ""
            let u = user.stringValue.trimmingCharacters(in: .whitespaces)
            if !u.isEmpty { link = u + (pass.stringValue.isEmpty ? "" : ":" + pass.stringValue) + "@" }
            var h = host.stringValue.trimmingCharacters(in: .whitespaces)
            if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
            if let colon = h.lastIndex(of: ":"), UInt16(h[h.index(after: colon)...]) != nil { h = String(h[..<colon]) }
            link += h + ":" + (UInt16(port.stringValue).map { String($0) } ?? "2121")
            done(link)
        }
    }
}

// MARK: - Advanced search

/// Builds a search from plain fields (Search → Advanced Search…).
final class AdvancedSearchWindowController: NSWindowController, NSWindowDelegate {
    weak var target: SearchWindowController?
    private let allWords = textField(width: 300)
    private let phrase = textField(width: 300)
    private let anyWords = textField(width: 300)
    private let noneWords = textField(width: 300)
    private let nameCase = checkbox("Match case")
    private let nameWhole = checkbox("Match whole words")
    private let nameDiac = checkbox("Match diacritics")
    private let content = textField(width: 300)
    private let contentCase = checkbox("Match case")
    private let contentWhole = checkbox("Match whole words")
    private let encoding = popup(["Auto detect", "UTF-8", "UTF-16", "UTF-16 big endian", "ANSI / Latin-1"])
    private let location = textField(placeholder: "/Users/you/Projects", width: 300)
    private let subfolders = checkbox("Include subfolders", true)
    private let fileType = popup(["Files and folders", "Files only", "Folders only"])
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let extField = textField(placeholder: "pdf;docx", width: 140)
    private let dateKind = popup(["Date modified", "Date created", "Date accessed", "Date recently changed", "Date run"])
    private let dateFromOn = checkbox("From")
    private let dateFrom = NSDatePicker()
    private let dateToOn = checkbox("To")
    private let dateTo = NSDatePicker()
    private let sizeFromOn = checkbox("At least")
    private let sizeFrom = textField(width: 70)
    private let sizeFromUnit = popup(["bytes", "KB", "MB", "GB"], selected: 2)
    private let sizeToOn = checkbox("At most")
    private let sizeTo = textField(width: 70)
    private let sizeToUnit = popup(["bytes", "KB", "MB", "GB"], selected: 2)
    private let attrib = textField(placeholder: "e.g. H (hidden), R (read-only)", width: 200)
    private let preview = NSTextField(wrappingLabelWithString: "")

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Advanced Search"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let f = FormView(labelWidth: 150)
        f.header("File names containing")
        f.row("All these words", [allWords])
        f.row("This exact phrase", [phrase])
        f.row("Any of these words", [anyWords])
        f.row("None of these words", [noneWords])
        f.row("", [nameCase, nameWhole, nameDiac])
        f.header("A word or phrase in the file")
        f.row("Text", [content])
        f.row("", [contentCase, contentWhole])
        f.row("Encoding", [encoding])
        f.note("Searching file contents reads every candidate file and is slow — combine it with a location or file type.")
        f.header("Location and type")
        f.row("Located in", [location, button("Choose…") { [weak self] in
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            if p.runModal() == .OK, let u = p.url { self?.location.stringValue = u.path; self?.update() }
        }])
        f.row("", [subfolders])
        f.row("Show", [fileType])
        filterPopup.addItems(withTitles: ["(any filter)"] + AppModel.shared.filters.current.filter { !$0.isEverything }.map(\.name))
        f.row("Filter", [filterPopup])
        f.row("Extensions", [extField])
        f.header("Dates and sizes")
        for p in [dateFrom, dateTo] {
            p.datePickerStyle = .textFieldAndStepper
            p.datePickerElements = .yearMonthDay
            p.dateValue = Date()
        }
        dateFrom.dateValue = Date().addingTimeInterval(-30 * 86_400)
        f.row("", [dateKind])
        f.row("", [dateFromOn, dateFrom, dateToOn, dateTo])
        f.row("Size", [sizeFromOn, sizeFrom, sizeFromUnit])
        f.row("", [sizeToOn, sizeTo, sizeToUnit])
        f.row("Attributes", [attrib])
        f.header("Search")
        preview.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.isSelectable = true
        preview.preferredMaxLayoutWidth = 560
        f.add(preview)
        f.add(hstack([button("Clear") { [weak self] in self?.clear() },
                      button("Search") { [weak self] in self?.apply(close: false) },
                      button("OK") { [weak self] in self?.apply(close: true) }]))

        for t in [allWords, phrase, anyWords, noneWords, content, location, extField, sizeFrom, sizeTo, attrib] { t.onTextChange { [weak self] _ in self?.update() } }
        for c in [nameCase, nameWhole, nameDiac, contentCase, contentWhole, subfolders, dateFromOn, dateToOn, sizeFromOn, sizeToOn,
                  encoding, fileType, filterPopup, dateKind, sizeFromUnit, sizeToUnit, dateFrom, dateTo] as [NSControl] {
            c.onAction { [weak self] _ in self?.update() }
        }
        window?.contentView = scrolling(f)
        window?.setContentSize(NSSize(width: 640, height: Swift.min(760, f.fittingSize.height + 20)))
        update()
    }

    private func q(_ s: String) -> String {
        s.contains(" ") || s.contains("|") || s.contains("<") || s.contains(">") || s.contains("!") ? "\"" + s.replacingOccurrences(of: "\"", with: "") + "\"" : s
    }

    private func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    var generated: String {
        var parts: [String] = []
        var mods = ""
        if nameCase.state == .on { mods += "case:" }
        if nameWhole.state == .on { mods += "ww:" }
        if nameDiac.state == .on { mods += "diacritics:" }
        for w in words(allWords.stringValue) { parts.append(mods + q(w)) }
        let ph = phrase.stringValue.trimmingCharacters(in: .whitespaces)
        if !ph.isEmpty { parts.append(mods + "\"" + ph.replacingOccurrences(of: "\"", with: "") + "\"") }
        let any = words(anyWords.stringValue)
        if any.count == 1 { parts.append(mods + q(any[0])) } else if any.count > 1 { parts.append("<" + any.map { mods + q($0) }.joined(separator: "|") + ">") }
        for w in words(noneWords.stringValue) { parts.append("!" + mods + q(w)) }

        let loc = location.stringValue.trimmingCharacters(in: .whitespaces)
        if !loc.isEmpty {
            let p = (loc as NSString).expandingTildeInPath
            if subfolders.state == .on { parts.insert(q(p.hasSuffix("/") ? p : p + "/"), at: 0) }
            else { parts.insert("parent:" + q(p), at: 0) }
        }
        switch fileType.indexOfSelectedItem {
        case 1: parts.insert("file:", at: 0)
        case 2: parts.insert("folder:", at: 0)
        default: break
        }
        if filterPopup.indexOfSelectedItem > 0, let name = filterPopup.titleOfSelectedItem, let flt = AppModel.shared.filter(named: name) {
            parts.append(flt.macro.isEmpty ? "<" + flt.search + ">" : flt.macro + ":")
        }
        let ext = extField.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if !ext.isEmpty { parts.append("ext:" + ext.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: " ", with: ";")) }

        let fn = ["dm", "dc", "da", "rc", "dr"][dateKind.indexOfSelectedItem]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let from = dateFromOn.state == .on ? df.string(from: dateFrom.dateValue) : nil
        let to = dateToOn.state == .on ? df.string(from: dateTo.dateValue) : nil
        if let a = from, let b = to { parts.append("\(fn):\(a)..\(b)") }
        else if let a = from { parts.append("\(fn):>=\(a)") }
        else if let b = to { parts.append("\(fn):<=\(b)") }

        let units = ["", "kb", "mb", "gb"]
        let sMin = sizeFromOn.state == .on && !sizeFrom.stringValue.isEmpty ? sizeFrom.stringValue + units[sizeFromUnit.indexOfSelectedItem] : nil
        let sMax = sizeToOn.state == .on && !sizeTo.stringValue.isEmpty ? sizeTo.stringValue + units[sizeToUnit.indexOfSelectedItem] : nil
        if let a = sMin, let b = sMax { parts.append("size:\(a)..\(b)") }
        else if let a = sMin { parts.append("size:>=\(a)") }
        else if let b = sMax { parts.append("size:<=\(b)") }

        let at = attrib.stringValue.trimmingCharacters(in: .whitespaces)
        if !at.isEmpty { parts.append("attrib:" + at) }

        let ct = content.stringValue.trimmingCharacters(in: .whitespaces)
        if !ct.isEmpty {
            let fnName = ["content", "utf8content", "utf16content", "utf16becontent", "ansicontent"][encoding.indexOfSelectedItem]
            var cm = ""
            if contentCase.state == .on { cm += "case:" }
            if contentWhole.state == .on { cm += "ww:" }
            parts.append(cm + fnName + ":\"" + ct.replacingOccurrences(of: "\"", with: "") + "\"")
        }
        return parts.joined(separator: " ")
    }

    func update() {
        let g = generated
        preview.stringValue = g.isEmpty ? "(everything)" : g
    }

    func clear() {
        for t in [allWords, phrase, anyWords, noneWords, content, location, extField, sizeFrom, sizeTo, attrib] { t.stringValue = "" }
        for c in [nameCase, nameWhole, nameDiac, contentCase, contentWhole, dateFromOn, dateToOn, sizeFromOn, sizeToOn] { c.state = .off }
        subfolders.state = .on
        for p in [encoding, fileType, filterPopup, dateKind] { p.selectItem(at: 0) }
        update()
    }

    func apply(close: Bool) {
        guard let wc = target ?? (NSApp.delegate as? AppDelegate)?.frontController else { NSSound.beep(); return }
        wc.pushHistory()
        wc.searchText = generated
        wc.updateTitle()
        wc.runSearch(immediate: true)
        wc.showWindow(nil)
        if close { window?.performClose(nil) }
    }
}
