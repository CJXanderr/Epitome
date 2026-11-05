import AppKit
import CoreServices
import EpitomeCore
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

/// Shared state: settings, filters, bookmarks, history, the index manager.
final class AppModel {
    static var shared: AppModel!

    static let settingsChanged = Notification.Name("EpitomeSettingsChanged")
    static let filtersChanged = Notification.Name("EpitomeFiltersChanged")
    static let bookmarksChanged = Notification.Name("EpitomeBookmarksChanged")
    static let indexChanged = Notification.Name("EpitomeIndexChanged")
    static let statusChanged = Notification.Name("EpitomeStatusChanged")

    let instance: String
    let supportDir: URL
    private(set) var settings: AppSettings
    let manager: IndexManager
    let filters: JSONStore<[Filter]>
    let bookmarks: JSONStore<[Bookmark]>
    let history: SearchHistory
    private(set) var formatter: ValueFormatter
    let log: DebugLog

    var settingsURL: URL { supportDir.appendingPathComponent("Settings.json") }

    init(instance: String, configPath: String?, databasePath: String?, readOnly: Bool, noDatabase: Bool, debugLog: String?) {
        self.instance = instance
        supportDir = IPCPaths.supportDirectory(instance: instance)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        log = DebugLog(path: debugLog)
        let sURL = configPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? supportDir.appendingPathComponent("Settings.json")
        settings = AppSettings.load(from: sURL)
        formatter = ValueFormatter(settings: settings)
        manager = IndexManager(dataDirectory: supportDir, settings: settings, readOnly: readOnly, noDatabase: noDatabase)
        if let db = databasePath { manager.databaseOverride = URL(fileURLWithPath: (db as NSString).expandingTildeInPath) }
        filters = JSONStore(url: supportDir.appendingPathComponent("Filters.json"), defaultValue: Filter.defaults)
        bookmarks = JSONStore(url: supportDir.appendingPathComponent("Bookmarks.json"), defaultValue: [])
        history = SearchHistory(url: supportDir.appendingPathComponent("SearchHistory.json"))
        history.enabled = settings.searchHistoryEnabled
        history.keepDays = settings.searchHistoryKeepDays
        let l = log
        manager.log = { l.write($0) }
        configureServices()
        refreshMacros()
    }

    // MARK: - Settings

    func updateSettings(_ body: (inout AppSettings) -> Void) {
        var s = settings
        body(&s)
        setSettings(s)
    }

    func setSettings(_ s: AppSettings) {
        guard s != settings else { return }
        settings = s
        formatter = ValueFormatter(settings: s)
        history.enabled = s.searchHistoryEnabled
        history.keepDays = s.searchHistoryKeepDays
        s.save(to: settingsURL)
        manager.applySettings(s)
        NotificationCenter.default.post(name: AppModel.settingsChanged, object: nil)
    }

    /// Saves without re-applying (window state such as last search/columns).
    func rememberState(_ body: (inout AppSettings) -> Void) {
        var s = settings
        body(&s)
        settings = s
        s.save(to: settingsURL)
    }

    // MARK: - Filters & macros

    func refreshMacros() {
        var m: [String: String] = [:]
        for f in filters.current where !f.macro.isEmpty && !f.isEverything { m[f.macro.lowercased()] = f.search }
        for b in bookmarks.current where !b.macro.isEmpty { m[b.macro.lowercased()] = b.search }
        if m["image"] == nil, let pic = m["pic"] { m["image"] = pic }
        manager.services.macros = m
    }

    func filterSpecs() -> [String: FilterSpec] {
        var d: [String: FilterSpec] = [:]
        for f in filters.current { if let s = f.spec { d[f.name.lowercased()] = s } }
        return d
    }

    func filter(named name: String) -> Filter? {
        filters.current.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func setFilters(_ list: [Filter]) {
        filters.current = list
        refreshMacros()
        NotificationCenter.default.post(name: AppModel.filtersChanged, object: nil)
    }

    func setBookmarks(_ list: [Bookmark]) {
        bookmarks.current = list
        refreshMacros()
        NotificationCenter.default.post(name: AppModel.bookmarksChanged, object: nil)
    }

    // MARK: - Engine services (file types, kinds, media properties)

    private func configureServices() {
        let s = manager.services
        s.typeName = { ext, isDir, isPkg in
            if isDir && !isPkg { return "Folder" }
            if ext.isEmpty { return isDir ? "Folder" : "Document" }
            if let t = UTType(filenameExtension: ext), let d = t.localizedDescription { return d }
            return ext.uppercased() + " File"
        }
        s.kindMatches = { ext, isDir, isPkg, kind in
            let k = kind.lowercased()
            if ["folder", "folders", "directory"].contains(k) { return isDir && !isPkg }
            if k == "file" || k == "files" { return !isDir }
            if k == "package" || k == "bundle" { return isPkg }
            guard !ext.isEmpty, let t = UTType(filenameExtension: ext) else { return false }
            let target: [UTType]
            switch k {
            case "image", "images", "picture", "pictures", "photo", "photos": target = [.image]
            case "movie", "movies", "video", "videos": target = [.movie, .video]
            case "audio", "music", "sound": target = [.audio]
            case "text", "plaintext": target = [.text]
            case "pdf": target = [.pdf]
            case "document", "documents", "doc": target = [.text, .pdf, .presentation, .spreadsheet, .rtf]
            case "presentation", "slides": target = [.presentation]
            case "spreadsheet": target = [.spreadsheet]
            case "app", "apps", "application", "applications": target = [.application]
            case "archive", "archives", "compressed": target = [.archive]
            case "source", "code", "sourcecode": target = [.sourceCode]
            case "script", "scripts": target = [.script]
            case "font", "fonts": target = [.font]
            case "executable": target = [.executable, .application]
            case "diskimage": target = [.diskImage]
            case "contact", "vcard": target = [.vCard]
            case "email", "message": target = [.emailMessage]
            default:
                if let named = UTType(k) { target = [named] } else { return false }
            }
            return target.contains { t.conforms(to: $0) }
        }
        s.mediaProperty = { path, prop in MediaReader.value(path, prop) }
    }
}

/// Reads media/document properties for width:, length:, artist:, tags: …
enum MediaReader {
    private static let cache = NSCache<NSString, NSDictionary>()

    static func value(_ path: String, _ prop: MediaProperty) -> MediaValue? {
        switch prop {
        case .width, .height, .bitDepth, .orientation:
            let d = imageInfo(path)
            switch prop {
            case .width: return (d["w"] as? Int).map { .int(Int64($0)) }
            case .height: return (d["h"] as? Int).map { .int(Int64($0)) }
            case .bitDepth: return (d["d"] as? Int).map { .int(Int64($0)) }
            default: return nil
            }
        case .tags:
            let url = URL(fileURLWithPath: path)
            let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            return .text(tags.joined(separator: ";"))
        default:
            return spotlight(path, prop)
        }
    }

    static func imageInfo(_ path: String) -> NSDictionary {
        if let c = cache.object(forKey: path as NSString) { return c }
        var out: [String: Any] = [:]
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            var w = props[kCGImagePropertyPixelWidth] as? Int
            var h = props[kCGImagePropertyPixelHeight] as? Int
            if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
            out["w"] = w
            out["h"] = h
            out["d"] = props[kCGImagePropertyDepth] as? Int
        } else if let item = MDItemCreate(nil, path as CFString) {
            out["w"] = MDItemCopyAttribute(item, kMDItemPixelWidth) as? Int
            out["h"] = MDItemCopyAttribute(item, kMDItemPixelHeight) as? Int
            out["d"] = MDItemCopyAttribute(item, kMDItemBitsPerSample) as? Int
        }
        let d = out as NSDictionary
        cache.setObject(d, forKey: path as NSString)
        return d
    }

    static func spotlight(_ path: String, _ prop: MediaProperty) -> MediaValue? {
        guard let item = MDItemCreate(nil, path as CFString) else { return assetValue(path, prop) }
        func str(_ k: CFString) -> String? {
            let v = MDItemCopyAttribute(item, k)
            if let s = v as? String { return s }
            if let a = v as? [String] { return a.joined(separator: ";") }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        switch prop {
        case .duration:
            if let d = MDItemCopyAttribute(item, kMDItemDurationSeconds) as? Double { return .int(Int64(d.rounded())) }
        case .album: if let s = str(kMDItemAlbum) { return .text(s) }
        case .artist: if let s = str(kMDItemAuthors) ?? str(kMDItemComposer) { return .text(s) }
        case .title: if let s = str(kMDItemTitle) { return .text(s) }
        case .genre: if let s = str(kMDItemMusicalGenre) { return .text(s) }
        case .comment: if let s = str(kMDItemComment) ?? str(kMDItemFinderComment) { return .text(s) }
        case .year:
            if let n = MDItemCopyAttribute(item, kMDItemRecordingYear) as? Int { return .int(Int64(n)) }
        case .track:
            if let n = MDItemCopyAttribute(item, kMDItemAudioTrackNumber) as? Int { return .int(Int64(n)) }
        default: break
        }
        return assetValue(path, prop)
    }

    /// Fallback for files Spotlight doesn't know: read with AVFoundation.
    static func assetValue(_ path: String, _ prop: MediaProperty) -> MediaValue? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard let t = UTType(filenameExtension: ext), t.conforms(to: .audiovisualContent) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        switch prop {
        case .duration:
            let d = CMTimeGetSeconds(asset.duration)
            return d.isFinite ? .int(Int64(d.rounded())) : nil
        default:
            let key: AVMetadataKey?
            switch prop {
            case .album: key = .commonKeyAlbumName
            case .artist: key = .commonKeyArtist
            case .title: key = .commonKeyTitle
            case .comment: key = .commonKeyDescription
            default: key = nil
            }
            guard let k = key else { return nil }
            let items = AVMetadataItem.metadataItems(from: asset.commonMetadata, withKey: k, keySpace: .common)
            if let s = items.first?.stringValue { return .text(s) }
            return nil
        }
    }
}

/// Log file + in-memory buffer for the debug console.
final class DebugLog {
    private let m = NSLock()
    private var lines: [String] = []
    private let handle: FileHandle?
    var onLine: ((String) -> Void)?
    /// Where the log is written (-debuglog, or ~/Library/Logs/Epitome/Epitome.log).
    let path: String

    init(path: String?) {
        let p = path ?? (NSHomeDirectory() + "/Library/Logs/Epitome/Epitome.log")
        self.path = p
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: p), let size = attrs[.size] as? Int, size > 4 << 20 {
            try? Data().write(to: URL(fileURLWithPath: p))
        }
        handle = FileHandle(forWritingAtPath: p)
        handle?.seekToEndOfFile()
    }

    func write(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(s)"
        m.lock()
        lines.append(line)
        if lines.count > 5000 { lines.removeFirst(1000) }
        handle?.write(Data((line + "\n").utf8))
        m.unlock()
        if let cb = onLine { DispatchQueue.main.async { cb(line) } }
    }

    var all: [String] {
        m.lock()
        defer { m.unlock() }
        return lines
    }
}
