import Foundation

/// Result-list columns shared by the UI, exports, the CLI and the servers.
public enum Column: String, CaseIterable, Codable, Sendable {
    case name
    case path
    case fullPath = "full-path"
    case size
    case ext = "extension"
    case type
    case dateModified = "date-modified"
    case dateCreated = "date-created"
    case dateAccessed = "date-accessed"
    case attributes
    case fileListFilename = "file-list-filename"
    case runCount = "run-count"
    case dateRun = "date-run"
    case dateRecentlyChanged = "date-recently-changed"

    public var title: String {
        switch self {
        case .name: return "Name"
        case .path: return "Path"
        case .fullPath: return "Full Path"
        case .size: return "Size"
        case .ext: return "Extension"
        case .type: return "Type"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .dateAccessed: return "Date Accessed"
        case .attributes: return "Attributes"
        case .fileListFilename: return "File List Filename"
        case .runCount: return "Run Count"
        case .dateRun: return "Date Run"
        case .dateRecentlyChanged: return "Date Recently Changed"
        }
    }

    public var sortKey: SortKey {
        switch self {
        case .name: return .name
        case .path, .fullPath: return .path
        case .size: return .size
        case .ext: return .ext
        case .type: return .type
        case .dateModified: return .dateModified
        case .dateCreated: return .dateCreated
        case .dateAccessed: return .dateAccessed
        case .attributes: return .attributes
        case .fileListFilename: return .fileListFilename
        case .runCount: return .runCount
        case .dateRun: return .dateRun
        case .dateRecentlyChanged: return .dateRecentlyChanged
        }
    }

    public var rightAligned: Bool { self == .size || self == .runCount }
}

/// Formats sizes, dates and attributes the way the options say.
public struct ValueFormatter: @unchecked Sendable {
    public var sizeFormat: SizeFormat
    public var sizeStandard: SizeStandard
    public var roundUp: Bool
    public var digitGrouping: Bool
    private let dateFormatter: DateFormatter
    private let number: NumberFormatter

    public init(sizeFormat: SizeFormat = .kb, sizeStandard: SizeStandard = .jedec, roundUp: Bool = true,
                digitGrouping: Bool = true, dateFormat: String = "") {
        self.sizeFormat = sizeFormat
        self.sizeStandard = sizeStandard
        self.roundUp = roundUp
        self.digitGrouping = digitGrouping
        dateFormatter = DateFormatter()
        if dateFormat.isEmpty {
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .short
        } else {
            dateFormatter.dateFormat = dateFormat
        }
        number = NumberFormatter()
        number.numberStyle = .decimal
        number.usesGroupingSeparator = digitGrouping
        number.maximumFractionDigits = 0
    }

    public init(settings s: AppSettings) {
        self.init(sizeFormat: s.sizeFormat, sizeStandard: s.sizeStandard, roundUp: s.sizeRoundUp, dateFormat: s.dateFormat)
    }

    var base: Double { sizeStandard == .metric ? 1000 : 1024 }

    func unit(_ i: Int) -> String {
        let units: [String]
        switch sizeStandard {
        case .jedec: units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        case .iec: units = ["bytes", "KiB", "MiB", "GiB", "TiB", "PiB"]
        case .metric: units = ["bytes", "kB", "MB", "GB", "TB", "PB"]
        }
        return units[Swift.min(i, units.count - 1)]
    }

    public func grouped(_ v: Int64) -> String {
        number.string(from: NSNumber(value: v)) ?? String(v)
    }

    public func size(_ bytes: Int64) -> String {
        if bytes < 0 { return "" }
        switch sizeFormat {
        case .bytes:
            return grouped(bytes)
        case .kb, .mb:
            let div = sizeFormat == .kb ? base : base * base
            let v = Double(bytes) / div
            let n = roundUp ? Int64(v.rounded(.up)) : Int64(v.rounded())
            return grouped(n) + " " + unit(sizeFormat == .kb ? 1 : 2)
        case .auto:
            if bytes < Int64(base) { return grouped(bytes) + " " + (bytes == 1 ? "byte" : "bytes") }
            var v = Double(bytes)
            var i = 0
            while v >= base && i < 5 { v /= base; i += 1 }
            let f = v < 10 ? String(format: "%.2f", v) : (v < 100 ? String(format: "%.1f", v) : String(format: "%.0f", v))
            return f + " " + unit(i)
        }
    }

    public func date(_ ns: Int64) -> String {
        if ns == kUnknownTime { return "" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9))
    }

    public static func iso(_ ns: Int64) -> String {
        if ns == kUnknownTime { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9))
    }

    /// Attribute letters: R H S D A C L O X P (only those that are set).
    public static func attributes(_ f: UInt32) -> String {
        var s = ""
        if f & EntryFlag.readOnly != 0 { s += "R" }
        if f & EntryFlag.hidden != 0 { s += "H" }
        if f & EntryFlag.system != 0 { s += "S" }
        if f & EntryFlag.directory != 0 { s += "D" }
        if f & EntryFlag.archive != 0 { s += "A" }
        if f & EntryFlag.compressed != 0 { s += "C" }
        if f & EntryFlag.symlink != 0 { s += "L" }
        if f & EntryFlag.offline != 0 { s += "O" }
        if f & EntryFlag.executable != 0 { s += "X" }
        if f & EntryFlag.package != 0 { s += "P" }
        return s
    }
}

/// Reads display values for one result (call with the index read lock held).
public struct RowReader {
    public let index: FileIndex
    public let program: QueryProgram?
    public let services: SearchServices
    public let fmt: ValueFormatter

    public init(index: FileIndex, program: QueryProgram?, services: SearchServices, formatter: ValueFormatter) {
        self.index = index
        self.program = program
        self.services = services
        fmt = formatter
    }

    public func string(_ col: Column, _ id: EntryID) -> String {
        let i = Int(id)
        switch col {
        case .name: return index.name(id)
        case .path: return index.parentPath(id)
        case .fullPath: return index.path(id)
        case .size: return fmt.size(index.size[i])
        case .ext: return index.isDirectory(id) && index.flags[i] & EntryFlag.package == 0 ? "" : index.extensionString(id)
        case .type: return typeName(id)
        case .dateModified: return fmt.date(index.mtime[i])
        case .dateCreated: return fmt.date(index.ctime[i])
        case .dateAccessed: return fmt.date(index.atime[i])
        case .attributes: return ValueFormatter.attributes(index.flags[i])
        case .fileListFilename:
            guard let (_, s) = index.source(of: id), s.kind == .fileList else { return "" }
            return ((s.fileListPath ?? s.name) as NSString).lastPathComponent
        case .runCount:
            let c = services.runHistory?.record(for: index.path(id))?.count ?? 0
            return c > 0 ? String(c) : ""
        case .dateRun:
            guard let r = services.runHistory?.record(for: index.path(id)) else { return "" }
            return fmt.date(Int64(r.last * 1e9))
        case .dateRecentlyChanged: return fmt.date(index.rctime[i])
        }
    }

    public func typeName(_ id: EntryID) -> String {
        if let p = program { return p.typeName(forID: id, index: index) }
        let f = index.flags[Int(id)]
        let dir = f & EntryFlag.directory != 0
        let pkg = f & EntryFlag.package != 0
        return services.typeName(dir && !pkg ? "" : index.extensionString(id).lowercased(), dir, pkg)
    }
}

// MARK: - Export

public enum ExportFormat: String, CaseIterable, Sendable {
    case efu, csv, txt, tsv, json, m3u, m3u8, html

    public var title: String {
        switch self {
        case .efu: return "Epitome File List (.efu)"
        case .csv: return "CSV (Comma delimited) (.csv)"
        case .txt: return "Text (.txt)"
        case .tsv: return "Tab delimited (.tsv)"
        case .json: return "JSON (.json)"
        case .m3u: return "M3U Playlist (.m3u)"
        case .m3u8: return "M3U8 Playlist (.m3u8)"
        case .html: return "HTML (.html)"
        }
    }

    public static func from(extension e: String) -> ExportFormat? {
        ExportFormat(rawValue: e.lowercased())
    }
}

public enum Exporter {
    static func csvQuote(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Renders results. `columns` are the visible columns (EFU always writes its own set).
    public static func render(_ ids: [UInt32], format: ExportFormat, columns: [Column], reader: RowReader,
                              header: Bool = true, folderTrailingSlash: Bool = true, total: Int? = nil) -> String {
        let ix = reader.index
        return ix.lock.read {
            var out = ""
            out.reserveCapacity(ids.count * 64)
            func full(_ id: UInt32) -> String {
                var p = ix.path(id)
                if folderTrailingSlash && ix.isDirectory(id) && p != "/" { p += "/" }
                return p
            }
            switch format {
            case .efu:
                out = FileList.write(FileList.from(ids: ids, index: ix))
            case .txt:
                for id in ids { out += full(id) + "\n" }
            case .m3u, .m3u8:
                out = "#EXTM3U\n"
                for id in ids where !ix.isDirectory(id) { out += ix.path(id) + "\n" }
            case .csv, .tsv:
                let sep = format == .csv ? "," : "\t"
                let cols = columns.isEmpty ? [.fullPath] : columns
                if header { out += cols.map { format == .csv ? csvQuote($0.title) : $0.title }.joined(separator: sep) + "\n" }
                for id in ids {
                    let vals = cols.map { c -> String in
                        let v: String
                        switch c {
                        case .size: v = ix.size[Int(id)] >= 0 ? String(ix.size[Int(id)]) : ""
                        case .dateModified: v = ValueFormatter.iso(ix.mtime[Int(id)])
                        case .dateCreated: v = ValueFormatter.iso(ix.ctime[Int(id)])
                        case .dateAccessed: v = ValueFormatter.iso(ix.atime[Int(id)])
                        case .dateRecentlyChanged: v = ValueFormatter.iso(ix.rctime[Int(id)])
                        case .fullPath: v = full(id)
                        default: v = reader.string(c, id)
                        }
                        return format == .csv ? csvQuote(v) : v.replacingOccurrences(of: "\t", with: " ")
                    }
                    out += vals.joined(separator: sep) + "\n"
                }
            case .json:
                var items: [[String: Any]] = []
                for id in ids {
                    var d: [String: Any] = ["type": ix.isDirectory(id) ? "folder" : "file", "name": ix.name(id), "path": ix.parentPath(id)]
                    if ix.size[Int(id)] >= 0 { d["size"] = String(ix.size[Int(id)]) }
                    if ix.mtime[Int(id)] != kUnknownTime { d["date_modified"] = String(FileList.nanosToFiletime(ix.mtime[Int(id)])) }
                    if ix.ctime[Int(id)] != kUnknownTime { d["date_created"] = String(FileList.nanosToFiletime(ix.ctime[Int(id)])) }
                    items.append(d)
                }
                let obj: [String: Any] = ["totalResults": total ?? ids.count, "results": items]
                if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
                    out = String(decoding: data, as: UTF8.self) + "\n"
                }
            case .html:
                let cols = columns.isEmpty ? [.name, .path, .size, .dateModified] : columns
                out = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Epitome export</title><style>body{font:13px -apple-system,Helvetica,sans-serif}table{border-collapse:collapse}td,th{padding:3px 8px;border-bottom:1px solid #ddd;text-align:left}</style></head><body><table>\n<tr>"
                out += cols.map { "<th>\(htmlEscape($0.title))</th>" }.joined() + "</tr>\n"
                for id in ids {
                    out += "<tr>" + cols.map { "<td>\(htmlEscape(reader.string($0, id)))</td>" }.joined() + "</tr>\n"
                }
                out += "</table></body></html>\n"
            }
            return out
        }
    }
}
