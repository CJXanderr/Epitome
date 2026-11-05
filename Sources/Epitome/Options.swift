import AppKit
import EpitomeCore
import UniformTypeIdentifiers

/// Binds controls to the Options window's draft copy of the settings.
/// Every control registers how to refresh itself and how to restore its default.
final class SettingsBinder {
    let get: () -> AppSettings
    let mutate: ((inout AppSettings) -> Void) -> Void
    var refreshers: [() -> Void] = []
    var resetters: [(inout AppSettings) -> Void] = []

    init(get: @escaping () -> AppSettings, mutate: @escaping ((inout AppSettings) -> Void) -> Void) {
        self.get = get
        self.mutate = mutate
    }

    func refresh() { for r in refreshers { r() } }

    func track<T>(_ kp: WritableKeyPath<AppSettings, T>) {
        resetters.append { s in s[keyPath: kp] = AppSettings()[keyPath: kp] }
    }

    func check(_ title: String, _ kp: WritableKeyPath<AppSettings, Bool>, tip: String? = nil,
               enabled: ((AppSettings) -> Bool)? = nil) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.toolTip = tip
        b.onAction { [unowned self] c in
            let on = (c as? NSButton)?.state == .on
            self.mutate { $0[keyPath: kp] = on }
        }
        refreshers.append { [unowned self, weak b] in
            guard let b else { return }
            let s = self.get()
            b.state = s[keyPath: kp] ? .on : .off
            if let e = enabled { b.isEnabled = e(s) }
        }
        track(kp)
        return b
    }

    func choice<T: Equatable>(_ items: [(String, T)], _ kp: WritableKeyPath<AppSettings, T>,
                              enabled: ((AppSettings) -> Bool)? = nil) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items.map(\.0))
        p.onAction { [unowned self] c in
            let i = (c as? NSPopUpButton)?.indexOfSelectedItem ?? -1
            guard i >= 0 && i < items.count else { return }
            let v = items[i].1
            self.mutate { $0[keyPath: kp] = v }
        }
        refreshers.append { [unowned self, weak p] in
            guard let p else { return }
            let s = self.get()
            let v = s[keyPath: kp]
            if let i = items.firstIndex(where: { $0.1 == v }) { p.selectItem(at: i) }
            if let e = enabled { p.isEnabled = e(s) }
        }
        track(kp)
        return p
    }

    func text(_ kp: WritableKeyPath<AppSettings, String>, placeholder: String = "", width: CGFloat = 260,
              secure: Bool = false, enabled: ((AppSettings) -> Bool)? = nil) -> NSTextField {
        let f = textField(placeholder: placeholder, width: width, secure: secure)
        f.onTextChange { [unowned self] t in
            let v = t.stringValue
            self.mutate { $0[keyPath: kp] = v }
        }
        refreshers.append { [unowned self, weak f] in
            guard let f else { return }
            let s = self.get()
            if f.currentEditor() == nil && f.stringValue != s[keyPath: kp] { f.stringValue = s[keyPath: kp] }
            if let e = enabled { f.isEnabled = e(s) }
        }
        track(kp)
        return f
    }

    func int(_ kp: WritableKeyPath<AppSettings, Int>, width: CGFloat = 70, range: ClosedRange<Int>? = nil,
             enabled: ((AppSettings) -> Bool)? = nil) -> NSTextField {
        let f = textField(width: width)
        f.alignment = .right
        f.onTextChange { [unowned self] t in
            guard var v = Int(t.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
            if let r = range { v = Swift.min(Swift.max(v, r.lowerBound), r.upperBound) }
            self.mutate { $0[keyPath: kp] = v }
        }
        refreshers.append { [unowned self, weak f] in
            guard let f else { return }
            let s = self.get()
            let str = String(s[keyPath: kp])
            if f.currentEditor() == nil && f.stringValue != str { f.stringValue = str }
            if let e = enabled { f.isEnabled = e(s) }
        }
        track(kp)
        return f
    }

    func double(_ kp: WritableKeyPath<AppSettings, Double>, width: CGFloat = 70, placeholder: String = "",
                zeroIsEmpty: Bool = false) -> NSTextField {
        let f = textField(placeholder: placeholder, width: width)
        f.alignment = .right
        f.onTextChange { [unowned self] t in
            let raw = t.stringValue.trimmingCharacters(in: .whitespaces)
            let v = raw.isEmpty && zeroIsEmpty ? 0 : Double(raw)
            guard let val = v else { return }
            self.mutate { $0[keyPath: kp] = val }
        }
        refreshers.append { [unowned self, weak f] in
            guard let f else { return }
            let d = self.get()[keyPath: kp]
            let str = zeroIsEmpty && d == 0 ? "" : (d == d.rounded() ? String(Int(d)) : String(d))
            if f.currentEditor() == nil && f.stringValue != str { f.stringValue = str }
        }
        track(kp)
        return f
    }

    /// "Keep for N days" (0 = forever).
    func days(_ title: String, _ kp: WritableKeyPath<AppSettings, Int>, enabled: ((AppSettings) -> Bool)? = nil) -> NSStackView {
        let c = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        let f = textField(width: 50)
        f.alignment = .right
        c.onAction { [unowned self] b in
            let on = (b as? NSButton)?.state == .on
            self.mutate { $0[keyPath: kp] = on ? 90 : 0 }
        }
        f.onTextChange { [unowned self] t in
            guard let v = Int(t.stringValue), v > 0 else { return }
            self.mutate { $0[keyPath: kp] = v }
        }
        refreshers.append { [unowned self, weak c, weak f] in
            guard let c, let f else { return }
            let s = self.get()
            let v = s[keyPath: kp]
            c.state = v > 0 ? .on : .off
            if f.currentEditor() == nil { f.stringValue = v > 0 ? String(v) : "90" }
            let en = enabled?(s) ?? true
            c.isEnabled = en
            f.isEnabled = en && v > 0
        }
        track(kp)
        return hstack([c, f, NSTextField(labelWithString: "days")])
    }

    func hotkey(_ kp: WritableKeyPath<AppSettings, KeyCombo?>) -> NSStackView {
        let b = KeyRecorderButton(combo: get()[keyPath: kp])
        b.onChange = { [unowned self] c in self.mutate { $0[keyPath: kp] = c } }
        let clear = button("Clear") { [unowned self] in self.mutate { $0[keyPath: kp] = nil } }
        refreshers.append { [unowned self, weak b] in
            guard let b else { return }
            let c = self.get()[keyPath: kp]
            if b.combo != c { b.combo = c }
        }
        track(kp)
        return hstack([b, clear])
    }

    func path(_ kp: WritableKeyPath<AppSettings, String>, placeholder: String, folder: Bool = true, width: CGFloat = 300) -> NSStackView {
        let f = text(kp, placeholder: placeholder, width: width)
        let b = button("Choose…") { [unowned self] in
            let p = NSOpenPanel()
            p.canChooseDirectories = folder
            p.canChooseFiles = !folder
            p.canCreateDirectories = true
            guard p.runModal() == .OK, let u = p.url else { return }
            f.stringValue = u.path
            self.mutate { $0[keyPath: kp] = u.path }
        }
        return hstack([f, b])
    }

    /// Lets custom views refresh and reset with the page.
    func custom(refresh: @escaping () -> Void, reset: @escaping (inout AppSettings) -> Void) {
        refreshers.append(refresh)
        resetters.append(reset)
    }
}

/// Tools → Options (also the app menu's Settings…): every option, grouped into pages.
final class OptionsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Page {
        let title: String
        let indent: Int
        let make: (SettingsBinder) -> NSView
    }

    var draft: AppSettings
    private var pages: [Page] = []
    private var views: [Int: NSView] = [:]
    private var binders: [Int: SettingsBinder] = [:]
    private let sidebar = NSTableView()
    private let container = NSView()
    private var applyButton: NSButton!
    private var selected = -1
    var model: AppModel { AppModel.shared }

    init() {
        draft = AppModel.shared.settings
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Epitome Settings"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 480)
        super.init(window: w)
        w.delegate = self
        pages = OptionsPages.all
        buildUI()
        w.center()
        w.setFrameAutosaveName("EpitomeOptions")
        select(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        // Frame-based outer layout: sidebar | separator | page, with the button bar below.
        let W = content.bounds.width, H = content.bounds.height
        let barH: CGFloat = 52
        let sideW: CGFloat = 200

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        col.width = sideW - 12
        sidebar.addTableColumn(col)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 24
        sidebar.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sidebar.dataSource = self
        sidebar.delegate = self
        let sideScroll = NSScrollView(frame: NSRect(x: 0, y: barH, width: sideW, height: H - barH))
        sideScroll.autoresizingMask = [.height]
        sideScroll.documentView = sidebar
        sideScroll.hasVerticalScroller = true
        sideScroll.autohidesScrollers = true
        sideScroll.drawsBackground = false
        sideScroll.borderType = .noBorder

        let sep = NSBox(frame: NSRect(x: sideW, y: barH, width: 1, height: H - barH))
        sep.boxType = .separator
        sep.autoresizingMask = [.height]

        container.frame = NSRect(x: sideW + 1, y: barH, width: W - sideW - 1, height: H - barH)
        container.autoresizingMask = [.width, .height]

        let bottomSep = NSBox(frame: NSRect(x: 0, y: barH - 1, width: W, height: 1))
        bottomSep.boxType = .separator
        bottomSep.autoresizingMask = [.width, .maxYMargin]

        let restore = button("Restore Defaults") { [weak self] in self?.restoreDefaults() }
        restore.toolTip = "Restores the options on this page"
        let cancel = button("Cancel") { [weak self] in self?.cancel() }
        cancel.keyEquivalent = "\u{1B}"
        let ok = button("OK") { [weak self] in self?.ok() }
        ok.keyEquivalent = "\r"
        applyButton = button("Apply") { [weak self] in self?.apply() }
        // Restore Defaults on the left; Cancel, Apply, OK on the right.
        let buttonY: CGFloat = 13
        restore.sizeToFit()
        restore.frame.origin = NSPoint(x: 16, y: buttonY)
        restore.autoresizingMask = [.maxXMargin, .maxYMargin]
        var x = W - 16
        for b in [ok, applyButton!, cancel] {
            b.sizeToFit()
            b.frame.size.width = Swift.max(b.frame.width, 82)
            x -= b.frame.width
            b.frame.origin = NSPoint(x: x, y: buttonY)
            b.autoresizingMask = [.minXMargin, .maxYMargin]
            x -= 8
        }

        for v in [sideScroll, sep, container, bottomSep, restore, cancel, applyButton!, ok] as [NSView] { content.addSubview(v) }
    }

    // MARK: pages

    func binder(_ i: Int) -> SettingsBinder {
        if let b = binders[i] { return b }
        let b = SettingsBinder(get: { [unowned self] in self.draft },
                               mutate: { [unowned self] body in
                                   body(&self.draft)
                                   self.changed()
                               })
        binders[i] = b
        return b
    }

    func select(_ i: Int) {
        guard i >= 0, i < pages.count, i != selected else { return }
        selected = i
        container.subviews.forEach { $0.removeFromSuperview() }
        let v: NSView
        if let existing = views[i] {
            v = existing
        } else {
            v = pages[i].make(binder(i))
            views[i] = v
        }
        v.translatesAutoresizingMaskIntoConstraints = true
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
        binders[i]?.refresh()
        if sidebar.selectedRow != i { sidebar.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }
        updateApply()
    }

    /// Show a page by title ("HTTP Server").
    func show(page title: String) {
        if let i = pages.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) { select(i) }
    }

    func changed() {
        for b in binders.values { b.refresh() }
        updateApply()
    }

    func updateApply() { applyButton?.isEnabled = draft != model.settings }

    /// Re-reads the live settings (each time the window is shown).
    func reload() {
        draft = model.settings
        changed()
    }

    func restoreDefaults() {
        guard let b = binders[selected] else { return }
        for r in b.resetters { r(&draft) }
        changed()
    }

    func apply() {
        model.setSettings(draft)
        draft = model.settings
        changed()
    }

    func ok() {
        apply()
        window?.performClose(nil)
    }

    func cancel() {
        draft = model.settings
        changed()
        window?.performClose(nil)
    }

    /// Closing with the window's close button discards unapplied changes, like Cancel.
    func windowWillClose(_ notification: Notification) {
        draft = model.settings
    }

    // MARK: sidebar

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = pages[row]
        let cell = NSTableCellView()
        let t = NSTextField(labelWithString: p.title)
        t.font = p.indent == 0 ? NSFont.systemFont(ofSize: 13, weight: .semibold) : NSFont.systemFont(ofSize: 13)
        t.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(t)
        cell.textField = t
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: CGFloat(4 + 16 * p.indent)),
            t.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = sidebar.selectedRow
        if r >= 0 { select(r) }
    }
}

// MARK: - The pages

enum OptionsPages {
    typealias Page = OptionsWindowController.Page

    static let all: [Page] = [
        Page(title: "General", indent: 0, make: general),
        Page(title: "UI", indent: 1, make: ui),
        Page(title: "Home", indent: 1, make: home),
        Page(title: "Search", indent: 1, make: search),
        Page(title: "Results", indent: 1, make: results),
        Page(title: "View", indent: 1, make: view),
        Page(title: "Context Menu", indent: 1, make: contextMenu),
        Page(title: "Fonts and Colors", indent: 1, make: fonts),
        Page(title: "Keyboard", indent: 1, make: keyboard),
        Page(title: "History", indent: 0, make: history),
        Page(title: "Indexes", indent: 0, make: indexes),
        Page(title: "Volumes", indent: 1, make: volumes),
        Page(title: "Folders", indent: 1, make: folders),
        Page(title: "File Lists", indent: 1, make: fileLists),
        Page(title: "Exclude", indent: 1, make: exclude),
        Page(title: "ETP/FTP Server", indent: 0, make: etpServer),
        Page(title: "HTTP Server", indent: 0, make: httpServer),
        Page(title: "Advanced", indent: 0, make: advanced),
    ]

    static var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    // MARK: General

    static func general(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.header("Startup")
        f.add(b.check("Start Epitome when you log in", \.startAtLogin,
                      tip: "Epitome starts in the background at login so the index is always up to date."))
        f.add(b.check("Keep running in the background when every window is closed", \.runInBackground))
        f.header("Menu bar and Dock")
        f.add(b.check("Show Epitome in the menu bar", \.showMenuBarIcon))
        f.add(b.check("Clicking the menu bar icon opens a search window (otherwise it shows the menu)", \.menuBarClickOpensWindow,
                      enabled: { $0.showMenuBarIcon }), indent: 18)
        f.add(b.check("…always as a new window", \.newWindowFromMenuBar, enabled: { $0.showMenuBarIcon && $0.menuBarClickOpensWindow }), indent: 36)
        f.add(b.check("Show Epitome in the Dock", \.showDockIcon))
        f.note("With the Dock icon hidden, the menu bar icon stays visible so Epitome can always be reached.", indent: 18)
        f.add(b.check("Opening Epitome again opens a new window instead of the existing one", \.newWindowOnLaunch))
        f.header("Integration")
        f.add(b.check("Open epitome: links (for example epitome:report?sort=date-modified)", \.handleURLScheme))
        f.note("Epitome opens .efu file lists, and adds “Search in Epitome” to the Services menu for folders and selected text.")
        f.add(hstack([button("Install Command Line Tool…") { appDelegate?.installCommandLineTool(nil) },
                      wrappingLabel("Adds the “ep” command to /usr/local/bin.", width: 300)]))
        f.header("Privacy")
        let fda = NSTextField(wrappingLabelWithString: "")
        let refresh = {
            let ok = AppModel.shared.manager.hasFullDiskAccess()
            fda.stringValue = ok ? "✓ Full Disk Access is on — Epitome can index everything." :
                "Full Disk Access is off — protected folders (Mail, Messages, Safari, other users …) are skipped and macOS may ask about Desktop, Documents and Downloads."
            fda.textColor = ok ? .labelColor : .systemOrange
        }
        refresh()
        fda.lineBreakMode = .byWordWrapping
        fda.preferredMaxLayoutWidth = 520
        fda.maximumNumberOfLines = 3
        f.add(fda)
        f.add(hstack([button("Open Privacy & Security Settings…") { Onboarding.openFullDiskAccessSettings() },
                      button("Check Again") { refresh() }]))
        b.custom(refresh: refresh, reset: { _ in })
        return scrolling(f)
    }

    // MARK: UI

    static func ui(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.header("Searching")
        f.add(b.check("Search as you type", \.searchAsYouType, tip: "Off: the search runs when you press Return."))
        f.row("Search delay", [b.int(\.searchDelayMs, range: 0...5000), NSTextField(labelWithString: "milliseconds")])
        f.add(b.check("Clicking into the search box selects its text", \.selectSearchOnMouseClick))
        f.add(b.check("Activating a window moves the focus to the search box", \.focusSearchOnActivate))
        f.header("Results")
        f.add(b.check("Open items with a single click", \.singleClickOpen))
        f.add(b.check("Highlight the row under the mouse pointer", \.showRowMouseover))
        return scrolling(f)
    }

    // MARK: Home

    static func homeBool(_ b: SettingsBinder, _ title: String, _ kp: WritableKeyPath<AppSettings, HomeBool>, _ f: FormView) {
        f.row(title, [b.choice([("Use last value", HomeBool.useLast), ("On", .on), ("Off", .off)], kp)])
    }

    static func home(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.note("What a new search window starts with. “Use last value” restores the state of the window you closed last.")
        f.header("Search")
        f.row("Search", [b.choice([("Custom", false), ("Use last value", true)], \.homeSearchUseLast),
                         b.text(\.homeSearch, placeholder: "(empty: show everything)", width: 240, enabled: { !$0.homeSearchUseLast })])
        homeBool(b, "Match case", \.homeMatchCase, f)
        homeBool(b, "Match whole word", \.homeMatchWholeWord, f)
        homeBool(b, "Match path", \.homeMatchPath, f)
        homeBool(b, "Match diacritics", \.homeMatchDiacritics, f)
        homeBool(b, "Regex", \.homeRegex, f)
        f.header("Results")
        let names = AppModel.shared.filters.current.map(\.name)
        let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        filterPopup.addItems(withTitles: names)
        filterPopup.onAction { c in
            let t = (c as? NSPopUpButton)?.titleOfSelectedItem ?? ""
            b.mutate { $0.homeFilter = t }
        }
        b.custom(refresh: { [weak filterPopup] in
            guard let p = filterPopup else { return }
            let s = b.get()
            let current = s.homeFilter.isEmpty ? (names.first ?? "") : s.homeFilter
            p.selectItem(withTitle: current)
            p.isEnabled = !s.homeFilterUseLast
        }, reset: { $0.homeFilter = AppSettings().homeFilter })
        f.row("Filter", [b.choice([("Use last value", true), ("Custom", false)], \.homeFilterUseLast), filterPopup])
        let sorts = SortKey.allCases.map { ($0.title, $0) }
        f.row("Sort", [b.choice([("Use last value", true), ("Custom", false)], \.homeSortUseLast),
                       b.choice(sorts, \.homeSort, enabled: { !$0.homeSortUseLast }),
                       b.choice([("Ascending", true), ("Descending", false)], \.homeSortAscending, enabled: { !$0.homeSortUseLast })])
        f.row("View", [b.choice([("Use last value", true), ("Custom", false)], \.homeViewUseLast),
                       b.choice([("Details", ViewMode.details), ("Medium Thumbnails", .medium), ("Large Thumbnails", .large),
                                 ("Extra Large Thumbnails", .extraLarge)], \.homeView, enabled: { !$0.homeViewUseLast })])
        f.header("Index")
        let kind = NSPopUpButton(frame: .zero, pullsDown: false)
        kind.addItems(withTitles: ["Local index", "File list", "ETP server"])
        let value = textField(placeholder: "", width: 260)
        func compose() {
            let v = value.stringValue.trimmingCharacters(in: .whitespaces)
            switch kind.indexOfSelectedItem {
            case 1: b.mutate { $0.homeIndex = "filelist:" + v }
            case 2: b.mutate { $0.homeIndex = "etp:" + v }
            default: b.mutate { $0.homeIndex = "" }
            }
        }
        kind.onAction { _ in compose() }
        value.onTextChange { _ in compose() }
        b.custom(refresh: { [weak kind, weak value] in
            guard let kind, let value else { return }
            let h = b.get().homeIndex
            if h.hasPrefix("filelist:") { kind.selectItem(at: 1); if value.currentEditor() == nil { value.stringValue = String(h.dropFirst(9)) } }
            else if h.hasPrefix("etp:") { kind.selectItem(at: 2); if value.currentEditor() == nil { value.stringValue = String(h.dropFirst(4)) } }
            else { kind.selectItem(at: 0); if value.currentEditor() == nil { value.stringValue = "" } }
            value.isEnabled = kind.indexOfSelectedItem != 0
            value.placeholderString = kind.indexOfSelectedItem == 2 ? "user:password@host:port" : "/path/to/list.efu"
        }, reset: { $0.homeIndex = "" })
        f.row("Index", [kind, value])
        return scrolling(f)
    }

    // MARK: Search

    static func search(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.header("Search syntax")
        f.add(b.check("Match the full path when a search term contains a slash", \.syntax.autoPathOnSeparator))
        f.add(b.check("Wildcards must match the whole file name", \.syntax.wildcardsMatchWholeName,
                      tip: "On: *.mp3 finds names ending in .mp3. Off: wildcards can match anywhere in the name."))
        f.add(b.check("A single * also matches across folders in path searches", \.syntax.starCrossesSeparators))
        f.add(b.check("Allow the words AND, OR and NOT as operators", \.syntax.literalOperators))
        f.add(b.check("Allow round brackets ( ) for grouping, like < >", \.syntax.roundBrackets))
        f.add(b.check("Treat a backslash \\ like a slash /", \.syntax.backslashIsSeparator))
        f.add(b.check("Expand ~ to your home folder", \.syntax.expandTilde))
        f.add(b.check("Expand environment variables ($HOME, %HOME%)", \.syntax.expandEnvironmentVariables))
        f.add(b.check("Size units are powers of 1000 (1kb = 1000 bytes)", \.syntax.metricSizes))
        f.row("Operator precedence", [b.choice([("OR before AND (a b|c = a <b|c>)", false), ("AND before OR (a b|c = <a b>|c)", true)], \.syntax.andPrecedence)])
        f.note("Search options such as Match Case live in the Search menu; Home decides what a new window starts with.")
        return scrolling(f)
    }

    // MARK: Results

    static func results(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.add(b.check("Show nothing for an empty search", \.hideEmptySearchResults))
        f.add(b.check("Clear the selection when the search changes", \.clearSelectionOnSearch))
        f.add(b.check("Close the window after opening an item", \.closeWindowOnExecute))
        f.add(b.check("Double-clicking the Path column opens the folder", \.doubleClickPathOpensPath))
        f.add(b.check("Put copied paths in double quotes", \.doubleQuoteCopyAsPath))
        f.add(b.check("Don’t select the extension when renaming", \.doNotSelectExtensionWhenRenaming))
        f.add(b.check("Sort dates newest first on the first click", \.sortDateDescendingFirst))
        f.add(b.check("Sort sizes largest first on the first click", \.sortSizeDescendingFirst))
        f.add(b.check("Sort numbers in names by value (file2 before file10)", \.naturalSort))
        f.row("Folders", [b.choice([("First when ascending, last when descending", FoldersFirst.ascending), ("Always first", .always),
                                    ("Mixed with files", .never)], \.foldersFirst)])
        f.row("Arrow keys at the ends", [b.choice([("Stop at the first and last result", FocusWrap.clamp), ("Wrap around", .wrap),
                                                   ("Wrap through the search box", .wrapWithSearch)], \.resultListFocus)])
        f.row("Ask before opening", [b.int(\.openManyWarningThreshold, range: 2...100000), NSTextField(labelWithString: "or more items")])
        return scrolling(f)
    }

    // MARK: View

    static func view(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.header("Window")
        f.add(b.check("Show the filter bar", \.showFilterBar))
        f.add(b.check("Show the status bar", \.showStatusBar))
        f.add(b.check("Show the column header", \.showHeader))
        f.add(b.check("Show the preview pane", \.showPreview))
        f.row("Keep window on top", [b.choice([("Never", OnTopMode.never), ("Always", .always), ("While searching", .whileSearching)], \.onTop)])
        f.header("Result list")
        f.add(b.check("Alternate row colors", \.alternateRowColor))
        f.add(b.check("Highlight matched text", \.showHighlightedSearchTerms))
        f.add(b.check("Show the full path in the Name column", \.showFullPathInName))
        f.header("Status bar")
        f.add(b.check("Show the selected item", \.showSelectedItemInStatusBar))
        f.row("Selected item format", [b.text(\.statusBarSelectedItemFormat, placeholder: "(default: name, size, date)", width: 260,
                                              enabled: { $0.showSelectedItemInStatusBar })], indent: 18)
        f.note("Tokens: $name $path $fullpath $size $ext $type $dm $dc $da $runcount — for example “$name — $size”.", indent: 18)
        f.add(b.check("Show the result count together with the selection count", \.showResultCountWithSelection))
        f.add(b.check("Show the total size of the results or selection", \.showTotalSizeInStatusBar))
        f.header("Sizes and dates")
        f.row("Size format", [b.choice([("Auto", SizeFormat.auto), ("Bytes", .bytes), ("KB", .kb), ("MB", .mb)], \.sizeFormat)])
        f.row("Size standard", [b.choice([("JEDEC (1 KB = 1024 bytes)", SizeStandard.jedec), ("IEC (1 KiB = 1024 bytes)", .iec),
                                          ("Metric (1 kB = 1000 bytes)", .metric)], \.sizeStandard)])
        f.add(b.check("Round sizes up", \.sizeRoundUp))
        f.row("Date format", [b.text(\.dateFormat, placeholder: "(system short date and time)", width: 220)])
        f.note("Uses Unicode date patterns, e.g. yyyy-MM-dd HH:mm.")
        return scrolling(f)
    }

    // MARK: Context menu

    static let contextTitles: [String: String] = [
        "open-folders": "Open (Folders)", "open-files": "Open (Files)", "open-path": "Show in Finder (Open Path)",
        "explore": "Explore", "explore-path": "Explore Path", "copy-name": "Copy Name", "copy-path": "Copy Path",
        "copy-full-name": "Copy Full Path",
    ]

    static func contextMenu(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.note("Choose when each item appears in the result list’s context menu, and optionally replace what it does with a command.")
        let t = SimpleTable([.init(id: "item", title: "Item", width: 220), .init(id: "vis", title: "Shown", width: 140),
                             .init(id: "cmd", title: "Command", width: 240)])
        t.table.allowsMultipleSelection = false
        t.rowCount = { b.get().contextMenu.count }
        t.value = { row, col in
            let it = b.get().contextMenu[row]
            switch col {
            case "item": return contextTitles[it.id] ?? it.id
            case "vis": return it.visibility == .show ? "Always" : (it.visibility == .shift ? "With Shift held" : "Never")
            default: return it.command.isEmpty ? "(built in)" : it.command
            }
        }
        t.scroll.heightAnchor.constraint(equalToConstant: 210).isActive = true
        t.scroll.widthAnchor.constraint(equalToConstant: 620).isActive = true
        f.add(t.scroll)
        let vis = popup(["Always", "With Shift held", "Never"])
        let cmd = textField(placeholder: "(built-in action)", width: 420)
        let nameField = textField(placeholder: "Menu title", width: 200)
        func selectedIndex() -> Int? {
            let r = t.table.selectedRow
            return r >= 0 && r < b.get().contextMenu.count ? r : nil
        }
        vis.onAction { _ in
            guard let i = selectedIndex() else { return }
            let v: MenuVisibility = [.show, .shift, .hide][vis.indexOfSelectedItem]
            b.mutate { $0.contextMenu[i].visibility = v }
        }
        cmd.onTextChange { tf in
            guard let i = selectedIndex() else { return }
            let s = tf.stringValue
            b.mutate { $0.contextMenu[i].command = s }
        }
        nameField.onTextChange { tf in
            guard let i = selectedIndex(), contextTitles[b.get().contextMenu[i].id] == nil, !tf.stringValue.isEmpty else { return }
            let s = tf.stringValue
            b.mutate { $0.contextMenu[i].id = s }
        }
        func syncEditor() {
            guard let i = selectedIndex() else {
                vis.isEnabled = false; cmd.isEnabled = false; nameField.isEnabled = false
                return
            }
            let it = b.get().contextMenu[i]
            vis.isEnabled = true
            cmd.isEnabled = true
            vis.selectItem(at: it.visibility == .show ? 0 : (it.visibility == .shift ? 1 : 2))
            if cmd.currentEditor() == nil { cmd.stringValue = it.command }
            let custom = contextTitles[it.id] == nil
            nameField.isEnabled = custom
            if nameField.currentEditor() == nil { nameField.stringValue = custom ? it.id : (contextTitles[it.id] ?? "") }
        }
        t.onSelect = { _ in syncEditor() }
        f.row("Shown", [vis])
        f.row("Command", [cmd])
        f.row("Title", [nameField])
        f.add(hstack([
            button("Add Custom Command") {
                b.mutate { $0.contextMenu.append(ContextMenuItem(id: "New Command", visibility: .show, command: "$exec(\"/usr/bin/open\" \"-a\" \"TextEdit\" \"%1\")")) }
                t.reload()
                t.table.selectRowIndexes(IndexSet(integer: b.get().contextMenu.count - 1), byExtendingSelection: false)
            },
            button("Remove") {
                guard let i = selectedIndex(), contextTitles[b.get().contextMenu[i].id] == nil else { NSSound.beep(); return }
                b.mutate { $0.contextMenu.remove(at: i) }
                t.reload()
            },
        ]))
        f.note("""
        Command templates: %1 is the item’s full path. $exec("program" "arg" …) runs a program (an .app path opens the item with that app); \
        $openpath(%1) shows the item in Finder; $parent(%1) and $namepart(%1) give the folder and the name; $$ $( $) are literal characters. \
        A plain command line runs with /bin/sh, e.g. open -a "Visual Studio Code" "%1".
        """)
        b.custom(refresh: { t.reload(); syncEditor() }, reset: { $0.contextMenu = AppSettings.defaultContextMenu })
        return scrolling(f)
    }

    // MARK: Fonts and colors

    static func fonts(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.row("Appearance", [b.choice([("System", ThemeMode.system), ("Light", .light), ("Dark", .dark)], \.theme)])
        f.header("Result list")
        let fam = NSPopUpButton(frame: .zero, pullsDown: false)
        let families = ["System Font"] + NSFontManager.shared.availableFontFamilies.sorted()
        fam.addItems(withTitles: families)
        fam.onAction { c in
            let i = (c as? NSPopUpButton)?.indexOfSelectedItem ?? 0
            let name = i <= 0 ? "" : families[i]
            b.mutate { $0.resultsFontName = name }
        }
        b.custom(refresh: { [weak fam] in
            let n = b.get().resultsFontName
            fam?.selectItem(withTitle: n.isEmpty ? "System Font" : n)
        }, reset: { $0.resultsFontName = "" })
        f.row("Font", [fam])
        f.row("Size", [b.double(\.resultsFontSize, width: 60, placeholder: "default", zeroIsEmpty: true), NSTextField(labelWithString: "points")])
        f.row("Extra row height", [b.double(\.rowHeightPadding, width: 60), NSTextField(labelWithString: "points")])
        f.row("Search box text size", [b.double(\.searchFontSize, width: 60, placeholder: "default", zeroIsEmpty: true), NSTextField(labelWithString: "points")])
        f.header("Highlighted search terms")
        f.add(b.check("Bold", \.highlightBold))
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let useAccent = NSButton(checkboxWithTitle: "Use the accent color", target: nil, action: nil)
        well.onAction { c in
            guard let w = c as? NSColorWell else { return }
            let hex = w.color.hexString
            b.mutate { $0.highlightColor = hex }
        }
        useAccent.onAction { c in
            let on = (c as? NSButton)?.state == .on
            let hex = on ? "" : well.color.hexString
            b.mutate { $0.highlightColor = hex }
        }
        b.custom(refresh: { [weak well, weak useAccent] in
            let hex = b.get().highlightColor
            useAccent?.state = hex.isEmpty ? .on : .off
            well?.isEnabled = !hex.isEmpty
            if let c = NSColor(hex: hex) { well?.color = c } else { well?.color = .controlAccentColor }
        }, reset: { $0.highlightColor = "" })
        f.row("Color", [useAccent, well])
        return scrolling(f)
    }

    // MARK: Keyboard

    static func effectiveShortcut(_ id: String, _ s: AppSettings) -> KeyCombo? {
        if let list = s.shortcuts[id] { return list.first }
        guard let d = MainMenuBuilder.shared.defaultShortcuts[id], !d.0.isEmpty else { return nil }
        return KeyCombo(key: d.0, command: d.1.contains(.command), option: d.1.contains(.option),
                        control: d.1.contains(.control), shift: d.1.contains(.shift))
    }

    static func sameKeys(_ a: KeyCombo?, _ b: KeyCombo?) -> Bool {
        guard let a, let b else { return false }
        return a.key.lowercased() == b.key.lowercased() && a.command == b.command && a.option == b.option &&
            a.control == b.control && a.shift == b.shift
    }

    static func keyboard(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.header("System-wide hotkeys")
        f.note("Work in any app while Epitome is running. Leave empty for none.")
        f.row("New window", [b.hotkey(\.hotkeyNewWindow)])
        f.row("Show window", [b.hotkey(\.hotkeyShowWindow)])
        f.row("Toggle window", [b.hotkey(\.hotkeyToggleWindow)])
        f.header("Menu commands")
        let all = MainMenuBuilder.shared.allCommands().compactMap { $0.identifier?.rawValue }
        var shown = all
        let filter = NSSearchField()
        filter.placeholderString = "Show commands containing"
        filter.translatesAutoresizingMaskIntoConstraints = false
        filter.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let t = SimpleTable([.init(id: "cmd", title: "Command", width: 380), .init(id: "key", title: "Shortcut", width: 150)])
        t.table.allowsMultipleSelection = false
        t.rowCount = { shown.count }
        t.value = { row, col in
            let id = shown[row]
            if col == "cmd" { return id }
            let s = b.get()
            let custom = s.shortcuts[id] != nil
            return (effectiveShortcut(id, s)?.display ?? "") + (custom ? "  •" : "")
        }
        t.tooltip = { row, _ in b.get().shortcuts[shown[row]] != nil ? "Changed from the default" : nil }
        filter.onTextChange { tf in
            let q = tf.stringValue.lowercased()
            shown = q.isEmpty ? all : all.filter { $0.lowercased().contains(q) }
            t.reload()
        }
        t.scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        t.scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        f.add(filter)
        f.add(t.scroll)
        func selectedID() -> String? {
            let r = t.table.selectedRow
            return r >= 0 && r < shown.count ? shown[r] : nil
        }
        let feedback = NSTextField(labelWithString: "")
        feedback.textColor = .secondaryLabelColor
        let recorder = KeyRecorderButton(combo: nil)
        recorder.requireModifier = false
        recorder.placeholder = "Set Shortcut…"
        recorder.onChange = { combo in
            defer { recorder.combo = nil }
            guard let id = selectedID() else { feedback.stringValue = "Select a command first."; return }
            var moved: [String] = []
            b.mutate { s in
                if let c = combo {
                    for other in all where other != id && sameKeys(effectiveShortcut(other, s), c) {
                        s.shortcuts[other] = []
                        moved.append(other)
                    }
                    s.shortcuts[id] = [c]
                } else {
                    s.shortcuts[id] = []
                }
            }
            if let c = combo {
                feedback.stringValue = moved.isEmpty ? "\(id): \(c.display)" : "\(c.display) moved from \(moved.joined(separator: ", ")) to \(id)"
            } else {
                feedback.stringValue = "\(id): no shortcut"
            }
            t.reload()
        }
        f.add(hstack([
            recorder,
            button("Remove Shortcut") {
                guard let id = selectedID() else { return }
                b.mutate { $0.shortcuts[id] = [] }
                t.reload()
            },
            button("Use Default") {
                guard let id = selectedID() else { return }
                b.mutate { $0.shortcuts[id] = nil }
                t.reload()
            },
            button("Reset All") {
                b.mutate { $0.shortcuts = [:] }
                t.reload()
            },
        ]))
        f.add(feedback)
        f.note("Select a command, click Set Shortcut… and press the keys (⌫ removes the shortcut, Esc cancels). A shortcut already used by another command moves to the selected one. Changes take effect when you click Apply or OK. Filters and bookmarks have their own shortcuts in their editors.")
        b.custom(refresh: { t.reload() }, reset: { $0.shortcuts = [:] })
        return scrolling(f)
    }

    // MARK: History

    static func history(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.header("Search history")
        f.add(b.check("Remember searches", \.searchHistoryEnabled,
                      tip: "A search is recorded when you press Return or open, copy or drag one of its results."))
        f.add(b.days("Keep searches for", \.searchHistoryKeepDays, enabled: { $0.searchHistoryEnabled }), indent: 18)
        f.add(b.check("Always show suggestions from the history while typing", \.alwaysShowSearchSuggestions,
                      enabled: { $0.searchHistoryEnabled }), indent: 18)
        f.row("Sort the history by", [b.choice([("Date searched", HistorySort.date), ("Number of uses", .count), ("Search text", .search)], \.searchHistorySort)], indent: 18)
        f.add(hstack([button("Clear Search History") {
            if alert("Clear the search history?", "", style: .warning, buttons: ["Clear", "Cancel"]) == .alertFirstButtonReturn {
                AppModel.shared.history.clear()
            }
        }, button("Show Search History…") { appDelegate?.showSearchHistory(nil) }]), indent: 18)
        f.header("Run history")
        f.add(b.check("Count how often items are opened from Epitome (Run Count and Date Run)", \.runHistoryEnabled))
        f.add(b.days("Keep run counts for", \.runHistoryKeepDays, enabled: { $0.runHistoryEnabled }), indent: 18)
        f.add(hstack([button("Clear Run History") {
            if alert("Clear the run history?", "Run counts and dates are reset for every item.", style: .warning, buttons: ["Clear", "Cancel"]) == .alertFirstButtonReturn {
                AppModel.shared.manager.runHistory.clear()
            }
        }, button("Show Run History…") { appDelegate?.showRunHistory(nil) }]), indent: 18)
        f.note("Pressing Return in the search box selects the result you have opened most often; press Return again to open it.")
        return scrolling(f)
    }

    // MARK: Indexes

    static func indexes(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.header("Database")
        f.row("Location", [b.path(\.databaseLocation, placeholder: "(default: Application Support/Epitome)")])
        f.row("Save every", [b.int(\.saveDatabaseEveryMinutes, range: 0...1440), NSTextField(labelWithString: "minutes (0 = only when quitting)")])
        f.header("Indexed information")
        f.note("Each option costs memory per item; fast sorting keeps a presorted list (4 bytes per item).")
        func pair(_ title: String, _ index: WritableKeyPath<AppSettings, Bool>, _ fast: WritableKeyPath<AppSettings, Bool>?) {
            if let fast {
                f.add(hstack([b.check(title, index), b.check("Fast sort", fast, enabled: { $0[keyPath: index] })], spacing: 24))
            } else {
                f.add(b.check(title, index))
            }
        }
        pair("Index file size", \.indexFileSize, \.fastSizeSort)
        f.add(b.check("Index folder size (total of everything inside)", \.indexFolderSize, enabled: { $0.indexFileSize }), indent: 18)
        pair("Index date modified", \.indexDateModified, \.fastDateModifiedSort)
        pair("Index date created", \.indexDateCreated, \.fastDateCreatedSort)
        pair("Index date accessed", \.indexDateAccessed, \.fastDateAccessedSort)
        pair("Index attributes", \.indexAttributes, \.fastAttributesSort)
        f.add(b.check("Fast path sort", \.fastPathSort))
        f.add(b.check("Fast extension sort", \.fastExtensionSort))
        f.add(b.check("Index recent changes (Date Recently Changed column, rc: search)", \.indexRecentChanges))
        f.add(b.check("Index the contents of packages (inside .app bundles, Photos libraries …)", \.indexPackageContents))
        f.header("Journal")
        f.add(b.check("Keep a journal of index changes", \.journalEnabled))
        f.row("Maximum entries", [b.int(\.journalMaxEntries, range: 100...10_000_000, enabled: { $0.journalEnabled })], indent: 18)
        f.add(hstack([button("Show Index Journal…") { appDelegate?.showJournal(nil) },
                      button("Statistics…") { appDelegate?.showStatistics(nil) },
                      button("Force Rebuild") { appDelegate?.forceRebuild(nil) }]))
        return scrolling(f)
    }

    // MARK: Volumes

    static func volumes(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.header("Automatically include")
        f.add(b.check("Internal volumes (including the startup disk)", \.autoIncludeFixedVolumes))
        f.add(b.check("External and removable drives", \.autoIncludeRemovableVolumes))
        f.add(b.check("Network volumes", \.autoIncludeNetworkVolumes))
        f.add(b.check("Remove volumes that are no longer connected", \.autoRemoveOfflineVolumes))
        f.header("Volumes")
        var mounted = IndexManager.mountedVolumes()
        struct VRow { var info: VolumeInfo?; var setting: VolumeSetting? }
        var rows: [VRow] = []
        func rebuildRows() {
            let s = b.get()
            rows = mounted.map { v in VRow(info: v, setting: s.volumes.first { $0.id == v.id || $0.path == v.path }) }
            for vs in s.volumes where !mounted.contains(where: { $0.id == vs.id || $0.path == vs.path }) {
                rows.append(VRow(info: nil, setting: vs))
            }
        }
        rebuildRows()
        func autoInclude(_ v: VolumeInfo, _ s: AppSettings) -> Bool {
            switch v.kind {
            case .boot, .fixed: return s.autoIncludeFixedVolumes
            case .removable: return s.autoIncludeRemovableVolumes
            case .network: return s.autoIncludeNetworkVolumes
            }
        }
        let t = SimpleTable([.init(id: "inc", title: "Include", width: 54, checkbox: true),
                             .init(id: "name", title: "Volume", width: 150), .init(id: "path", title: "Mount Point", width: 150),
                             .init(id: "fs", title: "Format", width: 60), .init(id: "kind", title: "Type", width: 76),
                             .init(id: "mon", title: "Monitor", width: 56, checkbox: true),
                             .init(id: "only", title: "Include Only (folder;folder)", width: 200, editable: true)])
        t.rowCount = { rows.count }
        t.value = { row, col in
            let r = rows[row]
            switch col {
            case "name": return (r.info?.name ?? r.setting?.name ?? "") + (r.info == nil ? " (offline)" : "")
            case "path": return r.info?.path ?? r.setting?.path ?? ""
            case "fs": return r.info?.fsType ?? ""
            case "kind":
                switch r.info?.kind {
                case .boot?: return "Startup"
                case .fixed?: return "Internal"
                case .removable?: return "External"
                case .network?: return "Network"
                case nil: return "—"
                }
            case "only": return r.setting?.includeOnly ?? ""
            default: return ""
            }
        }
        t.boolValue = { row, col in
            let r = rows[row]
            let s = b.get()
            if col == "inc" { return r.setting?.include ?? (r.info.map { autoInclude($0, s) } ?? false) }
            return r.setting?.monitor ?? true
        }
        func upsert(_ row: Int, _ body: (inout VolumeSetting) -> Void) {
            let r = rows[row]
            let s = b.get()
            var vs = r.setting ?? VolumeSetting(id: r.info?.id ?? "", path: r.info?.path ?? "", name: r.info?.name ?? "",
                                                include: r.info.map { autoInclude($0, s) } ?? false, includeOnly: "", monitor: true)
            body(&vs)
            b.mutate { st in
                if let i = st.volumes.firstIndex(where: { $0.id == vs.id || $0.path == vs.path }) { st.volumes[i] = vs } else { st.volumes.append(vs) }
            }
            rebuildRows()
        }
        t.setBool = { row, col, on in upsert(row) { if col == "inc" { $0.include = on } else { $0.monitor = on } } }
        t.setValue = { row, _, text in upsert(row) { $0.includeOnly = text } }
        t.scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        t.scroll.widthAnchor.constraint(equalToConstant: 600).isActive = true
        f.add(t.scroll)
        f.add(hstack([
            button("Refresh") { mounted = IndexManager.mountedVolumes(); rebuildRows(); t.reload() },
            button("Forget Selected Volume Settings") {
                let ids = t.selected.compactMap { rows[$0].setting?.id }
                b.mutate { s in s.volumes.removeAll { ids.contains($0.id) } }
                rebuildRows()
                t.reload()
            },
        ]))
        f.note("Epitome reads each volume once, then follows changes through FSEvents. A volume that comes back online is caught up from where it left off. Include Only limits a volume to some folders.")
        b.custom(refresh: { rebuildRows(); t.reload() }, reset: { $0.volumes = [] })
        return scrolling(f)
    }

    // MARK: Folders

    static func scheduleText(_ s: RescanSchedule) -> String {
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        switch s {
        case .never: return "Never"
        case .every(let m): return m % 60 == 0 ? "Every \(m / 60) hour\(m == 60 ? "" : "s")" : "Every \(m) minutes"
        case .daily(let h, let wd):
            if let d = wd, d >= 1, d <= 7 { return "\(days[d - 1])s at \(h):00" }
            return "Daily at \(h):00"
        }
    }

    static func folders(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.note("Folders outside the indexed volumes (for example on network shares). Monitored folders update live; a schedule rescans them as a safety net.")
        let t = SimpleTable([.init(id: "path", title: "Folder", width: 360), .init(id: "mon", title: "Monitor", width: 60, checkbox: true),
                             .init(id: "sched", title: "Rescan", width: 160)])
        t.table.allowsMultipleSelection = false
        t.rowCount = { b.get().folders.count }
        t.value = { row, col in
            let fs = b.get().folders[row]
            return col == "path" ? fs.path : scheduleText(fs.schedule)
        }
        t.boolValue = { row, _ in b.get().folders[row].monitor }
        t.setBool = { row, _, on in b.mutate { $0.folders[row].monitor = on } }
        t.scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        t.scroll.widthAnchor.constraint(equalToConstant: 600).isActive = true
        f.add(t.scroll)
        let kind = popup(["Never", "Every day", "Every week", "At an interval"])
        let hour = popup((0..<24).map { String(format: "%02d:00", $0) })
        let weekday = popup(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"])
        let minutes = textField(width: 60)
        minutes.alignment = .right
        func sel() -> Int? {
            let r = t.table.selectedRow
            return r >= 0 && r < b.get().folders.count ? r : nil
        }
        func write() {
            guard let i = sel() else { return }
            let s: RescanSchedule
            switch kind.indexOfSelectedItem {
            case 1: s = .daily(hour: hour.indexOfSelectedItem, weekday: nil)
            case 2: s = .daily(hour: hour.indexOfSelectedItem, weekday: weekday.indexOfSelectedItem + 1)
            case 3: s = .every(minutes: Swift.max(5, Int(minutes.stringValue) ?? 60))
            default: s = .never
            }
            b.mutate { $0.folders[i].schedule = s }
            t.reload()
            t.table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        for p in [kind, hour, weekday] { p.onAction { _ in write() } }
        minutes.onTextChange { _ in write() }
        func syncEditor() {
            guard let i = sel() else { for c in [kind, hour, weekday, minutes] as [NSControl] { c.isEnabled = false }; return }
            kind.isEnabled = true
            switch b.get().folders[i].schedule {
            case .never: kind.selectItem(at: 0)
            case .daily(let h, let wd):
                kind.selectItem(at: wd == nil ? 1 : 2)
                hour.selectItem(at: Swift.max(0, Swift.min(23, h)))
                if let d = wd { weekday.selectItem(at: Swift.max(0, Swift.min(6, d - 1))) }
            case .every(let m):
                kind.selectItem(at: 3)
                if minutes.currentEditor() == nil { minutes.stringValue = String(m) }
            }
            hour.isEnabled = kind.indexOfSelectedItem == 1 || kind.indexOfSelectedItem == 2
            weekday.isEnabled = kind.indexOfSelectedItem == 2
            minutes.isEnabled = kind.indexOfSelectedItem == 3
        }
        t.onSelect = { _ in syncEditor() }
        f.row("Rescan", [kind, hour, weekday, minutes, NSTextField(labelWithString: "minutes")])
        f.add(hstack([
            button("Add Folder…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true
                p.canChooseFiles = false
                p.allowsMultipleSelection = true
                guard p.runModal() == .OK else { return }
                b.mutate { s in
                    for u in p.urls where !s.folders.contains(where: { $0.path == u.path }) { s.folders.append(FolderSourceSetting(path: u.path)) }
                }
                t.reload()
            },
            button("Remove") {
                guard let i = sel() else { return }
                b.mutate { $0.folders.remove(at: i) }
                t.reload()
                syncEditor()
            },
            button("Rescan Now") {
                guard let i = sel() else { return }
                AppModel.shared.manager.rescan(path: b.get().folders[i].path)
            },
            button("Rescan All Now") { AppModel.shared.manager.rescanAllFolders() },
        ]))
        b.custom(refresh: { t.reload(); syncEditor() }, reset: { $0.folders = [] })
        return scrolling(f)
    }

    // MARK: File lists

    static func fileLists(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.note("File lists (.efu) added here are searched together with your volumes. Monitored lists are reloaded when the file changes.")
        let t = SimpleTable([.init(id: "path", title: "File List", width: 460), .init(id: "mon", title: "Monitor", width: 60, checkbox: true)])
        t.rowCount = { b.get().fileLists.count }
        t.value = { row, _ in b.get().fileLists[row].path }
        t.boolValue = { row, _ in b.get().fileLists[row].monitor }
        t.setBool = { row, _, on in b.mutate { $0.fileLists[row].monitor = on } }
        t.scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        t.scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        f.add(t.scroll)
        f.add(hstack([
            button("Add…") {
                let p = NSOpenPanel()
                p.allowsMultipleSelection = true
                p.allowedContentTypes = [UTType(filenameExtension: "efu") ?? .data, .commaSeparatedText, .plainText]
                p.allowsOtherFileTypes = true
                guard p.runModal() == .OK else { return }
                b.mutate { s in
                    for u in p.urls where !s.fileLists.contains(where: { $0.path == u.path }) { s.fileLists.append(FileListSourceSetting(path: u.path)) }
                }
                t.reload()
            },
            button("Remove") {
                let rows = t.selected
                b.mutate { s in for i in rows.sorted(by: >) where i < s.fileLists.count { s.fileLists.remove(at: i) } }
                t.reload()
            },
            button("File List Editor…") { appDelegate?.showFileListEditor(nil) },
            button("Create File List from Folder…") { appDelegate?.createFileListFromFolder(nil) },
        ]))
        b.custom(refresh: { t.reload() }, reset: { $0.fileLists = [] })
        return scrolling(f)
    }

    // MARK: Exclude

    static func exclude(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.add(b.check("Exclude hidden files and folders", \.excludeHidden))
        f.add(b.check("Exclude system files (macOS system locations and items flagged as system)", \.excludeSystem))
        f.add(b.check("Use the exclude list below", \.excludeListEnabled))
        f.header("Excluded folders")
        let t = SimpleTable([.init(id: "path", title: "Folder or pattern", width: 520, editable: true)])
        t.rowCount = { b.get().excludeFolders.count }
        t.value = { row, _ in b.get().excludeFolders[row] }
        t.setValue = { row, _, v in b.mutate { if row < $0.excludeFolders.count { $0.excludeFolders[row] = v } } }
        t.scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        t.scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        f.add(t.scroll)
        f.add(hstack([
            button("Add Folder…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true
                p.canChooseFiles = false
                p.allowsMultipleSelection = true
                guard p.runModal() == .OK else { return }
                b.mutate { s in for u in p.urls where !s.excludeFolders.contains(u.path) { s.excludeFolders.append(u.path) } }
                t.reload()
            },
            button("Add Pattern") {
                b.mutate { $0.excludeFolders.append("node_modules") }
                t.reload()
                let r = b.get().excludeFolders.count - 1
                t.table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
                t.table.editColumn(0, row: r, with: nil, select: true)
            },
            button("Remove") {
                let rows = t.selected
                b.mutate { s in for i in rows.sorted(by: >) where i < s.excludeFolders.count { s.excludeFolders.remove(at: i) } }
                t.reload()
            },
        ]))
        f.note("An absolute path excludes that folder; a name or wildcard (node_modules, .git, *.photoslibrary) excludes every folder with a matching name.")
        f.header("Files")
        f.row("Include only files", [b.text(\.includeOnlyFiles, placeholder: "e.g. *.pdf;*.docx (empty = all)", width: 300, enabled: { $0.excludeListEnabled })])
        f.row("Exclude files", [b.text(\.excludeFiles, placeholder: "e.g. *.tmp;.DS_Store", width: 300, enabled: { $0.excludeListEnabled })])
        f.note("Semicolon-separated wildcards. Changes take effect with a rescan of the index.")
        b.custom(refresh: { t.reload() }, reset: { $0.excludeFolders = [] })
        return scrolling(f)
    }

    // MARK: Servers

    static func serverStatus(_ running: @escaping () -> (Bool, UInt16)) -> (NSTextField, () -> Void) {
        let l = NSTextField(labelWithString: "")
        let refresh = {
            let (r, p) = running()
            l.stringValue = r ? "● Running on port \(p)" : "○ Not running"
            l.textColor = r ? .systemGreen : .secondaryLabelColor
        }
        refresh()
        return (l, refresh)
    }

    static func etpServer(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.note("Lets other copies of Epitome (Tools → Connect to ETP Server) and FTP clients search this Mac’s index.")
        f.add(b.check("Enable ETP/FTP server", \.etpEnabled))
        let (st, refresh) = serverStatus { (appDelegate?.etp.isRunning ?? false, appDelegate?.etp.boundPort ?? 0) }
        f.add(st, indent: 18)
        f.row("Listen on interfaces", [b.text(\.etpBind, placeholder: "(all) e.g. 127.0.0.1", width: 200)])
        f.row("Port", [b.int(\.etpPort, range: 1...65535)])
        f.row("Username", [b.text(\.etpUsername, placeholder: "(anyone)", width: 200)])
        f.row("Password", [b.text(\.etpPassword, width: 200, secure: true)])
        f.row("Welcome message", [b.text(\.etpWelcome, placeholder: "(default)", width: 300)])
        f.add(b.check("Allow file downloads", \.etpAllowDownload))
        f.add(b.check("Log connections and commands", \.etpLogging))
        f.row("Maximum log size", [b.int(\.etpLogMaxKB, range: 16...1_000_000, enabled: { $0.etpLogging }), NSTextField(labelWithString: "KB")])
        f.add(button("Show Log in Finder") {
            FileActions.reveal([AppModel.shared.supportDir.appendingPathComponent("ETP Server.log").path])
        })
        b.custom(refresh: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() } }, reset: { _ in })
        return scrolling(f)
    }

    static func httpServer(_ b: SettingsBinder) -> NSView {
        let f = FormView()
        f.note("Search this Mac from a web browser on your network. Results link to the files when downloads are allowed.")
        f.add(b.check("Enable HTTP server", \.httpEnabled))
        let (st, refresh) = serverStatus { (appDelegate?.http.isRunning ?? false, appDelegate?.http.boundPort ?? 0) }
        f.add(hstack([st, button("Open in Browser") {
            let port = AppModel.shared.settings.httpPort
            if let u = URL(string: "http://localhost:\(port)/") { NSWorkspace.shared.open(u) }
        }]), indent: 18)
        f.row("Listen on interfaces", [b.text(\.httpBind, placeholder: "(all) e.g. 127.0.0.1", width: 200)])
        f.row("Port", [b.int(\.httpPort, range: 1...65535)])
        f.row("Username", [b.text(\.httpUsername, placeholder: "(no login)", width: 200)])
        f.row("Password", [b.text(\.httpPassword, width: 200, secure: true)])
        f.add(b.check("Allow file downloads", \.httpAllowDownload))
        f.row("Serve pages from", [b.path(\.httpServePagesFrom, placeholder: "(built-in pages)", width: 260)])
        f.row("Default page", [b.text(\.httpDefaultPage, placeholder: "(built-in search page)", width: 200)])
        f.add(b.check("Log requests", \.httpLogging))
        f.row("Maximum log size", [b.int(\.httpLogMaxKB, range: 16...1_000_000, enabled: { $0.httpLogging }), NSTextField(labelWithString: "KB")])
        f.add(button("Show Log in Finder") {
            FileActions.reveal([AppModel.shared.supportDir.appendingPathComponent("HTTP Server.log").path])
        })
        f.note("Add ?json=1 to a search URL for machine-readable results, e.g. http://host:port/?search=report&json=1&count=20.")
        b.custom(refresh: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() } }, reset: { _ in })
        return scrolling(f)
    }

    // MARK: Advanced

    static func advanced(_ b: SettingsBinder) -> NSView {
        let root = NSView()
        let filter = NSSearchField()
        filter.placeholderString = "Show settings containing"
        let onlyModified = NSButton(checkboxWithTitle: "Show only changed settings", target: nil, action: nil)
        let defaults = dict(AppSettings())
        var keys: [String] = []
        var current: [String: Any] = [:]
        func reloadKeys() {
            current = dict(b.get())
            let q = filter.stringValue.lowercased()
            keys = current.keys.sorted().filter { k in
                (q.isEmpty || k.lowercased().contains(q)) &&
                    (onlyModified.state == .off || !same(current[k], defaults[k]))
            }
        }
        let t = SimpleTable([.init(id: "key", title: "Setting", width: 260), .init(id: "value", title: "Value", width: 320, editable: true)])
        t.table.allowsMultipleSelection = false
        t.rowCount = { keys.count }
        t.value = { row, col in
            let k = keys[row]
            if col == "key" { return k + (same(current[k], defaults[k]) ? "" : "  •") }
            return show(current[k])
        }
        t.setValue = { row, _, text in
            let k = keys[row]
            guard isScalar(current[k]) else { NSSound.beep(); t.reload(); return }
            var s = b.get()
            if s.setValue(k, text) { b.mutate { $0 = s } } else { NSSound.beep() }
            reloadKeys()
            t.reload()
        }
        filter.onTextChange { _ in reloadKeys(); t.reload() }
        onlyModified.onAction { _ in reloadKeys(); t.reload() }
        let reset = button("Reset to Default") {
            let r = t.table.selectedRow
            guard r >= 0, r < keys.count else { return }
            let k = keys[r]
            guard let dv = defaults[k], var d = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(b.get())) as? [String: Any] else { return }
            d[k] = dv
            if let data = try? JSONSerialization.data(withJSONObject: d), let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
                b.mutate { $0 = s }
            }
            reloadKeys()
            t.reload()
        }
        let note = wrappingLabel("Every setting by its stored name. Double-click a value to edit it (true/false, numbers, text). Lists are edited on their own pages. The same names work in the search box as commands: >name shows a value, >name=value changes it.", width: 600)
        let top = hstack([filter, onlyModified, reset])
        for v in [top, t.scroll, note] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        filter.widthAnchor.constraint(equalToConstant: 240).isActive = true
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            t.scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            t.scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            t.scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            note.topAnchor.constraint(equalTo: t.scroll.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        b.custom(refresh: { reloadKeys(); t.reload() }, reset: { _ in })
        reloadKeys()
        return root
    }

    static func dict(_ s: AppSettings) -> [String: Any] {
        guard let d = try? JSONEncoder().encode(s), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    static func isScalar(_ v: Any?) -> Bool { v is NSNumber || v is String }

    static func show(_ v: Any?) -> String {
        guard let v else { return "" }
        if let n = v as? NSNumber {
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let s = v as? String { return s }
        if let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed]), let s = String(data: d, encoding: .utf8) {
            return s
        }
        return "\(v)"
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool { show(a) == show(b) }
}
