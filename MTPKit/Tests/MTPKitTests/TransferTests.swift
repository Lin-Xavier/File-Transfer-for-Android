import Foundation
import Testing
@testable import MTPKit

extension TransferOutcome {
    /// The outcome without its record of what finished (`settled`, `folders`), for tests about what went wrong.
    var problems: TransferOutcome {
        var o = self
        o.settled = []
        o.folders = [:]
        return o
    }
}

@Suite struct TransferTests {
    static let phone = UInt32(0x0001_0001)   // internal storage
    static let root = UInt32(0xFFFF_FFFF)
    static let chunk: UInt32 = 65_536        // small chunks keep the fake's packetization fast (Pitfall 12)
    static let badName = "The name can’t be used on this Mac."

    private func openedSession(_ fake: sending FakeAndroidResponder = FakeAndroidResponder()) async throws -> DeviceSession {
        let session = DeviceSession(transport: fake)
        _ = try await session.openSession()
        return session
    }

    /// A fresh empty folder; the caller removes it.
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "TransferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func entries(_ handles: [UInt32], on session: DeviceSession, parent: UInt32 = 0xFFFF_FFFF) async throws -> [ObjectEntry] {
        try await session.entries(handles, parent: parent)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func modified(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func fakeBytes(_ handle: UInt32, _ count: Int) -> Data {
        Data(FakeAndroidResponder.content(handle: handle, offset: 0, count: count))
    }

    /// Plans and runs `handles` (listed under `parent`) into `dest`.
    private func download(_ handles: [UInt32], parent: UInt32 = 0xFFFF_FFFF, on session: DeviceSession,
                          into dest: URL) async throws -> (TransferPlan, TransferOutcome, UInt64) {
        let plan = try await Transfer.planDownload(try await entries(handles, on: session, parent: parent),
                                                   into: dest, session: session)
        let progress = Progress()
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { progress.total += $0 }
        return (plan, outcome, await progress.total)
    }

    /// Sums progress callbacks on the MainActor.
    @MainActor final class Progress {
        var total: UInt64 = 0
    }

    @Test func downloadsOneFileByteIdenticalWithThePhoneDate() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let items = try await entries([5], on: session)
        let plan = try await Transfer.planDownload(items, into: dest, session: session)
        #expect(plan.totalBytes == 2_345_678)
        let progress = Progress()
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { progress.total += $0 }

        #expect(outcome.problems == TransferOutcome())
        #expect(outcome.unfinished == nil)                          // it ran to the end
        let file = dest.appending(component: "IMG_2.jpg")
        let data = try Data(contentsOf: file)
        #expect(data == Data(FakeAndroidResponder.content(handle: 5, offset: 0, count: 2_345_678)))
        #expect(try modified(file) == parsePTPDate("20260312T184005"))
        #expect(await progress.total == 2_345_678)
        #expect(try names(in: dest) == ["IMG_2.jpg"])
        #expect(try !names(in: dest).contains { $0.hasSuffix(".aft-download") })
    }

    // MARK: Folders (XFER-03, D-15, D-21)

    @Test func folderCopiesRecursivelyWithBothDates() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let (plan, outcome, _) = try await download([1], on: session, into: dest)

        #expect(plan.totalBytes == 1_234 && plan.fileCount == 1)
        #expect(outcome.problems == TransferOutcome())
        let dcim = dest.appending(component: "DCIM"), inside = dcim.appending(component: "inside.jpg")
        #expect(try Data(contentsOf: inside) == fakeBytes(9, 1_234))
        #expect(try modified(inside) == parsePTPDate("20260314T120000"))
        #expect(try modified(dcim) == parsePTPDate("20260301T090000"))
        #expect(try names(in: dest) == ["DCIM"])
    }

    @Test func nestedSelectionLandsDirectlyInTheDestination() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let (_, outcome, _) = try await download([9], parent: 1, on: session, into: dest)

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["inside.jpg"])
    }

    // MARK: Clashes are asked, never overwritten (D-01, D-06, D-08, T-04-02)

    @Test func existingFileIsAClashAndNothingIsRead() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let existing = dest.appending(component: "IMG_2.jpg")
        try Data("keep".utf8).write(to: existing)
        let (plan, outcome, bytes) = try await download([5], on: session, into: dest)

        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
        #expect(plan.clashes.map(\.id) == [ItemKey(top: 0)])
        #expect(outcome.problems == TransferOutcome())                  // unanswered: nothing planned, nothing reported
        #expect(plan.steps.isEmpty && plan.totalBytes == 0)   // no file step, so no GetPartialObject64
        #expect(bytes == 0)
        #expect(fake.opCounts[0x95C1] == nil)
    }

    @Test func caseVariantNameIsAClashOnACaseInsensitiveVolume() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let values = try dest.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard values.volumeSupportsCaseSensitiveNames == false else { try Test.cancel("needs a case-insensitive volume") }
        try Data("keep".utf8).write(to: dest.appending(component: "img_2.JPG"))
        let (plan, _, bytes) = try await download([5], on: session, into: dest)

        #expect(plan.clashes.map(\.existing.name) == ["img_2.JPG"])   // the stored name, as the sheet shows it
        #expect(plan.clashes.map(\.incoming.name) == ["IMG_2.jpg"])
        #expect(try names(in: dest) == ["img_2.JPG"])
        #expect(bytes == 0)
    }

    @Test func existingFolderIsMergedAndItsClashingFileIsAsked() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let dcim = dest.appending(component: "DCIM"), inside = dcim.appending(component: "inside.jpg")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: inside)
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dcim.path)
        let (plan, outcome, _) = try await download([1], on: session, into: dest)

        #expect(plan.clashes.map(\.id) == [ItemKey(top: 0, path: ["inside.jpg"])])   // the folder itself merges (D-06)
        #expect(try Data(contentsOf: inside) == Data("keep".utf8))
        #expect(outcome.failed.isEmpty)
        #expect(try modified(dcim) == date)
    }

    @Test func leftoverTempsAreSweptWhenTheRunStarts() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let dcim = try macFolder("DCIM", in: dest)
        for folder in [dest, dcim] { try macFile(".\(UUID().uuidString).aft-download", 100, in: folder) }
        try macFile(".notes.aft-download", 10, in: dest)              // not a name `download` makes: kept
        let plan = try await Transfer.planDownload(try await entries([1], on: session), into: dest, session: session)
        // Planning alone sweeps nothing: another job may be writing into these folders while this one scans (Pitfall 6).
        #expect(try names(in: dest).count == 3 && names(in: dcim).count == 1)
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == [".notes.aft-download", "DCIM"])
        #expect(try names(in: dcim) == ["inside.jpg"])
    }

    @Test func symlinkAtAFolderNameIsATypeClashAndNotWrittenThrough() async throws {
        let session = try await openedSession()
        let dest = try tempFolder(), target = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: dest.appending(component: "DCIM"), withDestinationURL: target)
        let (plan, _, _) = try await download([1], on: session, into: dest)

        #expect(plan.clashes.count == 1)
        let clash = try #require(plan.clashes.first)
        #expect(clash.allowsReplace == false)
        #expect(clash.existing.name == "DCIM" && !clash.existing.isFolder)   // the link itself, never its target
        #expect(try names(in: target) == [])
    }

    // MARK: Hostile names (T-03-01)

    @Test func hostileNamesFailAndCreateNothing() async throws {
        let hostile = ["../evil.txt", "a/b", "..", ".", "", "x\u{0}y"]
        var objects = hostile.enumerated().map { i, name in
            FakeObject(handle: UInt32(100 + i), storageID: Self.phone, parent: Self.root, name: name,
                       format: name == ".." ? 0x3001 : 0x3000, size: 10, modified: "20260101T000000")
        }
        objects.append(FakeObject(handle: 200, storageID: Self.phone, parent: 102, name: "deep.txt",
                                  format: 0x3000, size: 10, modified: "20260101T000000"))   // inside ".."
        let session = try await openedSession(FakeAndroidResponder(objects: objects))
        let outer = try tempFolder()
        defer { try? FileManager.default.removeItem(at: outer) }
        let dest = outer.appending(component: "dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        let items = try await session.children(storage: Self.phone)
        #expect(items.map(\.name) == hostile)
        let plan = try await Transfer.planDownload(items, into: dest, session: session)
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }

        #expect(outcome.failed.map(\.name) == hostile && outcome.failed.allSatisfy { $0.detail == Self.badName })
        #expect(try names(in: dest) == [])
        #expect(try names(in: outer) == ["dest"])
    }

    /// CONTEXT discretion: a name the other side can't hold fails the same way every time, so Retry isn't offered for
    /// it; each failure names its own item.
    @Test func hostileNamesAreNotRetryable() async throws {
        let hostile = ["../evil.txt", "a/b", "", "x\u{0}y"]
        let objects = hostile.enumerated().map { i, name in
            FakeObject(handle: UInt32(100 + i), storageID: Self.phone, parent: Self.root, name: name, format: 0x3000,
                       size: 10, modified: "20260101T000000")
        }
        let session = try await openedSession(FakeAndroidResponder(objects: objects))
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let plan = try await Transfer.planDownload(try await session.children(storage: Self.phone), into: dest,
                                                   session: session)

        #expect(plan.failed == hostile.indices.map {
            TransferFailure(name: hostile[$0], detail: Self.badName, key: ItemKey(top: $0), retryable: false)
        })
        let long = String(repeating: "a", count: 251) + ".txt"                  // 255 UTF-16 units: too long for the phone
        let upload = try await Transfer.planUpload([try macFile(long, 10, in: dest)], storage: Self.phone,
                                                   parent: Self.root, session: session)
        #expect(upload.failed == [TransferFailure(name: long, detail: "The name is too long for the phone.",
                                                  key: ItemKey(top: 0), retryable: false)])
    }

    @Test func aFolderListedInsideItselfFailsInsteadOfRecursing() async throws {
        // Handle 50 is at the root, and the phone also lists it as its own child.
        let loop = FakeObject(handle: 50, storageID: Self.phone, parent: Self.root, name: "Loop", format: 0x3001, size: 0,
                              modified: "20260101T000000")
        var inner = loop
        inner.parent = 50
        let session = try await openedSession(FakeAndroidResponder(objects: [loop, inner]))
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let (plan, outcome, _) = try await download([50], on: session, into: dest)

        #expect(plan.failed == [TransferFailure(name: "Loop", detail: "The phone listed this folder inside itself.",
                                                key: ItemKey(top: 0, path: ["Loop"]), retryable: false)])
        #expect(outcome.failed == plan.failed)
        #expect(try names(in: dest) == ["Loop"])
    }

    @Test func safeNames() {
        for name in ["", ".", "..", "a/b", "../x", "x\u{0}y", "/"] { #expect(!Transfer.isSafeName(name), "\(name)") }
        for name in ["a.jpg", "a:b.txt", "...", ".hidden", "日本.txt"] { #expect(Transfer.isSafeName(name), "\(name)") }
    }

    // MARK: Failures, losses and stops (D-06, D-07, D-08, D-10)

    @Test func shortReadFailsOnlyThatFile() async throws {
        let session = try await openedSession(FakeAndroidResponder(shortReadHandles: [5]))
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let (_, outcome, _) = try await download([5, 6], on: session, into: dest)

        #expect(outcome.failed == [TransferFailure(name: "IMG_2.jpg", detail: "The phone sent less data than expected.",
                                                   key: ItemKey(top: 0))])
        #expect(outcome.settled == [ItemKey(top: 1)])
        #expect(outcome.lost == nil)
        #expect(try names(in: dest) == ["IMG_10.jpg"])
        #expect(try Data(contentsOf: dest.appending(component: "IMG_10.jpg")) == fakeBytes(6, 3_456_789))
    }

    @Test func lostSessionEndsTheRunAndListsTheItemInProgress() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let plan = try await Transfer.planDownload(try await entries([5, 6], on: session), into: dest, session: session)
        await session.close()
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }

        #expect(outcome.lost == .deviceGone)
        #expect(outcome.failed == [TransferFailure(name: "IMG_2.jpg", detail: MTPError.deviceGone.detail, key: ItemKey(top: 0))])
        #expect(outcome.unreached == [TransferFailure(name: "IMG_10.jpg", detail: MTPError.deviceGone.detail, key: ItemKey(top: 1))])
        #expect(outcome.cancelled == false)
        #expect(outcome.unfinished == ItemKey(top: 0))
        #expect(try names(in: dest) == [])
    }

    @Test func stopDuringPlanningThrowsCancellationAndLeavesTheSessionAlone() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let items = try await entries([1], on: session)
        let task = Task { () async throws -> TransferPlan in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Transfer.planDownload(items, into: dest, session: session)
        }
        switch await task.result {
        case .success: Issue.record("planning finished despite the stop")
        case let .failure(error):
            #expect(error is CancellationError)
            #expect(TransferEnd(error) == .stopped)
        }
        #expect(try names(in: dest) == [])
        #expect(try await !session.storages().isEmpty)
    }

    @Test func errorsAreClassified() {
        #expect(TransferEnd(CancellationError()) == .stopped)
        #expect(TransferEnd(MTPError.response(code: 0x2009, op: 0x95C1)) == .failed("MTP error 0x2009 (Invalid Object Handle)"))
        for lost: MTPError in [.io(operation: "Bulk read", code: 0xE000_02D6), .malformed("x"), .deviceGone] {
            #expect(TransferEnd(lost) == .lost(lost))
        }
        #expect(TransferEnd(TransferItemError(detail: "d")) == .failed("d"))
        let cocoa = CocoaError(.fileReadCorruptFile)       // an unmapped Mac error keeps its own text (O-06)
        #expect(TransferEnd(cocoa) == .failed(cocoa.localizedDescription))
    }

    @Test func vanishedFileFailsAndTheRestCopies() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let plan = try await Transfer.planDownload(try await entries([5, 6], on: session), into: dest, session: session)
        try await session.delete(5)
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }

        #expect(outcome.failed == [TransferFailure(name: "IMG_2.jpg", detail: "MTP error 0x2009 (Invalid Object Handle)",
                                                   key: ItemKey(top: 0))])
        #expect(try names(in: dest) == ["IMG_10.jpg"])
    }

    @Test func planningReadsTheFilesCurrentSizeNotTheListedOne() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        // An upload still growing when the browser listed it: listed at 0 bytes, 100 KB by the time it is copied.
        let handle = try await session.createForEdit(storage: Self.phone, parent: Self.root, name: "growing.bin")
        let stale = try #require(try await session.entry(handle))
        try await session.writePartial(handle, offset: 0, bytes: [UInt8](repeating: 7, count: 100_000))
        try await session.endEdit(handle)
        let gone = try #require(try await session.entry(6))
        try await session.delete(6)
        let plan = try await Transfer.planDownload([stale, gone], into: dest, session: session)
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }

        #expect(stale.size == 0 && plan.totalBytes == 100_000)
        #expect(outcome.failed == [TransferFailure(name: "IMG_10.jpg", detail: "The item is no longer on the phone.",
                                                   key: ItemKey(top: 1), retryable: false)])
        #expect(try Data(contentsOf: dest.appending(component: "growing.bin")) == Data(repeating: 7, count: 100_000))
    }

    /// A top-level folder's date comes from the phone, not the browser's cache: the cached one may have been decoded
    /// before the phone's zone was learned (WR-01).
    @Test func planningReadsATopLevelFoldersCurrentDate() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        var stale = try #require(try await session.entry(1))         // DCIM
        stale.modified = .distantPast
        let plan = try await Transfer.planDownload([stale], into: dest, session: session)

        #expect(plan.steps.first == .folder(dest.appending(component: "DCIM"), parsePTPDate("20260301T090000"),
                                            key: ItemKey(top: 0)))
    }

    @Test func stopBetweenChunksKeepsFinishedFilesAndLeavesNoTemp() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let plan = try await Transfer.planDownload(try await entries([5, 6], on: session), into: dest, session: session)
        let progress = Progress()
        let task = Task {
            await Transfer.run(plan, session: session, chunk: Self.chunk) { n in
                progress.total += n
                // The progress closure is awaited inside the run's task, so this stops that task.
                if progress.total >= 2_345_678 + 65_536 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let outcome = await task.value

        #expect(outcome.cancelled)
        #expect(outcome.failed.isEmpty && outcome.lost == nil)
        #expect(outcome.unfinished == ItemKey(top: 1))
        #expect(outcome.settled == [ItemKey(top: 0)])
        #expect(outcome.unreached == [TransferFailure(name: "IMG_10.jpg", key: ItemKey(top: 1))])   // a stop: no detail
        #expect(try names(in: dest) == ["IMG_2.jpg"])
        #expect(try Data(contentsOf: dest.appending(component: "IMG_2.jpg")) == fakeBytes(5, 2_345_678))
    }

    /// G-05-1-2: a promise receiver grants only the promised path, so a drag out's temps never appear beside it.
    @Test func tempsFolderKeepsTempsOutOfTheDestinationAndEmptiesOnStop() async throws {
        let session = try await openedSession()
        let dest = try tempFolder(), temps = try tempFolder()
        defer { for url in [dest, temps] { try? FileManager.default.removeItem(at: url) } }
        let plan = try await Transfer.planDownload(try await entries([5, 6], on: session), into: dest, session: session)
        let progress = Progress()
        let seen = Progress()                                   // dest listings that held anything but finished files
        let task = Task {
            await Transfer.run(plan, session: session, chunk: Self.chunk, temps: temps) { n in
                progress.total += n
                let inDest = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
                let inTemps = (try? FileManager.default.contentsOfDirectory(atPath: temps.path)) ?? []
                if inDest.contains(where: { $0.hasPrefix(".") }) || inTemps.count != 1 { seen.total += 1 }
                if progress.total >= 2_345_678 + 65_536 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let outcome = await task.value

        #expect(outcome.cancelled && outcome.settled == [ItemKey(top: 0)])
        #expect(await seen.total == 0)
        #expect(try names(in: dest) == ["IMG_2.jpg"])
        #expect(try Data(contentsOf: dest.appending(component: "IMG_2.jpg")) == fakeBytes(5, 2_345_678))
        #expect(try modified(dest.appending(component: "IMG_2.jpg")) == parsePTPDate("20260312T184005"))
        #expect(try names(in: temps).isEmpty)
        #expect(Transfer.sameVolume(temps, URL(filePath: "/nonexistent")))   // unreadable: taken as the same volume
        #expect(!Transfer.sameVolume(URL(filePath: "/nonexistent"), temps))  // no temps folder: the temp goes beside
    }

    @Test func unwritableDestinationFailsEveryFile() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dest.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            try? FileManager.default.removeItem(at: dest)
        }
        let (_, outcome, _) = try await download([5, 6], on: session, into: dest)

        #expect(outcome.failed.map(\.name) == ["IMG_2.jpg", "IMG_10.jpg"])
        #expect(outcome.failed.allSatisfy { !$0.detail.isEmpty })
        #expect(outcome.cancelled == false && outcome.lost == nil)
    }

    // MARK: Volumes without RENAME_EXCL (CR-01)

    /// A rename that fails as exFAT's RENAME_EXCL does.
    private static let noRenameExcl: @Sendable (String, String) -> Int32 = { _, _ in errno = ENOTSUP; return -1 }

    @Test func withoutRenameExclTheTempStillLandsUnderItsName() throws {
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let temp = try macFile(".x.aft-download", 100, in: dest), bytes = try Data(contentsOf: temp)
        let file = dest.appending(component: "IMG_2.jpg")

        #expect(try Transfer.moveExclusive(temp, to: file, renameExcl: Self.noRenameExcl))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try names(in: dest) == ["IMG_2.jpg"])
    }

    @Test func withoutRenameExclAnExistingFileIsNeverReplaced() throws {
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let temp = try macFile(".x.aft-download", 100, in: dest)
        let file = dest.appending(component: "IMG_2.jpg")
        try Data("keep".utf8).write(to: file)

        #expect(try !Transfer.moveExclusive(temp, to: file, renameExcl: Self.noRenameExcl))
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
    }

    /// Runs `body` with a fresh 40 MB disk image of `format` mounted. Needs hdiutil, hence the MTP_DISK_IMAGES gate.
    private func withDiskImage(_ format: String, _ body: (URL) async throws -> Void) async throws {
        let work = try tempFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let image = work.appending(component: "x.dmg"), mount = work.appending(component: "mnt")
        func hdiutil(_ args: String...) throws {
            let p = try Process.run(URL(filePath: "/usr/bin/hdiutil"), arguments: args)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        try hdiutil("create", "-size", "40m", "-fs", format, "-volname", "AFTX", "-quiet", image.path)
        try hdiutil("attach", "-nobrowse", "-quiet", "-mountpoint", mount.path, image.path)
        defer { try? hdiutil("detach", "-quiet", mount.path) }
        try await body(mount)
    }

    /// exFAT, where RENAME_EXCL answers ENOTSUP.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MTP_DISK_IMAGES"] != nil))
    func downloadsToAnExFATVolume() async throws {
        try await withDiskImage("ExFAT") { mount in
            let session = try await openedSession()
            let (_, outcome, _) = try await download([5], on: session, into: mount)

            #expect(outcome.problems == TransferOutcome())
            #expect(try Data(contentsOf: mount.appending(component: "IMG_2.jpg")) == fakeBytes(5, 2_345_678))
        }
    }

    // MARK: Free space on non-APFS volumes

    @Test(arguments: [
        (Int64?.some(500), Int?.some(200), UInt64(500)),   // APFS: purgeable space counts
        (0, 209_354_752, 209_354_752),                      // exFAT: important usage reads 0
        (nil, 7, 7), (9, nil, 9), (nil, nil, .max),         // unknown never refuses
    ] as [(Int64?, Int?, UInt64)])
    func macFreeSpaceTakesTheLargerKnownFigure(important: Int64?, plain: Int?, free: UInt64) {
        #expect(Transfer.macFreeSpace(important: important, plain: plain) == free)
    }

    /// A fresh 40 MB image reports about 40 MB free, not the 0 important usage reads on these formats.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MTP_DISK_IMAGES"] != nil),
          arguments: ["ExFAT", "MS-DOS FAT32"])
    func freeSpaceOnANonAPFSVolumeIsItsRealFreeSize(format: String) async throws {
        try await withDiskImage(format) { mount in
            let session = try await openedSession()
            let free = try await Transfer.availableSpace(for: TransferPlan(destination: .mac(mount)), session: session)

            #expect(free > 30_000_000 && free <= 40 * 1_048_576)
        }
    }

    // MARK: Volume file-size limits (IN-01)

    @Test func theMacsOwnVolumeTakesFilesOver4GiB() throws {
        #expect(Transfer.maxFileSize(in: FileManager.default.temporaryDirectory) > 0xFFFF_FFFF)
    }

    /// FAT32 caps a file at 4 GiB − 1: the 5 GB video fails before any byte is read.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MTP_DISK_IMAGES"] != nil))
    func aFileTooBigForFAT32FailsAtPlanTime() async throws {
        try await withDiskImage("MS-DOS FAT32") { mount in
            #expect(Transfer.maxFileSize(in: mount) == 0xFFFF_FFFF)
            let session = try await openedSession()
            let plan = try await Transfer.planDownload(try await entries([8, 5], on: session), into: mount, session: session)

            #expect(plan.failed == [TransferFailure(name: "big-video.mp4", detail: "The file is too large for the volume’s format.",
                                                    key: ItemKey(top: 0), retryable: false)])
            #expect(plan.fileCount == 1 && plan.totalBytes == 2_345_678)
        }
    }

    // MARK: Over 4 GiB (XFER-04)

    @Test(arguments: [4_294_967_295, 4_294_967_296, 4_294_967_297, 8_589_934_592] as [UInt64])
    func chunksCoverTheSizeExactly(size: UInt64) {
        let chunk: UInt32 = 8 << 20
        let pieces = Transfer.chunks(size: size, chunk: chunk)
        #expect(pieces.reduce(0) { $0 + UInt64($1.length) } == size)
        #expect(pieces.allSatisfy { (1...chunk).contains($0.length) })
        #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.offset + UInt64($0.length) == $1.offset })
        #expect(pieces.first?.offset == 0)
        #expect(pieces.last.map { $0.offset + UInt64($0.length) } == size)
    }

    @Test func emptyFileHasNoChunks() {
        #expect(Transfer.chunks(size: 0, chunk: 8 << 20).isEmpty)
    }

    @Test func readPartialSendsTheHighOffsetWord() async throws {
        let session = try await openedSession()
        let bytes = try await session.readPartial(8, offset: 0xFFFF_FFF0, length: 64)
        #expect(bytes == FakeAndroidResponder.content(handle: 8, offset: 0xFFFF_FFF0, count: 64))
    }

    // MARK: Upload (XFER-02, XFER-04)

    /// A Mac file of `count` bytes in `folder`, filled with a pattern that differs by name.
    @discardableResult
    private func macFile(_ name: String, _ count: Int, in folder: URL) throws -> URL {
        let url = folder.appending(component: name)
        let seed = UInt8(truncatingIfNeeded: name.hashValue)
        try Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed }).write(to: url)
        return url
    }

    /// Plans and runs an upload of `urls` into `parent`.
    private func upload(_ urls: [URL], parent: UInt32 = 0xFFFF_FFFF, on session: DeviceSession,
                        progress: @escaping @MainActor @Sendable (UInt64) -> Void = { _ in })
        async throws -> (TransferPlan, TransferOutcome) {
        let plan = try await Transfer.planUpload(urls, storage: Self.phone, parent: parent, session: session)
        return (plan, await Transfer.run(plan, session: session, chunk: Self.chunk, progress: progress))
    }

    @Test func uploadsSmallAndBigFilesByteIdentical() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let small = try macFile("small.bin", 500, in: src), big = try macFile("big.bin", 200 * 1024 + 3, in: src)
        let progress = Progress()
        let (plan, outcome) = try await upload([small, big], on: session) { progress.total += $0 }

        #expect(plan.totalBytes == 500 + 200 * 1024 + 3 && plan.fileCount == 2)
        let listed = try await session.children(storage: Self.phone)
        let made = Set(listed.filter { ["small.bin", "big.bin"].contains($0.name) }.map(\.id))
        #expect(made.count == 2)
        #expect(outcome == TransferOutcome(settled: [ItemKey(top: 0), ItemKey(top: 1)],
                                           touched: [FolderKey(storage: Self.phone, folder: Self.root)], created: made))
        #expect(await progress.total == plan.totalBytes)
        for url in [small, big] {
            let source = try Data(contentsOf: url)
            let entry = try #require(listed.first { $0.name == url.lastPathComponent })
            #expect(entry.size == UInt64(source.count))
            #expect(try await Data(session.readPartial(entry.id, offset: 0, length: UInt32(source.count))) == source)
        }
        #expect(fake.opCounts[0x95C4] == 1 && fake.opCounts[0x95C5] == 1)
        #expect(fake.opCounts[0x100D] == 2)
        #expect(fake.opCounts[0x95C2] == 4)       // 200 KiB + 3 in 64 KiB chunks
    }

    /// O-06e, O-06d: a source that can't be opened when its turn comes reads as a source problem. Foundation reports an
    /// unreadable file as a write-permission error (513), which would show the download's O-06a (06-08).
    @Test func unreadableOrVanishedUploadSourceReadsAsSourceReason() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let locked = try macFile("locked.txt", 5, in: src), gone = try macFile("gone.txt", 5, in: src)
        let plan = try await Transfer.planUpload([locked, gone], storage: Self.phone, parent: Self.root, session: session)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        try FileManager.default.removeItem(at: gone)
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }
        #expect(outcome.failed.map(\.detail) == [TransferText.sourceUnreadable, TransferText.sourceGone])
        #expect(TransferText.sourceUnreadable == "You don’t have permission to read this item.")
    }

    /// A Mac folder `name` in `parent`.
    @discardableResult
    private func macFolder(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appending(component: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// The phone object called `name` in `parent`.
    private func phoneItem(_ name: String, in parent: UInt32 = 0xFFFF_FFFF, on session: DeviceSession) async throws -> ObjectEntry? {
        try await session.children(storage: Self.phone, parent: parent).first { $0.name == name }
    }

    // MARK: Upload folders and edges (XFER-03, D-12, D-13, D-14, T-03-07)

    @Test func folderTreeUploadsWithItsStructureFoldersFirst() async throws {
        let session = try await openedSession()
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let album = try macFolder("Album", in: src)
        try macFile("a.jpg", 700, in: album)
        try macFile("b.jpg", 70_000, in: try macFolder("sub", in: album))
        let (plan, outcome) = try await upload([album], on: session)

        #expect(plan.totalBytes == 70_700 && plan.fileCount == 2)
        #expect(outcome.failed.isEmpty && !outcome.cancelled && outcome.lost == nil)
        let phoneAlbum = try #require(try await phoneItem("Album", on: session))
        #expect(phoneAlbum.isFolder)
        let inAlbum = try await session.children(storage: Self.phone, parent: phoneAlbum.id)
        #expect(inAlbum.map(\.name).sorted() == ["a.jpg", "sub"])
        let a = try #require(inAlbum.first { $0.name == "a.jpg" }), sub = try #require(inAlbum.first { $0.name == "sub" })
        #expect(a.size == 700 && sub.isFolder)
        let b = try #require(try await phoneItem("b.jpg", in: sub.id, on: session))
        #expect(b.size == 70_000)
        #expect(try await Data(session.readPartial(b.id, offset: 0, length: 70_000))
                == Data(contentsOf: album.appending(path: "sub/b.jpg")))
        #expect(phoneAlbum.id < a.id && phoneAlbum.id < sub.id && sub.id < b.id)
    }

    @Test func macMetadataIsDroppedSilentlyAndOtherDotfilesUpload() async throws {
        let session = try await openedSession()
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let meta = try macFolder("Meta", in: src)
        for name in [".DS_Store", "._a.jpg", ".localized", "Icon\r", ".nomedia", "keep.jpg"] { try macFile(name, 10, in: meta) }
        for name in [".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100"] {
            try macFile("inside.bin", 10, in: try macFolder(name, in: meta))
        }
        let (plan, outcome) = try await upload([meta], on: session)

        #expect(plan.fileCount == 2)
        #expect(outcome.failed.isEmpty)
        let phoneMeta = try #require(try await phoneItem("Meta", on: session))
        #expect(try await session.children(storage: Self.phone, parent: phoneMeta.id).map(\.name).sorted()
                == [".nomedia", "keep.jpg"])
    }

    @Test func symlinksAreListedAndNeverFollowed() async throws {
        let session = try await openedSession()
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let linked = try macFolder("Linked", in: src)
        let real = try macFile("real.txt", 20, in: linked)
        try FileManager.default.createSymbolicLink(at: linked.appending(component: "file-link"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: linked.appending(component: "loop"), withDestinationURL: linked)
        let (_, outcome) = try await upload([linked], on: session)

        #expect(outcome.failed == ["file-link", "loop"].map {
            TransferFailure(name: $0, detail: TransferText.linkNotCopied, key: ItemKey(top: 0, path: [$0]), retryable: false)
        })
        #expect(!outcome.cancelled && outcome.lost == nil)
        let phoneLinked = try #require(try await phoneItem("Linked", on: session))
        #expect(try await session.children(storage: Self.phone, parent: phoneLinked.id).map(\.name) == ["real.txt"])
    }

    @Test func packageUploadsAsPlainFolders() async throws {
        let session = try await openedSession()
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let app = try macFolder("Thing.app", in: src)
        try macFile("x.txt", 33, in: try macFolder("Contents", in: app))
        let (_, outcome) = try await upload([app], on: session)

        #expect(outcome.failed.isEmpty)
        let thing = try #require(try await phoneItem("Thing.app", on: session))
        let contents = try #require(try await phoneItem("Contents", in: thing.id, on: session))
        #expect(thing.isFolder && contents.isFolder)
        #expect(try await phoneItem("x.txt", in: contents.id, on: session)?.size == 33)
    }

    /// D-11: a case variant of a phone name is asked about; the scan sends nothing and touches nothing.
    @Test func caseVariantOfAPhoneFileIsAClashAndNothingIsSent() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let before = try await session.children(storage: Self.phone).count
        let (plan, outcome) = try await upload([try macFile("img_2.JPG", 500, in: src)], on: session)

        #expect(plan.clashes.map(\.id) == [ItemKey(top: 0)])
        #expect(outcome.failed.isEmpty)
        #expect(plan.totalBytes == 0 && plan.fileCount == 0)
        #expect(try await session.entry(5)?.size == 2_345_678)
        #expect(try await session.children(storage: Self.phone).count == before)
        #expect(fake.opCounts[0x100C] == nil)
    }

    /// D-10: two items of one job with one phone name ("a.jpg", "A.jpg") never both take it, or the phone would
    /// truncate the first with the second (Pitfall 5); the later one is kept both, folders with their own contents.
    @Test func twoItemsWithOnePhoneNameAreKeptBoth() async throws {
        let session = try await openedSession()
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let first = try macFile("a.jpg", 500, in: try macFolder("one", in: src))
        let second = try macFile("A.jpg", 700, in: try macFolder("two", in: src))
        let firstFolder = try macFolder("Album", in: try macFolder("three", in: src))
        try macFile("x.jpg", 10, in: firstFolder)
        let secondFolder = try macFolder("album", in: try macFolder("four", in: src))
        try macFile("x.jpg", 20, in: secondFolder)
        let (plan, outcome) = try await upload([first, second, firstFolder, secondFolder], on: session)

        #expect(plan.clashes.isEmpty && outcome.failed.isEmpty)
        #expect(plan.fileCount == 4 && plan.totalBytes == 1_230)
        #expect(try await phoneItem("a.jpg", on: session)?.size == 500)
        #expect(try await phoneItem("A 2.jpg", on: session)?.size == 700)
        let album = try #require(try await phoneItem("Album", on: session))
        #expect(try await phoneItem("x.jpg", in: album.id, on: session)?.size == 10)
        let album2 = try #require(try await phoneItem("album 2", on: session))
        #expect(try await phoneItem("x.jpg", in: album2.id, on: session)?.size == 20)
    }

    /// D-06: an existing phone folder is merged into with no question; its clashing file is asked (the scan plans
    /// only the missing one) and the phone's own file is untouched.
    @Test func existingPhoneFolderIsMergedAndItsClashingFileIsAsked() async throws {
        let session = try await openedSession()
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let dcim = try macFolder("DCIM", in: src)
        try macFile("inside.jpg", 50, in: dcim)
        try macFile("new.jpg", 60, in: dcim)
        let (plan, outcome) = try await upload([dcim], on: session)

        #expect(plan.totalBytes == 60 && plan.fileCount == 1)
        #expect(plan.clashes.map(\.id) == [ItemKey(top: 0, path: ["inside.jpg"])])
        #expect(outcome.failed.isEmpty)
        #expect(try await session.children(storage: Self.phone).filter { $0.name == "DCIM" }.count == 1)
        #expect(try await phoneItem("new.jpg", in: 1, on: session)?.size == 60)
        #expect(try await phoneItem("inside.jpg", in: 1, on: session)?.size == 1_234)
        #expect(outcome.touched.contains(FolderKey(storage: Self.phone, folder: 1)))
    }

    @Test func tooLongMacNameFailsBeforeAnythingIsSent() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let name = String(repeating: "a", count: 251) + ".txt"
        #expect(name.utf16.count == 255)
        let (_, outcome) = try await upload([try macFile(name, 10, in: src)], on: session)

        #expect(outcome.failed == [TransferFailure(name: name, detail: "The name is too long for the phone.",
                                                   key: ItemKey(top: 0), retryable: false)])
        #expect(fake.opCounts[0x100C] == nil)
    }

    @Test func stopMidBigUploadDeletesItsPartialObjectAndKeepsFinishedFiles() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let small = try macFile("small.bin", 500, in: src), big = try macFile("big.bin", 300 * 1024, in: src)
        let progress = Progress()
        let task = Task {
            try await upload([small, big], on: session) { n in
                progress.total += n
                if progress.total >= 500 + 65_536 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let (_, outcome) = try await task.value

        #expect(outcome.cancelled && outcome.failed.isEmpty && outcome.lost == nil)
        #expect(outcome.unfinished == ItemKey(top: 1))
        #expect(outcome.settled == [ItemKey(top: 0)] && outcome.unreached.map(\.key) == [ItemKey(top: 1)])
        #expect(fake.opCounts[0x95C5] == 1 && fake.opCounts[0x100B] == 1)    // EndEditObject, then DeleteObject
        #expect(try await phoneItem("big.bin", on: session) == nil)
        #expect(try await phoneItem("small.bin", on: session)?.size == 500)
    }

    @Test func macFileShrinkingFailsThatItemDeletesItsPartialAndTheJobContinues() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let big = try macFile("big.bin", 300 * 1024, in: src), after = try macFile("after.bin", 40, in: src)
        let plan = try await Transfer.planUpload([big, after], storage: Self.phone, parent: Self.root, session: session)
        try FileHandle(forWritingTo: big).truncate(atOffset: 100 * 1024)
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }

        #expect(outcome.failed == [TransferFailure(name: "big.bin", detail: "The file changed while it was being copied.",
                                                   key: ItemKey(top: 0))])
        #expect(outcome.settled == [ItemKey(top: 1)])
        #expect(outcome.lost == nil && !outcome.cancelled)
        #expect(fake.opCounts[0x100B] == 1)
        #expect(try await phoneItem("big.bin", on: session) == nil)
        #expect(try await phoneItem("after.bin", on: session)?.size == 40)
    }

    @Test func macFileGrowingFailsThatItemAndLeavesNothingOnThePhone() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let small = try macFile("small.bin", 500, in: src), big = try macFile("big.bin", 300 * 1024, in: src)
        let plan = try await Transfer.planUpload([small, big], storage: Self.phone, parent: Self.root, session: session)
        for url in [small, big] {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([1, 2, 3]))
            try handle.close()
        }
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }

        let changed = "The file changed while it was being copied."
        #expect(outcome.failed == [TransferFailure(name: "small.bin", detail: changed, key: ItemKey(top: 0)),
                                   TransferFailure(name: "big.bin", detail: changed, key: ItemKey(top: 1))])
        #expect(outcome.settled.isEmpty)
        #expect(fake.opCounts[0x100B] == 1)                 // the big file's partial object, deleted
        #expect(try await phoneItem("small.bin", on: session) == nil)
        #expect(try await phoneItem("big.bin", on: session) == nil)
    }

    @MainActor final class Names {
        var all: [String] = []
    }

    @Test func eachFileIsNamedAsItStarts() async throws {
        let session = try await openedSession()
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let album = try macFolder("Album", in: src)
        try macFile("a.jpg", 10, in: album)
        let plan = try await Transfer.planUpload([album, try macFile("b.jpg", 20, in: src)], storage: Self.phone,
                                                 parent: Self.root, session: session)
        let started = Names()
        _ = await Transfer.run(plan, session: session, chunk: Self.chunk, onFile: { started.all.append($0) }) { _ in }

        #expect(await started.all == ["a.jpg", "b.jpg"])
    }

    @Test func sessionLostMidBigUploadRecordsItsTemp() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(unansweredAfter: [0x95C2: 1])
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let small = try macFile("small.bin", 500, in: src), big = try macFile("big.bin", 300 * 1024, in: src)
        let (_, outcome) = try await upload([small, big], on: session)

        guard case .io = outcome.lost else { Issue.record("expected a read timeout, got \(String(describing: outcome.lost))"); return }
        #expect(outcome.failed.map(\.name) == ["big.bin"])
        #expect(outcome.leftovers.map(\.name) == ["big.bin"])
        #expect(fake.opCounts[0x100D] == 2)
        #expect(outcome.cancelled == false)
    }

    @Test func sessionLostWhileCreatingABigUploadRecordsItsTemp() async throws {
        let session = try await openedSession(FakeAndroidResponder(unansweredAfter: [0x95C4: 0]))   // BeginEditObject
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let (_, outcome) = try await upload([try macFile("big.bin", 300 * 1024, in: src)], on: session)

        guard case .io = outcome.lost else { Issue.record("expected a read timeout, got \(String(describing: outcome.lost))"); return }
        #expect(outcome.failed.map(\.name) == ["big.bin"])
        #expect(outcome.leftovers.map(\.name) == ["big.bin"])
    }

    /// IN-07: an upload that starts on a session already dropped sends nothing, so it records no phantom temp that
    /// would keep its row offering Retry.
    @Test func anUploadOnADroppedSessionRecordsNoTemp() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let small = try macFile("small.bin", 500, in: src), big = try macFile("big.bin", 300 * 1024, in: src)
        let plan = try await Transfer.planUpload([small, big], storage: Self.phone, parent: Self.root, session: session)
        await session.close()
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }

        #expect(outcome.lost == .deviceGone && outcome.failed.map(\.name) == ["small.bin"])
        #expect(outcome.leftovers.isEmpty && fake.opCounts[MTPOp.sendObjectInfo] == nil)
    }

    @Test func writePartialCarriesTheHighOffsetWord() async throws {
        let session = try await openedSession()
        let handle = try await session.createForEdit(storage: Self.phone, parent: Self.root, name: "edit.bin")
        do {
            // The low half is 0: only a dropped high parameter would make this an accepted write at offset 0.
            try await session.writePartial(handle, offset: 1 << 32, bytes: [1])
            Issue.record("a write past the object's end was accepted")
        } catch let MTPError.response(code, _) {
            #expect(code == 0x2002)
        }
        try await session.endEdit(handle)
    }

    // MARK: Wording

    @Test(arguments: [
        (nil, "Estimating time remaining…"), (.nan, "Estimating time remaining…"),
        (.infinity, "Estimating time remaining…"), (-1, "Estimating time remaining…"),
        (0, "Less than 5 seconds remaining"), (4.9, "Less than 5 seconds remaining"),
        (5, "Less than 15 seconds remaining"), (14.9, "Less than 15 seconds remaining"),
        (15, "Less than 30 seconds remaining"), (29.9, "Less than 30 seconds remaining"),
        (30, "About 1 minute remaining"), (89.9, "About 1 minute remaining"),
        (90, "About 2 minutes remaining"), (150, "About 3 minutes remaining"),
        (3569, "About 59 minutes remaining"), (3570, "About 1 hour remaining"),
        (5399, "About 1 hour remaining"), (5400, "About 2 hours remaining"),
    ] as [(Double?, String)])
    func remainingBuckets(seconds: Double?, text: String) {
        #expect(TransferText.remaining(seconds) == text)
    }

    @Test(arguments: [
        (0, 0, 0), (0, 100, 0), (99, 100, 99), (999, 1000, 99), (100, 100, 100), (5_000_000_000, 8_589_934_592, 58),
    ] as [(UInt64, UInt64, Int)])
    func percentIsFloored(done: UInt64, total: UInt64, percent: Int) {
        #expect(TransferText.percent(done: done, total: total) == percent)
    }

    @Test func progressLineAndRowLabels() {
        #expect(TransferText.progress(done: 1_200_000_000, total: 4_500_000_000, bytesPerSecond: 40_200_000)
                == "1.2 GB of 4.5 GB (40.2 MB/s) – About 1 minute remaining")
        #expect(TransferText.progress(done: 1_200_000_000, total: 4_500_000_000, bytesPerSecond: nil)
                == "1.2 GB of 4.5 GB – Estimating time remaining…")
        #expect(TransferText.preparing(destination: "Downloads") == "Preparing to copy to “Downloads”")
        #expect(TransferText.waiting == "Waiting…")
        #expect(TransferText.canceling == "Canceling…")
    }

    @Test func rateMeterNeedsTwoSecondsOfSamples() {
        var meter = RateMeter()
        #expect(meter.bytesPerSecond == nil)
        meter.add(done: 0, at: 0)
        meter.add(done: 40_000_000, at: 1)
        #expect(meter.bytesPerSecond == nil)
        meter.add(done: 80_000_000, at: 2)
        #expect(meter.bytesPerSecond == 40_000_000)
    }

    @Test func rateMeterOnlyCountsTheLastFiveSeconds() {
        var meter = RateMeter()
        for t in 0...3 { meter.add(done: UInt64(t) * 100_000_000, at: Double(t)) }   // 100 MB/s
        for t in 8...11 { meter.add(done: 400_000_000 + UInt64(t - 8) * 5_000_000, at: Double(t)) }   // then 5 MB/s
        #expect(meter.bytesPerSecond == 5_000_000)
    }

    // MARK: free space (D-04)

    @Test func noSpaceWording() {
        #expect(TransferText.noSpace(names: ["video.mp4"], needed: 5_000_000_000, available: 1_200_000_000) == AlertText(
            message: "“video.mp4” can’t be copied because there isn’t enough free space.",
            detail: "It needs 5 GB, but only 1.2 GB is available."))
        #expect(TransferText.noSpace(names: ["a", "b", "c"], needed: 5_000_000_000, available: 1_200_000_000) == AlertText(
            message: "The 3 items can’t be copied because there isn’t enough free space.",
            detail: "It needs 5 GB, but only 1.2 GB is available."))
    }

    private func phoneWithFree(_ free: UInt64) -> FakeAndroidResponder {
        FakeAndroidResponder(storages: [FakeStorage(id: Self.phone, type: 0x0003, capacity: 1_000_000, free: free,
                                                    description: "Internal shared storage")])
    }

    @Test func uploadThatDoesNotFitTheStorageSendsNothing() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(storages: [
            FakeStorage(id: Self.phone, type: 0x0003, capacity: 1_000_000, free: 1_000, description: "Internal shared storage"),
        ])
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let plan = try await Transfer.planUpload([try macFile("big.bin", 2_000, in: src)], storage: Self.phone,
                                                 parent: Self.root, session: session)
        let available = try await Transfer.availableSpace(for: plan, session: session)

        #expect(plan.totalBytes == 2_000)
        #expect(available == 1_000)
        #expect(plan.totalBytes > available)
        #expect((fake.opCounts[0x100C] ?? 0) == 0)
        #expect((fake.opCounts[0x100D] ?? 0) == 0)
        #expect((fake.opCounts[0x95C2] ?? 0) == 0)
    }

    @Test func uploadThatExactlyFitsIsAllowed() async throws {
        let session = try await openedSession(phoneWithFree(2_000))
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let plan = try await Transfer.planUpload([try macFile("big.bin", 2_000, in: src)], storage: Self.phone,
                                                 parent: Self.root, session: session)
        let available = try await Transfer.availableSpace(for: plan, session: session)
        #expect(available == 2_000)
        #expect(plan.totalBytes <= available)
    }

    @Test func goneStorageHasNoSpace() async throws {
        let session = try await openedSession(phoneWithFree(2_000))
        let plan = TransferPlan(destination: .phone(storage: 0x0009_0001, folder: Self.root))
        #expect(try await Transfer.availableSpace(for: plan, session: session) == 0)
    }

    @Test func macSpaceIsTheVolumesAvailableCapacity() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let plan = try await Transfer.planDownload([], into: dest, session: session)
        let available = try await Transfer.availableSpace(for: plan, session: session)
        let total = try #require(try dest.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity)
        #expect(available > 0)
        #expect(available <= UInt64(total))
    }

    @Test func failedRowWording() {
        #expect(TransferText.failedTitle([TransferFailure(name: "IMG_2.jpg")]) == "“IMG_2.jpg” couldn’t be copied")
        #expect(TransferText.failedTitle((1...3).map { TransferFailure(name: "\($0).jpg") }) == "3 items couldn’t be copied")
        // IN-04: named by the key, as Show does: the source name, not the Keep Both one the run's step carried.
        #expect(TransferText.failedTitle([TransferFailure(name: "IMG 2.jpg", key: ItemKey(top: 1))], names: ["a", "IMG.jpg"])
                == "“IMG.jpg” couldn’t be copied")
        #expect(TransferText.failedTitle([TransferFailure(name: "b 2.jpg", key: ItemKey(top: 0, path: ["sub", "b.jpg"]))],
                                         names: ["Album"]) == "“b.jpg” couldn’t be copied")
        #expect(TransferText.itemPath(ItemKey(top: 1, path: ["sub", "a.jpg"]), names: ["x", "Album"]) == "Album/sub/a.jpg")
        #expect(TransferText.itemPath(ItemKey(top: 0), names: ["IMG_2.jpg"]) == "IMG_2.jpg")
        #expect(TransferText.stoppedBefore == "The copy was stopped before this item.")
    }
}
