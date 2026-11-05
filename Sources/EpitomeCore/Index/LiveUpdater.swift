import Foundation
#if os(macOS)
import CoreServices
#endif

/// One file-system change notification.
public struct FileEvent: Sendable {
    public var path: String
    public var flags: UInt32
    public var id: UInt64
    public var inode: UInt64?

    public static let mustScanSubDirs: UInt32 = 0x0000_0001
    public static let userDropped: UInt32 = 0x0000_0002
    public static let kernelDropped: UInt32 = 0x0000_0004
    public static let idsWrapped: UInt32 = 0x0000_0008
    public static let historyDone: UInt32 = 0x0000_0010
    public static let rootChanged: UInt32 = 0x0000_0020
    public static let mount: UInt32 = 0x0000_0040
    public static let unmount: UInt32 = 0x0000_0080
    public static let itemCreated: UInt32 = 0x0000_0100
    public static let itemRemoved: UInt32 = 0x0000_0200
    public static let itemRenamed: UInt32 = 0x0000_0800
    public static let itemIsDir: UInt32 = 0x0002_0000
}

/// Watches paths for changes. On macOS this is FSEvents with file-level events
/// and persisted event IDs, so changes made while Epitome was not running are
/// replayed at the next start (like a change journal).
public final class FSWatcher: @unchecked Sendable {
    public typealias Handler = ([FileEvent]) -> Void
    let handler: Handler
    let queue: DispatchQueue
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #endif
    public private(set) var isRunning = false

    public init(queue: DispatchQueue, handler: @escaping Handler) {
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    /// System-wide current event ID (0 where unsupported).
    public static var currentEventID: UInt64 {
        #if os(macOS)
        return FSEventsGetCurrentEventId()
        #else
        return 0
        #endif
    }

    /// The FSEvents database UUID for the device holding `path` (changes when history is reset).
    public static func eventsUUID(forPath path: String) -> String? {
        #if os(macOS)
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        guard let u = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, u) as String?
        #else
        return nil
        #endif
    }

    /// Starts watching. `since` = last processed event ID to replay history, nil = from now.
    public func start(paths: [String], since: UInt64?, latency: Double = 0.3) {
        stop()
        #if os(macOS)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
                           kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseExtendedData |
                           kFSEventStreamCreateFlagWatchRoot)
        let cb: FSEventStreamCallback = { _, info, count, paths, flagsPtr, idsPtr in
            guard let info = info else { return }
            let me = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var events: [FileEvent] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                var path: String?
                var inode: UInt64?
                if let d = arr[i] as? NSDictionary {
                    path = d[kFSEventStreamEventExtendedDataPathKey as String] as? String
                    inode = (d[kFSEventStreamEventExtendedFileIDKey as String] as? NSNumber)?.uint64Value
                } else {
                    path = arr[i] as? String
                }
                guard let p = path else { continue }
                events.append(FileEvent(path: p, flags: flagsPtr[i], id: idsPtr[i], inode: inode))
            }
            me.handler(events)
        }
        let sinceID = since.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, paths as CFArray, sinceID, latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) {
            stream = s
            isRunning = true
        } else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        #endif
    }

    public func stop() {
        #if os(macOS)
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        #endif
        isRunning = false
    }

    /// Makes the stream deliver any pending events now.
    public func flush() {
        #if os(macOS)
        if let s = stream { FSEventStreamFlushAsync(s) }
        #endif
    }
}

/// Maps paths reported on the Data volume back to the firmlinked view ("/Users/…").
public func normalizeEventPath(_ p: String) -> String {
    var s = p
    if s.hasPrefix("/System/Volumes/Data/") {
        s = String(s.dropFirst("/System/Volumes/Data".count))
    } else if s == "/System/Volumes/Data" {
        s = "/"
    }
    while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
    return s
}
