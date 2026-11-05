import AppKit
import EpitomeCore

// Small helpers for building forms and dialogs in code.

/// Calls a closure from a control's target/action.
final class ActionTrampoline: NSObject {
    let handler: (Any?) -> Void
    init(_ h: @escaping (Any?) -> Void) { handler = h }
    @objc func fire(_ sender: Any?) { handler(sender) }
}

/// Calls a closure whenever a text field's text changes.
final class TextChangeTrampoline: NSObject, NSTextFieldDelegate {
    let handler: (NSTextField) -> Void
    init(_ h: @escaping (NSTextField) -> Void) { handler = h }
    func controlTextDidChange(_ obj: Notification) {
        if let f = obj.object as? NSTextField { handler(f) }
    }
}

private var trampolineKey: UInt8 = 0
private var textTrampolineKey: UInt8 = 0

extension NSControl {
    /// Sets a closure as the control's action. The closure gets the control.
    func onAction(_ h: @escaping (NSControl) -> Void) {
        let t = ActionTrampoline { s in if let c = s as? NSControl { h(c) } }
        objc_setAssociatedObject(self, &trampolineKey, t, .OBJC_ASSOCIATION_RETAIN)
        target = t
        action = #selector(ActionTrampoline.fire(_:))
    }
}

extension NSTextField {
    /// Calls `h` on every edit.
    func onTextChange(_ h: @escaping (NSTextField) -> Void) {
        let t = TextChangeTrampoline(h)
        objc_setAssociatedObject(self, &textTrampolineKey, t, .OBJC_ASSOCIATION_RETAIN)
        delegate = t
    }
}

extension NSMenuItem {
    convenience init(title: String, handler: @escaping () -> Void) {
        let t = ActionTrampoline { _ in handler() }
        self.init(title: title, action: #selector(ActionTrampoline.fire(_:)), keyEquivalent: "")
        target = t
        objc_setAssociatedObject(self, &trampolineKey, t, .OBJC_ASSOCIATION_RETAIN)
    }
}

func button(_ title: String, _ h: @escaping () -> Void) -> NSButton {
    let b = NSButton(title: title, target: nil, action: nil)
    b.bezelStyle = .rounded
    b.onAction { _ in h() }
    return b
}

func checkbox(_ title: String, _ on: Bool = false, _ h: ((Bool) -> Void)? = nil) -> NSButton {
    let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
    b.state = on ? .on : .off
    if let h { b.onAction { c in h((c as? NSButton)?.state == .on) } }
    return b
}

func textField(_ value: String = "", placeholder: String = "", width: CGFloat = 260, secure: Bool = false) -> NSTextField {
    let f: NSTextField = secure ? NSSecureTextField() : NSTextField()
    f.stringValue = value
    f.placeholderString = placeholder
    f.translatesAutoresizingMaskIntoConstraints = false
    f.widthAnchor.constraint(equalToConstant: width).isActive = true
    f.lineBreakMode = .byTruncatingTail
    f.usesSingleLineMode = true
    f.cell?.isScrollable = true
    return f
}

func popup(_ titles: [String], selected: Int = 0, _ h: ((Int) -> Void)? = nil) -> NSPopUpButton {
    let p = NSPopUpButton(frame: .zero, pullsDown: false)
    p.addItems(withTitles: titles)
    if selected >= 0 && selected < titles.count { p.selectItem(at: selected) }
    if let h { p.onAction { c in h((c as? NSPopUpButton)?.indexOfSelectedItem ?? 0) } }
    return p
}

func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.spacing = spacing
    s.alignment = .firstBaseline
    s.distribution = .fill
    return s
}

func vstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = spacing
    return s
}

func wrappingLabel(_ s: String, width: CGFloat = 520, small: Bool = true) -> NSTextField {
    let t = NSTextField(wrappingLabelWithString: s)
    t.font = small ? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize) : NSFont.systemFont(ofSize: NSFont.systemFontSize)
    t.textColor = .secondaryLabelColor
    t.preferredMaxLayoutWidth = width
    t.translatesAutoresizingMaskIntoConstraints = false
    t.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
    return t
}

/// A view whose coordinate system starts at the top (for scroll view documents).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A vertical form: sections, rows of "label: control", notes.
final class FormView: NSView {
    let stack = NSStackView()
    let labelWidth: CGFloat

    init(labelWidth: CGFloat = 170) {
        self.labelWidth = labelWidth
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 22, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func add(_ v: NSView, indent: CGFloat = 0) {
        if indent > 0 {
            let s = NSStackView(views: [v])
            s.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
            stack.addArrangedSubview(s)
        } else {
            stack.addArrangedSubview(v)
        }
    }

    func header(_ s: String) {
        if stack.arrangedSubviews.count > 0 { stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!) }
        let l = label(s, bold: true)
        stack.addArrangedSubview(l)
    }

    func note(_ s: String, indent: CGFloat = 0) { add(wrappingLabel(s), indent: indent) }

    @discardableResult
    func row(_ title: String, _ controls: [NSView], indent: CGFloat = 0) -> NSStackView {
        let l = NSTextField(labelWithString: title.isEmpty ? "" : title + ":")
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: labelWidth - indent).isActive = true
        let s = hstack([l] + controls)
        add(s, indent: indent)
        return s
    }

    func spacer(_ h: CGFloat = 6) {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        stack.addArrangedSubview(v)
    }
}

/// Wraps a form in a scroll view. The form keeps its own Auto Layout inside, but its
/// frame (and the document's) is set from its fitting size, so nothing in the form can
/// over-constrain the window around it.
final class FormScrollView: NSScrollView {
    let form: NSView
    private let doc = FlippedView()

    init(_ v: NSView) {
        form = v
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        v.translatesAutoresizingMaskIntoConstraints = true
        v.autoresizingMask = []
        // Start at the form's natural size, so its frame never contradicts its content.
        let fit = v.fittingSize
        v.frame = NSRect(x: 0, y: 0, width: ceil(fit.width), height: ceil(fit.height))
        doc.frame = v.frame
        doc.addSubview(v)
        documentView = doc
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fitDocument()
    }

    func fitDocument() {
        let clip = contentView.bounds.size
        let fit = form.fittingSize
        let w = Swift.max(clip.width, ceil(fit.width))
        let h = ceil(fit.height)
        let formFrame = NSRect(x: 0, y: 0, width: w, height: h)
        if form.frame != formFrame { form.frame = formFrame }
        let docFrame = NSRect(x: 0, y: 0, width: w, height: Swift.max(h, clip.height))
        if doc.frame != docFrame { doc.frame = docFrame }
    }
}

func scrolling(_ v: NSView) -> NSScrollView { FormScrollView(v) }

/// A table with simple string columns backed by closures.
final class SimpleTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct ColumnSpec {
        var id: String
        var title: String
        var width: CGFloat
        var editable = false
        var checkbox = false
        var popup: [String]? = nil
        var rightAligned = false
    }

    let table = NSTableView()
    let scroll = NSScrollView()
    var columns: [ColumnSpec]
    /// Setting the row source reloads the table (it may already have asked for a count).
    var rowCount: () -> Int = { 0 } { didSet { table.reloadData() } }
    var value: (Int, String) -> String = { _, _ in "" }
    var boolValue: (Int, String) -> Bool = { _, _ in false }
    var popupIndex: (Int, String) -> Int = { _, _ in 0 }
    var setValue: ((Int, String, String) -> Void)?
    var setBool: ((Int, String, Bool) -> Void)?
    var setPopup: ((Int, String, Int) -> Void)?
    var onSelect: ((IndexSet) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var onSort: ((String, Bool) -> Void)?
    var tooltip: ((Int, String) -> String?)?
    var menuFor: ((Int) -> NSMenu?)?
    /// Set to accept file drops (also call `table.registerForDraggedTypes([.fileURL])`).
    var dropHandler: (([URL]) -> Void)?

    init(_ columns: [ColumnSpec], sortable: Bool = false) {
        self.columns = columns
        super.init()
        for c in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = 30
            col.resizingMask = .userResizingMask
            if sortable { col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: true) }
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 20
        table.style = .fullWidth
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
    }

    func reload() { table.reloadData() }
    var selected: IndexSet { table.selectedRowIndexes }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let spec = columns.first(where: { $0.id == id }) else { return nil }
        if spec.checkbox {
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkToggled(_:)))
            b.state = boolValue(row, id) ? .on : .off
            b.identifier = NSUserInterfaceItemIdentifier(id)
            b.tag = row
            return b
        }
        if let items = spec.popup {
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.addItems(withTitles: items)
            p.controlSize = .small
            p.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            p.isBordered = false
            p.selectItem(at: popupIndex(row, id))
            p.identifier = NSUserInterfaceItemIdentifier(id)
            p.tag = row
            p.target = self
            p.action = #selector(popupChanged(_:))
            return p
        }
        let t = NSTextField(labelWithString: value(row, id))
        t.lineBreakMode = .byTruncatingMiddle
        t.alignment = spec.rightAligned ? .right : .left
        t.toolTip = tooltip?(row, id)
        if spec.editable {
            t.isEditable = true
            t.isSelectable = true
            t.identifier = NSUserInterfaceItemIdentifier(id)
            t.tag = row
            t.target = self
            t.action = #selector(textEdited(_:))
            t.cell?.sendsActionOnEndEditing = true
        }
        return t
    }

    @objc func checkToggled(_ b: NSButton) {
        setBool?(b.tag, b.identifier?.rawValue ?? "", b.state == .on)
    }

    @objc func popupChanged(_ p: NSPopUpButton) {
        setPopup?(p.tag, p.identifier?.rawValue ?? "", p.indexOfSelectedItem)
    }

    @objc func textEdited(_ t: NSTextField) {
        setValue?(t.tag, t.identifier?.rawValue ?? "", t.stringValue)
    }

    @objc func doubleClicked(_ sender: Any?) {
        let r = table.clickedRow
        if r >= 0 { onDoubleClick?(r) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onSelect?(table.selectedRowIndexes) }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let k = d.key else { return }
        onSort?(k, d.ascending)
    }
}

/// Runs a panel as a sheet on `parent`, or app-modal without one.
func runDialog(_ panel: NSWindow, over parent: NSWindow?, done: @escaping (NSApplication.ModalResponse) -> Void) {
    if let p = parent, p.isVisible {
        p.beginSheet(panel) { r in done(r) }
    } else {
        panel.center()
        let r = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        done(r)
    }
}

/// Ends a sheet or modal session started by `runDialog`.
func endDialog(_ panel: NSWindow, _ r: NSApplication.ModalResponse) {
    if let parent = panel.sheetParent {
        parent.endSheet(panel, returnCode: r)
    } else {
        NSApp.stopModal(withCode: r)
        panel.orderOut(nil)
    }
}

/// A titled panel with a content view and OK/Cancel buttons.
func makeDialog(title: String, content: NSView, ok: String = "OK", cancel: String? = "Cancel",
                extra: [NSView] = [], onOK: @escaping (NSWindow) -> Bool) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled, .resizable],
                        backing: .buffered, defer: false)
    panel.title = title
    panel.isReleasedWhenClosed = false
    let root = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(content)
    let okB = NSButton(title: ok, target: nil, action: nil)
    okB.bezelStyle = .rounded
    okB.keyEquivalent = "\r"
    okB.onAction { [weak panel] _ in
        guard let panel else { return }
        if onOK(panel) { endDialog(panel, .OK) }
    }
    var buttons: [NSView] = []
    buttons.append(contentsOf: extra)
    let flex = NSView()
    flex.setContentHuggingPriority(.init(1), for: .horizontal)
    buttons.append(flex)
    if let c = cancel {
        let cb = NSButton(title: c, target: nil, action: nil)
        cb.bezelStyle = .rounded
        cb.keyEquivalent = "\u{1B}"
        cb.onAction { [weak panel] _ in if let panel { endDialog(panel, .cancel) } }
        buttons.append(cb)
    }
    buttons.append(okB)
    let bar = hstack(buttons)
    bar.alignment = .centerY
    bar.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(bar)
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
        content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
        content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
        bar.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 16),
        bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
        bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
        bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
    ])
    panel.contentView = root
    panel.setContentSize(root.fittingSize)
    return panel
}
