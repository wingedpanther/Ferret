import Foundation

/// One file or folder from a `search`, `glob` or `recent` reply.
public struct Hit: Decodable, Hashable, Sendable {
    public let path: String
    public let kind: String      // file | dir | link | other
    public let size: UInt64
    public let mtime: Int        // unix seconds
    public let score: Int
    public let git: String?      // absent when clean

    public var name: String { (path as NSString).lastPathComponent }
    public var parent: String { (path as NSString).deletingLastPathComponent }
    public var isDir: Bool { kind == "dir" }
    public var modified: Date { Date(timeIntervalSince1970: TimeInterval(mtime)) }
}

public struct SearchReply: Decodable, Sendable {
    public let ok: Bool
    public let error: String?
    public let hits: [Hit]?
    public let next: Int?
    public let took_us: Int?
}

/// A matching line. `col` and `ranges` are byte offsets into `text` (UTF-8).
public struct GrepMatch: Decodable, Hashable, Sendable {
    public let line: Int
    public let col: Int
    public let text: String
    public let ranges: [[Int]]
    public let def: Bool?
    public let before: [String]?
    public let after: [String]?

    /// `ranges` as String indices, skipping any that don't land on a character boundary.
    public var stringRanges: [Range<String.Index>] {
        let utf8 = text.utf8
        return ranges.compactMap { r in
            guard r.count == 2, r[0] <= r[1], r[1] <= utf8.count,
                  let lo = utf8.index(utf8.startIndex, offsetBy: r[0]).samePosition(in: text),
                  let hi = utf8.index(utf8.startIndex, offsetBy: r[1]).samePosition(in: text)
            else { return nil }
            return lo..<hi
        }
    }

    /// 1-based column in characters, for editors' `path:line:col`.
    public var column: Int {
        let utf8 = text.utf8
        guard col <= utf8.count else { return 1 }
        let idx = utf8.index(utf8.startIndex, offsetBy: col)
        return text.distance(from: text.startIndex, to: idx.samePosition(in: text) ?? text.startIndex) + 1
    }
}

public struct GrepFile: Decodable, Hashable, Sendable {
    public let path: String
    public let git: String?
    public let matches: [GrepMatch]
}

public struct GrepReply: Decodable, Sendable {
    public let ok: Bool
    public let error: String?
    public var files: [GrepFile]?
    public let complete: Bool?
    public let indexing: Int?
    public let source: String?
    public let took_us: Int?
}

public struct Status: Decodable, Sendable {
    public let ok: Bool
    public let error: String?
    public let entries: Int?
    public let dirs: Int?
    public let event_id: UInt64?
    public let content_docs: Int?
    public let content_pending: Int?
    public let full_disk_access: Bool?
}

public struct GitReply: Decodable, Sendable {
    public let ok: Bool
    public let error: String?
    public let root: String?
    /// False on the first ask for a repo: fsearch starts reading its status and `changed` is missing.
    public let read: Bool?
    public let changed: Int?
}

public struct OKReply: Decodable, Sendable {
    public let ok: Bool
    public let error: String?
}
