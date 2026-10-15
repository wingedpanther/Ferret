import Foundation
import Testing
@testable import Ferret

@MainActor
@Suite struct QuickEditTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("quickedit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ contents: String, mode: Int = 0o644) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return path
    }

    @Test func savesTextAndKeepsPermissions() throws {
        let path = try file("run.sh", "#!/bin/sh\necho hi\n", mode: 0o755)
        let session = try EditSession(path: path)
        session.textChanged("#!/bin/sh\necho bye\n")
        #expect(session.isDirty)
        #expect(session.save())
        #expect(!session.isDirty)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "#!/bin/sh\necho bye\n")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test func asksBeforeOverwritingAChangeOnDisk() throws {
        let path = try file("a.txt", "one\n")
        let session = try EditSession(path: path)
        // Someone else saves the file after it was opened.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)
        session.textChanged("two\n")
        #expect(!session.save())
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "one\n")
        #expect(session.save())
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "two\n")
    }

    @Test func closingWithChangesNeedsASecondEsc() throws {
        let session = try EditSession(path: try file("b.txt", "x"))
        #expect(session.confirmClose())
        session.textChanged("y")
        #expect(!session.confirmClose())
        #expect(session.confirmClose())
    }

    @Test func refusesFoldersBinariesAndBigFiles() throws {
        #expect(throws: EditSession.OpenError.self) { try EditSession(path: dir.path) }
        let binary = dir.appendingPathComponent("bin").path
        FileManager.default.createFile(atPath: binary, contents: Data([0x7F, 0x45, 0x00, 0x01]))
        #expect(throws: EditSession.OpenError.self) { try EditSession(path: binary) }
        let big = try file("big.txt", String(repeating: "a", count: EditSession.maxBytes + 1))
        #expect(throws: EditSession.OpenError.self) { try EditSession(path: big) }
    }

    @Test func detectsIndentation() {
        #expect(CodeEditor.Coordinator.detectIndent("a\n\tb\n\tc\n") == "\t")
        #expect(CodeEditor.Coordinator.detectIndent("a\n  b\n    c\n  d\n") == "  ")
        #expect(CodeEditor.Coordinator.detectIndent("a\n    b\n        c\n") == "    ")
        #expect(CodeEditor.Coordinator.detectIndent("plain\ntext\n") == "    ")
    }
}
