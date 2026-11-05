import AppKit
import EpitomeCore
import Quartz

/// Saved search state for back/forward and bookmarks.
struct SearchState: Equatable {
    var text: String
    var options: SearchOptions
    var filterName: String?
    var sort: SortKey
    var ascending: Bool
}

/// One search window: search box, filter bar, results (details or thumbnails),
/// optional preview pane and a status bar.
final class SearchWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSSplitViewDelegate {
    let model = AppModel.shared!

    // MARK: state
    var options = SearchOptions()
    var filter: Filter?
    var sortKey: SortKey = .name
    var ascending = true
    var viewMode: ViewMode = .details
    var source: IndexSource = .local
    var results: ResultsModel
    var back: [SearchState] = []
    var forward: [SearchState] = []
    var lastCommitted: SearchState?
    var jumpText = ""
    var jumpTime = Date.distantPast
    var enterArmed = false
    var zoom: CGFloat = 0

    // MARK: views
    let searchField = EpitomeSearchField()
    let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let table = ResultsTableView()
    let tableScroll = NSScrollView()
    var thumbs: ThumbnailController?
    let split = NSSplitView()
    let resultsContainer = NSView()
    var preview: QLPreviewView?
    let statusBar = StatusBarView()
    var topBar = NSStackView()

    // MARK: search machinery
    let searchQueue = DispatchQueue(label: "app.epitome.search", qos: .userInitiated)
    var cancel: CancelToken?
    var seq = 0
    var pendingSearch: DispatchWorkItem?
    var commitTimer: Timer?
    var searching = false

    var searchText: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    init(state: SearchState? = nil, source: IndexSource = .local) {
        results = ResultsModel.empty(AppModel.shared.manager.services)
        self.source = source
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.minSize = NSSize(width: 420, height: 240)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.setFrameAutosaveName("EpitomeSearchWindow")
        super.init(window: w)
        w.delegate = self
        buildUI()
        applyHome(state)
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged), name: AppModel.indexChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppModel.settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(filtersChanged), name: AppModel.filtersChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged), name: AppModel.statusChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - UI construction

    func buildUI() {
        guard let w = window, let content = w.contentView else { return }
        w.titlebarAppearsTransparent = false
        w.titleVisibility = .visible
        w.toolbarStyle = .unifiedCompact

        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.controller = self
        searchField.font = NSFont.systemFont(ofSize: model.settings.searchFontSize > 0 ? model.settings.searchFontSize : 15)
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false

        filterPopup.target = self
        filterPopup.action = #selector(filterPopupChanged(_:))
        filterPopup.controlSize = .regular
        filterPopup.translatesAutoresizingMaskIntoConstraints = false
        rebuildFilterPopup()

        topBar = NSStackView(views: [searchField, filterPopup])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        filterPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .noBorder
        table.controller = self
        table.configure()

        resultsContainer.addSubview(tableScroll)
        tableScroll.pin(to: resultsContainer)

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(resultsContainer)
        split.translatesAutoresizingMaskIntoConstraints = false

        statusBar.controller = self
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(topBar)
        content.addSubview(sep)
        content.addSubview(split)
        content.addSubview(statusBar)
        let guide = content.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: guide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sep.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: sep.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
        applyVisibilityOptions()
        w.initialFirstResponder = searchField
    }

    func applyVisibilityOptions() {
        let s = model.settings
        filterPopup.isHidden = !s.showFilterBar
        statusBar.isHidden = !s.showStatusBar
        table.headerView = s.showHeader ? table.savedHeader : nil
        table.usesAlternatingRowBackgroundColors = s.alternateRowColor
        setPreviewVisible(s.showPreview)
        table.applyFont()
        applyOnTop()
    }

    func rebuildFilterPopup() {
        filterPopup.removeAllItems()
        for f in model.filters.current {
            filterPopup.addItem(withTitle: f.name)
            filterPopup.lastItem?.representedObject = f.id.uuidString
        }
        selectFilterInPopup()
    }

    func selectFilterInPopup() {
        if let f = filter, let i = model.filters.current.firstIndex(where: { $0.id == f.id }) {
            filterPopup.selectItem(at: i)
        } else {
            filterPopup.selectItem(at: model.filters.current.firstIndex(where: { $0.isEverything }) ?? 0)
        }
    }

    // MARK: - Home / state

    func applyHome(_ state: SearchState?) {
        let s = model.settings
        if let st = state {
            searchText = st.text
            options = st.options
            filter = st.filterName.flatMap { model.filter(named: $0) }
            sortKey = st.sort
            ascending = st.ascending
        } else {
            options.matchCase = s.homeMatchCase.resolve(s.lastOptions.matchCase)
            options.matchWholeWord = s.homeMatchWholeWord.resolve(s.lastOptions.matchWholeWord)
            options.matchPath = s.homeMatchPath.resolve(s.lastOptions.matchPath)
            options.matchDiacritics = s.homeMatchDiacritics.resolve(s.lastOptions.matchDiacritics)
            options.regex = s.homeRegex.resolve(s.lastOptions.regex)
            searchText = s.homeSearchUseLast ? s.lastSearch : s.homeSearch
            let fname = s.homeFilterUseLast ? s.lastFilter : s.homeFilter
            filter = fname.isEmpty ? nil : model.filter(named: fname)
            if filter?.isEverything == true { filter = nil }
            if s.homeSortUseLast {
                sortKey = s.lastSort
                ascending = s.lastSortAscending
            } else {
                sortKey = s.homeSort
                ascending = s.homeSortAscending
            }
            viewMode = s.homeViewUseLast ? s.lastView : s.homeView
        }
        selectFilterInPopup()
        setViewMode(viewMode, save: false)
        table.updateSortIndicator()
        updateTitle()
        runSearch(immediate: true)
    }

    var state: SearchState {
        SearchState(text: searchText, options: options, filterName: filter?.name, sort: sortKey, ascending: ascending)
    }

    func apply(_ st: SearchState, recordHistory: Bool = true) {
        if recordHistory { pushHistory() }
        searchText = st.text
        options = st.options
        filter = st.filterName.flatMap { model.filter(named: $0) }
        if filter?.isEverything == true { filter = nil }
        sortKey = st.sort
        ascending = st.ascending
        selectFilterInPopup()
        table.updateSortIndicator()
        runSearch(immediate: true)
    }

    func pushHistory() {
        let st = state
        if back.last != st { back.append(st) }
        if back.count > 100 { back.removeFirst() }
        forward.removeAll()
    }

    func rememberLast() {
        let st = state
        let view = viewMode
        let fname = filter?.name ?? ""
        model.rememberState { s in
            s.lastOptions = st.options
            s.lastSearch = st.text
            s.lastFilter = fname
            s.lastSort = st.sort
            s.lastSortAscending = st.ascending
            s.lastView = view
        }
    }

    // MARK: - Searching

    var currentIndex: FileIndex {
        if case .fileList(let ix, _) = source { return ix }
        return model.manager.index
    }

    func makeRequest() -> SearchRequest {
        let s = model.settings
        var r = SearchRequest(text: searchText, options: options, filter: filter?.spec, sort: sortKey, ascending: ascending,
                              foldersFirst: s.foldersFirst, syntax: s.syntax)
        r.hideWhenEmpty = s.hideEmptySearchResults
        return r
    }

    /// Starts a search (debounced while typing). `refresh` keeps selection and scroll position.
    func runSearch(immediate: Bool = false, refresh: Bool = false) {
        pendingSearch?.cancel()
        let delay = immediate || refresh ? 0 : Double(model.settings.searchDelayMs) / 1000
        let work = DispatchWorkItem { [weak self] in self?.startSearch(refresh: refresh) }
        pendingSearch = work
        if delay <= 0 { DispatchQueue.main.async(execute: work) } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        if !refresh { scheduleCommit() }
    }

    private func startSearch(refresh: Bool) {
        cancel?.cancel()
        let token = CancelToken()
        cancel = token
        seq += 1
        let mySeq = seq
        let req = makeRequest()
        let services = model.manager.services
        searching = true
        statusBar.setSearching(true)
        updateTitle()
        switch source {
        case .remote(let client):
            let f = filter?.spec
            searchQueue.async { [weak self] in
                let res = client.search(req.text, options: req.options, filter: f, sort: req.sort, ascending: req.ascending, offset: 0, count: 5000)
                DispatchQueue.main.async {
                    guard let self, mySeq == self.seq else { return }
                    let terms = QueryCompiler.compile(req.text, options: req.options, syntax: req.syntax).highlights
                    if let (total, rows) = res {
                        self.install(ResultsModel(.remote(total: total, rows: rows, highlights: terms), services: services), refresh: refresh)
                    } else {
                        self.install(ResultsModel.empty(services), refresh: refresh)
                        self.statusBar.flash("ETP: \(client.lastError)")
                    }
                }
            }
        default:
            let ix = currentIndex
            searchQueue.async { [weak self] in
                let res = SearchEngine.run(req, index: ix, services: services, cancel: token)
                DispatchQueue.main.async {
                    guard let self, mySeq == self.seq, let r = res else { return }
                    self.install(ResultsModel(.local(r), services: services), refresh: refresh)
                }
            }
        }
    }

    private func install(_ new: ResultsModel, refresh: Bool) {
        searching = false
        statusBar.setSearching(false)
        let keepSelection = refresh || !model.settings.clearSelectionOnSearch
        var selectedIDs = Set<EntryID>()
        if keepSelection, results.localResults != nil {
            for r in table.selectedRowIndexes { if let id = results.entry(r) { selectedIDs.insert(id) } }
        }
        // On a refresh, keep the item at the top of the list exactly where it is. The clip
        // view starts under the column header, so measure from below it (contentInsets).
        let clip = table.enclosingScrollView?.contentView
        let insetTop = clip?.contentInsets.top ?? 0
        let visibleTopY = (clip?.bounds.origin.y ?? 0) + insetTop
        let wasAtTop = visibleTopY <= 0.5
        var anchorID: EntryID?
        var anchorOffset: CGFloat = 0
        let oldTopRow = table.row(at: NSPoint(x: 0, y: Swift.max(0, visibleTopY)))
        if refresh, !wasAtTop, oldTopRow >= 0, let id = results.entry(oldTopRow) {
            anchorID = id
            anchorOffset = visibleTopY - table.rect(ofRow: oldTopRow).minY
        }
        results = new
        table.reloadData()
        thumbs?.reload()
        if keepSelection && !selectedIDs.isEmpty {
            let rows = results.rows(for: selectedIDs)
            if !rows.isEmpty { table.selectRowIndexes(rows, byExtendingSelection: false) }
        }
        if refresh && !wasAtTop {
            if let id = anchorID, let r = results.rows(for: [id]).first {
                scrollList(toY: table.rect(ofRow: r).minY + anchorOffset)
            } else if oldTopRow >= 0, results.count > 0 {
                scrollList(toY: table.rect(ofRow: Swift.min(oldTopRow, results.count - 1)).minY)
            }
        } else {
            scrollList(toY: 0)
        }
        enterArmed = false
        statusBar.update()
        updatePreview()
        if let err = results.errors.first { statusBar.flash(err) }
    }

    /// Scrolls the result list so that table position `y` is just below the column header.
    func scrollList(toY y: CGFloat) {
        guard let sv = table.enclosingScrollView else { return }
        table.tile()
        let clip = sv.contentView
        let insetTop = clip.contentInsets.top
        let maxY = Swift.max(-insetTop, table.frame.height - clip.bounds.height)
        let target = Swift.min(Swift.max(y - insetTop, -insetTop), maxY)
        if abs(clip.bounds.origin.y - target) > 0.25 {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            sv.reflectScrolledClipView(clip)
        }
    }

    /// Commits the search to back/forward history after typing pauses.
    func scheduleCommit() {
        commitTimer?.invalidate()
        commitTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            let st = self.state
            if let last = self.lastCommitted, last != st, last.text != st.text {
                if self.back.last != last { self.back.append(last) }
                self.forward.removeAll()
            }
            self.lastCommitted = st
            self.rememberLast()
        }
    }

    func recordSearchHistory() {
        model.history.record(searchText)
    }

    @objc func indexChanged() {
        if case .local = source { runSearch(refresh: true) }
    }

    @objc func settingsChanged() {
        applyVisibilityOptions()
        table.reloadData()
        statusBar.update()
        runSearch(refresh: true)
    }

    @objc func filtersChanged() {
        if let f = filter { filter = model.filters.current.first { $0.id == f.id } }
        rebuildFilterPopup()
        runSearch(refresh: true)
    }

    @objc func statusChanged() { statusBar.update() }

    func updateTitle() {
        let inst = model.instance.isEmpty ? "" : " (\(model.instance))"
        let t = searchText.isEmpty ? "Epitome" : "\(searchText) - Epitome"
        window?.title = t + inst
        applyOnTop()
    }

    func applyOnTop() {
        switch model.settings.onTop {
        case .never: window?.level = .normal
        case .always: window?.level = .floating
        case .whileSearching: window?.level = searchText.isEmpty ? .normal : .floating
        }
    }

    // MARK: - Search field

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        if model.settings.searchAsYouType { runSearch() }
        updateTitle()
        if model.settings.alwaysShowSearchSuggestions { searchField.showSuggestions(model.history.suggestions(for: searchText)) }
    }

    @objc func searchFieldAction(_ sender: Any?) {
        // sendsSearchStringImmediately triggers this on every change; Enter is handled in doCommandBy.
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === searchField else { return false }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if searchField.suggestionsVisible, let s = searchField.selectedSuggestion {
                searchText = s
                searchField.hideSuggestions()
                runSearch(immediate: true)
                return true
            }
            if handleSearchCommand() { return true }
            if !model.settings.searchAsYouType { runSearch(immediate: true) }
            recordSearchHistory()
            focusResultsSelectingMostRun()
            return true
        case #selector(NSResponder.moveDown(_:)):
            if searchField.suggestionsVisible { searchField.moveSuggestion(1); return true }
            focusResults(selectFirst: true)
            return true
        case #selector(NSResponder.moveUp(_:)):
            if searchField.suggestionsVisible { searchField.moveSuggestion(-1); return true }
            focusResults(selectFirst: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.suggestionsVisible { searchField.hideSuggestions(); return true }
            window?.performClose(nil)
            return true
        case #selector(NSResponder.insertTab(_:)):
            if searchText.hasPrefix(">") { completeCommand(); return true }
            focusResults(selectFirst: table.selectedRow < 0)
            return true
        case #selector(NSResponder.complete(_:)):
            showHistorySuggestions()
            return true
        default:
            return false
        }
    }

    func showHistorySuggestions() {
        let s = model.history.suggestions(for: searchText)
        if s.isEmpty { NSSound.beep(); return }
        if s.count == 1 { searchText = s[0]; runSearch(immediate: true); return }
        searchField.showSuggestions(s)
    }

    func focusResults(selectFirst: Bool) {
        guard results.count > 0 else { return }
        if viewMode != .details, let t = thumbs {
            window?.makeFirstResponder(t.collection)
            if t.collection.selectionIndexPaths.isEmpty { t.select(0) }
            return
        }
        window?.makeFirstResponder(table)
        if selectFirst || table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    /// Enter in the search box: select the most-opened result (second Enter opens it).
    func focusResultsSelectingMostRun() {
        guard results.count > 0 else { return }
        var best = 0
        if case .local(let res) = results.kind {
            let ix = res.index
            var bestCount = 0
            let runs = model.manager.runHistory.all()
            if !runs.isEmpty {
                var ids: [EntryID: Int] = [:]
                ix.lock.read {
                    for (p, r) in runs where r.count > bestCount || ids.isEmpty {
                        let id = ix.lookup(path: p)
                        if id != kNoEntry { ids[id] = r.count }
                    }
                }
                if !ids.isEmpty {
                    let limit = Swift.min(res.ids.count, 2_000_000)
                    for i in 0..<limit {
                        if let c = ids[res.ids[i]], c > bestCount { bestCount = c; best = i }
                    }
                }
            }
        }
        window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: best), byExtendingSelection: false)
        table.scrollRowToVisible(best)
        enterArmed = true
    }

    // MARK: - Search commands (">rebuild", "about:" …)

    func handleSearchCommand() -> Bool {
        let t = searchText.trimmingCharacters(in: .whitespaces)
        let app = NSApp.delegate as? AppDelegate
        if t.hasPrefix("about:") {
            switch t.lowercased() {
            case "about:": NSApp.orderFrontStandardAboutPanel(nil)
            case "about:options", "about:preferences": app?.showOptions(nil)
            case "about:home": goHome(nil)
            case "about:config": NSWorkspace.shared.open(model.settingsURL)
            case "about:license", "about:licence", "about:credits": app?.showHelp(page: "license")
            default: return false
            }
            searchText = ""
            runSearch(immediate: true)
            return true
        }
        guard t.hasPrefix(">") else { return false }
        let cmd = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        let lower = cmd.lowercased()
        var message = ""
        switch lower {
        case "rebuild", "reindex": model.manager.rebuild(); message = "Rebuilding index…"
        case "close": window?.performClose(nil)
        case "closeall": app?.closeAllWindows()
        case "quit", "exit": NSApp.terminate(nil)
        case "help": app?.showHelp(page: "syntax")
        case "options", "preferences": app?.showOptions(nil)
        case "monitor_pause", "monitor-pause", "pause": model.manager.pauseMonitoring(); message = "Monitoring paused"
        case "monitor_resume", "monitor-resume", "resume": model.manager.resumeMonitoring(); message = "Monitoring resumed"
        case "update", "rescan": model.manager.rescanAllFolders(); message = "Rescanning folders…"
        case "save-db", "save_db", "savedb": model.manager.save(); message = "Saving database…"
        case "debug", "console": app?.showDebugConsole(nil)
        case "new-window", "newwindow": app?.newSearchWindow(nil)
        case "restart": app?.restart()
        case "config_save", "config-save": app?.exportSettings()
        case "config_load", "config-load": app?.importSettings()
        default:
            if let eq = cmd.firstIndex(of: "=") {
                let key = String(cmd[..<eq]).trimmingCharacters(in: .whitespaces)
                let val = String(cmd[cmd.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                var s = model.settings
                if s.setValue(key, val) {
                    model.setSettings(s)
                    message = s.value(key) ?? "\(key) changed"
                } else { message = "Unknown setting or bad value: \(key)" }
            } else if let v = model.settings.value(cmd) {
                message = v
            } else if lower.hasPrefix("update ") || lower.hasPrefix("rescan ") {
                let p = (String(cmd.dropFirst(7)) as NSString).expandingTildeInPath
                model.manager.rescan(path: p)
                message = "Rescanning \(p)…"
            } else {
                message = "Unknown command: \(cmd)"
            }
        }
        searchText = ""
        runSearch(immediate: true)
        if !message.isEmpty { statusBar.flash(message) }
        return true
    }

    func completeCommand() {
        let typed = String(searchText.dropFirst()).lowercased()
        let commands = ["rebuild", "reindex", "close", "closeall", "quit", "help", "options", "monitor_pause", "monitor_resume",
                        "update", "save-db", "debug", "new-window", "restart", "config_save", "config_load"] + AppSettings.settingNames
        if let m = commands.first(where: { $0.lowercased().hasPrefix(typed) }) { searchText = ">" + m }
    }

    // MARK: - Filters & view

    @objc func filterPopupChanged(_ sender: NSPopUpButton) {
        guard let idStr = sender.selectedItem?.representedObject as? String,
              let f = model.filters.current.first(where: { $0.id.uuidString == idStr }) else { return }
        setFilter(f.isEverything ? nil : f)
    }

    func setFilter(_ f: Filter?) {
        pushHistory()
        filter = f
        selectFilterInPopup()
        runSearch(immediate: true)
        statusBar.update()
        rememberLast()
    }

    func setSort(_ key: SortKey, ascending asc: Bool? = nil) {
        if key == sortKey && asc == nil {
            ascending.toggle()
        } else {
            sortKey = key
            if let a = asc { ascending = a } else {
                let s = model.settings
                switch key {
                case .size: ascending = !s.sortSizeDescendingFirst
                case .dateModified, .dateCreated, .dateAccessed, .dateRecentlyChanged, .dateRun: ascending = !s.sortDateDescendingFirst
                case .runCount: ascending = false
                default: ascending = true
                }
            }
        }
        table.updateSortIndicator()
        runSearch(immediate: true, refresh: !model.settings.clearSelectionOnSearch)
        rememberLast()
    }

    func setViewMode(_ m: ViewMode, save: Bool = true) {
        viewMode = m
        if m == .details {
            thumbs?.view.removeFromSuperview()
            if tableScroll.superview == nil {
                resultsContainer.addSubview(tableScroll)
                tableScroll.pin(to: resultsContainer)
            }
        } else {
            if thumbs == nil { thumbs = ThumbnailController(owner: self) }
            tableScroll.removeFromSuperview()
            if let t = thumbs, t.view.superview == nil {
                resultsContainer.addSubview(t.view)
                t.view.pin(to: resultsContainer)
            }
            thumbs?.setSize(m)
            thumbs?.reload()
        }
        if save { rememberLast() }
    }

    func setPreviewVisible(_ show: Bool) {
        if show && preview == nil {
            guard let p = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 400), style: .normal) else { return }
            p.autostarts = true
            p.shouldCloseWithWindow = false
            preview = p
            split.addArrangedSubview(p)
            if let w = window { split.setPosition(w.frame.width * 0.66, ofDividerAt: 0) }
            updatePreview()
        } else if !show, let p = preview {
            p.close()
            p.removeFromSuperview()
            preview = nil
        }
    }

    func updatePreview() {
        guard let p = preview else { return }
        let row = focusedRow
        if row >= 0, let path = results.path(row), FileManager.default.fileExists(atPath: path) {
            p.previewItem = URL(fileURLWithPath: path) as NSURL
        } else {
            p.previewItem = nil
        }
    }

    var focusedRow: Int {
        if viewMode != .details, let t = thumbs { return t.collection.selectionIndexPaths.first?.item ?? -1 }
        return table.selectedRow
    }

    var selectedRows: IndexSet {
        if viewMode != .details, let t = thumbs { return IndexSet(t.collection.selectionIndexPaths.map(\.item)) }
        return table.selectedRowIndexes
    }

    var selectedPaths: [String] {
        selectedRows.compactMap { results.path($0) }
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        cancel?.cancel()
        rememberLast()
        table.saveColumns()
        if let p = preview { p.close() }
        if case .remote(let c) = source { c.close() }
        (NSApp.delegate as? AppDelegate)?.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if model.settings.focusSearchOnActivate { focusSearch(nil) }
        statusBar.update()
    }

    func windowDidResignKey(_ notification: Notification) {
        searchField.hideSuggestions()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        Swift.max(proposed, 240)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        Swift.min(proposed, splitView.frame.width - 160)
    }
}

/// Search field that accepts dropped files and shows history suggestions.
final class EpitomeSearchField: NSSearchField, NSTableViewDataSource, NSTableViewDelegate {
    weak var controller: SearchWindowController?
    private var panel: NSPanel?
    private var list: NSTableView?
    private var items: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let wasFirst = window?.firstResponder === currentEditor()
        super.mouseDown(with: event)
        if !wasFirst && AppModel.shared.settings.selectSearchOnMouseClick { currentEditor()?.selectAll(nil) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        var isDir: ObjCBool = false
        if urls.count == 1, FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir), isDir.boolValue {
            stringValue = "\"\(urls[0].path)/\""
        } else {
            stringValue = "filelist:\"" + urls.map(\.path).joined(separator: "|") + "\""
        }
        controller?.runSearch(immediate: true)
        return true
    }

    // MARK: suggestions popup

    var suggestionsVisible: Bool { panel?.isVisible == true }
    var selectedSuggestion: String? {
        guard let l = list, l.selectedRow >= 0, l.selectedRow < items.count else { return nil }
        return items[l.selectedRow]
    }

    func showSuggestions(_ s: [String]) {
        items = s
        guard !s.isEmpty, let w = window else { hideSuggestions(); return }
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.hasShadow = true
            p.isFloatingPanel = true
            p.backgroundColor = .windowBackgroundColor
            let t = NSTableView()
            t.headerView = nil
            t.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("s")))
            t.dataSource = self
            t.delegate = self
            t.rowHeight = 22
            t.target = self
            t.action = #selector(pick(_:))
            let sv = NSScrollView()
            sv.documentView = t
            sv.hasVerticalScroller = true
            p.contentView = sv
            panel = p
            list = t
        }
        list?.reloadData()
        let r = convert(bounds, to: nil)
        let screenRect = w.convertToScreen(r)
        let h = CGFloat(Swift.min(s.count, 10)) * 24 + 4
        panel?.setFrame(NSRect(x: screenRect.minX, y: screenRect.minY - h - 2, width: screenRect.width, height: h), display: true)
        if panel?.parent == nil { w.addChildWindow(panel!, ordered: .above) }
        panel?.orderFront(nil)
    }

    func hideSuggestions() {
        if let p = panel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
    }

    func moveSuggestion(_ d: Int) {
        guard let l = list, !items.isEmpty else { return }
        let n = Swift.max(0, Swift.min(items.count - 1, l.selectedRow + d))
        l.selectRowIndexes(IndexSet(integer: n), byExtendingSelection: false)
        l.scrollRowToVisible(n)
    }

    @objc func pick(_ sender: Any?) {
        guard let s = selectedSuggestion else { return }
        stringValue = s
        hideSuggestions()
        controller?.runSearch(immediate: true)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let t = NSTextField(labelWithString: items[row])
        t.lineBreakMode = .byTruncatingTail
        return t
    }
}
