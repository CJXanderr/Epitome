import AppKit
import EpitomeCore

/// Bottom bar: result / selection info on the left, state indicators on the right.
/// Double-click an indicator to switch that state off.
final class StatusBarView: NSView {
    weak var controller: SearchWindowController?
    let left = NSTextField(labelWithString: "")
    let right = NSStackView()
    let spinner = NSProgressIndicator()
    private var flashText: String?
    private var flashTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        left.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        left.textColor = .secondaryLabelColor
        left.lineBreakMode = .byTruncatingMiddle
        left.translatesAutoresizingMaskIntoConstraints = false
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        right.orientation = .horizontal
        right.spacing = 6
        right.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        addSubview(left)
        addSubview(spinner)
        addSubview(right)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSearching(_ on: Bool) {
        if on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                if self?.controller?.searching == true { self?.spinner.startAnimation(nil) }
            }
        } else {
            spinner.stopAnimation(nil)
        }
    }

    func flash(_ s: String) {
        flashText = s
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            self?.flashText = nil
            self?.update()
        }
        update()
    }

    func update() {
        guard let c = controller else { return }
        let model = c.model
        let s = model.settings
        let fmt = model.formatter
        let total = c.results.totalCount
        var text = ""
        let sel = c.selectedRows
        if let f = flashText {
            text = f
        } else if c.jumpText.count > 0 && Date().timeIntervalSince(c.jumpTime) < 1.2 {
            text = "Jump to: \(c.jumpText)"
        } else if sel.count == 1 && s.showSelectedItemInStatusBar, let r = c.results.row(sel.first!) {
            text = selectedItemText(r, c, s, fmt)
        } else if sel.count > 0 {
            text = "\(fmt.grouped(Int64(sel.count))) object\(sel.count == 1 ? "" : "s") selected"
            if s.showResultCountWithSelection { text += " of \(fmt.grouped(Int64(total)))" }
            if s.showTotalSizeInStatusBar {
                var sum: Int64 = 0
                var counted = 0
                for i in sel {
                    if let r = c.results.row(i), !r.isDir, r.size > 0 { sum += r.size }
                    counted += 1
                    if counted > 200_000 { break }
                }
                text += ", " + ValueFormatter(sizeFormat: .auto, sizeStandard: s.sizeStandard).size(sum)
            }
        } else {
            text = "\(fmt.grouped(Int64(total))) object\(total == 1 ? "" : "s")"
            if s.showTotalSizeInStatusBar && total > 0 && total <= 200_000 {
                var sum: Int64 = 0
                for i in 0..<c.results.count { if let r = c.results.row(i), !r.isDir, r.size > 0 { sum += r.size } }
                text += ", " + ValueFormatter(sizeFormat: .auto, sizeStandard: s.sizeStandard).size(sum)
            }
        }
        left.stringValue = text

        right.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let st = model.manager.status
        switch st.phase {
        case .scanning, .loading:
            addIndicator(st.message.isEmpty ? "Indexing…" : "\(st.message) \(fmt.grouped(Int64(st.count)))", nil)
        case .updating:
            addIndicator("Updating…", nil)
        case .saving:
            addIndicator("Saving…", nil)
        case .paused:
            addIndicator("PAUSED", { model.manager.resumeMonitoring() })
        default: break
        }
        if let lbl = c.source.label {
            addIndicator(lbl, { [weak c] in c?.closeFileList(nil) })
        }
        if c.options.matchCase { addIndicator("CASE", { [weak c] in c?.toggleMatchCase(nil) }) }
        if c.options.matchWholeWord { addIndicator("WHOLE WORD", { [weak c] in c?.toggleWholeWord(nil) }) }
        if c.options.matchPath { addIndicator("PATH", { [weak c] in c?.toggleMatchPath(nil) }) }
        if c.options.matchDiacritics { addIndicator("DIACRITICS", { [weak c] in c?.toggleDiacritics(nil) }) }
        if c.options.regex { addIndicator("REGEX", { [weak c] in c?.toggleRegex(nil) }) }
        if let f = c.filter { addIndicator(f.name, { [weak c] in c?.setFilter(nil) }) }
    }

    func selectedItemText(_ r: Row, _ c: SearchWindowController, _ s: AppSettings, _ fmt: ValueFormatter) -> String {
        if !s.statusBarSelectedItemFormat.isEmpty {
            var t = s.statusBarSelectedItemFormat
            let map: [String: String] = [
                "$f": r.fullPath, "$n": r.name, "$p": r.parent, "$s": fmt.size(r.size), "$e": r.ext,
                "$m": fmt.date(r.mtime), "$c": fmt.date(r.ctime), "$a": fmt.date(r.atime),
                "$b": ValueFormatter.attributes(r.flags), "$d": fmt.date(r.rctime),
                "$o": fmt.grouped(Int64(c.results.totalCount)),
            ]
            for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
            return t.replacingOccurrences(of: "$$", with: "$")
        }
        var parts: [String] = []
        if !(r.isDir && r.size < 0) { parts.append("Size: \(fmt.size(r.size))") }
        if r.mtime != kUnknownTime { parts.append("Date Modified: \(fmt.date(r.mtime))") }
        parts.append("Path: \(r.parent.isEmpty ? r.fullPath : r.parent)")
        return parts.joined(separator: ", ")
    }

    func addIndicator(_ title: String, _ action: (() -> Void)?) {
        let v = IndicatorLabel(title, action)
        right.addArrangedSubview(v)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let c = controller else { return nil }
        let m = NSMenu()
        func add(_ t: String, _ sel: Selector, _ on: Bool) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = c
            i.state = on ? .on : .off
            m.addItem(i)
        }
        add("Match Case", #selector(SearchWindowController.toggleMatchCase(_:)), c.options.matchCase)
        add("Match Whole Word", #selector(SearchWindowController.toggleWholeWord(_:)), c.options.matchWholeWord)
        add("Match Path", #selector(SearchWindowController.toggleMatchPath(_:)), c.options.matchPath)
        add("Match Diacritics", #selector(SearchWindowController.toggleDiacritics(_:)), c.options.matchDiacritics)
        add("Enable Regex", #selector(SearchWindowController.toggleRegex(_:)), c.options.regex)
        m.addItem(.separator())
        for f in c.model.filters.current {
            let i = NSMenuItem(title: f.name, action: #selector(SearchWindowController.selectFilterItem(_:)), keyEquivalent: "")
            i.target = c
            i.representedObject = f.id.uuidString
            i.state = (c.filter?.id == f.id || (c.filter == nil && f.isEverything)) ? .on : .off
            m.addItem(i)
        }
        return m
    }
}

/// A small label that runs an action on double-click.
final class IndicatorLabel: NSTextField {
    var onDouble: (() -> Void)?

    convenience init(_ title: String, _ action: (() -> Void)?) {
        self.init(labelWithString: title)
        font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        textColor = .secondaryLabelColor
        onDouble = action
        if action != nil { toolTip = "Double-click to turn off" }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDouble?() } else { super.mouseDown(with: event) }
    }
}

// MARK: - Thumbnails

/// Grid layout computed arithmetically, so millions of items stay cheap.
final class GridLayout: NSCollectionViewLayout {
    var itemSize = NSSize(width: 140, height: 160)
    var spacing: CGFloat = 8
    private var columns = 1
    private var count = 0

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        count = cv.numberOfSections > 0 ? cv.numberOfItems(inSection: 0) : 0
        let w = cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
        columns = Swift.max(1, Int((w - spacing) / (itemSize.width + spacing)))
    }

    override var collectionViewContentSize: NSSize {
        let rows = (count + columns - 1) / columns
        let w = collectionView?.enclosingScrollView?.contentView.bounds.width ?? 0
        return NSSize(width: w, height: CGFloat(rows) * (itemSize.height + spacing) + spacing)
    }

    func frame(_ i: Int) -> NSRect {
        let r = i / columns, c = i % columns
        let totalW = CGFloat(columns) * itemSize.width + CGFloat(columns - 1) * spacing
        let w = collectionView?.enclosingScrollView?.contentView.bounds.width ?? totalW
        let x0 = Swift.max(spacing, (w - totalW) / 2)
        return NSRect(x: x0 + CGFloat(c) * (itemSize.width + spacing), y: spacing + CGFloat(r) * (itemSize.height + spacing),
                      width: itemSize.width, height: itemSize.height)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard count > 0 else { return [] }
        let rowH = itemSize.height + spacing
        let first = Swift.max(0, Int((rect.minY - spacing) / rowH)) * columns
        let last = Swift.min(count - 1, (Int(rect.maxY / rowH) + 1) * columns - 1)
        guard first <= last else { return [] }
        return (first...last).map { i in
            let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
            a.frame = frame(i)
            return a
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let a = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        a.frame = frame(indexPath.item)
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}

final class ThumbItem: NSCollectionViewItem {
    let image = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    var path = ""

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(image)
        view.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            image.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            image.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -4),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            titleLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
            titleLabel.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil }
    }
}

final class ThumbCollectionView: NSCollectionView {
    weak var owner: SearchWindowController?

    override func keyDown(with event: NSEvent) {
        if let o = owner, o.handleResultsKey(event) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let ip = indexPathForItem(at: p), !selectionIndexPaths.contains(ip) { selectionIndexPaths = [ip] }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        return owner?.contextMenu(emptySpace: indexPathForItem(at: p) == nil)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { owner?.openSelection(nil) }
    }
}

/// Thumbnail view (Medium / Large / Extra Large).
final class ThumbnailController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    unowned let owner: SearchWindowController
    let view = NSScrollView()
    let collection = ThumbCollectionView()
    let layout = GridLayout()
    var thumbSize: CGFloat = 128

    init(owner: SearchWindowController) {
        self.owner = owner
        super.init()
        collection.owner = owner
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.textBackgroundColor]
        collection.register(ThumbItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("thumb"))
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        view.documentView = collection
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
    }

    func setSize(_ m: ViewMode) {
        switch m {
        case .medium: thumbSize = 96
        case .large: thumbSize = 128
        case .extraLarge: thumbSize = 256
        case .details: thumbSize = 128
        }
        layout.itemSize = NSSize(width: thumbSize + 24, height: thumbSize + 44)
        layout.invalidateLayout()
    }

    func reload() { collection.reloadData() }

    func select(_ i: Int) {
        collection.selectionIndexPaths = [IndexPath(item: i, section: 0)]
        collection.scrollToItems(at: [IndexPath(item: i, section: 0)], scrollPosition: .nearestHorizontalEdge)
        owner.statusBar.update()
        owner.updatePreview()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { owner.results.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("thumb"), for: indexPath) as! ThumbItem
        guard let r = owner.results.row(indexPath.item) else { return item }
        item.titleLabel.stringValue = r.name
        item.path = r.fullPath
        let path = r.fullPath
        let size = thumbSize
        if let img = ThumbnailCache.shared.thumbnail(path: path, size: size, ready: { [weak item] img in
            if item?.path == path { item?.image.image = img }
        }) {
            item.image.image = img
        } else {
            item.image.image = IconCache.shared.icon(path: path, isFolder: r.isDir, isPackage: r.isPackage, isRoot: r.isRoot, ext: r.ext) {}
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        owner.statusBar.update()
        owner.updatePreview()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        owner.statusBar.update()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let p = owner.results.path(indexPath.item), FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p) as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }
}
