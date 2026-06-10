import Foundation

/// Everything-style query: bare tokens AND-match the filename; prefixed tokens filter.
///
///   report q3          → name contains "report" AND "q3"
///   ext:swift           → extension filter (leading dot tolerated)
///   size:>1gb size:<2tb → allocated-size window (b/k/m/g/t units, decimals ok; bare = at-least)
///   kind:file | kind:folder
///   path:working        → full path contains (the expensive filter — applied last)
///
/// Unknown prefixes aren't special-cased: "foo:bar" just searches for the literal text,
/// so ordinary filenames with colons keep working.
public struct SearchQuery: Equatable {
    public var needles: [[UInt8]] = []   // lowercased UTF-8; ALL must appear in the name
    public var ext: String?
    public var kindDir: Bool?
    public var sizeMin: UInt64?
    public var sizeMax: UInt64?
    public var pathNeedle: String?
    /// A bare token contained '/' — no filename can ever match.
    public var impossible = false

    public var isEmpty: Bool {
        needles.isEmpty && ext == nil && kindDir == nil
            && sizeMin == nil && sizeMax == nil && pathNeedle == nil
    }
    /// The most selective needle leads the memmem sweep (longest = fewest hits).
    public var primary: [UInt8]? { needles.max { $0.count < $1.count } }

    public static func parse(_ raw: String) -> SearchQuery {
        var q = SearchQuery()
        for tok in raw.split(separator: " ") {
            let lower = tok.lowercased()
            if lower.hasPrefix("ext:") {
                var e = String(lower.dropFirst(4))
                if e.hasPrefix(".") { e.removeFirst() }
                if !e.isEmpty { q.ext = e }
            } else if lower.hasPrefix("kind:") {
                let v = lower.dropFirst(5)
                if v.hasPrefix("folder") || v.hasPrefix("dir") { q.kindDir = true }
                else if v.hasPrefix("file") { q.kindDir = false }
            } else if lower.hasPrefix("path:") {
                let v = String(lower.dropFirst(5))
                if !v.isEmpty { q.pathNeedle = v }
            } else if lower.hasPrefix("size:"), let (min, max) = parseSize(lower.dropFirst(5)) {
                if let min { q.sizeMin = max60(q.sizeMin, min) }
                if let max { q.sizeMax = min60(q.sizeMax, max) }
            } else if !lower.isEmpty {
                let u = Array(lower.utf8)
                if u.contains(0x2F) { q.impossible = true } else { q.needles.append(u) }
            }
        }
        return q
    }

    // Multiple size: tokens narrow the window.
    private static func max60(_ a: UInt64?, _ b: UInt64) -> UInt64 { Swift.max(a ?? 0, b) }
    private static func min60(_ a: UInt64?, _ b: UInt64) -> UInt64 { Swift.min(a ?? .max, b) }

    /// ">1.5gb" → (min, nil); "<500mb" → (nil, max); bare "10mb" → at-least. nil = unparsable.
    private static func parseSize(_ s: Substring) -> (min: UInt64?, max: UInt64?)? {
        var v = s
        var isMax = false
        if v.hasPrefix(">=") || v.hasPrefix(">") { v = v.drop { $0 == ">" || $0 == "=" } }
        else if v.hasPrefix("<=") || v.hasPrefix("<") { v = v.drop { $0 == "<" || $0 == "=" }; isMax = true }
        guard let b = bytes(v) else { return nil }
        return isMax ? (nil, b) : (b, nil)
    }

    /// "1.5gb", "500k", "2tb", "100" → bytes. nil for anything unparsable.
    static func bytes(_ s: Substring) -> UInt64? {
        var num = "", unit = ""
        for c in s {
            if c.isNumber || c == "." { num.append(c) } else { unit.append(c) }
        }
        guard let v = Double(num), v >= 0, v.isFinite else { return nil }
        let mult: Double
        switch unit {
        case "", "b":   mult = 1
        case "k", "kb": mult = 1024
        case "m", "mb": mult = 1048576
        case "g", "gb": mult = 1073741824
        case "t", "tb": mult = 1099511627776
        default: return nil
        }
        return UInt64(v * mult)
    }
}
