import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if os(Linux)
let kSockStream = Int32(SOCK_STREAM.rawValue)
#else
let kSockStream = SOCK_STREAM
#endif

/// Ignore SIGPIPE so writes to closed sockets return errors instead of killing us.
public func ignoreSIGPIPE() {
    signal(SIGPIPE, SIG_IGN)
}

/// A connected stream socket with simple buffered line reading.
public final class SocketConnection: @unchecked Sendable {
    public let fd: Int32
    public let peer: String
    private var buf = [UInt8]()
    private var pos = 0
    private var closed = false
    public var timeoutSeconds: Int = 0 {
        didSet {
            var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    public init(fd: Int32, peer: String) {
        self.fd = fd
        self.peer = peer
        #if os(macOS)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    deinit { close() }

    public func close() {
        if !closed {
            closed = true
            shutdown(fd, Int32(SHUT_RDWR))
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
        }
    }

    private func fill() -> Bool {
        if pos > 0 && pos == buf.count { buf.removeAll(keepingCapacity: true); pos = 0 }
        var tmp = [UInt8](repeating: 0, count: 16_384)
        let n = tmp.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 16_384, 0) }
        if n <= 0 { return false }
        buf.append(contentsOf: tmp[0..<n])
        return true
    }

    /// Reads up to "\n" (strips "\r\n"). Nil on EOF/error or when the line exceeds `max`.
    public func readLine(max: Int = 1 << 20) -> String? {
        while true {
            if let nl = buf[pos...].firstIndex(of: 10) {
                var end = nl
                if end > pos && buf[end - 1] == 13 { end -= 1 }
                let s = String(decoding: buf[pos..<end], as: UTF8.self)
                pos = nl + 1
                return s
            }
            if buf.count - pos > max { return nil }
            if !fill() {
                if pos < buf.count {
                    let s = String(decoding: buf[pos...], as: UTF8.self)
                    pos = buf.count
                    return s
                }
                return nil
            }
        }
    }

    /// Reads exactly `n` bytes (used for request bodies).
    public func readBytes(_ n: Int) -> [UInt8]? {
        while buf.count - pos < n { if !fill() { return nil } }
        let out = Array(buf[pos..<(pos + n)])
        pos += n
        return out
    }

    @discardableResult
    public func write(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
        var off = 0
        while off < n {
            #if os(Linux)
            let w = send(fd, p + off, n - off, Int32(MSG_NOSIGNAL))
            #else
            let w = send(fd, p + off, n - off, 0)
            #endif
            if w <= 0 {
                if w < 0 && errno == EINTR { continue }
                return false
            }
            off += w
        }
        return true
    }

    @discardableResult
    public func write(_ s: String) -> Bool {
        var str = s
        return str.withUTF8 { $0.count == 0 ? true : write($0.baseAddress!, $0.count) }
    }

    @discardableResult
    public func write(_ d: Data) -> Bool {
        d.withUnsafeBytes { $0.count == 0 ? true : write($0.baseAddress!, $0.count) }
    }

    /// Local address of this socket (for FTP PASV replies).
    public var localIPv4: String? {
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let r = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard r == 0 else { return nil }
        if addr.ss_family == sa_family_t(AF_INET) {
            return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p -> String in
                var a = p.pointee.sin_addr
                var b = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &a, &b, socklen_t(INET_ADDRSTRLEN))
                return String(cString: b)
            } }
        }
        if addr.ss_family == sa_family_t(AF_INET6) {
            return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p -> String? in
                var a = p.pointee.sin6_addr
                var b = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &a, &b, socklen_t(INET6_ADDRSTRLEN))
                let s = String(cString: b)
                if s.hasPrefix("::ffff:") { return String(s.dropFirst(7)) }
                return s == "::1" ? "127.0.0.1" : s
            } }
        }
        return nil
    }
}

public enum SocketError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        if case .failed(let s) = self { return s }
        return "socket error"
    }
}

/// A listening TCP or Unix-domain socket.
public final class Listener: @unchecked Sendable {
    public let fd: Int32
    public let port: UInt16
    private var closed = false

    init(fd: Int32, port: UInt16) {
        self.fd = fd
        self.port = port
    }

    deinit { close() }

    public func close() {
        if !closed {
            closed = true
            shutdown(fd, Int32(SHUT_RDWR))
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
        }
    }

    /// Opens a TCP listener. `bind` empty = all interfaces (IPv6 dual-stack when possible). Port 0 = any free port.
    public static func tcp(port: UInt16, bind host: String = "") throws -> Listener {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty || h.contains(":") {
            if let l = try? tcp6(port: port, host: h.isEmpty ? "::" : h) { return l }
            if !h.isEmpty { throw SocketError.failed("cannot bind to \(h)") }
        }
        return try tcp4(port: port, host: h.isEmpty ? "0.0.0.0" : h)
    }

    static func tcp4(port: UInt16, host: String) throws -> Listener {
        let fd = socket(AF_INET, kSockStream, 0)
        guard fd >= 0 else { throw SocketError.failed("socket() failed: \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        #if os(macOS)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            closeFD(fd)
            throw SocketError.failed("invalid address \(host)")
        }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Glue.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else {
            let e = errno
            closeFD(fd)
            throw SocketError.failed("bind to \(host):\(port) failed (\(String(cString: strerror(e))))")
        }
        guard listen(fd, 64) == 0 else { closeFD(fd); throw SocketError.failed("listen failed") }
        return Listener(fd: fd, port: actualPort(fd) ?? port)
    }

    static func tcp6(port: UInt16, host: String) throws -> Listener {
        let fd = socket(AF_INET6, kSockStream, 0)
        guard fd >= 0 else { throw SocketError.failed("socket6() failed") }
        var one: Int32 = 1
        var zero: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        #if os(macOS)
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        guard inet_pton(AF_INET6, host, &addr.sin6_addr) == 1 else { closeFD(fd); throw SocketError.failed("invalid address") }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Glue.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        guard r == 0 else { closeFD(fd); throw SocketError.failed("bind6 failed") }
        guard listen(fd, 64) == 0 else { closeFD(fd); throw SocketError.failed("listen failed") }
        return Listener(fd: fd, port: actualPort(fd) ?? port)
    }

    static func actualPort(_ fd: Int32) -> UInt16? {
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let r = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard r == 0 else { return nil }
        if addr.ss_family == sa_family_t(AF_INET) {
            return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) } }
        }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) } }
    }

    /// Opens a Unix-domain listener at `path` (removes a stale socket file; mode 0600).
    public static func unix(path: String) throws -> Listener {
        unlink(path)
        let fd = socket(AF_UNIX, kSockStream, 0)
        guard fd >= 0 else { throw SocketError.failed("socket(AF_UNIX) failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { closeFD(fd); throw SocketError.failed("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: cap) { b in
                for (i, c) in bytes.enumerated() { b[i] = c }
                b[bytes.count] = 0
            }
        }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Glue.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { closeFD(fd); throw SocketError.failed("bind(\(path)) failed: \(errno)") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { closeFD(fd); throw SocketError.failed("listen failed") }
        return Listener(fd: fd, port: 0)
    }

    /// Blocks until a client connects. Nil once the listener is closed.
    public func accept() -> SocketConnection? {
        while true {
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let c = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.accept(fd, $0, &len) } }
            if c < 0 {
                if errno == EINTR { continue }
                return nil
            }
            var peer = "local"
            if addr.ss_family == sa_family_t(AF_INET) {
                peer = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p -> String in
                    var a = p.pointee.sin_addr
                    var b = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &a, &b, socklen_t(INET_ADDRSTRLEN))
                    return String(cString: b)
                } }
            } else if addr.ss_family == sa_family_t(AF_INET6) {
                peer = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p -> String in
                    var a = p.pointee.sin6_addr
                    var b = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &a, &b, socklen_t(INET6_ADDRSTRLEN))
                    let s = String(cString: b)
                    return s.hasPrefix("::ffff:") ? String(s.dropFirst(7)) : s
                } }
            }
            return SocketConnection(fd: c, peer: peer)
        }
    }

    /// Runs `handler` for every connection on a background thread until closed.
    public func serve(_ handler: @escaping @Sendable (SocketConnection) -> Void) {
        let t = Thread { [self] in
            while let c = accept() {
                DispatchQueue.global(qos: .userInitiated).async { handler(c) }
            }
        }
        t.name = "epitome.listener.\(port)"
        t.start()
    }
}

func closeFD(_ fd: Int32) {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

/// Disambiguates libc calls that collide with Swift method names.
enum Glue {
    static func bind(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.bind(fd, a, l)
        #else
        return Glibc.bind(fd, a, l)
        #endif
    }

    static func accept(_ fd: Int32, _ a: UnsafeMutablePointer<sockaddr>, _ l: UnsafeMutablePointer<socklen_t>) -> Int32 {
        #if canImport(Darwin)
        return Darwin.accept(fd, a, l)
        #else
        return Glibc.accept(fd, a, l)
        #endif
    }

    static func connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(fd, a, l)
        #else
        return Glibc.connect(fd, a, l)
        #endif
    }
}

/// Client-side connections.
public enum Connector {
    public static func unix(path: String) -> SocketConnection? {
        let fd = socket(AF_UNIX, kSockStream, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { closeFD(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: cap) { b in
                for (i, c) in bytes.enumerated() { b[i] = c }
                b[bytes.count] = 0
            }
        }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Glue.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { closeFD(fd); return nil }
        return SocketConnection(fd: fd, peer: "local")
    }

    /// TCP connect by host name or address.
    public static func tcp(host: String, port: UInt16, timeout: Int = 15) -> SocketConnection? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = kSockStream
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                if Glue.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    let c = SocketConnection(fd: fd, peer: host)
                    c.timeoutSeconds = timeout
                    return c
                }
                closeFD(fd)
            }
            p = ai.pointee.ai_next
        }
        return nil
    }
}
