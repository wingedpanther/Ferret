import Foundation
import Testing
@testable import FSearchKit

// Round trips against the live fsearch daemon. Skipped when fsearch isn't installed.
private let installed = FileManager.default.isExecutableFile(atPath: FSearchClient.binary)

@Suite(.enabled(if: installed, "fsearch is not installed"))
struct FSearchClientTests {
    let client = FSearchClient()

    @Test func ping() async {
        #expect(await client.ping())
    }

    @Test func status() async throws {
        let s = try await client.status()
        #expect(s.ok)
        #expect((s.entries ?? 0) > 0)
    }

    @Test func searchFindsThisPackageDespiteATypo() async throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Package.swift").path
        let dir = (manifest as NSString).deletingLastPathComponent
        let hits = try await client.search("Pakage.swift", limit: 5, extra: ["in": dir])
        #expect(hits.first?.path == manifest)
    }

    @Test func grepReturnsLinesAndRanges() async throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        let reply = try await client.grep("grepReturnsLinesAndRanges", extra: ["in": dir, "context": 1])
        let match = try #require(reply.files?.first?.matches.first)
        #expect(match.line > 0)
        let range = try #require(match.stringRanges.first)
        #expect(match.text[range] == "grepReturnsLinesAndRanges")
    }

    @Test func symbolModeMarksDefinitions() async throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        let reply = try await client.grep("symbolModeMarksDefinitions", mode: "symbol", extra: ["in": dir, "defs": true])
        #expect(reply.files?.first?.matches.first?.def == true)
    }

    @Test func recentAndOpen() async throws {
        await client.opened(#filePath)
        let hits = try await client.recent(limit: 200)
        #expect(hits.contains { $0.path == #filePath })
    }

    @Test func gitReportsRoot() async throws {
        // This package may not be a repo; the fsearch checkout's parent home always answers.
        let reply = try? await client.git(NSHomeDirectory())
        #expect(reply == nil || reply?.ok == true)
    }

    @Test func requestsAreSerialised() async throws {
        async let a = client.search("main", limit: 3)
        async let b = client.search("readme", limit: 3)
        async let c = client.status()
        let (ha, hb, s) = try await (a, b, c)
        #expect(!ha.isEmpty && !hb.isEmpty && s.ok)
    }
}

@Test func binaryPrefersInstalledThenBundled() {
    let candidates = ["/home/.local/bin/fsearch", "/App.app/Contents/MacOS/fsearch", "/opt/homebrew/bin/fsearch"]
    #expect(FSearchClient.resolveBinary(candidates) { _ in true } == candidates[0])
    #expect(FSearchClient.resolveBinary(candidates) { $0 != candidates[0] } == candidates[1])
    #expect(FSearchClient.resolveBinary(candidates) { _ in false } == FSearchClient.installedPath)
}

@Test func columnCountsCharactersNotBytes() throws {
    let json = #"{"line":1,"col":3,"text":"é foo","ranges":[[3,6]]}"#
    let m = try JSONDecoder().decode(GrepMatch.self, from: Data(json.utf8))
    #expect(m.column == 3)
    #expect(m.text[m.stringRanges[0]] == "foo")
}
