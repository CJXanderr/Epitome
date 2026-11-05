import AppKit
import EpitomeCore

/// Switches that must be known before the app object exists (instance, settings
/// and database location, help, file-list creation). Everything else is passed
/// through as "GUI arguments" and applied to a search window (see `GUICommand`).
struct LaunchOptions {
    var instance = ""
    var config: String?
    var db: String?
    var readOnly = false
    var noDB = false
    var debugLog: String?
    var startup = false
    var help = false
    var exitRunning = false
    var firstInstanceOnly = false
    var onlyIfRunning = false
    var createFileList: (output: String, paths: [String])?
    var createOptions = ScanOptions()
    var createNoSubfolders = false
    var createNoFolders = false
    var createNoFiles = false
    var guiArgs: [String] = []

    /// Removes dashes and lower-cases a switch name ("-No-New-Window" → "nonewwindow").
    static func norm(_ s: String) -> String {
        var t = Substring(s)
        while t.hasPrefix("-") { t = t.dropFirst() }
        return String(t).lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    }

    static func parse(_ argv: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 0
        func next() -> String? {
            guard i + 1 < argv.count else { return nil }
            i += 1
            return argv[i]
        }
        while i < argv.count {
            let a = argv[i]
            defer { i += 1 }
            // Cocoa and LaunchServices add their own arguments.
            if a.hasPrefix("-psn_") { continue }
            if a.hasPrefix("-NS") || a.hasPrefix("-Apple") {
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") { i += 1 }
                continue
            }
            guard a.hasPrefix("-"), a.count > 1 else { o.guiArgs.append(a); continue }
            if a == "--" { o.guiArgs.append(contentsOf: argv[(i + 1)...]); i = argv.count; continue }
            switch norm(a) {
            case "instance": o.instance = next() ?? ""
            case "config": o.config = next()
            case "db": o.db = next()
            case "readonly": o.readOnly = true
            case "nodb": o.noDB = true
            case "debuglog":
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") { o.debugLog = next() }
            case "startup": o.startup = true
            case "?", "h", "help": o.help = true
            case "exit", "quit": o.exitRunning = true
            case "firstinstance": o.firstInstanceOnly = true
            case "nofirstinstance": o.onlyIfRunning = true
            case "createfilelist":
                if let out = next(), let p = next() {
                    o.createFileList = (out, p.split(separator: ";").map { String($0) })
                }
            case "createfilelistexcludefiles":
                o.createOptions.excludeFiles = (next() ?? "").split(separator: ";").map(String.init)
            case "createfilelistexcludefolders":
                o.createOptions.excludeFolders = (next() ?? "").split(separator: ";").map(String.init)
            case "createfilelistincludeonlyfiles":
                o.createOptions.includeOnlyFiles = (next() ?? "").split(separator: ";").map(String.init)
            case "createfilelistnosubfolders": o.createNoSubfolders = true
            case "createfilelistnofolders": o.createNoFolders = true
            case "createfilelistnofiles": o.createNoFiles = true
            default:
                o.guiArgs.append(a)
            }
        }
        return o
    }

    static let helpText = """
    Epitome — instant file-name search for macOS

    Usage: Epitome [file.efu | file | folder] [switches]
           ep [search] [options]          (command-line search, see ep -help)

    Searching
      -s, -search <text>        Set the search text.
      -p, -path <folder>        Search inside a folder (and its subfolders).
      -parent <folder>          Only items directly inside a folder.
      -parent-path <file>       Search inside the folder that contains a file.
      -filename <file>          Search for that file (a folder: its contents).
      -name-part <file>         Search for that exact name.
      -stem <file>, -extension <file>   Same name stem / same extension.
      -search-file-list <txt>   Search for the names listed in a text file.
      -case -nocase -wholeword -nowholeword -ww -noww -matchpath -nomatchpath
      -diacritics -nodiacritics -regex -noregex
      -filter <name>            Activate a filter.
      -bookmark <name>          Open a bookmark.
      -home                     Load the home search.
      -url <epitome:search>     Open an epitome: link.

    Results
      -sort <name>              Sort by "Date Modified", date-modified, size, …
      -sort-ascending, -sort-descending
      -details, -thumbnails, -thumbnail-size <px>
      -focus-results, -focus-top-result, -focus-bottom-result,
      -focus-most-run-result, -focus-last-run-result, -focus-search
      -select <file>            Select that item in the results.

    Window
      -newwindow, -nonewwindow, -toggle-window, -close, -close-all
      -minimized, -maximized, -fullscreen, -ontop (each with a no- form)
      -x <n> -y <n> -width <n> -height <n>, -zoom <percent>
      -filter-bar, -status-bar, -preview (each with a no- form)

    Indexes and file lists
      -f, -filelist <file.efu>  Use a file list as the window's index.
      -edit <file.efu>          Open a file list in the File List Editor.
      -connect <[user[:password]@]host[:port]>   Search an ETP server.
      -create-file-list <out.efu> <folder[;folder…]>   Scan folders and write a list, then exit.
         -create-file-list-exclude-files <filters>
         -create-file-list-exclude-folders <filters>
         -create-file-list-include-only-files <filters>
         -create-file-list-no-subfolders, -create-file-list-no-folders, -create-file-list-no-files
      -reindex, -update (save the database), -rescan <folder>, -rescan-all
      -monitor-pause, -monitor-resume

    General
      -instance <name>          Use a separate named instance (own settings and index).
      -config <file>            Use another settings file.
      -db <file>, -read-only, -nodb    Database location / never write / no database.
      -startup                  Start in the background without a window.
      -first-instance           Only start when no instance is running.
      -exit                     Quit the running instance.
      -options, -debug, -help

    """
}

// MARK: - Entry point

let launchOptions = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))

// With -debuglog, system messages (layout warnings and the like) go to a file next to the log.
if let dl = launchOptions.debugLog {
    setenv("OS_ACTIVITY_DT_MODE", "YES", 1)
    _ = freopen((dl as NSString).deletingPathExtension + "-stderr.log", "w", stderr)
}

if launchOptions.help {
    print(LaunchOptions.helpText)
    exit(0)
}

// -create-file-list: scan from disk, write the list, and exit without any UI.
if let job = launchOptions.createFileList {
    var all = FileList()
    for p in job.paths {
        let path = (p as NSString).expandingTildeInPath
        var opts = launchOptions.createOptions
        opts.crossMountPoints = true
        var list = FileList.create(fromFolder: path, options: opts)
        if launchOptions.createNoSubfolders {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            list.entries.removeAll { e in
                let rest = e.path.hasPrefix(prefix) ? String(e.path.dropFirst(prefix.count)) : e.path
                return rest.contains("/")
            }
        }
        if launchOptions.createNoFolders { list.entries.removeAll { $0.isFolder } }
        if launchOptions.createNoFiles { list.entries.removeAll { !$0.isFolder } }
        all.entries.append(contentsOf: list.entries)
    }
    let out = URL(fileURLWithPath: (job.output as NSString).expandingTildeInPath)
    do {
        try FileList.write(all).write(to: out, atomically: true, encoding: .utf8)
        print("Wrote \(all.entries.count) entries to \(out.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not write \(out.path): \(error)\n".utf8))
        exit(1)
    }
}

// Single instance: forward the command line to a running copy and quit.
let alreadyRunning = IPCClient.isRunning(instance: launchOptions.instance)
if launchOptions.exitRunning {
    if alreadyRunning { _ = IPCClient.call(IPCRequest(cmd: "exit"), instance: launchOptions.instance) }
    exit(0)
}
if launchOptions.onlyIfRunning && !alreadyRunning { exit(0) }
if alreadyRunning {
    if launchOptions.firstInstanceOnly { exit(0) }
    var req = IPCRequest(cmd: "gui")
    req.args = launchOptions.guiArgs.isEmpty ? ["-show"] : launchOptions.guiArgs
    _ = IPCClient.call(req, instance: launchOptions.instance)
    exit(0)
}

let app = NSApplication.shared
AppModel.shared = AppModel(instance: launchOptions.instance, configPath: launchOptions.config,
                           databasePath: launchOptions.db, readOnly: launchOptions.readOnly,
                           noDatabase: launchOptions.noDB, debugLog: launchOptions.debugLog)
AppModel.shared.log.write("Epitome \(EpitomeVersion.string) starting, args: \(CommandLine.arguments.dropFirst().joined(separator: " "))")
let appDelegate = AppDelegate(launch: launchOptions)
app.delegate = appDelegate
app.setActivationPolicy(AppModel.shared.settings.showDockIcon ? .regular : .accessory)
app.run()
