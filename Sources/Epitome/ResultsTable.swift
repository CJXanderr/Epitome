import AppKit
import EpitomeCore
import Quartz

/// The details view (virtual table, millions of rows).
final class ResultsTableView: NSTableView, NSMenuDelegate {
    weak var controller: SearchWindowController?
    var savedHeader: NSTableHeaderView?
    var resultsFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize)

    func configure() {
        allowsMultipleSelection = true
        allowsColumnReordering = true
        allowsColumnResizing = true
        allowsEmptySelection = true
        columnAutoresizingStyle = .noColumnAutoresizing
        style = .plain
        intercellSpacing = NSSize(width: 6, height: 0)
        gridStyleMask = []
        focusRingType = .none
        dataSource = controller
        delegate = controller
        target = controller
        doubleAction = #selector(SearchWindowController.tableDoubleClick(_:))
        action = #selector(SearchWindowController.tableClick(_:))
        setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        savedHeader = headerView
        let hm = NSMenu()
        hm.delegate = self
        headerView?.menu = hm
        rebuildColumns()
        applyFont()
    }

    func rebuildColumns() {
        for c in tableColumns { removeTableColumn(c) }
        let s = AppModel.shared.settings
        var seen = Set<String>()
        for cs in s.columns {
            guard let col = Column(rawValue: cs.id), seen.insert(cs.id).inserted else { continue }
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            tc.title = col.title
            tc.width = CGFloat(cs.width)
            tc.minWidth = 30
            tc.isHidden = !cs.visible && col != .name
            tc.headerCell.alignment = col.rightAligned ? .right : .left
            addTableColumn(tc)
        }
        if tableColumns.isEmpty || tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) == nil {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            tc.title = "Name"
            tc.width = 280
            addTableColumn(tc)
        }
        updateSortIndicator()
    }

    func saveColumns() {
        var list: [ColumnSetting] = tableColumns.map {
            ColumnSetting(id: $0.identifier.rawValue, width: Double($0.width), visible: !$0.isHidden)
        }
        for c in Column.allCases where c != .fullPath && !list.contains(where: { $0.id == c.rawValue }) {
            list.append(ColumnSetting(id: c.rawValue, width: 120, visible: false))
        }
        AppModel.shared.rememberState { $0.columns = list }
    }

    func applyFont() {
        let s = AppModel.shared.settings
        let base = s.resultsFontSize > 0 ? CGFloat(s.resultsFontSize) : NSFont.systemFontSize
        let size = Swift.max(8, base + (controller?.zoom ?? 0))
        if !s.resultsFontName.isEmpty, let f = NSFont(name: s.resultsFontName, size: size) { resultsFont = f } else { resultsFont = .systemFont(ofSize: size) }
        let lh = ceil(resultsFont.ascender - resultsFont.descender + resultsFont.leading)
        rowHeight = Swift.max(16, lh + CGFloat(s.rowHeightPadding))
        reloadData()
    }

    func updateSortIndicator() {
        guard let c = controller else { return }
        for tc in tableColumns {
            let col = Column(rawValue: tc.identifier.rawValue)
            if col?.sortKey == c.sortKey && col != .fullPath {
                setIndicatorImage(NSImage(named: c.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"), in: tc)
                highlightedTableColumn = tc
            } else {
                setIndicatorImage(nil, in: tc)
            }
        }
    }

    // MARK: header menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for c in Column.allCases where c != .fullPath {
            let item = NSMenuItem(title: c.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            let tc = tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(c.rawValue))
            item.state = (tc != nil && tc?.isHidden == false) ? .on : .off
            if c == .name { item.isEnabled = false }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let fit = NSMenuItem(title: "Size Columns to Fit", action: #selector(sizeColumnsToFit(_:)), keyEquivalent: "")
        fit.target = self
        menu.addItem(fit)
        let reset = NSMenuItem(title: "Reset Columns", action: #selector(resetColumns(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let tc = tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) {
            tc.isHidden.toggle()
        } else if let col = Column(rawValue: id) {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            tc.title = col.title
            tc.width = 120
            addTableColumn(tc)
        }
        saveColumns()
        reloadData()
    }

    @objc override func sizeToFit() { sizeColumnsToFit(nil) }

    @objc func sizeColumnsToFit(_ sender: Any?) {
        guard let c = controller else { return }
        let rows = rows(in: visibleRect)
        guard rows.location != NSNotFound else { return }
        for tc in tableColumns where !tc.isHidden {
            guard let col = Column(rawValue: tc.identifier.rawValue) else { continue }
            var w: CGFloat = (tc.title as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12)]).width + 24
            for r in rows.location..<(rows.location + rows.length) {
                let s = c.text(for: col, row: r)
                w = Swift.max(w, (s as NSString).size(withAttributes: [.font: resultsFont]).width + (col == .name ? 34 : 14))
            }
            tc.width = Swift.min(w, 900)
        }
        saveColumns()
    }

    @objc func resetColumns(_ sender: Any?) {
        AppModel.shared.rememberState { $0.columns = AppSettings.defaultColumns }
        rebuildColumns()
        reloadData()
    }

    // MARK: input

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return super.keyDown(with: event) }
        if c.handleResultsKey(event) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        // A right-click moves the focus to the list, like a left click does.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        return controller?.contextMenu(emptySpace: row < 0)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        controller?.statusBar.update()
        return ok
    }

    // Quick Look panel plumbing
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = controller
        panel.delegate = controller
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

/// A cell with an icon and (attributed) text.
final class ResultCellView: NSTableCellView {
    let text = NSTextField(labelWithString: "")
    let icon = NSImageView()
    var hasIcon = false
    var leading: NSLayoutConstraint?

    init(icon withIcon: Bool, identifier id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        hasIcon = withIcon
        // One line per row: long names are cut off with an ellipsis, never wrapped.
        text.lineBreakMode = .byTruncatingTail
        text.usesSingleLineMode = true
        text.maximumNumberOfLines = 1
        text.cell?.wraps = false
        text.cell?.isScrollable = false
        text.cell?.truncatesLastVisibleLine = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.translatesAutoresizingMaskIntoConstraints = false
        textField = text
        addSubview(text)
        if withIcon {
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            imageView = icon
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setIconSize(_ s: CGFloat) {
        for c in icon.constraints where c.firstAttribute == .width || c.firstAttribute == .height { c.constant = s }
    }
}

// MARK: - Data source / delegate

extension SearchWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func text(for col: Column, row: Int) -> String {
        guard let r = results.row(row) else { return "" }
        let fmt = model.formatter
        switch col {
        case .name: return model.settings.showFullPathInName ? r.fullPath : r.name
        case .path: return r.parent
        case .fullPath: return r.fullPath
        case .size: return (r.isDir && r.size < 0) ? "" : fmt.size(r.size)
        case .ext: return r.ext
        case .type: return results.typeName(row)
        case .dateModified: return fmt.date(r.mtime)
        case .dateCreated: return fmt.date(r.ctime)
        case .dateAccessed: return fmt.date(r.atime)
        case .attributes: return ValueFormatter.attributes(r.flags)
        case .fileListFilename: return r.fileListName
        case .runCount:
            let n = model.manager.runHistory.record(for: r.fullPath)?.count ?? 0
            return n > 0 ? String(n) : ""
        case .dateRun:
            guard let rec = model.manager.runHistory.record(for: r.fullPath) else { return "" }
            return fmt.date(Int64(rec.last * 1e9))
        case .dateRecentlyChanged: return fmt.date(r.rctime)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tc = tableColumn, let col = Column(rawValue: tc.identifier.rawValue) else { return nil }
        let isName = col == .name
        let id = NSUserInterfaceItemIdentifier(isName ? "NameCell" : "TextCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ResultCellView) ?? ResultCellView(icon: isName, identifier: id)
        let font = table.resultsFont
        let s = text(for: col, row: row)
        let showHL = model.settings.showHighlightedSearchTerms && !results.highlights.isEmpty && (col == .name || col == .path || col == .fullPath)
        if showHL {
            let terms = results.highlights
            var ranges: [NSRange] = []
            if col == .name {
                ranges = Highlighter.ranges(in: s, terms: terms.filter { !$0.path }, pathColumn: false, parentLength: nil)
                ranges += Highlighter.ranges(in: s, terms: terms.filter { $0.path }, pathColumn: true, parentLength: nil)
            } else {
                ranges = Highlighter.ranges(in: s, terms: terms, pathColumn: true, parentLength: nil)
            }
            let hc: NSColor? = model.settings.highlightColor.isEmpty ? nil : Theme.highlightColor
            cell.text.attributedStringValue = Highlighter.attributed(s, ranges: ranges, font: font,
                                                                     color: col == .path ? .secondaryLabelColor : .labelColor,
                                                                     bold: model.settings.highlightBold, highlightColor: hc,
                                                                     lineBreak: col == .name ? .byTruncatingTail : .byTruncatingMiddle)
        } else {
            cell.text.font = font
            cell.text.textColor = col == .path ? .secondaryLabelColor : .labelColor
            cell.text.lineBreakMode = col == .path || col == .fullPath ? .byTruncatingMiddle : .byTruncatingTail
            cell.text.stringValue = s
        }
        cell.text.alignment = col.rightAligned ? .right : .left
        cell.text.isEditable = false
        if isName, let r = results.row(row) {
            let rowIndex = row
            cell.icon.image = IconCache.shared.icon(path: r.fullPath, isFolder: r.isDir, isPackage: r.isPackage, isRoot: r.isRoot, ext: r.ext) { [weak tableView] in
                guard let tv = tableView, rowIndex < tv.numberOfRows else { return }
                tv.reloadData(forRowIndexes: IndexSet(integer: rowIndex), columnIndexes: IndexSet(integer: tv.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))))
            }
            let iconSize = Swift.min(32, Swift.max(14, table.rowHeight - 4))
            cell.setIconSize(iconSize)
            cell.alphaValue = r.flags & EntryFlag.hidden != 0 ? 0.6 : 1
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let col = Column(rawValue: tableColumn.identifier.rawValue) else { return }
        setSort(col.sortKey)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        enterArmed = false
        statusBar.update()
        updatePreview()
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    func tableViewColumnDidResize(_ notification: Notification) { scheduleSaveColumns() }
    func tableViewColumnDidMove(_ notification: Notification) { scheduleSaveColumns() }

    func scheduleSaveColumns() {
        NSObject.cancelPreviousPerformRequests(withTarget: table, selector: #selector(ResultsTableView.saveColumnsNow), object: nil)
        table.perform(#selector(ResultsTableView.saveColumnsNow), with: nil, afterDelay: 0.8)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let p = results.path(row), FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p) as NSURL
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = HoverRowView()
        rv.hoverEnabled = model.settings.showRowMouseover
        return rv
    }

    @objc func tableClick(_ sender: Any?) {
        if model.settings.singleClickOpen && table.clickedRow >= 0 && NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
            openSelection(nil)
        }
    }

    @objc func tableDoubleClick(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0 else { return }
        let colIdx = table.clickedColumn
        if model.settings.doubleClickPathOpensPath, colIdx >= 0, table.tableColumns[colIdx].identifier.rawValue == "path" {
            revealSelection(nil)
            return
        }
        openSelection(nil)
    }
}

extension ResultsTableView {
    @objc func saveColumnsNow() { saveColumns() }
}

/// Row view with optional mouse-over highlight.
final class HoverRowView: NSTableRowView {
    var hoverEnabled = false
    private var hovering = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        guard hoverEnabled else { return }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if hovering && !isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            bounds.fill()
        }
    }
}
