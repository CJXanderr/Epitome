import AppKit
import Carbon
import EpitomeCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - Icons

final class IconCache {
    static let shared = IconCache()
    private var byType: [String: NSImage] = [:]
    private let byPath = NSCache<NSString, NSImage>()
    private var pending = Set<String>()
    private let queue = DispatchQueue(label: "app.epitome.icons", qos: .userInitiated, attributes: .concurrent)

    lazy var folder: NSImage = NSWorkspace.shared.icon(for: .folder)
    lazy var genericFile: NSImage = NSWorkspace.shared.icon(for: .data)
    lazy var genericApp: NSImage = NSWorkspace.shared.icon(for: .application)
    lazy var volume: NSImage = NSWorkspace.shared.icon(for: UTType("public.volume") ?? .folder)

    func typeIcon(_ ext: String) -> NSImage {
        let k = ext.lowercased()
        if let i = byType[k] { return i }
        let img = k.isEmpty ? genericFile : NSWorkspace.shared.icon(for: UTType(filenameExtension: k) ?? .data)
        byType[k] = img
        return img
    }

    /// Returns an icon now; for items with their own icon (apps, volumes, custom
    /// folder icons) a placeholder is returned and `ready` fires when loaded.
    func icon(path: String, isFolder: Bool, isPackage: Bool, isRoot: Bool, ext: String, ready: @escaping () -> Void) -> NSImage {
        let needsOwn = isPackage || isRoot || ext.lowercased() == "app" || (!isFolder && ["icns", "webloc", "alias", "car"].contains(ext.lowercased()))
        if !needsOwn { return isFolder ? folder : typeIcon(ext) }
        if let i = byPath.object(forKey: path as NSString) { return i }
        if !pending.contains(path) {
            pending.insert(path)
            queue.async { [weak self] in
                let img = NSWorkspace.shared.icon(forFile: path)
                DispatchQueue.main.async {
                    self?.byPath.setObject(img, forKey: path as NSString)
                    self?.pending.remove(path)
                    ready()
                }
            }
        }
        if isRoot { return volume }
        return isPackage || ext.lowercased() == "app" ? genericApp : (isFolder ? folder : typeIcon(ext))
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private var pending = Set<String>()

    init() { cache.countLimit = 2000 }

    func thumbnail(path: String, size: CGFloat, ready: @escaping (NSImage) -> Void) -> NSImage? {
        let key = "\(Int(size))|\(path)" as NSString
        if let i = cache.object(forKey: key) { return i }
        if pending.contains(key as String) { return nil }
        pending.insert(key as String)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
                                               scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            DispatchQueue.main.async {
                self?.pending.remove(key as String)
                let img = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: path)
                self?.cache.setObject(img, forKey: key)
                ready(img)
            }
        }
        return nil
    }

    func clear() { cache.removeAllObjects() }
}

// MARK: - File actions

enum FileActions {
    static func urls(_ paths: [String]) -> [URL] { paths.map { URL(fileURLWithPath: $0) } }

    static func open(_ paths: [String], with app: URL? = nil) {
        let u = urls(paths)
        if let app {
            NSWorkspace.shared.open(u, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                if let e = err { DispatchQueue.main.async { NSApp.presentError(e) } }
            }
        } else {
            for url in u { NSWorkspace.shared.open(url) }
        }
    }

    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls(paths))
    }

    static func openFolder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func trash(_ paths: [String]) -> [String] {
        var failed: [String] = []
        for p in paths {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) } catch { failed.append(p) }
        }
        return failed
    }

    static func deletePermanently(_ paths: [String]) -> [String] {
        var failed: [String] = []
        for p in paths {
            do { try FileManager.default.removeItem(atPath: p) } catch { failed.append(p) }
        }
        return failed
    }

    static func rename(_ path: String, to newName: String) throws -> String {
        let dst = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)
        try FileManager.default.moveItem(atPath: path, toPath: dst)
        return dst
    }

    static func copyToPasteboard(files paths: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls(paths) as [NSURL])
    }

    static func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    static func copy(_ paths: [String], toFolder folder: String, move: Bool) -> [String] {
        var failed: [String] = []
        for p in paths {
            let dst = (folder as NSString).appendingPathComponent((p as NSString).lastPathComponent)
            do {
                if move { try FileManager.default.moveItem(atPath: p, toPath: dst) } else { try FileManager.default.copyItem(atPath: p, toPath: dst) }
            } catch { failed.append(p) }
        }
        return failed
    }

    /// Opens Finder's Get Info window (asks for Automation permission once).
    static func finderGetInfo(_ paths: [String]) {
        for p in paths.prefix(10) {
            let esc = p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let src = "tell application \"Finder\"\nactivate\nopen information window of (POSIX file \"\(esc)\" as alias)\nend tell"
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
        }
    }

    /// Runs a context-menu command template: `$exec("app" "%1")`, `$openpath(%1)`,
    /// `$parent(%1)`, `$pathpart(%1)`, `$namepart(%1)`, `%1`, or a plain command line.
    static func runTemplate(_ template: String, path: String) {
        var t = template.trimmingCharacters(in: .whitespaces)
        func expand(_ s: String) -> String {
            var r = s.replacingOccurrences(of: "$parent(%1)", with: (path as NSString).deletingLastPathComponent)
            r = r.replacingOccurrences(of: "$pathpart(%1)", with: (path as NSString).deletingLastPathComponent)
            r = r.replacingOccurrences(of: "$namepart(%1)", with: (path as NSString).lastPathComponent)
            r = r.replacingOccurrences(of: "%1", with: path)
            r = r.replacingOccurrences(of: "$$", with: "$").replacingOccurrences(of: "$(", with: "(").replacingOccurrences(of: "$)", with: ")")
            return r
        }
        if t.hasPrefix("$openpath(") && t.hasSuffix(")") {
            let inner = expand(String(t.dropFirst(10).dropLast())).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            reveal([inner])
            return
        }
        if t.hasPrefix("$exec(") && t.hasSuffix(")") { t = String(t.dropFirst(6).dropLast()) }
        let args = tokenize(expand(t))
        guard let first = args.first else { return }
        if first.hasSuffix(".app") {
            open(Array(args.dropFirst()), with: URL(fileURLWithPath: first))
            return
        }
        let p = Process()
        if first.hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: first)
            p.arguments = Array(args.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", expand(t)]
        }
        try? p.run()
    }

    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQ = false
        var any = false
        for ch in s {
            if ch == "\"" { inQ.toggle(); any = true; continue }
            if ch == " " && !inQ {
                if any || !cur.isEmpty { out.append(cur); cur = ""; any = false }
                continue
            }
            cur.append(ch)
        }
        if any || !cur.isEmpty { out.append(cur) }
        return out
    }
}

// MARK: - Key combos

extension KeyCombo {
    init(event e: NSEvent) {
        let chars = e.charactersIgnoringModifiers ?? ""
        let f = e.modifierFlags
        self.init(keyCode: e.keyCode, key: chars.lowercased(), command: f.contains(.command), option: f.contains(.option),
                  control: f.contains(.control), shift: f.contains(.shift))
    }

    var modifierMask: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if command { m.insert(.command) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        if shift { m.insert(.shift) }
        return m
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if command { m |= UInt32(cmdKey) }
        if option { m |= UInt32(optionKey) }
        if control { m |= UInt32(controlKey) }
        if shift { m |= UInt32(shiftKey) }
        return m
    }

    func matches(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
        return f == modifierMask && (e.charactersIgnoringModifiers?.lowercased() == key || e.keyCode == keyCode && keyCode != 0)
    }
}

/// System-wide hotkeys via Carbon (no Accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(_ combo: KeyCombo, id: UInt32, handler: @escaping () -> Void) -> Bool {
        install()
        unregister(id)
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4550_544D), id: id) // 'EPTM'
        let st = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard st == noErr, let r = ref else { return false }
        refs[id] = r
        handlers[id] = handler
        return true
    }

    func unregister(_ id: UInt32) {
        if let r = refs[id] { UnregisterEventHotKey(r) }
        refs[id] = nil
        handlers[id] = nil
    }

    func unregisterAll() { for id in Array(refs.keys) { unregister(id) } }
}

/// A button that records a key combination when clicked.
final class KeyRecorderButton: NSButton {
    var combo: KeyCombo? { didSet { updateTitle() } }
    var onChange: ((KeyCombo?) -> Void)?
    var requireModifier = true
    var placeholder = "Click to record" { didSet { updateTitle() } }
    private var monitor: Any?

    convenience init(combo: KeyCombo?) {
        self.init(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        bezelStyle = .rounded
        self.combo = combo
        target = self
        action = #selector(startRecording)
        updateTitle()
    }

    func updateTitle() { title = combo?.display ?? placeholder }

    @objc func startRecording() {
        title = "Type shortcut… (⌫ clears)"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if let m = self.monitor { NSEvent.removeMonitor(m) }
            self.monitor = nil
            if e.keyCode == 51 && e.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                self.combo = nil
            } else if e.keyCode == 53 {
                self.updateTitle()
                return nil
            } else {
                let c = KeyCombo(event: e)
                if self.requireModifier && !(c.command || c.control || c.option) && !(e.keyCode >= 96 && e.keyCode <= 122) {
                    NSSound.beep()
                    self.updateTitle()
                    return nil
                }
                self.combo = c
            }
            self.onChange?(self.combo)
            return nil
        }
    }
}

// MARK: - Appearance

enum Theme {
    static func apply(_ mode: ThemeMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static var highlightColor: NSColor {
        let hex = AppModel.shared.settings.highlightColor
        return NSColor(hex: hex) ?? .controlAccentColor
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

// MARK: - Small helpers

extension NSView {
    func pin(to v: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: v.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

func label(_ s: String, bold: Bool = false, small: Bool = false, secondary: Bool = false) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    var size = NSFont.systemFontSize
    if small { size = NSFont.smallSystemFontSize }
    t.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    if secondary { t.textColor = .secondaryLabelColor }
    t.lineBreakMode = .byTruncatingTail
    return t
}

func alert(_ title: String, _ text: String = "", style: NSAlert.Style = .warning, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.alertStyle = style
    for b in buttons { a.addButton(withTitle: b) }
    return a.runModal()
}

extension String {
    var nsRange: NSRange { NSRange(location: 0, length: (self as NSString).length) }
}
