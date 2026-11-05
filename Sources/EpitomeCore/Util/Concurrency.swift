import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A plain mutex. Heap allocated so the pthread object has a stable address.
public final class Mutex: @unchecked Sendable {
    private let m: UnsafeMutablePointer<pthread_mutex_t>

    public init() {
        m = .allocate(capacity: 1)
        m.initialize(to: pthread_mutex_t())
        pthread_mutex_init(m, nil)
    }

    deinit {
        pthread_mutex_destroy(m)
        m.deallocate()
    }

    @inline(__always) public func lock() { pthread_mutex_lock(m) }
    @inline(__always) public func unlock() { pthread_mutex_unlock(m) }

    @inline(__always)
    public func sync<R>(_ body: () throws -> R) rethrows -> R {
        pthread_mutex_lock(m)
        defer { pthread_mutex_unlock(m) }
        return try body()
    }

    fileprivate var raw: UnsafeMutablePointer<pthread_mutex_t> { m }
}

/// Condition variable bound to a `Mutex`.
public final class Condition: @unchecked Sendable {
    public let mutex = Mutex()
    private let c: UnsafeMutablePointer<pthread_cond_t>

    public init() {
        c = .allocate(capacity: 1)
        c.initialize(to: pthread_cond_t())
        pthread_cond_init(c, nil)
    }

    deinit {
        pthread_cond_destroy(c)
        c.deallocate()
    }

    /// Must be called with `mutex` held.
    public func wait() { pthread_cond_wait(c, mutex.raw) }

    /// Waits up to `seconds`; returns false on timeout. Must be called with `mutex` held.
    @discardableResult
    public func wait(seconds: Double) -> Bool {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var ts = timespec()
        let total = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000 + seconds
        ts.tv_sec = Int(total)
        ts.tv_nsec = Int((total - Double(Int(total))) * 1_000_000_000)
        return pthread_cond_timedwait(c, mutex.raw, &ts) == 0
    }

    public func signal() { pthread_cond_signal(c) }
    public func broadcast() { pthread_cond_broadcast(c) }
}

/// Many-readers / one-writer lock guarding the index.
public final class RWLock: @unchecked Sendable {
    private let l: UnsafeMutablePointer<pthread_rwlock_t>

    public init() {
        l = .allocate(capacity: 1)
        l.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(l, nil)
    }

    deinit {
        pthread_rwlock_destroy(l)
        l.deallocate()
    }

    @inline(__always) public func readLock() { pthread_rwlock_rdlock(l) }
    @inline(__always) public func writeLock() { pthread_rwlock_wrlock(l) }
    @inline(__always) public func unlock() { pthread_rwlock_unlock(l) }

    @inline(__always)
    public func read<R>(_ body: () throws -> R) rethrows -> R {
        pthread_rwlock_rdlock(l)
        defer { pthread_rwlock_unlock(l) }
        return try body()
    }

    @inline(__always)
    public func write<R>(_ body: () throws -> R) rethrows -> R {
        pthread_rwlock_wrlock(l)
        defer { pthread_rwlock_unlock(l) }
        return try body()
    }
}

/// Small lock-protected integer for counters that are touched occasionally.
public final class AtomicCounter: @unchecked Sendable {
    private let m = Mutex()
    private var v: Int

    public init(_ value: Int = 0) { v = value }

    public var value: Int {
        get { m.sync { v } }
        set { m.sync { v = newValue } }
    }

    @discardableResult
    public func add(_ d: Int) -> Int { m.sync { v += d; return v } }
}

/// Cooperative cancellation flag shared between a caller and background work.
public final class CancelToken: @unchecked Sendable {
    private let m = Mutex()
    private var flag = false

    public init() {}

    public var isCancelled: Bool { m.sync { flag } }
    public func cancel() { m.sync { flag = true } }
}

/// Parallel helpers built on GCD.
public enum Parallel {
    public static var coreCount: Int { Swift.max(1, ProcessInfo.processInfo.activeProcessorCount) }

    /// Runs `body(i)` for i in 0..<n across all cores.
    @inline(__always)
    public static func forEach(_ n: Int, _ body: (Int) -> Void) {
        if n <= 0 { return }
        if n == 1 { body(0); return }
        DispatchQueue.concurrentPerform(iterations: n, execute: body)
    }

    /// Sorts `buf` in place: chunks are sorted concurrently and merged pairwise.
    public static func sort(_ buf: UnsafeMutableBufferPointer<UInt32>, by less: (UInt32, UInt32) -> Bool) {
        let n = buf.count
        guard n > 1, let base = buf.baseAddress else { return }
        if n < 65_536 || coreCount == 1 {
            var whole = buf
            whole.sort(by: less)
            return
        }
        var parts = 1
        while parts < coreCount * 2 && parts < 64 { parts <<= 1 }
        let chunk = (n + parts - 1) / parts
        DispatchQueue.concurrentPerform(iterations: parts) { p in
            let lo = p * chunk
            let hi = Swift.min(n, lo + chunk)
            if lo < hi {
                var part = UnsafeMutableBufferPointer(start: base + lo, count: hi - lo)
                part.sort(by: less)
            }
        }
        let tmp = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        defer { tmp.deallocate() }
        var src = base
        var dst = tmp
        var width = chunk
        while width < n {
            let pairs = (n + 2 * width - 1) / (2 * width)
            let s = src, d = dst, w = width
            DispatchQueue.concurrentPerform(iterations: pairs) { k in
                let lo = k * 2 * w
                let mid = Swift.min(n, lo + w)
                let hi = Swift.min(n, lo + 2 * w)
                merge(s + lo, mid - lo, s + mid, hi - mid, into: d + lo, less)
            }
            swap(&src, &dst)
            width *= 2
        }
        if src != base { memcpy(base, src, n * MemoryLayout<UInt32>.stride) }
    }

    /// Stable merge of two sorted runs into `out`.
    @inline(__always)
    public static func merge(_ a: UnsafePointer<UInt32>, _ na: Int,
                             _ b: UnsafePointer<UInt32>, _ nb: Int,
                             into out: UnsafeMutablePointer<UInt32>,
                             _ less: (UInt32, UInt32) -> Bool) {
        var i = 0, j = 0, k = 0
        while i < na && j < nb {
            if less(b[j], a[i]) { out[k] = b[j]; j += 1 } else { out[k] = a[i]; i += 1 }
            k += 1
        }
        if i < na { memcpy(out + k, a + i, (na - i) * 4); k += na - i }
        if j < nb { memcpy(out + k, b + j, (nb - j) * 4) }
    }
}

/// Monotonic time helpers.
public enum Clock {
    public static var now: Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    /// Wall clock in nanoseconds since 1970 (the index's time unit).
    public static var wallNanos: Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) &* 1_000_000_000 &+ Int64(ts.tv_nsec)
    }
}
