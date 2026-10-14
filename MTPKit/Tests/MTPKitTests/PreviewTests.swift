import Foundation
import Testing
@testable import MTPKit

/// Open and Quick Look's fetch into the app's temp store (PREV-02, D-17, D-18), and its wording.
@Suite struct PreviewTests {
    static let chunk: UInt32 = 65_536        // small chunks keep the fake's packetization fast (Pitfall 12)

    private func openedSession(_ fake: sending FakeAndroidResponder = FakeAndroidResponder()) async throws -> DeviceSession {
        let session = DeviceSession(transport: fake)
        _ = try await session.openSession()
        return session
    }

    /// A fresh empty folder; the caller removes it.
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "PreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Sums progress callbacks on the MainActor; `sawFile` is whether the final file existed at the first one.
    @MainActor final class Progress {
        var total: UInt64 = 0
        var sawFile: Bool?
    }

    // MARK: Fetch (PREV-02, D-17)

    @Test func fetchWritesThePhoneBytesAndDate() async throws {
        let session = try await openedSession()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try await Transfer.fetch(5, into: folder, session: session, chunk: Self.chunk) { _ in }

        #expect(url == folder.appending(component: "IMG_2.jpg"))
        #expect(try Data(contentsOf: url) == Data(FakeAndroidResponder.content(handle: 5, offset: 0, count: 2_345_678)))
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(modified == parsePTPDate("20260312T184005"))
        #expect(try names(in: folder) == ["IMG_2.jpg"])
    }

    /// Quick Look shows an icon for the absent URL until the copy lands (RESEARCH S5b).
    @Test func theFileIsAbsentUntilItIsComplete() async throws {
        let session = try await openedSession()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appending(component: "IMG_2.jpg")
        let progress = Progress()
        _ = try await Transfer.fetch(5, into: folder, session: session, chunk: Self.chunk) { n in
            if progress.sawFile == nil { progress.sawFile = FileManager.default.fileExists(atPath: target.path) }
            progress.total += n
        }

        #expect(await progress.sawFile == false)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func aStoppedFetchLeavesNothing() async throws {
        let session = try await openedSession()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let progress = Progress()
        let task = Task {
            try await Transfer.fetch(5, into: folder, session: session, chunk: Self.chunk) { n in
                progress.total += n
                // The progress closure is awaited inside the fetch's task, so this stops that task.
                if progress.total >= 65_536 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try names(in: folder).isEmpty)                      // no file, no .aft-download
    }

    /// Phone names are untrusted (RESEARCH V5, T-05-11): refused before any Mac path is built.
    @Test func anUnsafeNameIsRefused() async throws {
        let evil = FakeObject(handle: 100, storageID: 0x0001_0001, parent: 0xFFFF_FFFF, name: "../evil.txt",
                              format: 0x3000, size: 10, modified: "20260101T000000")
        let session = try await openedSession(FakeAndroidResponder(objects: [evil]))
        let outer = try tempFolder()
        defer { try? FileManager.default.removeItem(at: outer) }
        let folder = outer.appending(component: "dest")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        do {
            _ = try await Transfer.fetch(100, into: folder, session: session, chunk: Self.chunk) { _ in }
            Issue.record("an unsafe name was fetched")
        } catch {
            #expect(TransferEnd(error) == .failed("The name can’t be used on this Mac."))
        }
        #expect(try names(in: folder).isEmpty)
        #expect(try names(in: outer) == ["dest"])
    }

    @Test func aGoneItemIsItemGone() async throws {
        let session = try await openedSession()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            _ = try await Transfer.fetch(9999, into: folder, session: session, chunk: Self.chunk) { _ in }
            Issue.record("a gone item was fetched")
        } catch {
            #expect(TransferEnd(error) == .failed(TransferText.itemGone))
        }
        await #expect(throws: (any Error).self) {
            _ = try await Transfer.fetch(1, into: folder, session: session, chunk: Self.chunk) { _ in }   // DCIM
        }
        #expect(try names(in: folder).isEmpty)
    }

    @Test func progressSumsToTheSize() async throws {
        let session = try await openedSession()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let progress = Progress()
        _ = try await Transfer.fetch(5, into: folder, session: session, chunk: Self.chunk) { progress.total += $0 }

        #expect(await progress.total == 2_345_678)
    }

    @Test func macFreeSpaceReadsTheTempVolume() {
        #expect(Transfer.macFreeSpace(at: FileManager.default.temporaryDirectory) > 0)
    }

    // MARK: Wording (D-16, D-19)

    @Test func previewWording() {
        #expect(PreviewText.question(names: ["VID.mp4"], size: 3_200_000_000)
                == "“VID.mp4” is \(EntryFormat.bytes(3_200_000_000)) and takes about 1 minute to get from the phone.")
        let three = PreviewText.question(names: ["a", "b", "c"], size: 3_200_000_000)
        #expect(three.hasPrefix("The 3 items are"))
        #expect(three.contains("take about"))

        #expect(PreviewText.duration(bytes: 1_200_000_000) == "less than a minute")
        #expect(PreviewText.duration(bytes: 3_200_000_000) == "about 1 minute")
        #expect(PreviewText.duration(bytes: 10_000_000_000) == "about 4 minutes")
        #expect(PreviewText.duration(bytes: 200_000_000_000) == "about 1 hour")

        #expect(PreviewText.fetching("IMG.jpg", percent: 45) == "Getting “IMG.jpg” from the phone… 45%")
        #expect(PreviewText.opening("VID.mp4", percent: 45) == "Opening “VID.mp4”… 45%")
        #expect(PreviewText.failed("X", detail: "d") == AlertText(message: "“X” couldn’t be opened.", detail: "d"))
        #expect(PreviewText.bigFile == 1_000_000_000)
    }

    // MARK: Temp copies (D-18, D-20, PREV-03)

    private func permissions(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    /// A document app can't save into the copy or beside it (D-18, RESEARCH S7).
    @Test func aReadOnlyCopyCannotBeWrittenOrJoined() throws {
        let root = try tempFolder()
        defer { PreviewFiles.removeAll(at: root) }      // a plain removeItem fails on a 0555 folder
        let folder = root.appending(component: "a")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appending(component: "note.txt")
        try Data("hi".utf8).write(to: file)

        try PreviewFiles.makeReadOnly(file)

        #expect(try permissions(file) == 0o444)
        #expect(try permissions(folder) == 0o555)
        #expect(throws: (any Error).self) { try FileHandle(forWritingTo: file) }
        #expect(!FileManager.default.createFile(atPath: folder.appending(component: "sibling").path, contents: nil))
    }

    @Test func removeAllDeletesAReadOnlyTree() throws {
        let outer = try tempFolder()
        defer { PreviewFiles.removeAll(at: outer) }
        let root = outer.appending(component: "root")
        let a = root.appending(component: "a"), b = a.appending(component: "b")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let file = b.appending(component: "file")
        try Data("x".utf8).write(to: file)
        try PreviewFiles.makeReadOnly(file)                                                   // file 0444, b 0555
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: a.path)

        PreviewFiles.removeAll(at: root)

        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: outer.path))
        #expect(try names(in: outer).isEmpty)
    }

    /// T-05-15: a link inside the tree is deleted, never followed; what it points at keeps its file and permissions.
    @Test func removeAllNeverFollowsALinkOut() throws {
        let outer = try tempFolder()
        defer { PreviewFiles.removeAll(at: outer) }
        let outside = outer.appending(component: "outside"), root = outer.appending(component: "root")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let kept = outside.appending(component: "kept")
        try Data("x".utf8).write(to: kept)
        try PreviewFiles.makeReadOnly(kept)                                                   // outside is 0555
        try FileManager.default.createSymbolicLink(at: root.appending(component: "link"), withDestinationURL: outside)

        PreviewFiles.removeAll(at: root)

        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(try permissions(outside) == 0o555)
    }

    @Test func removeAllOfAMissingFolderIsFine() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "PreviewTests-\(UUID().uuidString)")
        PreviewFiles.removeAll(at: missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    /// A crash's leftovers go at the next launch, never another running instance's (D-20).
    @Test func staleLaunchFoldersSkipsTheLiveOnes() throws {
        let parent = try tempFolder()
        defer { PreviewFiles.removeAll(at: parent) }
        for name in ["123", "456", "notes"] {
            try FileManager.default.createDirectory(at: parent.appending(component: name), withIntermediateDirectories: false)
        }

        let stale = PreviewFiles.staleLaunchFolders(in: parent, isAlive: { $0 == 123 })

        #expect(stale.map(\.lastPathComponent).sorted() == ["456", "notes"])
        #expect(stale.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL })
    }
}
