import AppKit
import EpitomeCore

/// A menu key equivalent for a function key constant (NSF2FunctionKey …).
func fkey(_ v: Int) -> String { String(Character(Unicode.Scalar(UInt32(v))!)) }

/// Builds the menu bar. Every item carries an identifier ("File | New Search Window")
/// so its shortcut can be changed in Options → Keyboard.
final class MainMenuBuilder: NSObject, NSMenuDelegate {
    static let shared = MainMenuBuilder()
    let searchMenu = NSMenu(title: "Search")
    let bookmarksMenu = NSMenu(title: "Bookmarks")
    let insertFunctionMenu = NSMenu(title: "Insert Function")
    private(set) var defaultShortcuts: [String: (String, NSEvent.ModifierFlags)] = [:]

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                      target: AnyObject? = nil) {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.target = target
        let id = "\(menu.title) | \(title)"
        i.identifier = NSUserInterfaceItemIdentifier(id)
        defaultShortcuts[id] = (key, key.isEmpty ? [] : mods)
        menu.addItem(i)
    }

    private func sub(_ parent: NSMenu, _ title: String, _ build: (NSMenu) -> Void) {
        let m = NSMenu(title: title)
        build(m)
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = m
        parent.addItem(i)
    }

    func build() -> NSMenu {
        let main = NSMenu()
        let app = NSApp.delegate as AnyObject?
        typealias W = SearchWindowController
        typealias A = AppDelegate

        // App
        let appMenu = NSMenu(title: "Epitome")
        item(appMenu, "About Epitome", #selector(A.showAbout(_:)), target: app)
        appMenu.addItem(.separator())
        item(appMenu, "Settings…", #selector(A.showOptions(_:)), ",", target: app)
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let si = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        si.submenu = services
        appMenu.addItem(si)
        appMenu.addItem(.separator())
        item(appMenu, "Hide Epitome", #selector(NSApplication.hide(_:)), "h")
        item(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(appMenu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        item(appMenu, "Quit Epitome", #selector(A.quitApp(_:)), "q", target: app)
        add(main, appMenu)

        // File
        let file = NSMenu(title: "File")
        item(file, "New Search Window", #selector(A.newSearchWindow(_:)), "n", target: app)
        item(file, "Open File List…", #selector(W.openFileListPanel(_:)), "o")
        item(file, "Close File List", #selector(W.closeFileList(_:)))
        item(file, "Export…", #selector(W.exportResults(_:)), "s")
        file.addItem(.separator())
        item(file, "Open", #selector(W.openSelection(_:)), fkey(NSDownArrowFunctionKey))
        item(file, "Show in Finder", #selector(W.revealSelection(_:)), "r")
        item(file, "Explore", #selector(W.exploreSelection(_:)))
        item(file, "Explore Path", #selector(W.explorePath(_:)))
        item(file, "Open With Other Application…", #selector(W.openWithOther(_:)))
        item(file, "Open Most Run", #selector(W.openMostRun(_:)))
        item(file, "Open Last Run", #selector(W.openLastRun(_:)))
        file.addItem(.separator())
        item(file, "Get Info", #selector(W.showProperties(_:)), "i")
        item(file, "Show Finder Info", #selector(W.finderGetInfo(_:)))
        item(file, "Rename", #selector(W.renameSelection(_:)), fkey(NSF2FunctionKey), [])
        item(file, "Move to Trash", #selector(W.moveToTrash(_:)), "\u{8}")
        item(file, "Delete Immediately…", #selector(W.deletePermanently(_:)), "\u{8}", [.command, .option])
        file.addItem(.separator())
        item(file, "Copy Name", #selector(W.copyName(_:)))
        item(file, "Copy Path", #selector(W.copyPath(_:)))
        item(file, "Copy Full Path", #selector(W.copyFullPath(_:)), "c", [.command, .option])
        item(file, "Set Run Count…", #selector(W.setRunCount(_:)))
        item(file, "Read Extended Information", #selector(W.readExtendedInformation(_:)), "e")
        file.addItem(.separator())
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        add(main, file)

        // Edit
        let edit = NSMenu(title: "Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        item(edit, "Invert Selection", #selector(W.invertSelection(_:)), "i", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Copy to Folder…", #selector(W.copyToFolder(_:)))
        item(edit, "Move to Folder…", #selector(W.moveToFolder(_:)))
        edit.addItem(.separator())
        item(edit, "Find", #selector(W.focusSearch(_:)), "f")
        item(edit, "Focus Search", #selector(W.focusSearch(_:)), "l")
        let ifi = NSMenuItem(title: "Insert Function", action: nil, keyEquivalent: "")
        insertFunctionMenu.delegate = self
        ifi.submenu = insertFunctionMenu
        edit.addItem(ifi)
        add(main, edit)

        // View
        let view = NSMenu(title: "View")
        item(view, "Filter Bar", #selector(W.toggleFilterBar(_:)))
        item(view, "Preview", #selector(W.togglePreview(_:)), "p", [.command, .option])
        item(view, "Status Bar", #selector(W.toggleStatusBar(_:)))
        view.addItem(.separator())
        item(view, "Details", #selector(W.viewDetails(_:)), "1", [.command, .control])
        item(view, "Medium Thumbnails", #selector(W.viewMedium(_:)), "2", [.command, .control])
        item(view, "Large Thumbnails", #selector(W.viewLarge(_:)), "3", [.command, .control])
        item(view, "Extra Large Thumbnails", #selector(W.viewExtraLarge(_:)), "4", [.command, .control])
        item(view, "Increase Thumbnail Size", #selector(W.increaseThumbnails(_:)), "=", [.command, .option])
        item(view, "Decrease Thumbnail Size", #selector(W.decreaseThumbnails(_:)), "-", [.command, .option])
        view.addItem(.separator())
        sub(view, "Window Size") { m in
            self.item(m, "Small", #selector(W.windowSizeSmall(_:)), "1", [.control, .option])
            self.item(m, "Medium", #selector(W.windowSizeMedium(_:)), "2", [.control, .option])
            self.item(m, "Large", #selector(W.windowSizeLarge(_:)), "3", [.control, .option])
            self.item(m, "Auto Fit", #selector(W.windowSizeAutoFit(_:)), "4", [.control, .option])
        }
        sub(view, "Zoom") { m in
            self.item(m, "Zoom In", #selector(W.zoomIn(_:)), "=")
            self.item(m, "Zoom Out", #selector(W.zoomOut(_:)), "-")
            self.item(m, "Actual Size", #selector(W.zoomReset(_:)), "0")
        }
        sub(view, "Go To") { m in
            self.item(m, "Back", #selector(W.goBack(_:)), "[")
            self.item(m, "Forward", #selector(W.goForward(_:)), "]")
            self.item(m, "Home", #selector(W.goHome(_:)), "h", [.command, .shift])
            m.addItem(.separator())
            self.item(m, "Show All Search History", #selector(A.showSearchHistory(_:)), "y", target: app)
        }
        sub(view, "Sort By") { m in
            self.item(m, "Name", #selector(W.sortByName(_:)), "1")
            self.item(m, "Path", #selector(W.sortByPath(_:)), "2")
            self.item(m, "Size", #selector(W.sortBySize(_:)), "3")
            self.item(m, "Extension", #selector(W.sortByExtension(_:)), "4")
            self.item(m, "Type", #selector(W.sortByType(_:)), "5")
            self.item(m, "Date Modified", #selector(W.sortByDateModified(_:)), "6")
            self.item(m, "Date Created", #selector(W.sortByDateCreated(_:)), "7")
            self.item(m, "Attributes", #selector(W.sortByAttributes(_:)), "8")
            self.item(m, "Date Recently Changed", #selector(W.sortByRecentlyChanged(_:)), "9")
            self.item(m, "File List Filename", #selector(W.sortByFileList(_:)))
            self.item(m, "Run Count", #selector(W.sortByRunCount(_:)))
            self.item(m, "Date Run", #selector(W.sortByDateRun(_:)))
            self.item(m, "Date Accessed", #selector(W.sortByDateAccessed(_:)))
            m.addItem(.separator())
            self.item(m, "Ascending", #selector(W.sortAscending(_:)))
            self.item(m, "Descending", #selector(W.sortDescending(_:)))
        }
        view.addItem(.separator())
        item(view, "Refresh", #selector(W.refresh(_:)), fkey(NSF5FunctionKey), [])
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        sub(view, "On Top") { m in
            self.item(m, "Never", #selector(W.onTopNever(_:)))
            self.item(m, "Always", #selector(W.onTopAlways(_:)), "t", [.command, .option])
            self.item(m, "While Searching", #selector(W.onTopWhileSearching(_:)))
        }
        add(main, view)

        // Search (filters are listed dynamically)
        searchMenu.delegate = self
        rebuildSearchMenu()
        add(main, searchMenu)

        // Bookmarks
        bookmarksMenu.delegate = self
        rebuildBookmarksMenu()
        add(main, bookmarksMenu)

        // Tools
        let tools = NSMenu(title: "Tools")
        item(tools, "Options…", #selector(A.showOptions(_:)), target: app)
        tools.addItem(.separator())
        item(tools, "File List Editor…", #selector(A.showFileListEditor(_:)), target: app)
        item(tools, "Create File List from Folder…", #selector(A.createFileListFromFolder(_:)), target: app)
        item(tools, "Index Journal", #selector(A.showJournal(_:)), "j", [.command, .option], target: app)
        item(tools, "Search History…", #selector(A.showSearchHistory(_:)), target: app)
        item(tools, "Run History…", #selector(A.showRunHistory(_:)), target: app)
        tools.addItem(.separator())
        item(tools, "Connect to ETP Server…", #selector(A.connectETP(_:)), target: app)
        item(tools, "Disconnect from ETP Server", #selector(W.closeFileList(_:)))
        tools.addItem(.separator())
        sub(tools, "Indexes") { m in
            self.item(m, "Force Rebuild", #selector(A.forceRebuild(_:)), target: app)
            self.item(m, "Rescan All Folders Now", #selector(A.rescanAllFolders(_:)), target: app)
            self.item(m, "Save Database Now", #selector(A.saveDatabase(_:)), target: app)
            self.item(m, "Pause Updating", #selector(A.togglePauseMonitoring(_:)), target: app)
            m.addItem(.separator())
            self.item(m, "Statistics…", #selector(A.showStatistics(_:)), target: app)
        }
        tools.addItem(.separator())
        item(tools, "Install Command Line Tool…", #selector(A.installCommandLineTool(_:)), target: app)
        item(tools, "Debug Console", #selector(A.showDebugConsole(_:)), "`", [.command, .option], target: app)
        item(tools, "Import Settings…", #selector(A.importSettingsAction(_:)), target: app)
        item(tools, "Export Settings…", #selector(A.exportSettingsAction(_:)), target: app)
        add(main, tools)

        // Window
        let window = NSMenu(title: "Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        item(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window
        add(main, window)

        // Help
        let help = NSMenu(title: "Help")
        item(help, "Epitome Help", #selector(A.showHelpAction(_:)), "?", target: app)
        item(help, "Search Syntax", #selector(A.showSyntaxHelp(_:)), target: app)
        item(help, "Regex Syntax", #selector(A.showRegexHelp(_:)), target: app)
        item(help, "Command Line Options", #selector(A.showCommandLineHelp(_:)), target: app)
        NSApp.helpMenu = help
        add(main, help)

        applyCustomShortcuts(main)
        return main
    }

    private func add(_ main: NSMenu, _ m: NSMenu) {
        let i = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
        i.submenu = m
        main.addItem(i)
    }

    func rebuildSearchMenu() {
        typealias W = SearchWindowController
        let m = searchMenu
        m.removeAllItems()
        item(m, "Match Case", #selector(W.toggleMatchCase(_:)), "i", [.command, .option])
        item(m, "Match Whole Word", #selector(W.toggleWholeWord(_:)), "b", [.command, .option])
        item(m, "Match Path", #selector(W.toggleMatchPath(_:)), "u", [.command, .option])
        item(m, "Match Diacritics", #selector(W.toggleDiacritics(_:)), "a", [.command, .option])
        item(m, "Enable Regex", #selector(W.toggleRegex(_:)), "r", [.command, .option])
        m.addItem(.separator())
        item(m, "Advanced Search…", #selector(AppDelegate.showAdvancedSearch(_:)), "f", [.command, .option], target: NSApp.delegate as AnyObject?)
        m.addItem(.separator())
        for f in AppModel.shared.filters.current {
            let i = NSMenuItem(title: f.name, action: #selector(W.selectFilterItem(_:)), keyEquivalent: f.shortcut?.key ?? "")
            i.keyEquivalentModifierMask = f.shortcut?.modifierMask ?? []
            i.representedObject = f.id.uuidString
            m.addItem(i)
        }
        m.addItem(.separator())
        item(m, "Add to Filters…", #selector(W.addToFilters(_:)))
        item(m, "Organize Filters…", #selector(AppDelegate.organizeFilters(_:)), "f", [.command, .shift], target: NSApp.delegate as AnyObject?)
        applyCustomShortcuts(m)
    }

    func rebuildBookmarksMenu() {
        let m = bookmarksMenu
        m.removeAllItems()
        item(m, "Add to Bookmarks…", #selector(SearchWindowController.addBookmark(_:)), "d")
        item(m, "Organize Bookmarks…", #selector(AppDelegate.organizeBookmarks(_:)), "b", [.command, .shift], target: NSApp.delegate as AnyObject?)
        let bms = AppModel.shared.bookmarks.current
        if !bms.isEmpty { m.addItem(.separator()) }
        var folders: [String: NSMenu] = [:]
        for b in bms {
            let i = NSMenuItem(title: b.name, action: #selector(AppDelegate.openBookmarkItem(_:)), keyEquivalent: b.shortcut?.key ?? "")
            i.keyEquivalentModifierMask = b.shortcut?.modifierMask ?? []
            i.representedObject = b.id.uuidString
            i.target = NSApp.delegate as AnyObject?
            if b.folder.isEmpty {
                m.addItem(i)
            } else {
                var parent = m
                var acc = ""
                for comp in b.folder.split(separator: "/") {
                    acc += "/" + comp
                    if let existing = folders[acc] { parent = existing; continue }
                    let sm = NSMenu(title: String(comp))
                    let si = NSMenuItem(title: String(comp), action: nil, keyEquivalent: "")
                    si.submenu = sm
                    parent.addItem(si)
                    folders[acc] = sm
                    parent = sm
                }
                parent.addItem(i)
            }
        }
        applyCustomShortcuts(m)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === insertFunctionMenu {
            menu.removeAllItems()
            let modifiers = ["case:", "nocase:", "diacritics:", "file:", "folder:", "path:", "nopath:", "regex:", "wfn:", "ww:", "wildcards:", "nowildcards:"]
            let ms = NSMenu(title: "Modifiers")
            for f in modifiers {
                let i = NSMenuItem(title: f, action: #selector(AppDelegate.insertFunction(_:)), keyEquivalent: "")
                i.target = NSApp.delegate as AnyObject?
                i.representedObject = f
                ms.addItem(i)
            }
            let mi = NSMenuItem(title: "Modifiers", action: nil, keyEquivalent: "")
            mi.submenu = ms
            menu.addItem(mi)
            menu.addItem(.separator())
            for f in QueryCompiler.functionNames {
                let i = NSMenuItem(title: f + ":", action: #selector(AppDelegate.insertFunction(_:)), keyEquivalent: "")
                i.target = NSApp.delegate as AnyObject?
                i.representedObject = f + ":"
                menu.addItem(i)
            }
        }
    }

    /// Applies Options → Keyboard customisations.
    func applyCustomShortcuts(_ menu: NSMenu) {
        let custom = AppModel.shared.settings.shortcuts
        for i in menu.items {
            if let sub = i.submenu { applyCustomShortcuts(sub) }
            guard let id = i.identifier?.rawValue else { continue }
            if let list = custom[id] {
                if let c = list.first {
                    i.keyEquivalent = c.key
                    i.keyEquivalentModifierMask = c.modifierMask
                } else {
                    i.keyEquivalent = ""
                }
            } else if let d = defaultShortcuts[id] {
                i.keyEquivalent = d.0
                i.keyEquivalentModifierMask = d.1
            }
        }
    }

    /// Every command with an identifier, for the Keyboard options page.
    func allCommands(_ menu: NSMenu? = NSApp.mainMenu) -> [NSMenuItem] {
        guard let menu else { return [] }
        var out: [NSMenuItem] = []
        for i in menu.items {
            if let s = i.submenu { out += allCommands(s) }
            if i.identifier != nil && i.action != nil { out.append(i) }
        }
        return out
    }
}
