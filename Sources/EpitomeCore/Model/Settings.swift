import Foundation

/// A keyboard shortcut, stored without any AppKit dependency.
public struct KeyCombo: Codable, Hashable, Sendable {
    /// Virtual key code (Carbon kVK_*), used for global hotkeys and special keys.
    public var keyCode: UInt16
    /// Character for menu key equivalents ("n", "\u{F704}" for F1 …).
    public var key: String
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(keyCode: UInt16 = 0, key: String, command: Bool = false, option: Bool = false,
                control: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode
        self.key = key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    public var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + KeyCombo.keyName(key)
    }

    public static func keyName(_ k: String) -> String {
        switch k {
        case "\r": return "↩"
        case "\u{1B}": return "⎋"
        case "\t": return "⇥"
        case " ": return "Space"
        case "\u{8}", "\u{7F}": return "⌫"
        case "\u{F728}": return "⌦"
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
        case "\u{F729}": return "↖"
        case "\u{F72B}": return "↘"
        case "\u{F72C}": return "⇞"
        case "\u{F72D}": return "⇟"
        default:
            if let u = k.unicodeScalars.first, u.value >= 0xF704, u.value <= 0xF726 { return "F\(u.value - 0xF704 + 1)" }
            return k.uppercased()
        }
    }
}

public enum SizeFormat: String, Codable, CaseIterable, Sendable { case auto, bytes, kb, mb }
public enum SizeStandard: String, Codable, CaseIterable, Sendable { case jedec, iec, metric }
public enum OnTopMode: String, Codable, CaseIterable, Sendable { case never, always, whileSearching }
public enum ViewMode: String, Codable, CaseIterable, Sendable { case details, medium, large, extraLarge }
public enum FocusWrap: String, Codable, CaseIterable, Sendable { case clamp, wrap, wrapWithSearch }
public enum MenuVisibility: String, Codable, CaseIterable, Sendable { case show, shift, hide }
public enum ThemeMode: String, Codable, CaseIterable, Sendable { case system, light, dark }
public enum HistorySort: String, Codable, CaseIterable, Sendable { case date, count, search }

/// "Use last value" or a fixed value (Options → Home).
public enum HomeBool: String, Codable, CaseIterable, Sendable {
    case useLast, on, off
    public func resolve(_ last: Bool) -> Bool { self == .useLast ? last : self == .on }
}

public struct ContextMenuItem: Codable, Equatable, Sendable {
    public var id: String
    public var visibility: MenuVisibility
    /// Command template: `$exec("app" "%1")`, `$openpath(%1)`, or empty for the built-in action.
    public var command: String

    public init(id: String, visibility: MenuVisibility, command: String) {
        self.id = id
        self.visibility = visibility
        self.command = command
    }
}

public enum RescanSchedule: Codable, Equatable, Sendable {
    case daily(hour: Int, weekday: Int?) // weekday 1 = Sunday … 7, nil = every day
    case every(minutes: Int)
    case never
}

public struct FolderSourceSetting: Codable, Equatable, Sendable {
    public var path: String
    public var monitor: Bool
    public var schedule: RescanSchedule
    public var lastScan: Double?
    public init(path: String, monitor: Bool = true, schedule: RescanSchedule = .daily(hour: 3, weekday: nil)) {
        self.path = path
        self.monitor = monitor
        self.schedule = schedule
    }
}

public struct FileListSourceSetting: Codable, Equatable, Sendable {
    public var path: String
    public var monitor: Bool
    public init(path: String, monitor: Bool = true) {
        self.path = path
        self.monitor = monitor
    }
}

public struct VolumeSetting: Codable, Equatable, Sendable {
    /// Volume UUID when known, else the mount path.
    public var id: String
    public var path: String
    public var name: String
    public var include: Bool
    /// Semicolon list of folders to index on that volume (empty = whole volume).
    public var includeOnly: String
    public var monitor: Bool

    public init(id: String, path: String, name: String, include: Bool, includeOnly: String, monitor: Bool) {
        self.id = id
        self.path = path
        self.name = name
        self.include = include
        self.includeOnly = includeOnly
        self.monitor = monitor
    }
}

public struct ColumnSetting: Codable, Equatable, Sendable {
    public var id: String
    public var width: Double
    public var visible: Bool

    public init(id: String, width: Double, visible: Bool) {
        self.id = id
        self.width = width
        self.visible = visible
    }
}

/// Everything Epitome remembers. Unknown or missing keys fall back to defaults,
/// so the file survives upgrades.
public struct AppSettings: Codable, Equatable, Sendable {
    // General
    public var startAtLogin = true
    public var runInBackground = true
    public var showMenuBarIcon = true
    public var showDockIcon = true
    public var menuBarClickOpensWindow = true
    public var newWindowFromMenuBar = false
    public var newWindowOnLaunch = false
    public var handleURLScheme = true
    public var onboardingDone = false
    /// The copy of Epitome the login item launches (so an installed copy takes over from a build).
    public var loginItemPath = ""

    // UI
    public var searchAsYouType = true
    public var searchDelayMs = 0
    public var selectSearchOnMouseClick = true
    public var focusSearchOnActivate = false
    public var singleClickOpen = false
    public var showRowMouseover = false
    public var alternateRowColor = false
    public var showHighlightedSearchTerms = true
    public var showSelectedItemInStatusBar = true
    public var showResultCountWithSelection = false
    public var showTotalSizeInStatusBar = true
    public var statusBarSelectedItemFormat = ""
    public var sizeFormat: SizeFormat = .kb
    public var sizeStandard: SizeStandard = .jedec
    public var sizeRoundUp = true
    public var dateFormat = ""
    public var showFilterBar = true
    public var showStatusBar = true
    public var showPreview = false
    public var showHeader = true
    public var onTop: OnTopMode = .never
    public var theme: ThemeMode = .system
    public var resultsFontName = ""
    public var resultsFontSize = 0.0
    public var searchFontSize = 0.0
    public var highlightBold = true
    public var highlightColor = ""
    public var rowHeightPadding = 4.0
    public var columns: [ColumnSetting] = AppSettings.defaultColumns
    public var showFullPathInName = false

    // Home
    public var homeMatchCase: HomeBool = .useLast
    public var homeMatchWholeWord: HomeBool = .useLast
    public var homeMatchPath: HomeBool = .useLast
    public var homeMatchDiacritics: HomeBool = .useLast
    public var homeRegex: HomeBool = .useLast
    public var homeSearchUseLast = false
    public var homeSearch = ""
    public var homeFilterUseLast = true
    public var homeFilter = ""
    public var homeSortUseLast = true
    public var homeSort: SortKey = .name
    public var homeSortAscending = true
    public var homeViewUseLast = true
    public var homeView: ViewMode = .details
    /// "", "filelist:<path>", or "etp:<user:pass@host:port>"
    public var homeIndex = ""

    // Search
    public var syntax = SyntaxSettings()

    // Results
    public var hideEmptySearchResults = false
    public var clearSelectionOnSearch = true
    public var closeWindowOnExecute = false
    public var doubleClickPathOpensPath = true
    public var doubleQuoteCopyAsPath = false
    public var doNotSelectExtensionWhenRenaming = true
    public var sortDateDescendingFirst = true
    public var sortSizeDescendingFirst = true
    public var resultListFocus: FocusWrap = .clamp
    public var foldersFirst: FoldersFirst = .ascending
    public var naturalSort = true
    public var openManyWarningThreshold = 32

    // Context menu
    public var contextMenu: [ContextMenuItem] = AppSettings.defaultContextMenu

    // Keyboard
    public var hotkeyNewWindow: KeyCombo? = nil
    public var hotkeyShowWindow: KeyCombo? = nil
    public var hotkeyToggleWindow: KeyCombo? = nil
    /// Command ID → custom shortcuts (replaces the default when present).
    public var shortcuts: [String: [KeyCombo]] = [:]

    // History
    public var searchHistoryEnabled = false
    public var searchHistoryKeepDays = 0
    public var alwaysShowSearchSuggestions = false
    public var searchHistorySort: HistorySort = .date
    public var runHistoryEnabled = true
    public var runHistoryKeepDays = 0

    // Indexes
    public var databaseLocation = ""
    public var indexRecentChanges = true
    public var indexFileSize = true
    public var fastSizeSort = true
    public var indexFolderSize = true
    public var indexDateCreated = true
    public var fastDateCreatedSort = false
    public var indexDateModified = true
    public var fastDateModifiedSort = true
    public var indexDateAccessed = false
    public var fastDateAccessedSort = false
    public var indexAttributes = true
    public var fastAttributesSort = false
    public var fastPathSort = true
    public var fastExtensionSort = false
    public var journalEnabled = true
    public var journalMaxEntries = 5000
    public var saveDatabaseEveryMinutes = 30

    // Volumes
    public var autoIncludeFixedVolumes = true
    public var autoIncludeRemovableVolumes = false
    public var autoIncludeNetworkVolumes = false
    public var autoRemoveOfflineVolumes = true
    public var volumes: [VolumeSetting] = []
    public var indexPackageContents = true

    // Folders & file lists
    public var folders: [FolderSourceSetting] = []
    public var fileLists: [FileListSourceSetting] = []

    // Exclude
    public var excludeHidden = false
    public var excludeSystem = false
    public var excludeListEnabled = true
    public var excludeFolders: [String] = []
    public var includeOnlyFiles = ""
    public var excludeFiles = ""

    // ETP / FTP server
    public var etpEnabled = false
    public var etpBind = ""
    public var etpPort = 2121
    public var etpUsername = ""
    public var etpPassword = ""
    public var etpLogging = true
    public var etpLogMaxKB = 4096
    public var etpAllowDownload = true
    public var etpWelcome = ""

    // HTTP server
    public var httpEnabled = false
    public var httpBind = ""
    public var httpPort = 8080
    public var httpUsername = ""
    public var httpPassword = ""
    public var httpLogging = true
    public var httpLogMaxKB = 4096
    public var httpAllowDownload = true
    public var httpServePagesFrom = ""
    public var httpDefaultPage = ""

    // Remembered state ("use last value")
    public var lastOptions = SearchOptions()
    public var lastSearch = ""
    public var lastFilter = ""
    public var lastSort: SortKey = .name
    public var lastSortAscending = true
    public var lastView: ViewMode = .details
    public var etpRecent: [String] = []

    public init() {}

    public static let defaultColumns: [ColumnSetting] = [
        ColumnSetting(id: "name", width: 280, visible: true),
        ColumnSetting(id: "path", width: 340, visible: true),
        ColumnSetting(id: "size", width: 90, visible: true),
        ColumnSetting(id: "extension", width: 70, visible: false),
        ColumnSetting(id: "type", width: 140, visible: false),
        ColumnSetting(id: "date-modified", width: 140, visible: true),
        ColumnSetting(id: "date-created", width: 140, visible: false),
        ColumnSetting(id: "date-accessed", width: 140, visible: false),
        ColumnSetting(id: "attributes", width: 70, visible: false),
        ColumnSetting(id: "file-list-filename", width: 120, visible: false),
        ColumnSetting(id: "run-count", width: 70, visible: false),
        ColumnSetting(id: "date-run", width: 140, visible: false),
        ColumnSetting(id: "date-recently-changed", width: 140, visible: false),
    ]

    public static let defaultContextMenu: [ContextMenuItem] = [
        ContextMenuItem(id: "open-folders", visibility: .show, command: ""),
        ContextMenuItem(id: "open-files", visibility: .show, command: ""),
        ContextMenuItem(id: "open-path", visibility: .show, command: ""),
        ContextMenuItem(id: "explore", visibility: .shift, command: ""),
        ContextMenuItem(id: "explore-path", visibility: .shift, command: ""),
        ContextMenuItem(id: "copy-name", visibility: .shift, command: ""),
        ContextMenuItem(id: "copy-path", visibility: .shift, command: ""),
        ContextMenuItem(id: "copy-full-name", visibility: .show, command: ""),
    ]

    /// The orders the index should keep presorted.
    public var fastSorts: Set<SortKey> {
        var s: Set<SortKey> = [.name]
        if fastPathSort { s.insert(.path) }
        if fastSizeSort && indexFileSize { s.insert(.size) }
        if fastDateModifiedSort && indexDateModified { s.insert(.dateModified) }
        if fastDateCreatedSort && indexDateCreated { s.insert(.dateCreated) }
        if fastDateAccessedSort && indexDateAccessed { s.insert(.dateAccessed) }
        if fastAttributesSort && indexAttributes { s.insert(.attributes) }
        if fastExtensionSort { s.insert(.ext) }
        if indexRecentChanges { s.insert(.dateRecentlyChanged) }
        return s
    }

    public var scanOptions: ScanOptions {
        var o = ScanOptions()
        o.excludeHidden = excludeHidden
        o.excludeSystem = excludeSystem
        if excludeListEnabled {
            o.excludeFolders = excludeFolders
            o.excludeFiles = [excludeFiles]
            o.includeOnlyFiles = [includeOnlyFiles]
        }
        o.indexAccessTime = indexDateAccessed
        o.indexPackageContents = indexPackageContents
        return o
    }

    // MARK: - Tolerant load / save

    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        return decodeMerged(data) ?? AppSettings()
    }

    /// Decodes `data` over the defaults so missing keys keep their default values.
    public static func decodeMerged(_ data: Data) -> AppSettings? {
        guard let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(AppSettings()),
              let defaults = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return nil }
        let merged = deepMerge(defaults, loaded)
        guard let mdata = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: mdata)
    }

    static func deepMerge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        for (k, v) in b {
            if let av = a[k] as? [String: Any], let bv = v as? [String: Any], !(k == "shortcuts") {
                out[k] = deepMerge(av, bv)
            } else {
                out[k] = v
            }
        }
        return out
    }

    public func save(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// Reads or changes a setting by key (search commands `>setting` / `>setting=value`).
    public mutating func setValue(_ key: String, _ value: String) -> Bool {
        let mirror = Mirror(reflecting: self)
        guard let child = mirror.children.first(where: { ($0.label ?? "").lowercased() == key.lowercased() ||
            QueryCompiler.normalize($0.label ?? "") == QueryCompiler.normalize(key) }), let k = child.label else { return false }
        guard let data = try? JSONEncoder().encode(self),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let lv = value.lowercased()
        switch child.value {
        case let b as Bool:
            dict[k] = lv == "!" ? !b : ["1", "true", "yes", "on"].contains(lv)
        case is Int:
            guard let i = Int(value) else { return false }
            dict[k] = i
        case is Double:
            guard let d = Double(value) else { return false }
            dict[k] = d
        case is String:
            dict[k] = value
        default:
            if let raw = child.value as? any RawRepresentable, raw.rawValue is String {
                dict[k] = value
            } else {
                return false
            }
        }
        guard let nd = try? JSONSerialization.data(withJSONObject: dict),
              let s = try? JSONDecoder().decode(AppSettings.self, from: nd) else { return false }
        self = s
        return true
    }

    public func value(_ key: String) -> String? {
        guard let data = try? JSONEncoder().encode(self),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let k = dict.keys.first(where: { QueryCompiler.normalize($0) == QueryCompiler.normalize(key) }) else { return nil }
        return "\(k) = \(dict[k] ?? "")"
    }

    public static var settingNames: [String] {
        guard let data = try? JSONEncoder().encode(AppSettings()),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return dict.keys.sorted()
    }
}

// MARK: - Filters

public struct Filter: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var search: String
    public var macro: String
    public var shortcut: KeyCombo?
    public var options: SearchOptions
    /// Built-in "Everything" (no filter) entry.
    public var isEverything: Bool

    public init(id: UUID = UUID(), name: String, search: String, macro: String = "", shortcut: KeyCombo? = nil,
                options: SearchOptions = SearchOptions(), isEverything: Bool = false) {
        self.id = id
        self.name = name
        self.search = search
        self.macro = macro
        self.shortcut = shortcut
        self.options = options
        self.isEverything = isEverything
    }

    public var spec: FilterSpec? { isEverything || search.isEmpty ? nil : FilterSpec(text: search, options: options) }

    static func ext(_ list: String) -> String { "ext:" + list.split(separator: " ").joined(separator: ";") }

    public static let defaults: [Filter] = [
        Filter(name: "Everything", search: "", isEverything: true),
        Filter(name: "Audio", search: ext("aac ac3 aif aifc aiff alac amr ape au caf cda dts fla flac it m1a m2a m3u m3u8 m4a m4b m4p mid midi mka mod mp2 mp3 mpa mpc oga ogg opus ra rmi snd spc umx voc wav weba wma xm"), macro: "audio"),
        Filter(name: "Compressed", search: ext("7z ace arj bz2 cab cpgz dmg gz gzip jar lz lz4 lzma r00 r01 r02 r03 r04 r05 r06 r07 r08 r09 r10 r11 r12 r13 r14 r15 r16 r17 r18 r19 r20 r21 r22 r23 r24 r25 r26 r27 r28 r29 rar sit sitx tar tbz tbz2 tgz txz xar xip xz z zip zst"), macro: "zip"),
        Filter(name: "Document", search: ext("c cc chm cpp cs css csv cxx doc docm docx dot dotm dotx epub h hpp htm html hxx ini java js json key lua m md mht mhtml mobi numbers odp ods odt pages pdf php pot potm potx pps ppsm ppsx ppt pptm pptx pub py rb rtf rtfd sh sldm sldx swift tex thmx toml ts txt vb vsd webarchive wpd wps wri xlam xls xlsb xlsm xlsx xltm xltx xml yaml yml"), macro: "doc"),
        Filter(name: "Executable", search: "<" + ext("app appex bat cmd command dmg exe jar mpkg msi pkg ps1 scpt sh tool workflow") + "> | <file: attrib:X !ext:sh;py;rb;pl>", macro: "exe"),
        Filter(name: "Folder", search: "folder:"),
        Filter(name: "Picture", search: ext("ai ani apng arw avif bmp bpg cr2 cr3 cur dng eps exr gif hdr heic heics heif ico icns jfi jfif jif jp2 jpe jpeg jpg jxl nef orf pcx pic pict png psb psd raf raw rle rw2 sketch svg tga tif tiff webp wmf xcf"), macro: "pic"),
        Filter(name: "Video", search: ext("3g2 3gp 3gp2 3gpp amv asf asx avi bdmv bik d2v divx drc dsa dsm dss dsv evo f4v flc fli flic flv hdmov ifo ivf m1v m2p m2t m2ts m2v m4v mkv mod mov mp2v mp4 mp4v mpe mpeg mpg mpls mpv2 mpv4 mts mxf ogm ogv ogx pss pva qt ram ratdvd rm rmm rmvb roq rpm smil smk swf tod tp tpr ts tts vob vp6 webm wm wmp wmv wmx wvx"), macro: "video"),
    ]
}

// MARK: - Bookmarks

public struct Bookmark: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var search: String
    public var options: SearchOptions
    public var filter: String?
    public var sort: SortKey?
    public var ascending: Bool?
    public var view: ViewMode?
    /// "", "filelist:<path>", "etp:<server>"
    public var index: String?
    public var macro: String
    public var shortcut: KeyCombo?
    /// Submenu path ("Music/Beatles") for organising.
    public var folder: String

    public init(id: UUID = UUID(), name: String, search: String, options: SearchOptions = SearchOptions(),
                filter: String? = nil, sort: SortKey? = nil, ascending: Bool? = nil, view: ViewMode? = nil,
                index: String? = nil, macro: String = "", shortcut: KeyCombo? = nil, folder: String = "") {
        self.id = id
        self.name = name
        self.search = search
        self.options = options
        self.filter = filter
        self.sort = sort
        self.ascending = ascending
        self.view = view
        self.index = index
        self.macro = macro
        self.shortcut = shortcut
        self.folder = folder
    }
}

// MARK: - Search history

public struct SearchHistoryItem: Codable, Equatable, Sendable {
    public var search: String
    public var count: Int
    public var last: Double

    public init(search: String, count: Int, last: Double) {
        self.search = search
        self.count = count
        self.last = last
    }
}

/// Persistent JSON-backed list storage for filters, bookmarks and history.
public final class JSONStore<T: Codable>: @unchecked Sendable {
    public let url: URL
    private let m = Mutex()
    private var value: T

    public init(url: URL, defaultValue: T) {
        self.url = url
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(T.self, from: d) {
            value = v
        } else {
            value = defaultValue
        }
    }

    public var current: T {
        get { m.sync { value } }
        set {
            m.sync { value = newValue }
            save()
        }
    }

    public func update(_ body: (inout T) -> Void) {
        m.sync { body(&value) }
        save()
    }

    public func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        let snapshot = m.sync { value }
        guard let d = try? enc.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

/// Search history with use counts.
public final class SearchHistory: @unchecked Sendable {
    let store: JSONStore<[SearchHistoryItem]>
    public var enabled = false
    public var keepDays = 0

    public init(url: URL) {
        store = JSONStore(url: url, defaultValue: [])
    }

    public func record(_ search: String) {
        let s = search.trimmingCharacters(in: .whitespaces)
        guard enabled, !s.isEmpty else { return }
        store.update { list in
            let now = Date().timeIntervalSince1970
            if let i = list.firstIndex(where: { $0.search == s }) {
                list[i].count += 1
                list[i].last = now
            } else {
                list.append(SearchHistoryItem(search: s, count: 1, last: now))
            }
            if keepDays > 0 {
                let cutoff = now - Double(keepDays) * 86_400
                list.removeAll { $0.last < cutoff }
            }
        }
    }

    public var items: [SearchHistoryItem] { store.current }

    public func sorted(_ by: HistorySort) -> [SearchHistoryItem] {
        switch by {
        case .date: return items.sorted { $0.last > $1.last }
        case .count: return items.sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
        case .search: return items.sorted { $0.search.localizedCaseInsensitiveCompare($1.search) == .orderedAscending }
        }
    }

    /// History entries starting with (or containing) `prefix`, best first.
    public func suggestions(for prefix: String, limit: Int = 12) -> [String] {
        let p = prefix.lowercased()
        if p.isEmpty { return Array(sorted(.date).prefix(limit).map(\.search)) }
        let all = sorted(.count)
        let starts = all.filter { $0.search.lowercased().hasPrefix(p) && $0.search.lowercased() != p }
        let contains = all.filter { !$0.search.lowercased().hasPrefix(p) && $0.search.lowercased().contains(p) }
        return Array((starts + contains).prefix(limit).map(\.search))
    }

    public func remove(_ search: String) { store.update { $0.removeAll { $0.search == search } } }
    public func clear() { store.current = [] }
    public func replaceAll(_ items: [SearchHistoryItem]) { store.current = items }
}
