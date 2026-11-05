import AppKit
import EpitomeCore
import UniformTypeIdentifiers
import WebKit

/// A window with a filter field and buttons above a table, and a status line below.
class TableWindowController: NSWindowController, NSWindowDelegate {
    let table: SimpleTable
    let filterField = NSSearchField()
    let statusLine = NSTextField(labelWithString: "")
    var model: AppModel { AppModel.shared }

    init(title: String, size: NSSize, columns: [SimpleTable.ColumnSpec], buttons: [NSView], sortable: Bool = true) {
        table = SimpleTable(columns, sortable: sortable)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 260)
        super.init(window: w)
        w.delegate = self
        guard let content = w.contentView else { return }
        filterField.placeholderString = "Filter"
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        filterField.onTextChange { [weak self] _ in self?.reload() }
        let flex = NSView()
        flex.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = hstack([filterField, flex] + buttons)
        bar.alignment = .centerY
        bar.translatesAutoresizingMaskIntoConstraints = false
        statusLine.textColor = .secondaryLabelColor
        statusLine.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        content.addSubview(table.scroll)
        content.addSubview(statusLine)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            table.scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            table.scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            table.scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLine.topAnchor.constraint(equalTo: table.scroll.bottomAnchor, constant: 6),
            statusLine.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusLine.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            statusLine.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var query: String { filterField.stringValue.lowercased() }
    func reload() { table.reload() }
    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
    }
}

// MARK: - Search history

final class SearchHistoryWindowController: TableWindowController {
    var items: [SearchHistoryItem] = []
    var sortKey = "date"
    var ascending = false

    init() {
        var useB: (() -> Void)?, removeB: (() -> Void)?, clearB: (() -> Void)?, exportB: (() -> Void)?
        super.init(title: "Search History", size: NSSize(width: 640, height: 440),
                   columns: [.init(id: "search", title: "Search", width: 360), .init(id: "count", title: "Count", width: 60, rightAligned: true),
                             .init(id: "date", title: "Last Used", width: 160)],
                   buttons: [button("Search") { useB?() }, button("Remove") { removeB?() }, button("Clear All") { clearB?() },
                             button("Export…") { exportB?() }])
        useB = { [weak self] in self?.use() }
        removeB = { [weak self] in self?.remove() }
        clearB = { [weak self] in self?.clear() }
        exportB = { [weak self] in self?.export() }
        switch model.settings.searchHistorySort {
        case .date: sortKey = "date"
        case .count: sortKey = "count"
        case .search: sortKey = "search"; ascending = true
        }
        let fmt = model.formatter
        table.rowCount = { [unowned self] in self.items.count }
        table.value = { [unowned self] row, col in
            let it = self.items[row]
            switch col {
            case "search": return it.search
            case "count": return String(it.count)
            default: return fmt.date(Int64(it.last * 1_000_000_000))
            }
        }
        table.onDoubleClick = { [weak self] _ in self?.use() }
        table.onSort = { [weak self] k, asc in self?.sortKey = k; self?.ascending = asc; self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func reload() {
        var list = model.history.items
        let q = query
        if !q.isEmpty { list = list.filter { $0.search.lowercased().contains(q) } }
        switch sortKey {
        case "search": list.sort { $0.search.localizedCaseInsensitiveCompare($1.search) == .orderedAscending }
        case "count": list.sort { $0.count != $1.count ? $0.count < $1.count : $0.last < $1.last }
        default: list.sort { $0.last < $1.last }
        }
        if !ascending { list.reverse() }
        items = list
        table.reload()
        statusLine.stringValue = model.settings.searchHistoryEnabled ? "\(items.count) searches" :
            "\(items.count) searches — recording is off (Settings → History)"
    }

    func use() {
        guard let r = table.selected.first, r < items.count, let app = NSApp.delegate as? AppDelegate else { return }
        let wc = app.frontController ?? app.openSearchWindow()
        wc.pushHistory()
        wc.searchText = items[r].search
        wc.updateTitle()
        wc.runSearch(immediate: true)
        wc.showWindow(nil)
    }

    func remove() {
        for r in table.selected where r < items.count { model.history.remove(items[r].search) }
        reload()
    }

    func clear() {
        guard alert("Clear all search history?", "", style: .warning, buttons: ["Clear", "Cancel"]) == .alertFirstButtonReturn else { return }
        model.history.clear()
        reload()
    }

    func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Search History.csv"
        guard p.runModal() == .OK, let url = p.url else { return }
        var text = "Search,Count,Last Used\r\n"
        for it in model.history.sorted(.date) {
            text += CSV.escape(it.search) + "," + String(it.count) + "," + ValueFormatter.iso(Int64(it.last * 1_000_000_000)) + "\r\n"
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Run history

final class RunHistoryWindowController: TableWindowController {
    var items: [(String, RunHistory.Record)] = []
    var sortKey = "count"
    var ascending = false

    init() {
        var openB: (() -> Void)?, revealB: (() -> Void)?, setB: (() -> Void)?, removeB: (() -> Void)?, clearB: (() -> Void)?
        super.init(title: "Run History", size: NSSize(width: 760, height: 440),
                   columns: [.init(id: "name", title: "Name", width: 200), .init(id: "path", title: "Path", width: 320),
                             .init(id: "count", title: "Run Count", width: 80, rightAligned: true), .init(id: "date", title: "Date Run", width: 150)],
                   buttons: [button("Open") { openB?() }, button("Show in Finder") { revealB?() }, button("Set Count…") { setB?() },
                             button("Remove") { removeB?() }, button("Clear All") { clearB?() }])
        openB = { [weak self] in self?.openSelected() }
        revealB = { [weak self] in self?.revealSelected() }
        setB = { [weak self] in self?.setCount() }
        removeB = { [weak self] in self?.remove() }
        clearB = { [weak self] in self?.clear() }
        let fmt = model.formatter
        table.rowCount = { [unowned self] in self.items.count }
        table.value = { [unowned self] row, col in
            let (p, r) = self.items[row]
            switch col {
            case "name": return (p as NSString).lastPathComponent
            case "path": return (p as NSString).deletingLastPathComponent
            case "count": return String(r.count)
            default: return fmt.date(Int64(r.last * 1_000_000_000))
            }
        }
        table.onDoubleClick = { [weak self] _ in self?.openSelected() }
        table.onSort = { [weak self] k, asc in self?.sortKey = k; self?.ascending = asc; self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func reload() {
        var list = model.manager.runHistory.all().map { ($0.key, $0.value) }
        let q = query
        if !q.isEmpty { list = list.filter { $0.0.lowercased().contains(q) } }
        switch sortKey {
        case "name": list.sort { ($0.0 as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1.0 as NSString).lastPathComponent) == .orderedAscending }
        case "path": list.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        case "date": list.sort { $0.1.last < $1.1.last }
        default: list.sort { $0.1.count != $1.1.count ? $0.1.count < $1.1.count : $0.1.last < $1.1.last }
        }
        if !ascending { list.reverse() }
        items = list
        table.reload()
        statusLine.stringValue = "\(items.count) items" + (model.settings.runHistoryEnabled ? "" : " — counting is off (Settings → History)")
    }

    var selectedPaths: [String] { table.selected.compactMap { $0 < items.count ? items[$0].0 : nil } }

    func openSelected() {
        let ps = selectedPaths
        FileActions.open(ps)
        for p in ps { model.manager.runHistory.recordRun(path: p) }
        reload()
    }

    func revealSelected() { FileActions.reveal(selectedPaths) }

    func setCount() {
        let ps = selectedPaths
        guard !ps.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Set Run Count"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        f.stringValue = String(model.manager.runHistory.record(for: ps[0])?.count ?? 0)
        a.accessoryView = f
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, let n = Int(f.stringValue) else { return }
        for p in ps { model.manager.runHistory.set(path: p, count: n) }
        reload()
    }

    func remove() {
        for p in selectedPaths { model.manager.runHistory.set(path: p, count: 0) }
        reload()
    }

    func clear() {
        guard alert("Clear the run history?", "", style: .warning, buttons: ["Clear", "Cancel"]) == .alertFirstButtonReturn else { return }
        model.manager.runHistory.clear()
        reload()
    }
}

// MARK: - Index journal

final class JournalWindowController: TableWindowController {
    var items: [IndexJournal.Record] = []
    var actionFilter: IndexJournal.Action?
    let actionPopup = popup(["All changes", "Created", "Deleted", "Modified", "Renamed"])

    init() {
        var revealB: (() -> Void)?, clearB: (() -> Void)?, exportB: (() -> Void)?
        super.init(title: "Index Journal", size: NSSize(width: 820, height: 480),
                   columns: [.init(id: "time", title: "Time", width: 150), .init(id: "action", title: "Change", width: 80),
                             .init(id: "name", title: "Name", width: 200), .init(id: "path", title: "Folder", width: 340)],
                   buttons: [], sortable: false)
        let bar = filterField.superview as? NSStackView
        for b in [actionPopup, button("Show in Finder") { revealB?() }, button("Export…") { exportB?() }, button("Clear") { clearB?() }] as [NSView] {
            bar?.addArrangedSubview(b)
        }
        revealB = { [weak self] in self?.reveal() }
        clearB = { [weak self] in self?.model.manager.journal.clear(); self?.reload() }
        exportB = { [weak self] in self?.export() }
        let actions: [IndexJournal.Action?] = [nil, .created, .deleted, .modified, .renamed]
        actionPopup.onAction { [weak self] c in
            let i = (c as? NSPopUpButton)?.indexOfSelectedItem ?? 0
            self?.actionFilter = i < actions.count ? actions[i] : nil
            self?.reload()
        }
        let fmt = model.formatter
        table.rowCount = { [unowned self] in self.items.count }
        table.value = { [unowned self] row, col in
            let r = self.items[row]
            switch col {
            case "time": return fmt.date(r.time)
            case "action": return r.action.rawValue.capitalized + (r.isFolder ? " 📁" : "")
            case "name": return (r.path as NSString).lastPathComponent
            default: return (r.path as NSString).deletingLastPathComponent
            }
        }
        table.onDoubleClick = { [weak self] _ in self?.reveal() }
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged), name: AppModel.indexChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func indexChanged() {
        if window?.isVisible == true { reload() }
    }

    override func reload() {
        var list = model.manager.journal.snapshot()
        list.reverse() // newest first
        if let a = actionFilter { list = list.filter { $0.action == a } }
        let q = query
        if !q.isEmpty { list = list.filter { $0.path.lowercased().contains(q) } }
        items = list
        table.reload()
        let j = model.manager.journal
        statusLine.stringValue = model.settings.journalEnabled ?
            "\(items.count) shown · \(j.total) changes recorded since launch (keeps the last \(j.capacity))" :
            "The journal is off (Settings → Indexes)"
    }

    func reveal() {
        let ps = table.selected.compactMap { $0 < items.count ? items[$0].path : nil }.filter { FileManager.default.fileExists(atPath: $0) }
        if ps.isEmpty { NSSound.beep() } else { FileActions.reveal(ps) }
    }

    func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Index Journal.csv"
        guard p.runModal() == .OK, let url = p.url else { return }
        var text = "Time,Change,Folder,Path\r\n"
        for r in items { text += ValueFormatter.iso(r.time) + "," + r.action.rawValue + "," + (r.isFolder ? "1" : "0") + "," + CSV.escape(r.path) + "\r\n" }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Text windows (statistics, debug console)

class TextWindowController: NSWindowController, NSWindowDelegate {
    let textView: NSTextView
    let scroll: NSScrollView
    var model: AppModel { AppModel.shared }

    init(title: String, size: NSSize, buttons: [NSView]) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init(window: w)
        w.delegate = self
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        guard let content = w.contentView else { return }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let flex = NSView()
        flex.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = hstack([flex] + buttons)
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setText(_ s: String) {
        textView.string = s
    }
}

final class StatisticsWindowController: TextWindowController {
    init() {
        var refreshB: (() -> Void)?, copyB: (() -> Void)?
        super.init(title: "Index Statistics", size: NSSize(width: 640, height: 520),
                   buttons: [button("Copy") { copyB?() }, button("Refresh") { refreshB?() }])
        refreshB = { [weak self] in self?.refresh() }
        copyB = { [weak self] in FileActions.copyText(self?.textView.string ?? "") }
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged), name: AppModel.statusChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func statusChanged() { if window?.isVisible == true { refresh() } }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
    }

    func refresh() {
        let m = model.manager
        let ix = m.index
        let st = ix.lock.read { ix.stats() }
        let fmt = model.formatter
        func n(_ v: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal) }
        var out = "Epitome \(EpitomeVersion.string)\n\n"
        out += "INDEX\n"
        out += "  Status:          \(m.status.phase.rawValue) \(m.status.message)\n"
        out += "  Items:           \(n(st.entries - st.deleted))  (\(n(st.files)) files, \(n(st.folders)) folders)\n"
        out += "  Removed, pending compaction: \(n(st.deleted))\n"
        out += "  Name storage:    \(fmt.size(Int64(st.nameBytes)))\n"
        out += "  Memory (approx): \(fmt.size(Int64(st.memoryBytes)))\n"
        out += "  Fast sorts:      \(ix.maintainedOrders.map(\.title).sorted().joined(separator: ", "))\n"
        out += "  Monitoring:      \(m.isPaused ? "paused" : "on")\n"
        let db = m.databaseURL
        let dbSize = (try? FileManager.default.attributesOfItem(atPath: db.path)[.size] as? Int64) ?? nil
        out += "  Database:        \(db.path)\(dbSize.map { " (\(fmt.size($0)))" } ?? " (not saved yet)")\(m.readOnly ? " [read-only]" : "")\n\n"
        out += "SOURCES\n"
        let sources = ix.lock.read { ix.roots.compactMap { ix.sources[$0] } }
        for s in sources {
            out += "  \(s.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(s.kind == .fileList ? (s.fileListPath ?? s.name) : s.path)"
            if let fs = s.fsType { out += "  [\(fs)]" }
            out += s.monitored ? "  monitored" : "  not monitored"
            if let t = s.lastScan { out += "  scanned \(fmt.date(Int64(t * 1_000_000_000)))" }
            if s.lastEventID > 0 { out += "  event \(s.lastEventID)" }
            out += "\n"
        }
        out += "\nDATA\n"
        out += "  Filters:         \(model.filters.current.count)\n"
        out += "  Bookmarks:       \(model.bookmarks.current.count)\n"
        out += "  Search history:  \(model.history.items.count)\(model.settings.searchHistoryEnabled ? "" : " (off)")\n"
        out += "  Run history:     \(m.runHistory.all().count)\n"
        out += "  Journal:         \(m.journal.total) changes since launch\n"
        out += "  Settings folder: \(model.supportDir.path)\n\n"
        out += "SERVERS\n"
        if let app = NSApp.delegate as? AppDelegate {
            out += "  HTTP:            \(app.http.isRunning ? "port \(app.http.boundPort)" : "off")\n"
            out += "  ETP/FTP:         \(app.etp.isRunning ? "port \(app.etp.boundPort)" : "off")\n"
        }
        out += "  Command line:    \(IPCPaths.socketPath(instance: model.instance))\n\n"
        out += "PRIVACY\n"
        out += "  Full Disk Access: \(m.hasFullDiskAccess() ? "granted" : "not granted")\n"
        setText(out)
    }
}

final class DebugConsoleWindowController: TextWindowController {
    var paused = false

    init() {
        var clearB: (() -> Void)?, copyB: (() -> Void)?, openB: (() -> Void)?, pauseB: ((Bool) -> Void)?
        super.init(title: "Debug Console", size: NSSize(width: 820, height: 480),
                   buttons: [checkbox("Pause", false) { pauseB?($0) }, button("Clear") { clearB?() }, button("Copy All") { copyB?() },
                             button("Show Log File") { openB?() }])
        clearB = { [weak self] in self?.textView.string = "" }
        copyB = { [weak self] in FileActions.copyText(self?.textView.string ?? "") }
        openB = { FileActions.reveal([AppModel.shared.log.path]) }
        pauseB = { [weak self] on in self?.paused = on }
        setText(model.log.all.joined(separator: "\n") + "\n")
        model.log.onLine = { [weak self] line in self?.append(line) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func append(_ line: String) {
        guard !paused, let storage = textView.textStorage else { return }
        let atEnd = scroll.verticalScroller?.floatValue ?? 1 > 0.98
        storage.append(NSAttributedString(string: line + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                                                             .foregroundColor: NSColor.textColor]))
        if storage.length > 2_000_000 { storage.deleteCharacters(in: NSRange(location: 0, length: 500_000)) }
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        textView.scrollToEndOfDocument(nil)
    }
}

// MARK: - File list editor

final class FileListEditorWindowController: NSWindowController, NSWindowDelegate {
    var path: String?
    var list = FileList()
    var shown: [Int] = []
    var dirty = false { didSet { updateTitle() } }
    let table: SimpleTable
    let filterField = NSSearchField()
    let statusLine = NSTextField(labelWithString: "")
    var model: AppModel { AppModel.shared }

    init() {
        table = SimpleTable([.init(id: "name", title: "Name", width: 220), .init(id: "folder", title: "Folder", width: 300),
                             .init(id: "size", title: "Size", width: 80, rightAligned: true), .init(id: "dm", title: "Date Modified", width: 140),
                             .init(id: "dc", title: "Date Created", width: 140), .init(id: "attr", title: "Attributes", width: 70)])
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 600, height: 300)
        super.init(window: w)
        w.delegate = self
        build()
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let fmt = model.formatter
        table.rowCount = { [unowned self] in self.shown.count }
        table.value = { [unowned self] row, col in
            let e = self.list.entries[self.shown[row]]
            switch col {
            case "name": return (e.path as NSString).lastPathComponent
            case "folder": return (e.path as NSString).deletingLastPathComponent
            case "size": return e.isFolder ? "" : (e.size.map { fmt.size($0) } ?? "")
            case "dm": return e.mtime.map { fmt.date($0) } ?? ""
            case "dc": return e.ctime.map { fmt.date($0) } ?? ""
            default: return e.attributes.map { ValueFormatter.attributes(FileList.flags(fromAttributes: $0)) } ?? ""
            }
        }
        table.table.registerForDraggedTypes([.fileURL])
        table.dropHandler = { [weak self] urls in self?.add(urls: urls) }
        filterField.placeholderString = "Filter"
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        filterField.onTextChange { [weak self] _ in self?.refilter() }
        let bar = hstack([
            button("New") { [weak self] in self?.newList() },
            button("Open…") { [weak self] in self?.openPanel() },
            button("Save") { [weak self] in _ = self?.save(as: false) },
            button("Save As…") { [weak self] in _ = self?.save(as: true) },
            button("Add Files…") { [weak self] in self?.addPanel(folders: false) },
            button("Add Folder…") { [weak self] in self?.addPanel(folders: true) },
            button("Remove") { [weak self] in self?.removeSelected() },
            button("Search This List") { [weak self] in self?.searchList() },
        ])
        let flex = NSView()
        flex.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = hstack([bar, flex, filterField])
        top.translatesAutoresizingMaskIntoConstraints = false
        statusLine.textColor = .secondaryLabelColor
        statusLine.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(top)
        content.addSubview(table.scroll)
        content.addSubview(statusLine)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            table.scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            table.scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            table.scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLine.topAnchor.constraint(equalTo: table.scroll.bottomAnchor, constant: 6),
            statusLine.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusLine.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        refilter()
    }

    func updateTitle() {
        let name = path.map { ($0 as NSString).lastPathComponent } ?? "Untitled.efu"
        window?.title = "File List Editor — " + name + (dirty ? " (edited)" : "")
        window?.isDocumentEdited = dirty
        if let p = path { window?.representedURL = URL(fileURLWithPath: p) } else { window?.representedURL = nil }
    }

    func refilter() {
        let q = filterField.stringValue.lowercased()
        shown = q.isEmpty ? Array(list.entries.indices) : list.entries.indices.filter { list.entries[$0].path.lowercased().contains(q) }
        table.reload()
        let folders = list.entries.filter(\.isFolder).count
        statusLine.stringValue = "\(list.entries.count) items (\(list.entries.count - folders) files, \(folders) folders)" +
            (shown.count != list.entries.count ? " · \(shown.count) shown" : "") + " · drop files or folders here to add them"
    }

    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let r = alert("Save changes to the file list?", "", style: .warning, buttons: ["Save", "Don’t Save", "Cancel"])
        if r == .alertFirstButtonReturn { return save(as: false) }
        return r == .alertSecondButtonReturn
    }

    func newList() {
        guard confirmDiscard() else { return }
        path = nil
        list = FileList()
        dirty = false
        refilter()
    }

    func load(path p: String) {
        guard confirmDiscard() else { return }
        do {
            list = try FileList.load(URL(fileURLWithPath: p))
            path = p
            dirty = false
            refilter()
        } catch {
            _ = alert("Cannot open the file list", "\(error)")
        }
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "efu") ?? .data, .commaSeparatedText, .plainText]
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let u = p.url else { return }
        load(path: u.path)
    }

    @discardableResult
    func save(as saveAs: Bool) -> Bool {
        var target = path
        if saveAs || target == nil || (target.map { ($0 as NSString).pathExtension.lowercased() != "efu" } ?? true) {
            let p = NSSavePanel()
            p.nameFieldStringValue = path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension + ".efu" } ?? "File List.efu"
            p.allowedContentTypes = [UTType(filenameExtension: "efu") ?? .data]
            guard p.runModal() == .OK, let u = p.url else { return false }
            target = u.path
        }
        guard let t = target else { return false }
        do {
            try FileList.write(list).write(toFile: t, atomically: true, encoding: .utf8)
            path = t
            dirty = false
            return true
        } catch {
            NSApp.presentError(error)
            return false
        }
    }

    func addPanel(folders: Bool) {
        let p = NSOpenPanel()
        p.canChooseDirectories = folders
        p.canChooseFiles = !folders
        p.allowsMultipleSelection = true
        p.prompt = "Add"
        guard p.runModal() == .OK else { return }
        add(urls: p.urls)
    }

    func add(urls: [URL]) {
        statusLine.stringValue = "Adding…"
        let opts = model.settings.scanOptions
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var entries: [FileList.Entry] = []
            for u in urls {
                let p = u.path
                entries.append(FileListEditorWindowController.entry(for: p))
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    entries += FileList.create(fromFolder: p, options: opts).entries
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let existing = Set(self.list.entries.map(\.path))
                self.list.entries += entries.filter { !existing.contains($0.path) }
                self.dirty = true
                self.refilter()
            }
        }
    }

    static func entry(for p: String) -> FileList.Entry {
        let a = (try? FileManager.default.attributesOfItem(atPath: p)) ?? [:]
        let isDir = (a[.type] as? FileAttributeType) == .typeDirectory
        var flags: UInt32 = isDir ? EntryFlag.directory : 0
        if (p as NSString).lastPathComponent.hasPrefix(".") { flags |= EntryFlag.hidden }
        if let perm = a[.posixPermissions] as? Int, perm & 0o200 == 0 { flags |= EntryFlag.readOnly }
        func ns(_ d: Any?) -> Int64? { (d as? Date).map { Int64($0.timeIntervalSince1970 * 1_000_000_000) } }
        return FileList.Entry(path: p, size: isDir ? nil : (a[.size] as? NSNumber)?.int64Value, mtime: ns(a[.modificationDate]),
                              ctime: ns(a[.creationDate]), attributes: FileList.attributes(fromFlags: flags))
    }

    func removeSelected() {
        let rows = table.selected.map { shown[$0] }.sorted(by: >)
        guard !rows.isEmpty else { return }
        for i in rows { list.entries.remove(at: i) }
        dirty = true
        refilter()
    }

    func searchList() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        if dirty || path == nil {
            guard save(as: false), path != nil else { return }
        }
        let wc = app.openSearchWindow()
        if let p = path { wc.openFileList(path: p) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscard() }
}

extension SimpleTable {
    @objc func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropHandler != nil else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    @objc func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let h = dropHandler,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        h(urls)
        return true
    }
}

// MARK: - Help

final class HelpWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    let web = WKWebView()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Epitome Help"
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("EpitomeHelp")
        super.init(window: w)
        w.delegate = self
        web.navigationDelegate = self
        w.contentView = web
    }

    required init?(coder: NSCoder) { fatalError() }

    static var helpFolder: URL? {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("Help"), FileManager.default.fileExists(atPath: u.path) { return u }
        return nil
    }

    func show(page: String) {
        if let dir = HelpWindowController.helpFolder {
            let file = dir.appendingPathComponent(page + ".html")
            let url = FileManager.default.fileExists(atPath: file.path) ? file : dir.appendingPathComponent("index.html")
            web.loadFileURL(url, allowingReadAccessTo: dir)
        } else {
            web.loadHTMLString("<html><body style='font: 14px -apple-system; padding: 2em'><h1>Epitome Help</h1><p>The help pages are missing from this copy of Epitome.</p><p>Type a few letters of a file name to search. Use <code>ext:pdf</code>, <code>size:&gt;10mb</code>, <code>dm:today</code>, <code>folder:</code>, and <code>|</code> for OR, <code>!</code> for NOT, <code>&lt; &gt;</code> to group.</p></body></html>", baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.allow); return }
        if let s = url.scheme?.lowercased(), s == "epitome" {
            (NSApp.delegate as? AppDelegate)?.apply(GUICommand.parse(url: url.absoluteString))
            decisionHandler(.cancel)
            return
        }
        if url.isFileURL || url.scheme == "about" { decisionHandler(.allow); return }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }
}

// MARK: - First run

enum Onboarding {
    static func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }
}

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    var model: AppModel { AppModel.shared }
    let fdaStatus = NSTextField(labelWithString: "")
    let indexStatus = NSTextField(labelWithString: "")
    let loginBox: NSButton
    let menuBarBox: NSButton
    let hotkey: KeyRecorderButton
    var timer: Timer?
    var hadAccess: Bool

    init() {
        let s = AppModel.shared.settings
        loginBox = checkbox("Start Epitome when I log in, so the index stays current", s.startAtLogin)
        menuBarBox = checkbox("Show Epitome in the menu bar", s.showMenuBarIcon)
        hotkey = KeyRecorderButton(combo: s.hotkeyToggleWindow)
        hadAccess = AppModel.shared.manager.hasFullDiskAccess()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Welcome to Epitome"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshNow), name: AppModel.statusChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func build() {
        let f = FormView(labelWidth: 0)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: "Find any file by name, instantly.")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let head = hstack([icon, vstack([title, wrappingLabel("Epitome reads the file names on your disks once, then follows every change as it happens. Type a few letters and every match appears as you type.", width: 440, small: false)], spacing: 4)])
        head.alignment = .centerY
        f.add(head)
        f.header("1. Let Epitome see every file")
        f.note("macOS protects some folders (Mail, Messages, Safari, other apps’ data). With Full Disk Access, Epitome can index them too and macOS won’t ask about Desktop, Documents and Downloads separately. Epitome only reads names and dates — never file contents unless you search for content.")
        f.add(fdaStatus)
        f.add(hstack([button("Open Privacy & Security Settings…") { Onboarding.openFullDiskAccessSettings() },
                      button("Show Epitome in Finder") { FileActions.reveal([Bundle.main.bundlePath]) }]))
        f.note("In Full Disk Access, turn on Epitome (drag it into the list if it isn’t there). macOS may ask to reopen Epitome.")
        f.header("2. Keep it running")
        f.add(loginBox)
        f.add(menuBarBox)
        hotkey.onChange = { _ in }
        f.add(hstack([NSTextField(labelWithString: "Show or hide Epitome from any app with:"), hotkey, button("Clear") { [weak self] in self?.hotkey.combo = nil }]))
        f.header("3. Search")
        f.note("Try: report pdf · ext:jpg;png · size:>1gb · dm:thisweek · \"exact phrase\" · a|b · !tmp · ~/Projects/ swift\nHelp → Search Syntax lists everything you can type.")
        f.add(indexStatus)
        let start = button("Start Searching") { [weak self] in self?.finish() }
        start.keyEquivalent = "\r"
        f.add(hstack([start, button("Search Syntax…") { (NSApp.delegate as? AppDelegate)?.showHelp(page: "syntax") }]))
        window?.contentView = f
        window?.setContentSize(f.fittingSize)
    }

    @objc func refreshNow() { refresh() }

    func refresh() {
        let ok = model.manager.hasFullDiskAccess()
        fdaStatus.stringValue = ok ? "✓ Full Disk Access is on." : "Full Disk Access is off. Epitome works without it but skips protected folders."
        fdaStatus.textColor = ok ? .systemGreen : .systemOrange
        if ok && !hadAccess {
            hadAccess = true
            model.manager.rebuild()
        }
        let st = model.manager.status
        let n = NumberFormatter.localizedString(from: NSNumber(value: model.manager.index.liveCount), number: .decimal)
        switch st.phase {
        case .ready, .idle: indexStatus.stringValue = "Index ready: \(n) items."
        default: indexStatus.stringValue = (st.message.isEmpty ? "Indexing…" : st.message) + (st.count > 0 ? " \(NumberFormatter.localizedString(from: NSNumber(value: st.count), number: .decimal)) items" : "")
        }
    }

    func finish() {
        let login = loginBox.state == .on
        let menuBar = menuBarBox.state == .on
        let hk = hotkey.combo
        model.updateSettings { s in
            s.onboardingDone = true
            s.startAtLogin = login
            s.showMenuBarIcon = menuBar
            s.hotkeyToggleWindow = hk
        }
        (NSApp.delegate as? AppDelegate)?.applyLoginItem(login)
        window?.performClose(nil)
        (NSApp.delegate as? AppDelegate)?.showWindow()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
