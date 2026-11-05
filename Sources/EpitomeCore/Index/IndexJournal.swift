import Foundation

/// A bounded log of recent index changes (what was created, deleted, renamed or
/// modified, and when). Backs the Index Journal window and `ep -journal`.
public final class IndexJournal: @unchecked Sendable {
    public enum Action: String, Codable, Sendable {
        case created, deleted, modified, renamed
    }

    public struct Record: Codable, Sendable {
        public let time: Int64
        public let action: Action
        public let path: String
        public let isFolder: Bool
    }

    private let m = Mutex()
    private var ring: [Record] = []
    private var head = 0
    public let capacity: Int
    public private(set) var total = 0
    public var enabled = true

    public init(capacity: Int = 50_000) {
        self.capacity = capacity
        ring.reserveCapacity(Swift.min(capacity, 4096))
    }

    /// Called by the index while it holds the write lock.
    func record(_ action: Action, _ index: FileIndex, _ id: EntryID) {
        guard enabled else { return }
        let rec = Record(time: Clock.wallNanos, action: action, path: index.path(id), isFolder: index.isDirectory(id))
        append(rec)
    }

    public func append(_ rec: Record) {
        m.sync {
            if ring.count < capacity {
                ring.append(rec)
            } else {
                ring[head] = rec
                head = (head + 1) % capacity
            }
            total += 1
        }
    }

    /// Oldest-first copy of the retained records.
    public func snapshot() -> [Record] {
        m.sync {
            if ring.count < capacity { return ring }
            return Array(ring[head...] + ring[..<head])
        }
    }

    public func clear() {
        m.sync {
            ring.removeAll(keepingCapacity: true)
            head = 0
        }
    }
}
