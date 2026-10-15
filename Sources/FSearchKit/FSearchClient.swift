import Foundation

public enum FSearchError: LocalizedError {
    case daemonUnavailable(String)
    case server(String)
    case badReply

    public var errorDescription: String? {
        switch self {
        case .daemonUnavailable(let why): return "fsearch isn't running: \(why)"
        case .server(let message): return message
        case .badReply: return "fsearch sent a reply that couldn't be read"
        }
    }
}

/// One connection to the fsearch daemon. Requests go strictly one at a time:
/// the daemon can deadlock on concurrent searches sharing a connection's tables,
/// and an open connection keeps its cores warm for search-as-you-type.
public final class FSearchClient: @unchecked Sendable {
    public static let socketPath = NSHomeDirectory() + "/Library/Application Support/FSearch/fsearch.sock"
    /// Where `fsearch install` puts the CLI. Preferred, so the app and the terminal run the same build.
    public static let installedPath = NSHomeDirectory() + "/.local/bin/fsearch"
    /// The copy scripts/bundle.sh ships in Ferret.app/Contents/MacOS, for machines without fsearch.
    public static var bundledPath: String? { Bundle.main.url(forAuxiliaryExecutable: "fsearch")?.path }

    public static var binary: String { resolveBinary() }
    public static var isUsingBundled: Bool { bundledPath != nil && binary == bundledPath }

    /// The first runnable fsearch: installed, then bundled, then Homebrew. Falls back to the
    /// installed path so error messages name where it's expected.
    public static func resolveBinary(_ candidates: [String]? = nil,
                                     isExecutable: (String) -> Bool = FileManager.default.isExecutableFile) -> String {
        let list = candidates ?? [installedPath, bundledPath, "/opt/homebrew/bin/fsearch", "/usr/local/bin/fsearch"].compactMap { $0 }
        return list.first(where: isExecutable) ?? installedPath
    }

    /// FERRET_SCOPE=<folder> keeps every search inside that folder, for recording demos without
    /// showing anything else on the disk. Requests are scoped and replies are filtered again.
    public static let scope: String? = ProcessInfo.processInfo.environment["FERRET_SCOPE"].map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardized.path
    }

    static func scoped(_ request: [String: Any]) -> [String: Any] {
        guard let scope else { return request }
        var req = request
        if let inside = req["in"] as? String, inside == scope || inside.hasPrefix(scope + "/") { return req }
        req["in"] = scope
        return req
    }

    static func inScope(_ path: String) -> Bool {
        guard let scope else { return true }
        return path == scope || path.hasPrefix(scope + "/")
    }

    private let queue = DispatchQueue(label: "fsearch.client")
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextID = 0

    public init() {}
    deinit { if fd >= 0 { close(fd) } }

    // MARK: Ops

    public func search(_ q: String, limit: Int = 50, extra: [String: Any] = [:]) async throws -> [Hit] {
        var req: [String: Any] = ["q": q, "limit": limit]
        req.merge(extra) { _, new in new }
        let reply: SearchReply = try await send(Self.scoped(req))
        try check(reply.ok, reply.error)
        return (reply.hits ?? []).filter { Self.inScope($0.path) }
    }

    public func grep(_ pattern: String, mode: String = "literal", limit: Int = 30, extra: [String: Any] = [:]) async throws -> GrepReply {
        var req: [String: Any] = ["op": "grep", "pattern": pattern, "mode": mode, "limit": limit]
        req.merge(extra) { _, new in new }
        var reply: GrepReply = try await send(Self.scoped(req))
        try check(reply.ok, reply.error)
        reply.files = reply.files?.filter { Self.inScope($0.path) }
        return reply
    }

    public func recent(_ q: String = "", limit: Int = 50, extra: [String: Any] = [:]) async throws -> [Hit] {
        var req: [String: Any] = ["op": "recent", "limit": limit]
        if !q.isEmpty { req["q"] = q }
        req.merge(extra) { _, new in new }
        let reply: SearchReply = try await send(Self.scoped(req))
        try check(reply.ok, reply.error)
        return (reply.hits ?? []).filter { Self.inScope($0.path) }
    }

    /// Tells fsearch a file was opened, so `boost` and `recent` learn from it.
    public func opened(_ path: String) async {
        let _: OKReply? = try? await send(["op": "open", "path": path])
    }

    public func git(_ path: String) async throws -> GitReply {
        let reply: GitReply = try await send(["op": "git", "path": path])
        try check(reply.ok, reply.error)
        return reply
    }

    /// Returns the status even when `ok` is false (the first index build reports progress that way).
    public func status() async throws -> Status {
        try await send(["op": "status"])
    }

    public func ping() async -> Bool {
        let reply: OKReply? = try? await send(["op": "ping"])
        return reply?.ok == true
    }

    private func check(_ ok: Bool, _ error: String?) throws {
        if !ok { throw FSearchError.server(error ?? "fsearch request failed") }
    }

    // MARK: Transport

    public func send<T: Decodable>(_ request: [String: Any]) async throws -> T {
        let line = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async {
                do { cont.resume(returning: try self.roundTrip(request)) } catch { cont.resume(throwing: error) }
            }
        }
        do { return try JSONDecoder().decode(T.self, from: line) } catch { throw FSearchError.badReply }
    }

    /// Runs on `queue`. Retries once on a fresh connection, starting the daemon if needed.
    private func roundTrip(_ request: [String: Any]) throws -> Data {
        var req = request
        nextID += 1
        req["id"] = nextID
        var payload = try JSONSerialization.data(withJSONObject: req)
        payload.append(0x0A)
        do {
            try ensureConnected()
            try write(payload)
            return try readLine()
        } catch {
            disconnect()
            try ensureConnected()
            try write(payload)
            return try readLine()
        }
    }

    private func ensureConnected() throws {
        if fd >= 0 { return }
        if connectSocket() { return }
        // `fsearch status` connects the same way the CLI does, which starts the daemon.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.binary)
        p.arguments = ["status"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            throw FSearchError.daemonUnavailable("couldn't run \(Self.binary)")
        }
        p.waitUntilExit()
        for _ in 0..<30 {
            if connectSocket() { return }
            usleep(100_000)
        }
        throw FSearchError.daemonUnavailable("no socket at \(Self.socketPath)")
    }

    private func connectSocket() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { close(s); return false }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        buffer.removeAll()
        return true
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        buffer.removeAll()
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { throw FSearchError.daemonUnavailable("write failed (\(errno))") }
                sent += n
            }
        }
    }

    private func readLine() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw FSearchError.daemonUnavailable("connection closed") }
            buffer.append(chunk, count: n)
        }
    }
}
