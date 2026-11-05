#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A growable, manually managed array of trivial (POD) values.
///
/// The index stores every entry as a "struct of arrays" built from these, so
/// the hot search loops can read raw pointers without ARC traffic, exclusivity
/// checks or bounds checks. Only use trivial types (integers, floats, POD structs).
/// Callers synchronise access themselves (see `RWLock`).
public final class PODArray<T> {
    public private(set) var base: UnsafeMutablePointer<T>
    public private(set) var count: Int
    public private(set) var capacity: Int

    public init(capacity: Int = 0) {
        let cap = Swift.max(capacity, 16)
        self.capacity = cap
        self.count = 0
        self.base = malloc(cap &* MemoryLayout<T>.stride)!.bindMemory(to: T.self, capacity: cap)
    }

    public convenience init(repeating value: T, count n: Int) {
        self.init(capacity: n)
        resize(n, fill: value)
    }

    deinit { free(base) }

    @inline(__always)
    public subscript(i: Int) -> T {
        get { base[i] }
        set { base[i] = newValue }
    }

    @inline(__always)
    public func append(_ value: T) {
        if count == capacity { grow(minimum: count + 1) }
        (base + count).initialize(to: value)
        count += 1
    }

    /// Appends `n` values copied from `source`.
    public func append(_ source: UnsafePointer<T>, count n: Int) {
        guard n > 0 else { return }
        reserve(count + n)
        memcpy(base + count, source, n &* MemoryLayout<T>.stride)
        count += n
    }

    public func append(contentsOf other: PODArray<T>) {
        append(other.base, count: other.count)
    }

    public func reserve(_ n: Int) {
        if n > capacity { grow(minimum: n) }
    }

    /// Sets the logical size. New slots are filled with `fill`.
    public func resize(_ n: Int, fill: T) {
        reserve(n)
        if n > count {
            var i = count
            while i < n { (base + i).initialize(to: fill); i += 1 }
        }
        count = n
    }

    /// Sets the logical size without initialising new slots (caller must fill them).
    public func resizeUninitialized(_ n: Int) {
        reserve(n)
        count = n
    }

    public func removeAll(keepingCapacity: Bool = false) {
        count = 0
        if !keepingCapacity && capacity > 4096 {
            free(base)
            capacity = 16
            base = malloc(16 &* MemoryLayout<T>.stride)!.bindMemory(to: T.self, capacity: 16)
        }
    }

    public func removeLast() -> T {
        count -= 1
        return base[count]
    }

    public func shrinkToFit() {
        let cap = Swift.max(count, 16)
        guard cap < capacity else { return }
        base = realloc(base, cap &* MemoryLayout<T>.stride)!.bindMemory(to: T.self, capacity: cap)
        capacity = cap
    }

    public func fill(_ value: T) {
        var i = 0
        while i < count { base[i] = value; i += 1 }
    }

    public var buffer: UnsafeMutableBufferPointer<T> { UnsafeMutableBufferPointer(start: base, count: count) }

    public var byteCount: Int { count &* MemoryLayout<T>.stride }

    public func toArray() -> [T] { Array(UnsafeBufferPointer(start: base, count: count)) }

    public func copy() -> PODArray<T> {
        let c = PODArray<T>(capacity: count)
        c.append(base, count: count)
        return c
    }

    private func grow(minimum: Int) {
        var cap = capacity
        while cap < minimum { cap = cap < (1 << 20) ? cap &* 2 : cap &+ cap / 2 }
        base = realloc(base, cap &* MemoryLayout<T>.stride)!.bindMemory(to: T.self, capacity: cap)
        capacity = cap
    }
}

/// An append-only byte arena (names, keys). Offsets stay valid until `removeAll`.
public typealias ByteArena = PODArray<UInt8>

extension PODArray where T == UInt8 {
    /// Appends raw bytes and returns the offset where they start.
    @discardableResult
    public func appendBytes(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
        let off = count
        append(p, count: n)
        return off
    }

    @discardableResult
    public func appendBytes<C: Collection>(_ bytes: C) -> Int where C.Element == UInt8 {
        let off = count
        reserve(count + bytes.count)
        for b in bytes { append(b) }
        return off
    }
}
