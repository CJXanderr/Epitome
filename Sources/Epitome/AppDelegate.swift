import AppKit
import Carbon
import EpitomeCore
import ServiceManagement
import UniformTypeIdentifiers

/// App lifecycle: windows, menu bar icon, global hotkeys, IPC and network
/// servers, URL and file opening, and the Tools/Help menu commands.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let launch: LaunchOptions
    var model: AppModel { AppModel.shared }
    private(set) var windows: [SearchWindowController] = []
    weak var lastKeyController: SearchWindowController?
    var statusItem: NSStatusItem?
    var ipc: IPCServer?
    let http: HTTPServer
    let etp: ETPServer
    var applied: AppSettings
    var optionsController: OptionsWindowController?
    var panels: [String: NSWindowController] = [:]
    var didFinishLaunching = false
    var pendingOpen: [URL] = []
    var launchedAsLoginItem = false
    private var termSource: DispatchSourceSignal?

    init(launch: LaunchOptions) {
        self.launch = launch
        http = HTTPServer(manager: AppModel.shared.manager)
        etp = ETPServer(manager: AppModel.shared.manager)
        applied = AppModel.shared.settings
        super.init()
    }

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let ev = NSAppleEventManager.shared().currentAppleEvent, ev.eventID == AEEventID(kAEOpenApplication),
           ev.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAsLoginItem = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let s = model.settings
        NSApp.mainMenu = MainMenuBuilder.shared.build()
        Theme.apply(s.theme)
        // `kill`/`pkill` quit normally, so the index is saved first.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term
        updateStatusItem()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        let mgr = model.manager
        mgr.onChange = { _ in NotificationCenter.default.post(name: AppModel.indexChanged, object: nil) }
        mgr.onStatus = { [weak self] st in
            NotificationCenter.default.post(name: AppModel.statusChanged, object: nil)
            self?.statusChanged(st)
        }
        mgr.start()
        startIPC()
        applyServers()
        registerHotkeys()
        adoptLoginItemIfNeeded()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(settingsChanged), name: AppModel.settingsChanged, object: nil)
        nc.addObserver(self, selector: #selector(filtersChanged), name: AppModel.filtersChanged, object: nil)
        nc.addObserver(self, selector: #selector(bookmarksChanged), name: AppModel.bookmarksChanged, object: nil)
        nc.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        didFinishLaunching = true

        let background = launch.startup || (launchedAsLoginItem && s.runInBackground)
        if !pendingOpen.isEmpty {
            let urls = pendingOpen
            pendingOpen = []
            open(urls)
        } else if !launch.guiArgs.isEmpty {
            handleGUI(launch.guiArgs)
        } else if !background {
            openSearchWindow()
        }
        if !s.onboardingDone && !background { showOnboarding() }
        model.log.write("ready; full disk access: \(mgr.hasFullDiskAccess() ? "yes" : "no")")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty || !windows.contains(where: { $0.window?.isVisible == true }) { showWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        for w in windows { w.rememberLast(); w.table.saveColumns() }
        HotKeyCenter.shared.unregisterAll()
        http.stop()
        etp.stop()
        ipc?.stop()
        model.manager.shutdown()
        model.log.write("Epitome quit")
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "New Search Window", action: #selector(newSearchWindow(_:)), keyEquivalent: "").target = self
        return m
    }

    // MARK: - Opening files and URLs

    func application(_ application: NSApplication, open urls: [URL]) {
        if !didFinishLaunching { pendingOpen += urls; return }
        open(urls)
    }

    func open(_ urls: [URL]) {
        for u in urls {
            if u.isFileURL {
                let p = u.path
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
                if !isDir.boolValue && u.pathExtension.lowercased() == "efu" {
                    let wc = openSearchWindow()
                    wc.openFileList(path: p)
                } else {
                    handleGUI([p, "-newwindow"])
                }
            } else if let scheme = u.scheme?.lowercased(), scheme == "epitome" || scheme == "es" {
                guard model.settings.handleURLScheme else {
                    model.log.write("ignored URL (URL protocol disabled): \(u.absoluteString)")
                    continue
                }
                apply(GUICommand.parse(url: u.absoluteString))
            }
        }
    }

    // MARK: - Windows

    @discardableResult
    func openSearchWindow(state: SearchState? = nil, source: IndexSource = .local) -> SearchWindowController {
        let wc = SearchWindowController(state: state, source: source)
        if let last = frontController ?? windows.last, let lw = last.window, let w = wc.window {
            let p = w.cascadeTopLeft(from: NSPoint(x: lw.frame.minX, y: lw.frame.maxY))
            w.setFrameTopLeftPoint(p)
        } else if windows.isEmpty, wc.window?.frame.origin == .zero {
            wc.window?.center()
        }
        windows.append(wc)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        return wc
    }

    /// The search window the user is working in.
    var frontController: SearchWindowController? {
        if let wc = NSApp.keyWindow?.windowController as? SearchWindowController { return wc }
        if let wc = NSApp.mainWindow?.windowController as? SearchWindowController { return wc }
        if let wc = lastKeyController, windows.contains(where: { $0 === wc }) { return wc }
        return windows.last
    }

    /// Shows an existing search window, or opens one.
    func showWindow() {
        if let wc = frontController {
            if wc.window?.isMiniaturized == true { wc.window?.deminiaturize(nil) }
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            if model.settings.focusSearchOnActivate { wc.focusSearch(nil) }
        } else {
            openSearchWindow()
        }
    }

    /// Hides the app when a search window is in front, otherwise shows one.
    func toggleWindow() {
        if NSApp.isActive, NSApp.keyWindow?.windowController is SearchWindowController {
            NSApp.hide(nil)
        } else {
            showWindow()
        }
    }

    func windowClosed(_ wc: SearchWindowController) {
        windows.removeAll { $0 === wc }
        if windows.isEmpty && !model.settings.runInBackground {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func closeAllWindows() {
        for w in windows { w.window?.performClose(nil) }
    }

    @objc func windowBecameKey(_ n: Notification) {
        if let wc = (n.object as? NSWindow)?.windowController as? SearchWindowController { lastKeyController = wc }
    }

    // MARK: - Settings side effects

    @objc func settingsChanged() {
        let s = model.settings
        let old = applied
        applied = s
        if old.theme != s.theme { Theme.apply(s.theme) }
        if old.showDockIcon != s.showDockIcon { applyActivationPolicy() }
        if old.showMenuBarIcon != s.showMenuBarIcon { updateStatusItem() }
        if old.hotkeyNewWindow != s.hotkeyNewWindow || old.hotkeyShowWindow != s.hotkeyShowWindow ||
            old.hotkeyToggleWindow != s.hotkeyToggleWindow { registerHotkeys() }
        if old.shortcuts != s.shortcuts, let menu = NSApp.mainMenu { MainMenuBuilder.shared.applyCustomShortcuts(menu) }
        if old.startAtLogin != s.startAtLogin { applyLoginItem(s.startAtLogin) }
        applyServers()
    }

    @objc func filtersChanged() { MainMenuBuilder.shared.rebuildSearchMenu() }
    @objc func bookmarksChanged() { MainMenuBuilder.shared.rebuildBookmarksMenu() }

    func applyActivationPolicy() {
        let show = model.settings.showDockIcon
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if !show && !model.settings.showMenuBarIcon { updateStatusItem() }
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    func applyLoginItem(_ on: Bool) {
        let svc = SMAppService.mainApp
        do {
            if on {
                if svc.status != .enabled { try svc.register() }
                let here = Bundle.main.bundlePath
                if model.settings.loginItemPath != here { model.rememberState { $0.loginItemPath = here } }
            } else if svc.status == .enabled || svc.status == .requiresApproval {
                try svc.unregister()
            }
            model.log.write("login item \(on ? "on" : "off"): status \(svc.status.rawValue)")
        } catch {
            model.log.write("login item change failed: \(error)")
        }
    }

    /// When "Start at login" is on, make the login item open this copy if it is the better one:
    /// the copy in /Applications wins over a build folder, and a missing copy is replaced.
    func adoptLoginItemIfNeeded() {
        let s = model.settings
        guard s.startAtLogin else { return }
        let here = Bundle.main.bundlePath
        let registered = s.loginItemPath
        guard registered != here else { return }
        let registeredGone = registered.isEmpty || !FileManager.default.fileExists(atPath: registered)
        let hereIsInstalled = here.hasPrefix("/Applications/")
        let registeredIsInstalled = registered.hasPrefix("/Applications/")
        guard registeredGone || (hereIsInstalled && !registeredIsInstalled) else { return }
        let svc = SMAppService.mainApp
        try? svc.unregister()
        do {
            try svc.register()
            model.rememberState { $0.loginItemPath = here }
            model.log.write("login item now opens \(here)")
        } catch {
            model.log.write("login item update failed: \(error)")
        }
    }

    func registerHotkeys() {
        let s = model.settings
        let hk = HotKeyCenter.shared
        hk.unregisterAll()
        var failed: [String] = []
        if let c = s.hotkeyNewWindow, !hk.register(c, id: 1, handler: { [weak self] in self?.openSearchWindow() }) { failed.append(c.display) }
        if let c = s.hotkeyShowWindow, !hk.register(c, id: 2, handler: { [weak self] in self?.showWindow() }) { failed.append(c.display) }
        if let c = s.hotkeyToggleWindow, !hk.register(c, id: 3, handler: { [weak self] in self?.toggleWindow() }) { failed.append(c.display) }
        if !failed.isEmpty { model.log.write("could not register hotkeys (in use by another app?): \(failed.joined(separator: ", "))") }
    }

    // MARK: - Menu bar icon

    func updateStatusItem() {
        let s = model.settings
        // Always keep a way back into the app when the Dock icon is hidden.
        let want = s.showMenuBarIcon || !s.showDockIcon
        if want && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let b = item.button {
                let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Epitome")
                img?.isTemplate = true
                b.image = img
                b.target = self
                b.action = #selector(statusItemClicked(_:))
                b.sendAction(on: [.leftMouseUp, .rightMouseUp])
                b.toolTip = "Epitome"
            }
            statusItem = item
        } else if !want, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc func statusItemClicked(_ sender: Any?) {
        let ev = NSApp.currentEvent
        let right = ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true
        if right || !model.settings.menuBarClickOpensWindow {
            showStatusMenu()
        } else if model.settings.newWindowFromMenuBar {
            openSearchWindow()
        } else {
            showWindow()
        }
    }

    func showStatusMenu() {
        guard let item = statusItem else { return }
        let m = NSMenu()
        m.addItem(withTitle: "New Search Window", action: #selector(newSearchWindow(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Show Epitome", action: #selector(showWindowAction(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        let st = model.manager.status
        let info = NSMenuItem(title: statusLine(st), action: nil, keyEquivalent: "")
        info.isEnabled = false
        m.addItem(info)
        let pause = NSMenuItem(title: "Pause Updating", action: #selector(togglePauseMonitoring(_:)), keyEquivalent: "")
        pause.target = self
        pause.state = model.manager.isPaused ? .on : .off
        m.addItem(pause)
        m.addItem(withTitle: "Rescan All Folders Now", action: #selector(rescanAllFolders(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(showOptions(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Quit Epitome", action: #selector(quitApp(_:)), keyEquivalent: "").target = self
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    func statusLine(_ st: IndexStatus) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: model.manager.index.liveCount), number: .decimal)
        switch st.phase {
        case .ready, .idle: return "\(n) items indexed"
        case .paused: return "Updating paused · \(n) items"
        default: return st.message.isEmpty ? "Indexing…" : st.message
        }
    }

    func statusChanged(_ st: IndexStatus) {
        statusItem?.button?.toolTip = "Epitome — " + statusLine(st)
    }

    @objc func showWindowAction(_ sender: Any?) { showWindow() }

    // MARK: - IPC and network servers

    func startIPC() {
        do {
            let server = try IPCServer(path: IPCPaths.socketPath(instance: model.instance), manager: model.manager)
            server.filters = { AppModel.shared.filterSpecs() }
            server.control = { [weak self] req in self?.handleIPC(req) }
            server.start()
            ipc = server
        } catch {
            model.log.write("IPC server failed: \(error)")
        }
    }

    /// Runs on the IPC thread; UI work hops to the main thread.
    func handleIPC(_ req: IPCRequest) -> String? {
        switch req.cmd {
        case "gui":
            let args = req.args ?? []
            DispatchQueue.main.async { self.handleGUI(args.isEmpty ? ["-show"] : args) }
            return "ok"
        case "exit", "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return "quitting"
        case "show":
            DispatchQueue.main.async { self.showWindow() }
            return "ok"
        case "new-window":
            DispatchQueue.main.async { self.openSearchWindow() }
            return "ok"
        case "toggle-window":
            DispatchQueue.main.async { self.toggleWindow() }
            return "ok"
        case "monitor-pause":
            model.manager.pauseMonitoring()
            return "paused"
        case "monitor-resume":
            model.manager.resumeMonitoring()
            return "resumed"
        case "rescan":
            if let p = req.path { model.manager.rescan(path: p); return "rescanning \(p)" }
            return nil
        default:
            return nil
        }
    }

    func applyServers() {
        let s = model.settings
        let logDir = model.supportDir

        var hc = HTTPServer.Config()
        hc.port = UInt16(clamping: s.httpPort)
        hc.bind = s.httpBind
        hc.username = s.httpUsername
        hc.password = s.httpPassword
        hc.allowDownload = s.httpAllowDownload
        hc.logging = s.httpLogging
        hc.logPath = logDir.appendingPathComponent("HTTP Server.log").path
        hc.logMaxKB = s.httpLogMaxKB
        hc.defaultPage = s.httpDefaultPage
        hc.servePagesFrom = s.httpServePagesFrom
        hc.title = model.instance.isEmpty ? "Epitome" : "Epitome (\(model.instance))"
        http.filters = { AppModel.shared.filterSpecs() }
        if s.httpEnabled {
            if !http.isRunning || http.config != hc {
                http.stop()
                do {
                    try http.start(hc)
                    model.log.write("HTTP server listening on port \(http.boundPort)")
                } catch {
                    model.log.write("HTTP server failed: \(error)")
                    flash("HTTP server could not start: \(error)")
                }
            }
        } else if http.isRunning {
            http.stop()
            model.log.write("HTTP server stopped")
        }

        var ec = ETPServer.Config()
        ec.port = UInt16(clamping: s.etpPort)
        ec.bind = s.etpBind
        ec.username = s.etpUsername
        ec.password = s.etpPassword
        ec.allowDownload = s.etpAllowDownload
        ec.logging = s.etpLogging
        ec.logPath = logDir.appendingPathComponent("ETP Server.log").path
        ec.logMaxKB = s.etpLogMaxKB
        ec.welcome = s.etpWelcome
        etp.filters = { AppModel.shared.filterSpecs() }
        if s.etpEnabled {
            if !etp.isRunning || etp.config != ec {
                etp.stop()
                do {
                    try etp.start(ec)
                    model.log.write("ETP server listening on port \(etp.boundPort)")
                } catch {
                    model.log.write("ETP server failed: \(error)")
                    flash("ETP server could not start: \(error)")
                }
            }
        } else if etp.isRunning {
            etp.stop()
            model.log.write("ETP server stopped")
        }
    }

    func flash(_ s: String) { frontController?.statusBar.flash(s) }

    // MARK: - Services menu ("Search in Epitome")

    @objc func searchInEpitome(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var args: [String] = []
            for u in urls.prefix(1) { args.append(u.path) }
            handleGUI(args + ["-newwindow"])
        } else if let text = pboard.string(forType: .string) {
            handleGUI(["-newwindow", "-search", text.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    // MARK: - Menu commands

    @objc func newSearchWindow(_ sender: Any?) {
        // A new window inherits the current window's search when Option is held.
        if NSEvent.modifierFlags.contains(.option), let wc = frontController {
            openSearchWindow(state: wc.state, source: wc.source)
        } else {
            openSearchWindow()
        }
    }

    @objc func quitApp(_ sender: Any?) { NSApp.terminate(nil) }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(string: "Instant file-name search for macOS.\nA clean-room implementation inspired by the features of voidtools Everything.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Epitome",
            .applicationVersion: EpitomeVersion.string,
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showOptions(_ sender: Any?) {
        if optionsController == nil { optionsController = OptionsWindowController() }
        optionsController?.reload()
        optionsController?.showWindow(nil)
        optionsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showPanel<T: NSWindowController>(_ key: String, _ make: () -> T) -> T {
        if let p = panels[key] as? T {
            p.showWindow(nil)
            p.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return p
        }
        let p = make()
        panels[key] = p
        p.showWindow(nil)
        p.window?.center()
        p.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return p
    }

    @objc func showSearchHistory(_ sender: Any?) { _ = showPanel("history") { SearchHistoryWindowController() } }
    @objc func showRunHistory(_ sender: Any?) { _ = showPanel("runs") { RunHistoryWindowController() } }
    @objc func showJournal(_ sender: Any?) { _ = showPanel("journal") { JournalWindowController() } }
    @objc func showStatistics(_ sender: Any?) { _ = showPanel("stats") { StatisticsWindowController() } }
    @objc func showDebugConsole(_ sender: Any?) { _ = showPanel("debug") { DebugConsoleWindowController() } }
    @objc func organizeFilters(_ sender: Any?) { _ = showPanel("filters") { OrganizeWindowController(kind: .filters) } }
    @objc func organizeBookmarks(_ sender: Any?) { _ = showPanel("bookmarks") { OrganizeWindowController(kind: .bookmarks) } }
    @objc func showFileListEditor(_ sender: Any?) { showFileListEditor(path: nil) }

    func showFileListEditor(path: String?) {
        let ed = showPanel("filelist") { FileListEditorWindowController() }
        if let p = path { ed.load(path: p) }
    }

    func showOnboarding() { _ = showPanel("onboarding") { OnboardingWindowController() } }

    @objc func showAdvancedSearch(_ sender: Any?) {
        guard let wc = frontController ?? windows.last else { return }
        let a = showPanel("advanced") { AdvancedSearchWindowController() }
        a.target = wc
    }

    @objc func connectETP(_ sender: Any?) {
        ConnectETPDialog.run { [weak self] link in
            guard let self, let link else { return }
            self.connectETP(link: link, window: self.frontController ?? self.openSearchWindow())
        }
    }

    func connectETP(link: String, window wc: SearchWindowController) {
        guard let client = ETPClient(link: link) else { _ = alert("Not a valid server address", link); return }
        wc.statusBar.flash("Connecting to \(client.label)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = client.connect()
            DispatchQueue.main.async {
                if ok {
                    wc.connect(client)
                    let recent = link.replacingOccurrences(of: #":[^:@/]*@"#, with: "@", options: .regularExpression)
                    self.model.rememberState { s in
                        s.etpRecent.removeAll { $0 == recent }
                        s.etpRecent.insert(recent, at: 0)
                        if s.etpRecent.count > 10 { s.etpRecent.removeLast(s.etpRecent.count - 10) }
                    }
                } else {
                    _ = alert("Could not connect to \(client.label)", client.lastError)
                }
            }
        }
    }

    @objc func createFileListFromFolder(_ sender: Any?) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Choose"
        p.message = "Choose the folders to put in the file list."
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let folders = p.urls.map(\.path)
        let save = NSSavePanel()
        save.nameFieldStringValue = ((folders[0] as NSString).lastPathComponent) + ".efu"
        guard save.runModal() == .OK, let out = save.url else { return }
        flash("Creating file list…")
        let opts = model.settings.scanOptions
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var all = FileList()
            for f in folders { all.entries += FileList.create(fromFolder: f, options: opts).entries }
            let text = FileList.write(all)
            DispatchQueue.main.async {
                do {
                    try text.write(to: out, atomically: true, encoding: .utf8)
                    self?.flash("Wrote \(all.entries.count) items to \(out.lastPathComponent)")
                } catch {
                    NSApp.presentError(error)
                }
            }
        }
    }

    @objc func forceRebuild(_ sender: Any?) {
        guard alert("Rebuild the index?", "Epitome scans every included volume, folder and file list again. Searching keeps working on the current index until the new one is ready.",
                    style: .informational, buttons: ["Rebuild", "Cancel"]) == .alertFirstButtonReturn else { return }
        model.manager.rebuild()
    }

    @objc func rescanAllFolders(_ sender: Any?) {
        model.manager.rescanAllFolders()
        flash("Rescanning folders…")
    }

    @objc func saveDatabase(_ sender: Any?) {
        model.manager.save()
        flash("Saving database…")
    }

    @objc func togglePauseMonitoring(_ sender: Any?) {
        if model.manager.isPaused { model.manager.resumeMonitoring() } else { model.manager.pauseMonitoring() }
        NotificationCenter.default.post(name: AppModel.statusChanged, object: nil)
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        let src = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ep").path
        guard FileManager.default.fileExists(atPath: src) else {
            _ = alert("The ep tool is missing from this copy of Epitome", src)
            return
        }
        let dest = "/usr/local/bin/ep"
        guard alert("Install the “ep” command?",
                    "Creates \(dest), a link to the command-line search tool inside Epitome, so you can search from Terminal (try “ep -help”). macOS will ask for an administrator password.",
                    style: .informational, buttons: ["Install", "Cancel"]) == .alertFirstButtonReturn else { return }
        func sq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shell = "mkdir -p /usr/local/bin && ln -sf \(sq(src)) \(sq(dest))"
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let e = err {
            if (e[NSAppleScript.errorNumber] as? Int) != -128 { _ = alert("Could not install the command", "\(e[NSAppleScript.errorMessage] ?? e)") }
        } else {
            _ = alert("Installed", "Type “ep something” in Terminal to search. Epitome must be running.", style: .informational)
        }
    }

    // Settings import/export (Tools menu and >config_save / >config_load).
    @objc func exportSettingsAction(_ sender: Any?) { exportSettings() }
    @objc func importSettingsAction(_ sender: Any?) { importSettings() }

    func exportSettings() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Epitome Settings.json"
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        model.settings.save(to: url)
    }

    func importSettings() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }
        guard let s = AppSettings.decodeMerged(data) else {
            _ = alert("Not an Epitome settings file", url.path)
            return
        }
        model.setSettings(s)
        if alert("Settings imported", "Some settings take effect after Epitome restarts.", style: .informational,
                 buttons: ["Restart Now", "Later"]) == .alertFirstButtonReturn { restart() }
    }

    func restart() {
        var args = ["-n", Bundle.main.bundlePath, "--args"]
        if !model.instance.isEmpty { args += ["-instance", model.instance] }
        if let c = launch.config { args += ["-config", c] }
        if let d = launch.debugLog { args += ["-debuglog", d] }
        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1.5; /usr/bin/open \(quoted)"]
        try? p.run()
        NSApp.terminate(nil)
    }

    // Help
    func showHelp(page: String) {
        let h = showPanel("help") { HelpWindowController() }
        h.show(page: page)
    }

    @objc func showHelpAction(_ sender: Any?) { showHelp(page: "index") }
    @objc func showSyntaxHelp(_ sender: Any?) { showHelp(page: "syntax") }
    @objc func showRegexHelp(_ sender: Any?) { showHelp(page: "regex") }
    @objc func showCommandLineHelp(_ sender: Any?) { showHelp(page: "cmdline") }

    // Bookmarks and functions
    @objc func openBookmarkItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let b = model.bookmarks.current.first(where: { $0.id.uuidString == id }) else { return }
        let newWindow = NSEvent.modifierFlags.contains(.option) || windows.isEmpty
        let wc = newWindow ? openSearchWindow() : (frontController ?? openSearchWindow())
        wc.openBookmark(b)
        wc.showWindow(nil)
    }

    @objc func insertFunction(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let wc = frontController else { return }
        wc.window?.makeFirstResponder(wc.searchField)
        if let ed = wc.searchField.currentEditor() as? NSTextView {
            ed.insertText(text, replacementRange: ed.selectedRange())
        } else {
            wc.searchText += text
        }
        wc.runSearch()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePauseMonitoring(_:)):
            item.state = model.manager.isPaused ? .on : .off
        case #selector(showAdvancedSearch(_:)), #selector(insertFunction(_:)):
            return frontController != nil
        case #selector(forceRebuild(_:)), #selector(rescanAllFolders(_:)), #selector(saveDatabase(_:)):
            return !model.manager.readOnly
        default:
            break
        }
        return true
    }
}
