import AppKit
import EpitomeCore
import Quartz
import UniformTypeIdentifiers

/// Menu commands, context menu, keyboard handling and file operations for a search window.
extension SearchWindowController: NSMenuItemValidation, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    // MARK: - Keyboard in the result list

    func handleResultsKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = e.charactersIgnoringModifiers ?? ""
        switch e.keyCode {
        case 36, 76: // return / enter
            if mods == .command { revealSelection(nil); return true }
            if mods == .option { showProperties(nil); return true }
            if mods.isEmpty { openSelection(nil); return true }
        case 120: // F2
            renameSelection(nil)
            return true
        case 49: // space
            if mods.isEmpty { quickLook(nil); return true }
        case 51, 117: // delete / forward delete
            if mods == [.command, .option] || mods == .shift { deletePermanently(nil); return true }
            if mods == .command || e.keyCode == 117 { moveToTrash(nil); return true }
            if mods.isEmpty {
                if !jumpText.isEmpty { jumpText.removeLast(); jumpTime = Date(); statusBar.update(); return true }
                moveToTrash(nil)
                return true
            }
        case 48: // tab
            focusSearch(nil)
            return true
        case 53: // esc
            window?.performClose(nil)
            return true
        case 126: // up arrow: wrap to the search box
            if mods.isEmpty && focusedRow <= 0 && model.settings.resultListFocus == .wrapWithSearch { focusSearch(nil); return true }
            if mods.isEmpty && focusedRow <= 0 && model.settings.resultListFocus == .wrap && results.count > 0 {
                table.selectRowIndexes(IndexSet(integer: results.count - 1), byExtendingSelection: false)
                table.scrollRowToVisible(results.count - 1)
                return true
            }
        case 125: // down
            if mods.isEmpty && focusedRow == results.count - 1 {
                if model.settings.resultListFocus == .wrapWithSearch { focusSearch(nil); return true }
                if model.settings.resultListFocus == .wrap {
                    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    table.scrollRowToVisible(0)
                    return true
                }
            }
        default:
            break
        }
        // jump-to: printable characters
        if mods.subtracting(.shift).isEmpty, let ch = e.characters, !ch.isEmpty,
           ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            if Date().timeIntervalSince(jumpTime) > 1.0 { jumpText = "" }
            jumpText += ch
            jumpTime = Date()
            jumpTo(jumpText)
            statusBar.update()
            return true
        }
        _ = chars
        return false
    }

    func jumpTo(_ prefix: String) {
        let n = results.count
        guard n > 0 else { return }
        let start = Swift.max(0, focusedRow) + (prefix.count == 1 ? 1 : 0)
        let limit = Swift.min(n, 500_000)
        for k in 0..<limit {
            let i = (start + k) % n
            if let r = results.row(i), r.name.range(of: prefix, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil {
                selectRow(i)
                return
            }
        }
        NSSound.beep()
    }

    func selectRow(_ i: Int) {
        if viewMode != .details, let t = thumbs { t.select(i); return }
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    // MARK: - Opening

    func ensureLocal(_ i: Int) -> String? {
        guard let r = results.row(i) else { return nil }
        if case .remote(let client) = source {
            if FileManager.default.fileExists(atPath: r.fullPath) { return r.fullPath }
            if r.isDir { return nil }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Epitome-ETP", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let dest = tmp.appendingPathComponent(r.name)
            statusBar.flash("Downloading \(r.name)…")
            return client.download(r.fullPath, to: dest) ? dest.path : nil
        }
        return r.fullPath
    }

    @objc func openSelection(_ sender: Any?) {
        let rows = selectedRows
        guard !rows.isEmpty else { return }
        if rows.count >= model.settings.openManyWarningThreshold {
            if alert("Open \(rows.count) items?", "This opens every selected item.", style: .warning, buttons: ["Open", "Cancel"]) != .alertFirstButtonReturn { return }
        }
        var paths: [String] = []
        for i in rows { if let p = ensureLocal(i) { paths.append(p) } }
        let s = model.settings
        let files = s.contextMenu.first { $0.id == "open-files" }?.command ?? ""
        let folders = s.contextMenu.first { $0.id == "open-folders" }?.command ?? ""
        for p in paths {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            let isPkg = (p as NSString).pathExtension.lowercased() == "app"
            let tmpl = isDir.boolValue && !isPkg ? folders : files
            if !tmpl.isEmpty { FileActions.runTemplate(tmpl, path: p) } else { FileActions.open([p]) }
            model.manager.runHistory.recordRun(path: p)
        }
        recordSearchHistory()
        if s.closeWindowOnExecute { window?.performClose(nil) }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(0..<table.numberOfColumns))
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let paths = selectedRows.compactMap { ensureLocal($0) }
        FileActions.open(paths, with: app)
        for p in paths { model.manager.runHistory.recordRun(path: p) }
        recordSearchHistory()
    }

    @objc func openWithOther(_ sender: Any?) {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.prompt = "Open"
        guard p.runModal() == .OK, let app = p.url else { return }
        FileActions.open(selectedRows.compactMap { ensureLocal($0) }, with: app)
    }

    @objc func revealSelection(_ sender: Any?) {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        let tmpl = model.settings.contextMenu.first { $0.id == "open-path" }?.command ?? ""
        if !tmpl.isEmpty { for p in paths { FileActions.runTemplate(tmpl, path: p) } } else { FileActions.reveal(paths) }
        recordSearchHistory()
    }

    /// Explore: open the folder itself (or the file's folder) in Finder.
    @objc func exploreSelection(_ sender: Any?) {
        for i in selectedRows {
            guard let r = results.row(i) else { continue }
            let tmpl = model.settings.contextMenu.first { $0.id == "explore" }?.command ?? ""
            if !tmpl.isEmpty { FileActions.runTemplate(tmpl, path: r.fullPath); continue }
            FileActions.openFolder(r.isDir ? r.fullPath : r.parent)
        }
    }

    @objc func explorePath(_ sender: Any?) {
        for i in selectedRows {
            guard let r = results.row(i) else { continue }
            let tmpl = model.settings.contextMenu.first { $0.id == "explore-path" }?.command ?? ""
            if !tmpl.isEmpty { FileActions.runTemplate(tmpl, path: r.fullPath); continue }
            FileActions.openFolder(r.parent.isEmpty ? "/" : r.parent)
        }
    }

    @objc func openMostRun(_ sender: Any?) {
        focusResultsSelectingMostRun()
        openSelection(nil)
    }

    @objc func openLastRun(_ sender: Any?) {
        let runs = model.manager.runHistory.all().sorted { $0.value.last > $1.value.last }
        guard let p = runs.first?.key else { NSSound.beep(); return }
        FileActions.open([p])
        model.manager.runHistory.recordRun(path: p)
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        FileActions.copyToPasteboard(files: paths)
        recordSearchHistory()
    }

    @objc func copyFullPath(_ sender: Any?) {
        let s = model.settings
        let paths = selectedRows.compactMap { i -> String? in
            guard let r = results.row(i) else { return nil }
            let p = r.fullPath
            return s.doubleQuoteCopyAsPath ? "\"\(p)\"" : p
        }
        guard !paths.isEmpty else { return }
        FileActions.copyText(paths.joined(separator: "\n"))
        recordSearchHistory()
    }

    @objc func copyName(_ sender: Any?) {
        let names = selectedRows.compactMap { results.row($0)?.name }
        guard !names.isEmpty else { return }
        FileActions.copyText(names.joined(separator: "\n"))
    }

    @objc func copyPath(_ sender: Any?) {
        let s = model.settings
        let paths = selectedRows.compactMap { i -> String? in
            guard let r = results.row(i) else { return nil }
            return s.doubleQuoteCopyAsPath ? "\"\(r.parent)\"" : r.parent
        }
        guard !paths.isEmpty else { return }
        FileActions.copyText(paths.joined(separator: "\n"))
    }

    @objc func cut(_ sender: Any?) { copy(sender) }

    @objc func paste(_ sender: Any?) {
        guard window?.firstResponder === table || window?.firstResponder === thumbs?.collection else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
            return
        }
        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, let r = results.row(focusedRow) else { return }
        let dest = r.isDir ? r.fullPath : r.parent
        let failed = FileActions.copy(urls.map(\.path), toFolder: dest, move: false)
        if !failed.isEmpty { _ = alert("Some items could not be pasted", failed.joined(separator: "\n")) }
    }

    override func selectAll(_ sender: Any?) {
        if window?.firstResponder === table { table.selectAll(sender); return }
        if let t = thumbs, window?.firstResponder === t.collection { t.collection.selectAll(sender); return }
        searchField.currentEditor()?.selectAll(sender)
    }

    @objc func invertSelection(_ sender: Any?) {
        let all = IndexSet(0..<results.count)
        table.selectRowIndexes(all.subtracting(table.selectedRowIndexes), byExtendingSelection: false)
    }

    @objc func copyToFolder(_ sender: Any?) { transferSelection(move: false) }
    @objc func moveToFolder(_ sender: Any?) { transferSelection(move: true) }

    func transferSelection(move: Bool) {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = move ? "Move" : "Copy"
        guard p.runModal() == .OK, let dir = p.url else { return }
        let failed = FileActions.copy(paths, toFolder: dir.path, move: move)
        if !failed.isEmpty { _ = alert("Some items could not be \(move ? "moved" : "copied")", failed.joined(separator: "\n")) }
    }

    // MARK: - Delete / rename

    @objc func moveToTrash(_ sender: Any?) {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        let failed = FileActions.trash(paths)
        if !failed.isEmpty { _ = alert("Could not move to Trash", failed.prefix(20).joined(separator: "\n")) }
        model.manager.flushEvents()
    }

    @objc func deletePermanently(_ sender: Any?) {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        let what = paths.count == 1 ? "“\((paths[0] as NSString).lastPathComponent)”" : "\(paths.count) items"
        guard alert("Delete \(what) immediately?", "You can’t undo this action.", style: .critical, buttons: ["Delete", "Cancel"]) == .alertFirstButtonReturn else { return }
        let failed = FileActions.deletePermanently(paths)
        if !failed.isEmpty { _ = alert("Could not delete", failed.prefix(20).joined(separator: "\n")) }
        model.manager.flushEvents()
    }

    @objc func renameSelection(_ sender: Any?) {
        let rows = selectedRows
        if rows.count > 1 {
            let paths = rows.compactMap { results.path($0) }
            RenameDialog.show(paths: paths, over: window)
            return
        }
        guard let row = rows.first, viewMode == .details, results.row(row) != nil else { return }
        let col = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard col >= 0, let cell = table.view(atColumn: col, row: row, makeIfNecessary: true) as? ResultCellView else { return }
        let r = results.row(row)!
        cell.text.stringValue = r.name
        cell.text.isEditable = true
        cell.text.delegate = self
        cell.text.tag = row
        window?.makeFirstResponder(cell.text)
        if let ed = cell.text.currentEditor() {
            let ns = r.name as NSString
            let ext = ns.pathExtension
            if model.settings.doNotSelectExtensionWhenRenaming && !ext.isEmpty && !r.isDir {
                ed.selectedRange = NSRange(location: 0, length: ns.length - ext.count - 1)
            } else {
                ed.selectAll(nil)
            }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== searchField, field.isEditable else { return }
        field.isEditable = false
        let row = field.tag
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        guard let r = results.row(row) else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        defer {
            window?.makeFirstResponder(table)
            table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(0..<table.numberOfColumns))
        }
        guard movement != NSTextMovement.cancel.rawValue, !newName.isEmpty, newName != r.name, !newName.contains("/") else { return }
        do {
            let dst = try FileActions.rename(r.fullPath, to: newName)
            model.manager.runHistory.renamed(from: r.fullPath, to: dst)
            model.manager.flushEvents()
        } catch {
            NSApp.presentError(error)
        }
    }

    // MARK: - Info

    @objc func showProperties(_ sender: Any?) {
        let rows = selectedRows
        guard !rows.isEmpty else { return }
        PropertiesPanel.show(rows.prefix(20).compactMap { results.row($0) }, model: results, over: window)
    }

    @objc func finderGetInfo(_ sender: Any?) {
        FileActions.finderGetInfo(selectedPaths)
    }

    @objc func setRunCount(_ sender: Any?) {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Set Run Count"
        a.informativeText = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) items"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        f.stringValue = String(model.manager.runHistory.record(for: paths[0])?.count ?? 0)
        a.accessoryView = f
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, let n = Int(f.stringValue) else { return }
        for p in paths { model.manager.runHistory.set(path: p, count: n) }
        table.reloadData()
    }

    @objc func readExtendedInformation(_ sender: Any?) {
        table.reloadData()
        statusBar.flash("Refreshed")
    }

    @objc func refresh(_ sender: Any?) {
        ThumbnailCache.shared.clear()
        runSearch(immediate: true, refresh: true)
    }

    @objc func share(_ sender: NSMenuItem) {
        guard let svc = sender.representedObject as? NSSharingService else { return }
        svc.perform(withItems: selectedPaths.map { URL(fileURLWithPath: $0) })
    }

    // MARK: - Quick Look

    @objc func quickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedRows.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let rows = Array(selectedRows)
        guard index < rows.count, let p = results.path(rows[index]) else { return nil }
        return URL(fileURLWithPath: p) as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown { table.keyDown(with: event); return true }
        return false
    }

    // MARK: - Context menu

    func contextMenu(emptySpace: Bool) -> NSMenu {
        let m = NSMenu()
        if emptySpace || selectedRows.isEmpty {
            let sortMenu = NSMenu()
            for c in Column.allCases where c != .fullPath {
                let i = NSMenuItem(title: c.title, action: #selector(sortByMenu(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = c.sortKey.rawValue
                i.state = sortKey == c.sortKey ? .on : .off
                sortMenu.addItem(i)
            }
            let si = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            si.submenu = sortMenu
            m.addItem(si)
            let viewMenu = NSMenu()
            for (t, v) in [("Details", ViewMode.details), ("Medium Thumbnails", .medium), ("Large Thumbnails", .large), ("Extra Large Thumbnails", .extraLarge)] {
                let i = NSMenuItem(title: t, action: #selector(viewModeMenu(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = v.rawValue
                i.state = viewMode == v ? .on : .off
                viewMenu.addItem(i)
            }
            let vi = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            vi.submenu = viewMenu
            m.addItem(vi)
            m.addItem(.separator())
            m.addItem(withTitle: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "").target = self
            return m
        }
        let shift = NSEvent.modifierFlags.contains(.shift)
        let s = model.settings
        func visible(_ id: String) -> Bool {
            guard let it = s.contextMenu.first(where: { $0.id == id }) else { return true }
            switch it.visibility {
            case .show: return true
            case .shift: return shift
            case .hide: return false
            }
        }
        func add(_ title: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            m.addItem(i)
        }
        let rows = selectedRows
        let anyFolder = rows.contains { results.row($0)?.isDir == true }
        let anyFile = rows.contains { results.row($0)?.isDir == false }
        if (anyFile && visible("open-files")) || (anyFolder && visible("open-folders")) { add("Open", #selector(openSelection(_:))) }
        // Open With
        if let first = rows.first, let p = results.path(first), anyFile {
            let sub = NSMenu()
            let url = URL(fileURLWithPath: p)
            let def = NSWorkspace.shared.urlForApplication(toOpen: url)
            var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            if let d = def { apps.removeAll { $0 == d }; apps.insert(d, at: 0) }
            for app in apps.prefix(24) {
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                let i = NSMenuItem(title: app == def ? "\(name) (default)" : name, action: #selector(openWithApp(_:)), keyEquivalent: "")
                i.representedObject = app
                i.target = self
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                i.image = icon
                sub.addItem(i)
                if app == def && apps.count > 1 { sub.addItem(.separator()) }
            }
            sub.addItem(.separator())
            sub.addItem(withTitle: "Other…", action: #selector(openWithOther(_:)), keyEquivalent: "").target = self
            let ow = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            ow.submenu = sub
            m.addItem(ow)
        }
        if visible("open-path") { add("Show in Finder", #selector(revealSelection(_:)), "\r", .command) }
        if visible("explore") { add("Explore", #selector(exploreSelection(_:))) }
        if visible("explore-path") { add("Explore Path", #selector(explorePath(_:))) }
        add("Quick Look", #selector(quickLook(_:)), " ", [])
        m.addItem(.separator())
        add("Copy", #selector(copy(_:)), "c", .command)
        if visible("copy-name") { add("Copy Name", #selector(copyName(_:))) }
        if visible("copy-path") { add("Copy Path", #selector(copyPath(_:))) }
        if visible("copy-full-name") { add("Copy Full Path", #selector(copyFullPath(_:)), "c", [.command, .option]) }
        add("Copy to Folder…", #selector(copyToFolder(_:)))
        add("Move to Folder…", #selector(moveToFolder(_:)))
        m.addItem(.separator())
        add(rows.count > 1 ? "Rename…" : "Rename", #selector(renameSelection(_:)))
        add("Move to Trash", #selector(moveToTrash(_:)), "\u{8}", .command)
        if shift { add("Delete Immediately…", #selector(deletePermanently(_:)), "\u{8}", [.command, .option]) }
        m.addItem(.separator())
        add("Get Info", #selector(showProperties(_:)), "i", .command)
        add("Show Finder Info", #selector(finderGetInfo(_:)))
        add("Set Run Count…", #selector(setRunCount(_:)))
        // Share
        let items = selectedPaths.prefix(50).map { URL(fileURLWithPath: $0) }
        let services = NSSharingService.sharingServices(forItems: items)
        if !services.isEmpty {
            let sub = NSMenu()
            for svc in services {
                let i = NSMenuItem(title: svc.menuItemTitle, action: #selector(share(_:)), keyEquivalent: "")
                i.image = svc.image
                i.representedObject = svc
                i.target = self
                sub.addItem(i)
            }
            let si = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
            si.submenu = sub
            m.addItem(si)
        }
        // Custom commands with templates beyond the built-ins appear here too.
        for it in s.contextMenu where !["open-folders", "open-files", "open-path", "explore", "explore-path", "copy-name", "copy-path", "copy-full-name"].contains(it.id) && visible(it.id) {
            let i = NSMenuItem(title: it.id, action: #selector(runCustomCommand(_:)), keyEquivalent: "")
            i.representedObject = it.command
            i.target = self
            m.addItem(i)
        }
        return m
    }

    @objc func runCustomCommand(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? String else { return }
        for p in selectedPaths { FileActions.runTemplate(t, path: p) }
    }

    @objc func sortByMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let k = SortKey(rawValue: raw) { setSort(k) }
    }

    @objc func viewModeMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let v = ViewMode(rawValue: raw) { setViewMode(v) }
    }

    // MARK: - Search menu

    func toggled(_ body: (inout SearchOptions) -> Void) {
        pushHistory()
        body(&options)
        runSearch(immediate: true)
        statusBar.update()
        rememberLast()
    }

    @objc func toggleMatchCase(_ sender: Any?) { toggled { $0.matchCase.toggle() } }
    @objc func toggleWholeWord(_ sender: Any?) { toggled { $0.matchWholeWord.toggle() } }
    @objc func toggleMatchPath(_ sender: Any?) { toggled { $0.matchPath.toggle() } }
    @objc func toggleDiacritics(_ sender: Any?) { toggled { $0.matchDiacritics.toggle() } }
    @objc func toggleRegex(_ sender: Any?) { toggled { $0.regex.toggle() } }

    @objc func selectFilterItem(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let f = model.filters.current.first(where: { $0.id.uuidString == idStr }) else { return }
        setFilter(f.isEverything ? nil : f)
    }

    @objc func addToFilters(_ sender: Any?) {
        var f = Filter(name: searchText.isEmpty ? "New Filter" : searchText, search: searchText, options: options)
        f.name = String(f.name.prefix(40))
        FilterEditor.edit(f, isNew: true, over: window) { [weak self] nf in
            guard let self, let nf else { return }
            self.model.setFilters(self.model.filters.current + [nf])
        }
    }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    // MARK: - View menu

    @objc func sortByName(_ sender: Any?) { setSort(.name) }
    @objc func sortByPath(_ sender: Any?) { setSort(.path) }
    @objc func sortBySize(_ sender: Any?) { setSort(.size) }
    @objc func sortByExtension(_ sender: Any?) { setSort(.ext) }
    @objc func sortByType(_ sender: Any?) { setSort(.type) }
    @objc func sortByDateModified(_ sender: Any?) { setSort(.dateModified) }
    @objc func sortByDateCreated(_ sender: Any?) { setSort(.dateCreated) }
    @objc func sortByDateAccessed(_ sender: Any?) { setSort(.dateAccessed) }
    @objc func sortByAttributes(_ sender: Any?) { setSort(.attributes) }
    @objc func sortByRecentlyChanged(_ sender: Any?) { setSort(.dateRecentlyChanged) }
    @objc func sortByRunCount(_ sender: Any?) { setSort(.runCount) }
    @objc func sortByDateRun(_ sender: Any?) { setSort(.dateRun) }
    @objc func sortByFileList(_ sender: Any?) { setSort(.fileListFilename) }
    @objc func sortAscending(_ sender: Any?) { setSort(sortKey, ascending: true) }
    @objc func sortDescending(_ sender: Any?) { setSort(sortKey, ascending: false) }

    @objc func viewDetails(_ sender: Any?) { setViewMode(.details) }
    @objc func viewMedium(_ sender: Any?) { setViewMode(.medium) }
    @objc func viewLarge(_ sender: Any?) { setViewMode(.large) }
    @objc func viewExtraLarge(_ sender: Any?) { setViewMode(.extraLarge) }

    @objc func increaseThumbnails(_ sender: Any?) {
        let order: [ViewMode] = [.details, .medium, .large, .extraLarge]
        if let i = order.firstIndex(of: viewMode), i + 1 < order.count { setViewMode(order[i + 1]) }
    }

    @objc func decreaseThumbnails(_ sender: Any?) {
        let order: [ViewMode] = [.details, .medium, .large, .extraLarge]
        if let i = order.firstIndex(of: viewMode), i > 0 { setViewMode(order[i - 1]) }
    }

    @objc func togglePreview(_ sender: Any?) {
        model.rememberState { $0.showPreview.toggle() }
        setPreviewVisible(model.settings.showPreview)
    }

    @objc func toggleFilterBar(_ sender: Any?) {
        model.rememberState { $0.showFilterBar.toggle() }
        filterPopup.isHidden = !model.settings.showFilterBar
    }

    @objc func toggleStatusBar(_ sender: Any?) {
        model.rememberState { $0.showStatusBar.toggle() }
        statusBar.isHidden = !model.settings.showStatusBar
    }

    @objc func zoomIn(_ sender: Any?) { zoom = Swift.min(24, zoom + 1); table.applyFont() }
    @objc func zoomOut(_ sender: Any?) { zoom = Swift.max(-6, zoom - 1); table.applyFont() }
    @objc func zoomReset(_ sender: Any?) { zoom = 0; table.applyFont() }

    @objc func windowSizeSmall(_ sender: Any?) { resizeWindow(NSSize(width: 512, height: 398)) }
    @objc func windowSizeMedium(_ sender: Any?) { resizeWindow(NSSize(width: 640, height: 497)) }
    @objc func windowSizeLarge(_ sender: Any?) { resizeWindow(NSSize(width: 768, height: 597)) }
    @objc func windowSizeAutoFit(_ sender: Any?) {
        let w = table.tableColumns.filter { !$0.isHidden }.reduce(CGFloat(40)) { $0 + $1.width + table.intercellSpacing.width }
        let rows = CGFloat(Swift.min(Swift.max(results.count, 8), 30))
        resizeWindow(NSSize(width: Swift.min(w, (NSScreen.main?.visibleFrame.width ?? 1400) - 40), height: rows * table.rowHeight + 110))
    }

    func resizeWindow(_ size: NSSize) {
        guard let w = window else { return }
        var f = w.frame
        f.origin.y += f.height - size.height
        f.size = size
        w.setFrame(f, display: true, animate: true)
    }

    @objc func onTopNever(_ sender: Any?) { model.rememberState { $0.onTop = .never }; applyOnTop() }
    @objc func onTopAlways(_ sender: Any?) { model.rememberState { $0.onTop = .always }; applyOnTop() }
    @objc func onTopWhileSearching(_ sender: Any?) { model.rememberState { $0.onTop = .whileSearching }; applyOnTop() }
    @objc func toggleOnTop(_ sender: Any?) {
        model.rememberState { $0.onTop = $0.onTop == .always ? .never : .always }
        applyOnTop()
    }

    @objc func goBack(_ sender: Any?) {
        guard let st = back.popLast() else { NSSound.beep(); return }
        forward.append(state)
        apply(st, recordHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let st = forward.popLast() else { NSSound.beep(); return }
        back.append(state)
        apply(st, recordHistory: false)
    }

    @objc func goHome(_ sender: Any?) {
        pushHistory()
        var s = state
        let set = model.settings
        s.text = set.homeSearch
        s.options = SearchOptions(matchCase: set.homeMatchCase == .on, matchWholeWord: set.homeMatchWholeWord == .on,
                                  matchPath: set.homeMatchPath == .on, matchDiacritics: set.homeMatchDiacritics == .on,
                                  regex: set.homeRegex == .on)
        s.filterName = set.homeFilterUseLast ? nil : (set.homeFilter.isEmpty ? nil : set.homeFilter)
        if !set.homeSortUseLast { s.sort = set.homeSort; s.ascending = set.homeSortAscending }
        apply(s, recordHistory: false)
    }

    // MARK: - Bookmarks

    @objc func addBookmark(_ sender: Any?) {
        let b = Bookmark(name: searchText.isEmpty ? "New Bookmark" : String(searchText.prefix(40)), search: searchText, options: options,
                         filter: filter?.name, sort: sortKey, ascending: ascending, view: viewMode,
                         index: sourceString)
        BookmarkEditor.edit(b, isNew: true, over: window) { [weak self] nb in
            guard let self, let nb else { return }
            self.model.setBookmarks(self.model.bookmarks.current + [nb])
        }
    }

    var sourceString: String? {
        switch source {
        case .local: return nil
        case .fileList(_, let p): return "filelist:" + p
        case .remote(let c): return "etp:" + c.label
        }
    }

    func openBookmark(_ b: Bookmark) {
        pushHistory()
        searchText = b.search
        options = b.options
        if let f = b.filter { filter = model.filter(named: f); if filter?.isEverything == true { filter = nil } } else { filter = nil }
        if let s = b.sort { sortKey = s }
        if let a = b.ascending { ascending = a }
        if let v = b.view { setViewMode(v, save: false) }
        if let ix = b.index, ix.hasPrefix("filelist:") { openFileList(path: String(ix.dropFirst(9))) }
        selectFilterInPopup()
        table.updateSortIndicator()
        if b.search.hasPrefix(">") { _ = handleSearchCommand(); return }
        runSearch(immediate: true)
    }

    // MARK: - File lists / ETP / export

    @objc func openFileListPanel(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "efu") ?? .commaSeparatedText, .commaSeparatedText, .plainText]
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let url = p.url else { return }
        openFileList(path: url.path)
    }

    func openFileList(path: String) {
        do {
            let list = try FileList.load(URL(fileURLWithPath: path))
            let ix = FileListLoader.makeIndex(list, named: (path as NSString).lastPathComponent, path: path)
            source = .fileList(ix, path)
            runSearch(immediate: true)
            statusBar.update()
        } catch {
            _ = alert("Cannot open file list", "\(error)")
        }
    }

    @objc func closeFileList(_ sender: Any?) {
        if case .remote(let c) = source { c.close() }
        source = .local
        runSearch(immediate: true)
        statusBar.update()
    }

    func connect(_ client: ETPClient) {
        if case .remote(let old) = source { old.close() }
        source = .remote(client)
        runSearch(immediate: true)
        statusBar.update()
    }

    @objc func exportResults(_ sender: Any?) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Results.efu"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for f in ExportFormat.allCases { popup.addItem(withTitle: f.title); popup.lastItem?.representedObject = f.rawValue }
        let selOnly = NSButton(checkboxWithTitle: "Export selection only", target: nil, action: nil)
        let stack = NSStackView(views: [popup, selOnly])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        p.accessoryView = stack
        let handler = PopupNameSync(panel: p, popup: popup)
        popup.target = handler
        popup.action = #selector(PopupNameSync.changed(_:))
        guard p.runModal() == .OK, let url = p.url else { return }
        _ = handler
        let fmt = ExportFormat(rawValue: popup.selectedItem?.representedObject as? String ?? "efu") ?? .efu
        let cols = table.tableColumns.filter { !$0.isHidden }.compactMap { Column(rawValue: $0.identifier.rawValue) }
        let text: String
        switch results.kind {
        case .local(let res):
            var ids = res.ids
            if selOnly.state == .on { ids = selectedRows.compactMap { results.entry($0) } }
            let reader = RowReader(index: res.index, program: res.program, services: model.manager.services, formatter: model.formatter)
            text = Exporter.render(ids, format: fmt, columns: cols.map { $0 == .path ? .path : $0 }, reader: reader, total: res.totalCount)
        default:
            var lines = ""
            for i in 0..<results.count { lines += (results.path(i) ?? "") + "\n" }
            text = lines
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSApp.presentError(error) }
    }

    // MARK: - Validation

    private func isInMainMenu(_ item: NSMenuItem) -> Bool {
        var m = item.menu
        while let cur = m {
            if cur === NSApp.mainMenu { return true }
            m = cur.supermenu
        }
        return false
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasSel = !selectedRows.isEmpty
        let editingText = window?.firstResponder is NSTextView
        let fileOps: [Selector] = [#selector(moveToTrash(_:)), #selector(deletePermanently(_:)), #selector(renameSelection(_:)),
                                   #selector(openSelection(_:)), #selector(revealSelection(_:))]
        // While typing in the search box, menu-bar shortcuts such as ⌘⌫ edit the text instead of
        // acting on files. This only applies to the menu bar, never to the right-click menu.
        if editingText, let a = item.action, fileOps.contains(a), item.keyEquivalent != "", isInMainMenu(item) { return false }
        switch item.action {
        case #selector(toggleMatchCase(_:)): item.state = options.matchCase ? .on : .off
        case #selector(toggleWholeWord(_:)): item.state = options.matchWholeWord ? .on : .off
        case #selector(toggleMatchPath(_:)): item.state = options.matchPath ? .on : .off
        case #selector(toggleDiacritics(_:)): item.state = options.matchDiacritics ? .on : .off
        case #selector(toggleRegex(_:)): item.state = options.regex ? .on : .off
        case #selector(selectFilterItem(_:)):
            let id = item.representedObject as? String
            item.state = (filter?.id.uuidString == id || (filter == nil && model.filters.current.first { $0.id.uuidString == id }?.isEverything == true)) ? .on : .off
        case #selector(togglePreview(_:)): item.state = preview != nil ? .on : .off
        case #selector(toggleFilterBar(_:)): item.state = model.settings.showFilterBar ? .on : .off
        case #selector(toggleStatusBar(_:)): item.state = model.settings.showStatusBar ? .on : .off
        case #selector(viewDetails(_:)): item.state = viewMode == .details ? .on : .off
        case #selector(viewMedium(_:)): item.state = viewMode == .medium ? .on : .off
        case #selector(viewLarge(_:)): item.state = viewMode == .large ? .on : .off
        case #selector(viewExtraLarge(_:)): item.state = viewMode == .extraLarge ? .on : .off
        case #selector(sortAscending(_:)): item.state = ascending ? .on : .off
        case #selector(sortDescending(_:)): item.state = ascending ? .off : .on
        case #selector(onTopNever(_:)): item.state = model.settings.onTop == .never ? .on : .off
        case #selector(onTopAlways(_:)): item.state = model.settings.onTop == .always ? .on : .off
        case #selector(onTopWhileSearching(_:)): item.state = model.settings.onTop == .whileSearching ? .on : .off
        case #selector(closeFileList(_:)):
            if case .local = source { return false }
            return true
        case #selector(goBack(_:)): return !back.isEmpty
        case #selector(goForward(_:)): return !forward.isEmpty
        case #selector(openSelection(_:)), #selector(revealSelection(_:)), #selector(copyFullPath(_:)), #selector(copyName(_:)),
             #selector(copyPath(_:)), #selector(moveToTrash(_:)), #selector(deletePermanently(_:)), #selector(renameSelection(_:)),
             #selector(showProperties(_:)), #selector(quickLook(_:)), #selector(setRunCount(_:)), #selector(copyToFolder(_:)),
             #selector(moveToFolder(_:)), #selector(exploreSelection(_:)), #selector(explorePath(_:)), #selector(finderGetInfo(_:)),
             #selector(readExtendedInformation(_:)), #selector(invertSelection(_:)):
            return hasSel || item.action == #selector(invertSelection(_:))
        case #selector(copy(_:)), #selector(cut(_:)):
            if window?.firstResponder is NSTextView { return true }
            return hasSel
        default:
            break
        }
        if let raw = item.representedObject as? String, let key = SortKey(rawValue: raw), item.action != #selector(sortByMenu(_:)) {
            item.state = key == sortKey ? .on : .off
        }
        let sortActions: [Selector: SortKey] = [
            #selector(sortByName(_:)): .name, #selector(sortByPath(_:)): .path, #selector(sortBySize(_:)): .size,
            #selector(sortByExtension(_:)): .ext, #selector(sortByType(_:)): .type, #selector(sortByDateModified(_:)): .dateModified,
            #selector(sortByDateCreated(_:)): .dateCreated, #selector(sortByDateAccessed(_:)): .dateAccessed,
            #selector(sortByAttributes(_:)): .attributes, #selector(sortByRecentlyChanged(_:)): .dateRecentlyChanged,
            #selector(sortByRunCount(_:)): .runCount, #selector(sortByDateRun(_:)): .dateRun, #selector(sortByFileList(_:)): .fileListFilename,
        ]
        if let a = item.action, let k = sortActions[a] { item.state = k == sortKey ? .on : .off }
        return true
    }
}

/// Keeps the save panel's file extension in sync with the chosen export format.
final class PopupNameSync: NSObject {
    weak var panel: NSSavePanel?
    weak var popup: NSPopUpButton?

    init(panel: NSSavePanel, popup: NSPopUpButton) {
        self.panel = panel
        self.popup = popup
    }

    @objc func changed(_ sender: Any?) {
        guard let p = panel, let raw = popup?.selectedItem?.representedObject as? String else { return }
        let base = (p.nameFieldStringValue as NSString).deletingPathExtension
        p.nameFieldStringValue = base + "." + raw
    }
}
