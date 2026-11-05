import Foundation

/// Tracks how often and when files were opened through Epitome
/// (the Run Count and Date Run columns, `runcount:` and `dr:`).
public final class RunHistory: @unchecked Sendable {
    public struct Record: Codable, Sendable {
        public var count: Int
        /// Unix time of the last run.
        public var last: Double
    }

    private let m = Mutex()
    private var map: [String: Record] = [:]
    private let url: URL?
    public var enabled = true

    public init(url: URL?) {
        self.url = url
        if let u = url, let d = try? Data(contentsOf: u), let v = try? JSONDecoder().decode([String: Record].self, from: d) {
            map = v
        }
    }

    public func recordRun(path: String, at date: Date = Date()) {
        guard enabled else { return }
        m.sync {
            var r = map[path] ?? Record(count: 0, last: 0)
            r.count += 1
            r.last = date.timeIntervalSince1970
            map[path] = r
        }
        save()
    }

    public func record(for path: String) -> Record? { m.sync { map[path] } }

    public func all() -> [String: Record] { m.sync { map } }

    public func set(path: String, count: Int) {
        m.sync {
            if count <= 0 { map[path] = nil } else {
                var r = map[path] ?? Record(count: 0, last: Date().timeIntervalSince1970)
                r.count = count
                map[path] = r
            }
        }
        save()
    }

    public func renamed(from old: String, to new: String) {
        m.sync {
            if let r = map.removeValue(forKey: old) { map[new] = r }
        }
        save()
    }

    public func clear() {
        m.sync { map.removeAll() }
        save()
    }

    public func save() {
        guard let u = url else { return }
        let snapshot = m.sync { map }
        if let d = try? JSONEncoder().encode(snapshot) {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: u, options: .atomic)
        }
    }
}
