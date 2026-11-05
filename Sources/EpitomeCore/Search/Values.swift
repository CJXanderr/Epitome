import Foundation

/// Comparison operator in `function:<op><value>` terms.
public enum CompareOp: String, Sendable {
    case eq = ""          // equal within the value's granularity (size:1kb = 1024…2047)
    case exact = "="      // exactly equal (size:=1kb = 1024)
    case ne = "!"         // not equal within granularity
    case notExact = "!="  // not exactly equal
    case lt = "<", le = "<=", gt = ">", ge = ">="
    case range = ".."
}

/// A half-open interval [lo, hi) used for sizes, dates and numbers.
/// Exact numbers are the degenerate interval [v, v+1).
public struct ValueRange: Sendable, Equatable {
    public var lo: Int64
    public var hi: Int64

    public init(lo: Int64, hi: Int64) {
        self.lo = lo
        self.hi = hi
    }

    public static func exact(_ v: Int64) -> ValueRange { ValueRange(lo: v, hi: v &+ 1) }

    /// Open-ended into the future (rolling windows like `last2weeks`).
    public var isOpenEnded: Bool { hi == .max }
}

/// A compiled comparison against an Int64 value.
public struct RangeTest: Sendable {
    public var op: CompareOp
    public var a: ValueRange
    public var b: ValueRange?
    /// Matches unknown values (e.g. `size:unknown`, `dm:unknown`).
    public var matchUnknown = false
    /// `f:` with no value: anything known and non-zero.
    public var matchNonZero = false
    public var unknownValue: Int64
    /// For date ranges: an open-ended end value contributes its start ("3weeks..2weeks").
    public var openEndUsesStart = false

    public init(op: CompareOp, a: ValueRange, b: ValueRange? = nil, unknownValue: Int64) {
        self.op = op
        self.a = a
        self.b = b
        self.unknownValue = unknownValue
    }

    @inline(__always)
    public func test(_ v: Int64) -> Bool {
        if v == unknownValue { return matchUnknown ? op != .ne && op != .notExact : (op == .ne || op == .notExact) && !matchNonZero }
        if matchUnknown { return op == .ne || op == .notExact }
        if matchNonZero { return v != 0 }
        switch op {
        case .eq: return v >= a.lo && v < a.hi
        case .exact: return v == a.lo
        case .ne: return !(v >= a.lo && v < a.hi)
        case .notExact: return v != a.lo
        case .lt: return v < a.lo
        case .le: return v < a.hi
        case .gt: return v >= a.hi
        case .ge: return v >= a.lo
        case .range:
            guard let bb = b else { return v >= a.lo && v < a.hi }
            let hi = (openEndUsesStart && bb.isOpenEnded) ? bb.lo : bb.hi
            let lo = Swift.min(a.lo, bb.lo)
            return v >= lo && v < hi
        }
    }
}

/// Splits "<=value", ">x", "a..b" etc.
public struct Comparison {
    public var op: CompareOp
    public var first: String
    public var second: String?

    public static func parse(_ raw: String, allowDashRange: Bool) -> Comparison {
        var s = Substring(raw)
        var op: CompareOp = .eq
        if s.hasPrefix("<=") { op = .le; s = s.dropFirst(2) }
        else if s.hasPrefix(">=") { op = .ge; s = s.dropFirst(2) }
        else if s.hasPrefix("!=") { op = .notExact; s = s.dropFirst(2) }
        else if s.hasPrefix("==") { op = .exact; s = s.dropFirst(2) }
        else if s.hasPrefix("<") { op = .lt; s = s.dropFirst() }
        else if s.hasPrefix(">") { op = .gt; s = s.dropFirst() }
        else if s.hasPrefix("=") { op = .exact; s = s.dropFirst() }
        else if s.hasPrefix("!") { op = .ne; s = s.dropFirst() }
        let str = String(s)
        if op == .eq, let r = str.range(of: "..") {
            return Comparison(op: .range, first: String(str[..<r.lowerBound]), second: String(str[r.upperBound...]))
        }
        if op == .eq && allowDashRange, let dash = str.dropFirst().firstIndex(of: "-") {
            let a = String(str[..<dash]), b = String(str[str.index(after: dash)...])
            if !a.isEmpty && !b.isEmpty && a.last != "e" { return Comparison(op: .range, first: a, second: b) }
        }
        return Comparison(op: op, first: str, second: nil)
    }
}

// MARK: - Sizes

public enum SizeValue {
    public static let kb: Int64 = 1024
    public static let mb: Int64 = 1024 * 1024
    public static let gb: Int64 = 1024 * 1024 * 1024
    public static let tb: Int64 = 1024 * 1024 * 1024 * 1024

    /// Named size ranges (lower bound exclusive, upper inclusive, in bytes).
    public static func constant(_ s: String) -> ValueRange? {
        switch s.lowercased() {
        case "empty": return ValueRange(lo: 0, hi: 1)
        case "tiny": return ValueRange(lo: 1, hi: 10 * kb + 1)
        case "small": return ValueRange(lo: 10 * kb + 1, hi: 100 * kb + 1)
        case "medium": return ValueRange(lo: 100 * kb + 1, hi: mb + 1)
        case "large": return ValueRange(lo: mb + 1, hi: 16 * mb + 1)
        case "huge": return ValueRange(lo: 16 * mb + 1, hi: 128 * mb + 1)
        case "gigantic": return ValueRange(lo: 128 * mb + 1, hi: .max)
        default: return nil
        }
    }

    /// Parses "123", "1.5mb", "10 KB", "2g" into a bucket: `size:1kb` covers
    /// 1024…2047 bytes. Use `isConstant` to tell named classes apart.
    public static func parse(_ raw: String, metric: Bool = false) -> (ValueRange, isConstant: Bool)? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        if let c = constant(s) { return (c, true) }
        var numEnd = s.startIndex
        for ch in s.indices {
            let c = s[ch]
            if c.isNumber || c == "." || c == "," { numEnd = s.index(after: ch) } else { break }
        }
        let numStr = s[..<numEnd].replacingOccurrences(of: ",", with: ".")
        let unitStr = s[numEnd...].trimmingCharacters(in: .whitespaces)
        guard let num = Double(numStr) else { return nil }
        let k: Int64 = metric ? 1000 : 1024
        let mult: Int64
        switch unitStr {
        case "", "b", "byte", "bytes": mult = 1
        case "k", "kb", "kib", "kilobyte", "kilobytes": mult = k
        case "m", "mb", "mib", "megabyte", "megabytes": mult = k * k
        case "g", "gb", "gib", "gigabyte", "gigabytes": mult = k * k * k
        case "t", "tb", "tib", "terabyte", "terabytes": mult = k * k * k * k
        default: return nil
        }
        let decimals = numStr.split(separator: ".").dropFirst().first?.count ?? 0
        var gran = Double(mult)
        for _ in 0..<decimals { gran /= 10 }
        let lo = Int64((num * Double(mult)).rounded())
        let width = Swift.max(1, Int64(gran.rounded()))
        return (ValueRange(lo: lo, hi: lo + width), false)
    }
}

// MARK: - Numbers & durations

public enum NumberValue {
    public static func parse(_ raw: String) -> ValueRange? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let v = Int64(s) { return .exact(v) }
        if s.hasPrefix("0x"), let v = Int64(s.dropFirst(2), radix: 16) { return .exact(v) }
        if let d = Double(s) { return .exact(Int64(d.rounded())) }
        return nil
    }

    /// "90", "1:30", "01:02:03", "2m", "1h30m", "1hour2mins5secs", "pt1h20m" → seconds.
    public static func duration(_ raw: String) -> ValueRange? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("pt") { s = String(s.dropFirst(2)) }
        if s.contains(":") {
            var total: Double = 0
            for part in s.split(separator: ":") {
                guard let v = Double(part) else { return nil }
                total = total * 60 + v
            }
            return .exact(Int64(total))
        }
        if let v = Int64(s) { return .exact(v) }
        var total: Int64 = 0
        var num = ""
        var unit = ""
        func flush() -> Bool {
            if num.isEmpty && unit.isEmpty { return true }
            guard let v = Int64(num) else { return false }
            switch unit {
            case "d", "day", "days": total += v * 86_400
            case "h", "hour", "hours", "hr", "hrs": total += v * 3600
            case "m", "min", "mins", "minute", "minutes": total += v * 60
            case "s", "sec", "secs", "second", "seconds": total += v
            default: return false
            }
            num = ""
            unit = ""
            return true
        }
        for c in s {
            if c.isNumber {
                if !unit.isEmpty { guard flush() else { return nil } }
                num.append(c)
            } else if c.isLetter {
                unit.append(c)
            } else if c != " " {
                return nil
            }
        }
        guard flush() else { return nil }
        return .exact(total)
    }
}

// MARK: - Dates

/// Parses date values into [start, end) ranges in nanoseconds since 1970.
///
/// Semantics follow the newer (1.5) rules: `lastweek` = previous calendar week,
/// `last2weeks` / `past2weeks` / `2weeks` = rolling window from two weeks ago
/// (open-ended), `previous2weeks` = the two whole weeks before this one.
public struct DateValue {
    public var now: Date
    public var calendar: Calendar
    /// True when numeric dates are written day first (dd/mm/yyyy).
    public var dayFirst: Bool

    public init(now: Date = Date(), calendar: Calendar = .current, dayFirst: Bool? = nil) {
        self.now = now
        self.calendar = calendar
        self.dayFirst = dayFirst ?? DateValue.localeIsDayFirst()
    }

    static func localeIsDayFirst() -> Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: Locale.current) ?? "MM/dd/yyyy"
        guard let d = fmt.firstIndex(of: "d"), let m = fmt.firstIndex(of: "M") else { return false }
        return d < m
    }

    @inline(__always)
    static func ns(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1_000_000_000).rounded()) }

    func range(_ a: Date, _ b: Date) -> ValueRange { ValueRange(lo: DateValue.ns(a), hi: DateValue.ns(b)) }
    func rolling(_ a: Date) -> ValueRange { ValueRange(lo: DateValue.ns(a), hi: .max) }

    func startOf(_ unit: Calendar.Component, _ d: Date) -> Date {
        calendar.dateInterval(of: unit, for: d)?.start ?? d
    }

    func add(_ unit: Calendar.Component, _ n: Int, _ d: Date) -> Date {
        calendar.date(byAdding: unit, value: n, to: d) ?? d
    }

    static let unitWords: [(String, Calendar.Component)] = [
        ("years", .year), ("year", .year), ("yrs", .year), ("yr", .year),
        ("months", .month), ("month", .month),
        ("weeks", .weekOfYear), ("week", .weekOfYear), ("wks", .weekOfYear), ("wk", .weekOfYear),
        ("days", .day), ("day", .day),
        ("hours", .hour), ("hour", .hour), ("hrs", .hour), ("hr", .hour),
        ("minutes", .minute), ("minute", .minute), ("mins", .minute), ("min", .minute),
        ("seconds", .second), ("second", .second), ("secs", .second), ("sec", .second),
    ]

    static func unit(_ s: Substring) -> Calendar.Component? {
        unitWords.first(where: { $0.0 == s })?.1
    }

    static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                         "september", "october", "november", "december"]
    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// Returns nil when the text is not a date.
    public func parse(_ raw: String) -> ValueRange? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        if let r = relative(s) { return r }
        if let r = named(s) { return r }
        return absolute(s)
    }

    private func relative(_ s: String) -> ValueRange? {
        switch s {
        case "today": let a = startOf(.day, now); return range(a, add(.day, 1, a))
        case "yesterday": let a = add(.day, -1, startOf(.day, now)); return range(a, add(.day, 1, a))
        case "tomorrow": let a = add(.day, 1, startOf(.day, now)); return range(a, add(.day, 1, a))
        case "now": return range(now, now.addingTimeInterval(1))
        case "mtd": return rolling(startOf(.month, now))
        case "ytd": return rolling(startOf(.year, now))
        case "qtd":
            let m = calendar.component(.month, from: now)
            let qStartMonth = ((m - 1) / 3) * 3 + 1
            var c = calendar.dateComponents([.year], from: now)
            c.month = qStartMonth
            c.day = 1
            return calendar.date(from: c).map { rolling($0) }
        default: break
        }
        let prefixes = ["inthelast", "previous", "current", "coming", "this", "last", "prev", "past", "next"]
        var body = Substring(s)
        var prefix = ""
        for p in prefixes where s.hasPrefix(p) {
            prefix = p
            body = s.dropFirst(p.count)
            break
        }
        var digits = ""
        while let c = body.first, c.isNumber { digits.append(c); body = body.dropFirst() }
        guard let unit = DateValue.unit(body) else { return nil }
        let count = Int(digits) ?? 1
        let hasCount = !digits.isEmpty
        switch prefix {
        case "":
            // bare duration "2days" → rolling from 2 days ago
            guard hasCount else { return nil }
            return rolling(add(unit, -count, now))
        case "this", "current":
            let a = startOf(unit, now)
            return range(a, add(unit, 1, a))
        case "last", "prev", "previous":
            if hasCount {
                if prefix == "last" { return rolling(add(unit, -count, now)) }
                let cur = startOf(unit, now)
                return range(add(unit, -count, cur), cur)
            }
            let cur = startOf(unit, now)
            return range(add(unit, -1, cur), cur)
        case "past", "inthelast":
            return rolling(add(unit, -count, now))
        case "next", "coming":
            if hasCount { return range(now, add(unit, count, now)) }
            let nxt = add(unit, 1, startOf(unit, now))
            return range(nxt, add(unit, 1, nxt))
        default:
            return nil
        }
    }

    private func named(_ s: String) -> ValueRange? {
        guard s.count >= 3, s.allSatisfy(\.isLetter) else { return nil }
        if let mi = DateValue.months.firstIndex(where: { $0 == s || $0.hasPrefix(s) }) {
            var comps = calendar.dateComponents([.year], from: now)
            comps.month = mi + 1
            comps.day = 1
            guard let start = calendar.date(from: comps) else { return nil }
            return range(start, add(.month, 1, start))
        }
        if let wi = DateValue.weekdays.firstIndex(where: { $0 == s || $0.hasPrefix(s) }) {
            let today = startOf(.day, now)
            let wd = calendar.component(.weekday, from: today) - 1
            var back = wd - wi
            if back < 0 { back += 7 }
            let start = add(.day, -back, today)
            return range(start, add(.day, 1, start))
        }
        return nil
    }

    private func absolute(_ s: String) -> ValueRange? {
        var datePart = s
        var timePart: String? = nil
        if let t = s.firstIndex(where: { $0 == "t" || $0 == " " }) {
            datePart = String(s[..<t])
            timePart = String(s[s.index(after: t)...])
        }
        // Compact ISO basic forms: YYYYMMDD, YYYYMM
        if datePart.count == 8 || datePart.count == 6, datePart.allSatisfy(\.isNumber) {
            let ch = Array(datePart)
            let y = Int(String(ch[0..<4]))!
            let m = Int(String(ch[4..<6]))!
            if datePart.count == 6 {
                guard (1...12).contains(m), let a = date(y, m, 1) else { return nil }
                return range(a, add(.month, 1, a))
            }
            let d = Int(String(ch[6..<8]))!
            datePart = "\(y)-\(m)-\(d)"
            if let tp = timePart, tp.count >= 2, tp.allSatisfy(\.isNumber) {
                let tc = Array(tp)
                var parts: [String] = []
                var i = 0
                while i + 2 <= tc.count { parts.append(String(tc[i..<(i + 2)])); i += 2 }
                timePart = parts.joined(separator: ":")
            }
        }
        let seps = CharacterSet(charactersIn: "-/.")
        let parts = datePart.components(separatedBy: seps).filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        var y = 0, m = 0, d = 0
        let nums = parts.compactMap { Int($0) }
        switch nums.count {
        case 1:
            guard parts[0].count == 4 else { return nil }
            y = nums[0]
            return date(y, 1, 1).map { range($0, add(.year, 1, $0)) }
        case 2:
            if parts[0].count == 4 { y = nums[0]; m = nums[1] } else if parts[1].count == 4 { m = nums[0]; y = nums[1] } else { return nil }
            guard (1...12).contains(m), let a = date(y, m, 1) else { return nil }
            return range(a, add(.month, 1, a))
        case 3:
            if parts[0].count == 4 { y = nums[0]; m = nums[1]; d = nums[2] }
            else if dayFirst { d = nums[0]; m = nums[1]; y = nums[2] }
            else { m = nums[0]; d = nums[1]; y = nums[2] }
            if y < 100 { y += y < 70 ? 2000 : 1900 }
            guard (1...12).contains(m), (1...31).contains(d), let day = date(y, m, d) else { return nil }
            guard let tp = timePart, !tp.isEmpty else { return range(day, add(.day, 1, day)) }
            let tparts = tp.replacingOccurrences(of: "z", with: "").split(separator: ":").map(String.init)
            var hh = 0, mm = 0, ss = 0.0
            if tparts.count >= 1 { hh = Int(tparts[0]) ?? -1 }
            if tparts.count >= 2 { mm = Int(tparts[1]) ?? -1 }
            if tparts.count >= 3 { ss = Double(tparts[2]) ?? -1 }
            guard hh >= 0, hh < 24, mm >= 0, mm < 60, ss >= 0 else { return nil }
            let start = day.addingTimeInterval(Double(hh * 3600 + mm * 60) + ss)
            let unit: TimeInterval = tparts.count >= 3 ? (tparts[2].contains(".") ? 0.001 : 1) : (tparts.count == 2 ? 60 : 3600)
            return range(start, start.addingTimeInterval(unit))
        default:
            return nil
        }
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        c.hour = 0
        return calendar.date(from: c)
    }
}
