import Foundation

/// A piece of a search term: text plus whether it was inside double quotes.
public struct TermSegment: Equatable, Sendable {
    public var text: String
    public var quoted: Bool
}

/// One search term as typed (before modifiers/functions are interpreted).
public struct TermToken: Equatable, Sendable {
    public var segments: [TermSegment]
    /// The term was immediately followed by '<' (e.g. `case:<a b>`).
    public var prefixesGroup = false

    public var text: String { segments.map(\.text).joined() }
    public var isEmpty: Bool { segments.allSatisfy { $0.text.isEmpty } && !segments.contains { $0.quoted } }
    public var anyQuoted: Bool { segments.contains { $0.quoted } }
}

public enum QueryToken: Equatable, Sendable {
    case term(TermToken)
    case or
    case not
    case open
    case close
    case and
}

/// Syntax tree of a search.
public indirect enum QueryAST: Equatable, Sendable {
    case and([QueryAST])
    case or([QueryAST])
    case not(QueryAST)
    case term(TermToken)
    /// Modifiers/macros written in front of a group: `case:path:<...>`.
    case prefixed(TermToken, QueryAST)
    case empty
}

public struct ParserOptions: Sendable {
    public var literalOperators = false
    public var roundBrackets = false
    /// AND binds tighter than OR (`a b|c d` = `(a b)|(c d)`). Default: OR binds tighter.
    public var andPrecedence = false
    public init(literalOperators: Bool = false, roundBrackets: Bool = false, andPrecedence: Bool = false) {
        self.literalOperators = literalOperators
        self.roundBrackets = roundBrackets
        self.andPrecedence = andPrecedence
    }
}

/// Tokenizer + recursive-descent parser for the Everything-style syntax.
///
/// Precedence (highest first): `!` NOT, `< >` grouping, `|` OR, space AND.
/// So `a b|c` means `a AND (b OR c)`.
public enum QueryParser {
    public static func tokenize(_ q: String, options: ParserOptions = ParserOptions()) -> [QueryToken] {
        var tokens: [QueryToken] = []
        var segs: [TermSegment] = []
        var buf = ""
        var inQuote = false
        var termStarted = false

        func flushSeg(quoted: Bool) {
            if !buf.isEmpty || quoted { segs.append(TermSegment(text: buf, quoted: quoted)) }
            buf = ""
        }
        func endTerm(prefixesGroup: Bool = false) {
            flushSeg(quoted: false)
            if termStarted || !segs.isEmpty {
                var t = TermToken(segments: segs)
                t.prefixesGroup = prefixesGroup
                if !segs.isEmpty { tokens.append(.term(t)) }
            }
            segs = []
            termStarted = false
        }
        /// Unquoted text of the current term so far (for comparison detection).
        func unquotedTail() -> String { buf }
        func currentTermEmpty() -> Bool { buf.isEmpty && segs.isEmpty }

        let chars = Array(q)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuote {
                if c == "\"" {
                    flushSeg(quoted: true)
                    inQuote = false
                } else {
                    buf.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "\"":
                flushSeg(quoted: false)
                inQuote = true
                termStarted = true
            case " ", "\t", "\n", "\r":
                endTerm()
            case "|":
                endTerm()
                tokens.append(.or)
            case "!" where currentTermEmpty():
                tokens.append(.not)
            case "<", "(":
                if c == "(" && !options.roundBrackets { buf.append(c); break }
                let tail = unquotedTail()
                if c == "<" && !currentTermEmpty() && (tail.hasSuffix(":") || tail.hasSuffix("=") || tail.hasSuffix("<") || tail.hasSuffix(">")) {
                    buf.append(c) // comparison operator inside a function value
                } else {
                    let adjacent = !currentTermEmpty()
                    endTerm(prefixesGroup: adjacent)
                    tokens.append(.open)
                }
            case ">", ")":
                if c == ")" && !options.roundBrackets { buf.append(c); break }
                let tail = unquotedTail()
                if c == ">" && !currentTermEmpty() && (tail.hasSuffix(":") || tail.hasSuffix("<") || tail.hasSuffix(">") || tail.hasSuffix("=")) {
                    buf.append(c)
                } else {
                    endTerm()
                    tokens.append(.close)
                }
            default:
                buf.append(c)
            }
            i += 1
        }
        if inQuote { flushSeg(quoted: true) }
        endTerm()

        if options.literalOperators {
            tokens = tokens.map { tok in
                if case .term(let t) = tok, t.segments.count == 1, !t.segments[0].quoted {
                    switch t.segments[0].text {
                    case "AND", "&&": return .and
                    case "OR", "||": return .or
                    case "NOT": return .not
                    default: break
                    }
                }
                return tok
            }
        }
        return tokens
    }

    public static func parse(_ q: String, options: ParserOptions = ParserOptions()) -> QueryAST {
        var p = Parser(tokens: tokenize(q, options: options), andPrecedence: options.andPrecedence)
        let ast = p.parseExpr(topLevel: true)
        return ast
    }

    struct Parser {
        let tokens: [QueryToken]
        var pos = 0
        let andPrecedence: Bool

        init(tokens: [QueryToken], andPrecedence: Bool = false) {
            self.tokens = tokens
            self.andPrecedence = andPrecedence
        }

        mutating func parseExpr(topLevel: Bool) -> QueryAST {
            andPrecedence ? parseOrOfAnds(topLevel: topLevel) : parseAnd(topLevel: topLevel)
        }

        /// AND > OR: alternatives are whole AND sequences.
        mutating func parseOrOfAnds(topLevel: Bool) -> QueryAST {
            var alts: [[QueryAST]] = []
            var cur: [QueryAST] = []
            while let t = peek {
                if t == .close {
                    if topLevel { pos += 1; continue }
                    break
                }
                if t == .or { pos += 1; alts.append(cur); cur = []; continue }
                if t == .and { pos += 1; continue }
                let u = parseUnary()
                if u != .empty { cur.append(u) }
            }
            alts.append(cur)
            let nodes: [QueryAST] = alts.map { $0.isEmpty ? .empty : ($0.count == 1 ? $0[0] : .and($0)) }
            let live = nodes.filter { $0 != .empty }
            if live.isEmpty { return .empty }
            if nodes.count == 1 { return nodes[0] }
            return .or(nodes.map { $0 == .empty ? .and([]) : $0 })
        }

        var peek: QueryToken? { pos < tokens.count ? tokens[pos] : nil }
        mutating func next() -> QueryToken? {
            guard pos < tokens.count else { return nil }
            defer { pos += 1 }
            return tokens[pos]
        }

        mutating func parseAnd(topLevel: Bool) -> QueryAST {
            var items: [QueryAST] = []
            while let t = peek {
                if t == .close {
                    if topLevel { pos += 1; continue } // stray '>' — ignore
                    break
                }
                if t == .and || t == .or { pos += 1; continue }
                let node = parseOr()
                if node != .empty { items.append(node) }
            }
            if items.isEmpty { return .empty }
            return items.count == 1 ? items[0] : .and(items)
        }

        mutating func parseOr() -> QueryAST {
            var alts: [QueryAST] = [parseUnary()]
            while peek == .or {
                pos += 1
                // "a | " at the end or "a | > " — ignore the dangling OR
                guard let t = peek, t != .close else { break }
                alts.append(parseUnary())
            }
            let live = alts.filter { $0 != .empty }
            if live.isEmpty { return .empty }
            if live.count == 1 && alts.count == 1 { return live[0] }
            // An empty alternative (e.g. `a|""`) matches everything – keep it explicit.
            return .or(alts.map { $0 == .empty ? .and([]) : $0 })
        }

        mutating func parseUnary() -> QueryAST {
            if peek == .not {
                pos += 1
                let inner = parseUnary()
                if inner == .empty { return .empty }
                if case .not(let x) = inner { return x }
                return .not(inner)
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> QueryAST {
            guard let t = next() else { return .empty }
            switch t {
            case .open:
                let inner = parseExpr(topLevel: false)
                if peek == .close { pos += 1 }
                return inner
            case .term(let term):
                if term.prefixesGroup && peek == .open {
                    pos += 1
                    let inner = parseExpr(topLevel: false)
                    if peek == .close { pos += 1 }
                    return .prefixed(term, inner)
                }
                return .term(term)
            case .not:
                pos -= 1
                return parseUnary()
            case .or, .and, .close:
                return .empty
            }
        }
    }
}
