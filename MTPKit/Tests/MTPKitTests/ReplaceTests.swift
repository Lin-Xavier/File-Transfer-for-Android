import Foundation
import Testing
@testable import MTPKit

/// Replace on the Mac (XFER-08, D-11, D-20): one rename(2) of a complete, dated temp, so the name always holds the
/// complete old file or the complete new one, whatever cuts the copy short and whatever the volume's format.
/// Uploads (XFER-09, D-22): every file goes to a hidden temp on the phone and is renamed into place only once complete.
@Suite struct ReplaceTests {
    static let chunk: UInt32 = 65_536        // small chunks keep the fake's packetization fast (Pitfall 12)
    static let phone = UInt32(0x0001_0001)   // internal storage
    static let root = UInt32(0xFFFF_FFFF)
    static let uuid = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
    static let first = ItemKey(top: 0)
    static let replaceFirst = ClashAnswers(byItem: [first: .replace])

    private func openedSession(_ fake: sending FakeAndroidResponder = FakeAndroidResponder()) async throws -> DeviceSession {
        let session = DeviceSession(transport: fake)
        _ = try await session.openSession()
        return session
    }

    /// A fresh empty folder; the caller removes it.
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ReplaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func entries(_ handles: [UInt32], on session: DeviceSession) async throws -> [ObjectEntry] {
        try await session.entries(handles, parent: 0xFFFF_FFFF)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func fakeBytes(_ handle: UInt32, _ count: Int) -> Data {
        Data(FakeAndroidResponder.content(handle: handle, offset: 0, count: count))
    }

    /// A Mac file holding `text` ("keep": the original a Replace must never lose early).
    @discardableResult
    private func macFile(_ name: String, _ text: String = "keep", in folder: URL) throws -> URL {
        let url = folder.appending(component: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A Mac file of `count` bytes in `folder`, filled with a pattern that differs by name.
    @discardableResult
    private func macFile(_ name: String, _ count: Int, in folder: URL) throws -> URL {
        let url = folder.appending(component: name)
        let seed = UInt8(truncatingIfNeeded: name.hashValue)
        try Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed }).write(to: url)
        return url
    }

    private func macFolder(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appending(component: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Sums progress callbacks on the MainActor.
    @MainActor final class Progress {
        var total: UInt64 = 0
    }

    /// `run`'s `landed` calls, each with the fake's last rename at that moment.
    @MainActor final class Landed {
        var calls: [(handle: UInt32, replaced: UInt32?, lastRename: String?)] = []
    }

    /// Plans and runs an upload of `urls` into `parent`, with the clash `answers` given on the sheet.
    private func upload(_ urls: [URL], parent: UInt32 = 0xFFFF_FFFF, answers: ClashAnswers = ClashAnswers(),
                        on session: DeviceSession,
                        landed: @escaping @MainActor @Sendable (UInt32, UInt32?) -> Void = { _, _ in },
                        progress: @escaping @MainActor @Sendable (UInt64) -> Void = { _ in }) async throws -> TransferOutcome {
        let plan = try await Transfer.planUpload(urls, storage: Self.phone, parent: parent, answers: answers, session: session)
        return await Transfer.run(plan, session: session, chunk: Self.chunk, landed: landed, progress: progress)
    }

    /// Plans `handles` into `dest` as the queue does: the scan (`.ask`) must ask exactly `asked`, then the attempt
    /// plans again with the answers and `.keepBoth`. Returns the attempt's plan, not yet run.
    private func answered(_ handles: [UInt32], into dest: URL, answers: ClashAnswers, asked: [ItemKey] = [first],
                          on session: DeviceSession) async throws -> TransferPlan {
        let items = try await entries(handles, on: session)
        let scan = try await Transfer.planDownload(items, into: dest, session: session)
        #expect(scan.clashes.map(\.id) == asked)
        return try await Transfer.planDownload(items, into: dest, answers: answers, unanswered: .keepBoth, session: session)
    }

    private func run(_ plan: TransferPlan, on session: DeviceSession) async -> TransferOutcome {
        await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }
    }

    // MARK: Case-only, folder and link at the name (D-11, T-04-02, T-04-11)

    /// D-11: "IMG_2.jpg" onto "img_2.JPG" is a clash, and after Replace the Mac file has the incoming name, which
    /// APFS alone wouldn't give (it keeps the old case on a rename-over, Pitfall 4).
    @Test func caseOnlyReplaceLeavesTheIncomingName() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let values = try dest.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard values.volumeSupportsCaseSensitiveNames == false else { try Test.cancel("needs a case-insensitive volume") }
        try macFile("img_2.JPG", in: dest)
        let outcome = await run(try await answered([5], into: dest, answers: Self.replaceFirst, on: session), on: session)

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["IMG_2.jpg"])
        let file = dest.appending(component: "IMG_2.jpg")
        #expect(try Data(contentsOf: file) == fakeBytes(5, 2_345_678))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
                == parsePTPDate("20260312T184005"))
    }

    /// T-04-11: a folder that takes the name between planning and the rename makes rename(2) answer EISDIR. That
    /// item fails; the folder and its contents are untouched, and no temp is left.
    @Test func aFolderAtTheNameMakesReplaceFailAndKeepsTheFolder() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let original = try macFile("IMG_2.jpg", in: dest)
        let plan = try await answered([5], into: dest, answers: Self.replaceFirst, on: session)
        try FileManager.default.removeItem(at: original)
        let folder = try macFolder("IMG_2.jpg", in: dest)
        let inside = try macFile("inside.txt", in: folder)
        let outcome = await run(plan, on: session)

        #expect(outcome.failed == [TransferFailure(name: "IMG_2.jpg", detail: POSIXError(.EISDIR).localizedDescription,
                                                   key: Self.first)])
        #expect(outcome.lost == nil && !outcome.cancelled)
        #expect(try names(in: dest) == ["IMG_2.jpg"])                  // no .aft-download beside it
        #expect(try names(in: folder) == ["inside.txt"])
        #expect(try Data(contentsOf: inside) == Data("keep".utf8))
    }

    /// T-04-02: Replace onto a symlink replaces the link itself with the phone's file; the link's target is never
    /// written.
    @Test func replaceOntoASymlinkReplacesTheLinkNotItsTarget() async throws {
        let session = try await openedSession()
        let dest = try tempFolder(), elsewhere = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: elsewhere) }
        let target = try macFile("target.jpg", "target", in: elsewhere)
        let link = dest.appending(component: "IMG_2.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let outcome = await run(try await answered([5], into: dest, answers: Self.replaceFirst, on: session), on: session)

        #expect(outcome.problems == TransferOutcome())
        #expect(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: link) == fakeBytes(5, 2_345_678))
        #expect(try Data(contentsOf: target) == Data("target".utf8))
        #expect(try names(in: elsewhere) == ["target.jpg"])
    }

    // MARK: A Replace cut short keeps the original (XFER-08, SC2 Mac side)

    /// The phone stops answering on the third chunk: the session is lost, the original is byte-identical, no temp.
    @Test func aReplaceCutMidFileKeepsTheOriginal() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(unansweredAfter: [0x95C1: 2])
        let session = try await openedSession(fake)
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let original = try macFile("IMG_2.jpg", in: dest)
        let outcome = await run(try await answered([5], into: dest, answers: Self.replaceFirst, on: session), on: session)

        #expect(outcome.lost != nil)
        #expect(outcome.unfinished == ItemKey(top: 0))
        #expect(fake.opCounts[0x95C1] == 3)                         // two chunks written to the temp, then the cut
        #expect(try names(in: dest) == ["IMG_2.jpg"])
        #expect(try Data(contentsOf: original) == Data("keep".utf8))
    }

    /// The user stops between chunks: the original is byte-identical and no temp is left.
    @Test func aReplaceStoppedMidFileKeepsTheOriginal() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let original = try macFile("IMG_2.jpg", in: dest)
        let plan = try await answered([5], into: dest, answers: Self.replaceFirst, on: session)
        let progress = Progress()
        let task = Task {
            await Transfer.run(plan, session: session, chunk: Self.chunk) { n in
                progress.total += n
                // The progress closure is awaited inside the run's task, so this stops that task.
                if progress.total >= 3 * 65_536 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let outcome = await task.value

        #expect(outcome.cancelled)
        #expect(outcome.failed.isEmpty && outcome.lost == nil)
        #expect(outcome.unfinished == ItemKey(top: 0))
        #expect(await progress.total < 2_345_678)
        #expect(try names(in: dest) == ["IMG_2.jpg"])
        #expect(try Data(contentsOf: original) == Data("keep".utf8))
    }

    // MARK: Every local volume format (04-RESEARCH Q3)

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

    /// On each format: Replace leaves one file with the phone's bytes, a case-only Replace leaves the incoming name,
    /// and Keep Both leaves the original beside "IMG_2 2.jpg" (on exFAT through moveExclusive's placeholder, since
    /// RENAME_EXCL answers ENOTSUP there). Each case gets its own folder, away from the volume root's own files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MTP_DISK_IMAGES"] != nil),
          arguments: ["APFS", "Journaled HFS+", "ExFAT", "MS-DOS FAT32"])
    func replaceOnEveryVolumeFormat(format: String) async throws {
        try await withDiskImage(format) { mount in
            let session = try await openedSession()
            let phone = fakeBytes(5, 2_345_678)

            let replaced = try macFolder("replace", in: mount)
            try macFile("IMG_2.jpg", in: replaced)
            var outcome = await run(try await answered([5], into: replaced, answers: Self.replaceFirst, on: session),
                                    on: session)
            #expect(outcome.problems == TransferOutcome())
            #expect(try names(in: replaced) == ["IMG_2.jpg"])
            #expect(try Data(contentsOf: replaced.appending(component: "IMG_2.jpg")) == phone)

            let cased = try macFolder("case", in: mount)
            try macFile("img_2.JPG", in: cased)
            outcome = await run(try await answered([5], into: cased, answers: Self.replaceFirst, on: session), on: session)
            #expect(outcome.problems == TransferOutcome())
            #expect(try names(in: cased) == ["IMG_2.jpg"])
            #expect(try Data(contentsOf: cased.appending(component: "IMG_2.jpg")) == phone)

            let kept = try macFolder("keep", in: mount)
            let original = try macFile("IMG_2.jpg", in: kept)
            outcome = await run(try await answered([5], into: kept, answers: ClashAnswers(byItem: [Self.first: .keepBoth]),
                                                   on: session), on: session)
            #expect(outcome.problems == TransferOutcome())
            #expect(try names(in: kept) == ["IMG_2 2.jpg", "IMG_2.jpg"])
            #expect(try Data(contentsOf: original) == Data("keep".utf8))
            #expect(try Data(contentsOf: kept.appending(component: "IMG_2 2.jpg")) == phone)
        }
    }

    // MARK: Phone uploads go through a hidden temp (D-22, D-23, XFER-09)

    /// Both upload paths send a temp name and rename it once the phone has the whole file; the rename keeps the handle.
    @Test func everyUploadGoesThroughATempAndKeepsItsHandle() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let small = try macFile("small.bin", 500, in: src), big = try macFile("big.bin", 300 * 1024, in: src)
        let outcome = try await upload([small, big], on: session)

        #expect(outcome.failed.isEmpty && outcome.lost == nil && outcome.leftovers.isEmpty)
        #expect(fake.sentNames.count == 2 && fake.sentNames.allSatisfy(Transfer.isUploadTemp))
        #expect(fake.renamedNames == ["small.bin", "big.bin"])
        let listed = try await session.children(storage: Self.phone)
        #expect(!listed.contains { Transfer.isUploadTemp($0.name) })
        #expect(outcome.created.count == 2)
        for url in [small, big] {
            let entry = try #require(listed.first { $0.name == url.lastPathComponent })
            #expect(outcome.created.contains(entry.id))                 // the handle its temp was created with
            let source = try Data(contentsOf: url)
            #expect(entry.size == UInt64(source.count))
            #expect(try await Data(session.readPartial(entry.id, offset: 0, length: UInt32(source.count))) == source)
        }
    }

    /// D-23: `landed` names each file once its rename is done, in plan order, so the browser can show it at once; never
    /// a folder, and never an item whose rename was refused.
    @Test func landedReportsEachFileAfterItsRename() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let album = try macFolder("Album", in: src)
        try macFile("a.jpg", 500, in: album)
        let big = try macFile("b.bin", 300 * 1024, in: src), refused = try macFile("x.bin", 40, in: src)
        let plan = try await Transfer.planUpload([album, big, refused], storage: Self.phone, parent: Self.root, session: session)
        _ = try await session.createFile(storage: Self.phone, parent: Self.root, name: "x.bin", contents: [1, 2, 3])
        let landed = Landed()
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk, landed: { handle, replaced in
            landed.calls.append((handle, replaced, fake.renamedNames.last))
        }) { _ in }

        let calls = await landed.calls
        let files = try ["a.jpg", "b.bin"].map { name in try #require(fake.objects.first { $0.name == name }).handle }
        #expect(calls.map(\.handle) == files)
        #expect(calls.map(\.lastRename) == ["a.jpg", "b.bin"])     // each reported after its own rename
        #expect(calls.allSatisfy { $0.replaced == nil })
        #expect(fake.renamedNames == ["a.jpg", "b.bin", "x.bin"])  // x.bin's rename was tried and refused
        #expect(outcome.failed.map(\.name) == ["x.bin"])
    }

    /// A folder has no partial state: it is made under its real name and never renamed.
    @Test func foldersAreMadeUnderTheirRealName() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let outcome = try await upload([try macFolder("Album", in: src)], on: session)

        #expect(outcome.failed.isEmpty && outcome.leftovers.isEmpty)
        #expect(fake.sentNames == ["Album"])
        #expect(fake.renamedNames.isEmpty)
        #expect(fake.objects.contains { $0.name == "Album" && $0.format == 0x3001 })
    }

    /// A cable pull mid edit path leaves no "big.bin", only its hidden temp, recorded with the folder made this run.
    @Test func aPullMidUploadLeavesOnlyARecordedTemp() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(goneAfter: [0x95C2: 1])
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let album = try macFolder("Album", in: src)
        try macFile("big.bin", 300 * 1024, in: album)
        let outcome = try await upload([album], on: session)

        #expect(outcome.lost == .deviceGone)
        #expect(outcome.failed == [TransferFailure(name: "big.bin", detail: MTPError.deviceGone.detail,
                                                   key: ItemKey(top: 0, path: ["big.bin"]))])
        #expect(outcome.folders == [Self.first: "Album"] && outcome.unreached.isEmpty)
        #expect(!fake.objects.contains { $0.name == "big.bin" })
        let made = try #require(fake.objects.first { $0.name == "Album" })
        let temps = fake.objects.filter { Transfer.isUploadTemp($0.name) }
        #expect(temps.count == 1)
        let temp = try #require(temps.first)
        #expect(temp.parent == made.handle)
        #expect(outcome.leftovers == [PhoneLeftover(storage: Self.phone, folder: made.handle, temp: temp.name,
                                                    name: "big.bin", size: 307_200, key: ItemKey(top: 0, path: ["big.bin"]),
                                                    folderPath: ["Album"], handle: temp.handle)])
    }

    /// XFER-09 adjacency edge: a pull after the last byte but before the rename leaves the complete temp, recorded.
    @Test func aPullBeforeTheRenameLeavesTheCompleteTemp() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(goneAfter: [0x9804: 0])
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let landed = Landed()
        let outcome = try await upload([try macFile("small.bin", 500, in: src)], on: session,
                                       landed: { landed.calls.append(($0, $1, nil)) })

        #expect(outcome.lost == .deviceGone)
        #expect(!fake.objects.contains { $0.name == "small.bin" })
        let temp = try #require(fake.objects.first { Transfer.isUploadTemp($0.name) })
        #expect(temp.size == 500)
        #expect(outcome.leftovers == [PhoneLeftover(storage: Self.phone, folder: Self.root, temp: temp.name,
                                                    name: "small.bin", size: 500, key: ItemKey(top: 0), handle: temp.handle)])
        #expect(await landed.calls.isEmpty)
    }

    /// D-09 unchanged: a stop between chunks ends the edit and deletes the temp; the file finished before stays.
    @Test func aStopMidUploadDeletesItsTemp() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let small = try macFile("small.bin", 500, in: src), big = try macFile("big.bin", 300 * 1024, in: src)
        let progress = Progress()
        let task = Task {
            try await upload([small, big], on: session, progress: { n in
                progress.total += n
                if progress.total >= 500 + 65_536 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        let outcome = try await task.value

        #expect(outcome.cancelled && outcome.failed.isEmpty && outcome.lost == nil && outcome.leftovers.isEmpty)
        #expect(outcome.unfinished == ItemKey(top: 1))
        #expect(fake.sentNames.count == 2 && fake.sentNames.allSatisfy(Transfer.isUploadTemp))
        #expect(fake.opCounts[0x95C5] == 1 && fake.opCounts[0x100B] == 1)    // EndEditObject, then DeleteObject
        #expect(!fake.objects.contains { $0.name == "big.bin" || Transfer.isUploadTemp($0.name) })
        #expect(fake.objects.first { $0.name == "small.bin" }?.size == 500)
    }

    /// Pitfall 8: a stop that lands during the last chunk's callback can't cut the finalize, so the file ends complete
    /// under its name; the next item doesn't start.
    @Test func aStopDuringTheLastChunkStillFinishesTheFile() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let big = try macFile("big.bin", 300 * 1024, in: src), after = try macFile("after.bin", 40, in: src)
        let progress = Progress()
        let task = Task {
            try await upload([big, after], on: session, progress: { n in
                progress.total += n
                if progress.total >= 300 * 1024 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        let outcome = try await task.value

        #expect(outcome.cancelled && outcome.failed.isEmpty && outcome.leftovers.isEmpty)
        #expect(outcome.unfinished == ItemKey(top: 1))
        #expect(fake.renamedNames == ["big.bin"])
        let file = try #require(fake.objects.first { $0.name == "big.bin" })
        #expect(file.size == 307_200)
        #expect(try await Data(session.readPartial(file.handle, offset: 0, length: 307_200)) == Data(contentsOf: big))
        #expect(!fake.objects.contains { $0.name == "after.bin" || Transfer.isUploadTemp($0.name) })
    }

    /// Something took the name after planning: the phone refuses the rename, the temp is deleted, the other item is
    /// untouched and this item fails with the code line. The Mac still has the file, so nothing is recorded.
    @Test func aRefusedRenameDeletesTheTempAndKeepsTheOtherItem() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let plan = try await Transfer.planUpload([try macFile("x.bin", 500, in: src)], storage: Self.phone,
                                                 parent: Self.root, session: session)
        let other = try await session.createFile(storage: Self.phone, parent: Self.root, name: "x.bin", contents: [1, 2, 3])
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }

        let refused = MTPError.response(code: MTPCode.generalError, op: MTPOp.setObjectPropValue)
        #expect(outcome.failed == [TransferFailure(name: "x.bin", detail: try #require(refused.codeLine), key: Self.first)])
        #expect(outcome.leftovers.isEmpty && outcome.lost == nil)
        #expect(fake.renamedNames == ["x.bin"])
        #expect(fake.objects.filter { $0.name == "x.bin" }.map(\.handle) == [other])
        #expect(try await session.readPartial(other, offset: 0, length: 3) == [1, 2, 3])
        #expect(!fake.objects.contains { Transfer.isUploadTemp($0.name) })
    }

    /// RESEARCH Pitfall 2: the finalize rename waits for MediaStore scans, so it gets 120 s, not the browser's 5 s.
    @Test func theFinalizeRenameUsesTheLongTimeout() async throws {
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let file = try macFile("small.bin", 500, in: src)
        let session = DeviceSession(transport: MinTimeout(FakeAndroidResponder(), op: MTPOp.setObjectPropValue, atLeast: 120))
        _ = try await session.openSession()
        let outcome = try await upload([file], on: session)

        #expect(outcome.failed.isEmpty && outcome.lost == nil)
        #expect(try await session.children(storage: Self.phone).contains { $0.name == "small.bin" })
        // The wrapper does bite: a rename sent with less than 121 s is cut.
        let strict = DeviceSession(transport: MinTimeout(FakeAndroidResponder(), op: MTPOp.setObjectPropValue, atLeast: 121))
        _ = try await strict.openSession()
        #expect(try await upload([file], on: strict).lost == .io(operation: "short timeout", code: 0))
    }

    /// D-23: only the app's own exact temp form is hidden; every other dotfile still shows.
    @Test(arguments: [
        (".\(ReplaceTests.uuid).aft-upload", true), (Transfer.uploadTempName(), true),
        (".\(ReplaceTests.uuid).aft-upload.jpg", false),          // the extension form wasn't chosen (04-PROBE-REPORT)
        (".nomedia", false), (".notes.aft-upload", false), ("\(ReplaceTests.uuid).aft-upload", false),
        (".\(ReplaceTests.uuid).aft-download", false), ("IMG.jpg", false), (".aft-upload", false),
    ])
    func uploadTempNames(name: String, matches: Bool) {
        #expect(Transfer.isUploadTemp(name) == matches)
    }

    // MARK: Replace on the phone (XFER-08 phone side, D-11, D-21, D-27; RESEARCH Q2)

    /// A phone object as the tests compare it.
    private func describe(_ o: FakeObject) -> String { "\(o.handle) \(o.parent) \(o.name) \(o.size)" }

    /// The original a Replace goes over: handle 5, "IMG_2.jpg", 2,345,678 bytes.
    private func isOriginal(_ o: FakeObject) -> Bool { o.handle == 5 && o.name == "IMG_2.jpg" && o.size == 2_345_678 }

    /// U1–U3 upload the temp, U4 deletes the original, U5 renames the temp: the original goes only once the complete
    /// new copy is on the phone, and `landed` names the original the browser must drop.
    @Test func replaceUploadsThenDeletesThenRenames() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let mac = try macFile("IMG_2.jpg", 500, in: src)
        let landed = Landed()
        let outcome = try await upload([mac], answers: Self.replaceFirst, on: session,
                                       landed: { landed.calls.append(($0, $1, nil)) })

        #expect(outcome.failed.isEmpty && outcome.lost == nil && outcome.leftovers.isEmpty)
        let file = try #require(fake.objects.first { $0.name == "IMG_2.jpg" })
        #expect(fake.objects.filter { Transfer.phoneKey($0.name) == "img_2.jpg" }.count == 1)
        #expect(file.handle != 5 && file.size == 500 && !fake.objects.contains { $0.handle == 5 })
        #expect(try await Data(session.readPartial(file.handle, offset: 0, length: 500)) == Data(contentsOf: mac))
        let order: [UInt16] = [MTPOp.sendObjectInfo, MTPOp.sendObject, MTPOp.deleteObject, MTPOp.setObjectPropValue]
        #expect(fake.ops.filter(order.contains) == order)
        #expect(fake.sentNames.allSatisfy(Transfer.isUploadTemp) && fake.renamedNames == ["IMG_2.jpg"])
        let calls = await landed.calls
        #expect(calls.map(\.handle) == [file.handle] && calls.map(\.replaced) == [5])
    }

    /// Where a cable pull or a lost answer cuts a Replace (RESEARCH Q2's table).
    enum Cut: Sendable { case c1, c2, c3, c4, c5 }

    private func cutFake(_ cut: Cut) -> FakeAndroidResponder {
        switch cut {
        case .c1: FakeAndroidResponder(goneAfter: [0x95C2: 1])            // a pull during the second chunk
        case .c2: FakeAndroidResponder(goneAfter: [0x100B: 0])            // a pull before the delete
        case .c3: FakeAndroidResponder(dropResponseAfter: [0x100B: 0])    // the delete done, its answer lost
        case .c4: FakeAndroidResponder(goneAfter: [0x9804: 0])            // a pull before the rename
        case .c5: FakeAndroidResponder(dropResponseAfter: [0x9804: 0])    // the rename done, its answer lost
        }
    }

    /// A new "IMG_2.jpg" (C1: 300 KiB on the edit path, else 500 B) uploaded with Replace onto handle 5 and cut at
    /// `cut`. Checks what every cut must leave (XFER-08): one recorded leftover, and a complete copy on the phone, either
    /// the original at its full size or an object of the new file's full size under either name.
    private func replaceCut(_ cut: Cut) async throws -> (outcome: TransferOutcome, objects: [FakeObject]) {
        nonisolated(unsafe) let fake = cutFake(cut)
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let size = cut == .c1 ? 300 * 1024 : 500
        let outcome = try await upload([try macFile("IMG_2.jpg", size, in: src)], answers: Self.replaceFirst, on: session)
        let objects = fake.objects

        #expect(outcome.lost != nil)
        #expect(outcome.leftovers.map(\.name) == ["IMG_2.jpg"] && outcome.leftovers.map(\.size) == [UInt64(size)])
        #expect(outcome.leftovers.map(\.folder) == [Self.root] && outcome.leftovers.map(\.key) == [Self.first])
        #expect(objects.contains(where: isOriginal)
                || objects.contains { $0.size == UInt64(size) && ($0.name == "IMG_2.jpg" || Transfer.isUploadTemp($0.name)) })
        return (outcome, objects)
    }

    /// C1: a pull mid-upload leaves the original whole beside the partial temp.
    @Test func cutPointC1() async throws {
        let (outcome, objects) = try await replaceCut(.c1)
        #expect(objects.contains(where: isOriginal))
        let temp = try #require(objects.first { Transfer.isUploadTemp($0.name) })
        #expect(temp.size == 65_536)                                    // one chunk landed
        #expect(outcome.leftovers.map(\.temp) == [temp.name])
    }

    /// C2: a pull before the delete leaves the original and the complete temp.
    @Test func cutPointC2() async throws {
        let (outcome, objects) = try await replaceCut(.c2)
        #expect(objects.contains(where: isOriginal))
        let temp = try #require(objects.first { Transfer.isUploadTemp($0.name) })
        #expect(temp.size == 500 && outcome.leftovers.map(\.temp) == [temp.name])
    }

    /// C3: the delete happened but its answer was lost: the original is gone, the complete temp is the copy.
    @Test func cutPointC3() async throws {
        let (outcome, objects) = try await replaceCut(.c3)
        guard case .io = outcome.lost else { Issue.record("expected a read timeout, got \(String(describing: outcome.lost))"); return }
        #expect(!objects.contains { $0.handle == 5 })
        let temp = try #require(objects.first { Transfer.isUploadTemp($0.name) })
        #expect(temp.size == 500 && outcome.leftovers.map(\.temp) == [temp.name])
    }

    /// C4: a pull before the rename leaves only the complete temp.
    @Test func cutPointC4() async throws {
        let (outcome, objects) = try await replaceCut(.c4)
        #expect(!objects.contains { $0.handle == 5 || $0.name == "IMG_2.jpg" })
        let temp = try #require(objects.first { Transfer.isUploadTemp($0.name) })
        #expect(temp.size == 500 && outcome.leftovers.map(\.temp) == [temp.name])
    }

    /// C5: the rename happened but its answer was lost: the new file is under its name, no temp is left.
    @Test func cutPointC5() async throws {
        let (outcome, objects) = try await replaceCut(.c5)
        guard case .io = outcome.lost else { Issue.record("expected a read timeout, got \(String(describing: outcome.lost))"); return }
        #expect(objects.filter { $0.name == "IMG_2.jpg" }.map(\.size) == [500])
        #expect(!objects.contains { $0.handle == 5 || Transfer.isUploadTemp($0.name) })
    }

    /// CONTEXT discretion: the phone won't delete the original, so the new copy is deleted and the original stays.
    @Test func aRefusedDeleteKeepsTheOriginal() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(protectedHandles: [5])
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let outcome = try await upload([try macFile("IMG_2.jpg", 500, in: src)], answers: Self.replaceFirst, on: session)

        let refused = try #require(MTPError.response(code: MTPCode.accessDenied, op: MTPOp.deleteObject).codeLine)
        #expect(outcome.failed == [TransferFailure(name: "IMG_2.jpg", detail: TransferText.replaceRefused + "\n" + refused,
                                                   key: Self.first)])
        #expect(outcome.leftovers.isEmpty && outcome.lost == nil)
        #expect(fake.objects.contains(where: isOriginal))
        #expect(!fake.objects.contains { Transfer.isUploadTemp($0.name) })
        #expect(fake.renamedNames.isEmpty)
    }

    /// Pitfall 1: after the delete, AOSP may still hold the name for a moment; the rename is retried with backoff.
    @Test func theRenameWaitsOutTheNameCache() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(staleNameRenames: 2)
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let outcome = try await upload([try macFile("IMG_2.jpg", 500, in: src)], answers: Self.replaceFirst, on: session)

        #expect(outcome.failed.isEmpty && outcome.leftovers.isEmpty && outcome.lost == nil)
        #expect(fake.renamedNames == ["IMG_2.jpg", "IMG_2.jpg", "IMG_2.jpg"])
        #expect(fake.objects.filter { $0.name == "IMG_2.jpg" }.map(\.size) == [500])
        #expect(!fake.objects.contains { Transfer.isUploadTemp($0.name) })
    }

    /// D-27: the rename still refused after all 6 retries: the original is gone, so the temp is the only copy on the
    /// phone; it is kept and recorded, and the item fails saying Retry finishes it.
    @Test func aRenameStillRefusedAfterTheDeleteKeepsTheTemp() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(staleNameRenames: 7)
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let outcome = try await upload([try macFile("IMG_2.jpg", 500, in: src)], answers: Self.replaceFirst, on: session)

        let refused = try #require(MTPError.response(code: MTPCode.generalError, op: MTPOp.setObjectPropValue).codeLine)
        #expect(outcome.failed == [TransferFailure(name: "IMG_2.jpg", detail: TransferText.finishOnRetry + "\n" + refused,
                                                   key: Self.first)])
        #expect(outcome.lost == nil)
        #expect(fake.renamedNames.count == 7)
        #expect(!fake.objects.contains { $0.handle == 5 || $0.name == "IMG_2.jpg" })
        let temp = try #require(fake.objects.first { Transfer.isUploadTemp($0.name) })
        #expect(temp.size == 500)
        #expect(outcome.leftovers == [PhoneLeftover(storage: Self.phone, folder: Self.root, temp: temp.name,
                                                    name: "IMG_2.jpg", size: 500, key: Self.first, handle: temp.handle)])
    }

    /// T-04-23: 0x2002 on a rename that followed no delete means the name is taken: one try, the temp deleted.
    @Test func createRenameIsNotRetried() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let plan = try await Transfer.planUpload([try macFile("x.bin", 500, in: src)], storage: Self.phone,
                                                 parent: Self.root, session: session)
        _ = try await session.createFile(storage: Self.phone, parent: Self.root, name: "x.bin", contents: [1, 2, 3])
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }

        #expect(fake.renamedNames == ["x.bin"])
        #expect(outcome.failed.map(\.name) == ["x.bin"] && outcome.leftovers.isEmpty)
        #expect(fake.opCounts[0x100B] == 1 && !fake.objects.contains { Transfer.isUploadTemp($0.name) })
    }

    /// Pitfall 8: a stop during the last chunk of a Replace can't land between the delete and the rename, even while
    /// the rename waits out the name cache; the new file ends under its name and the next item doesn't start.
    @Test func aStopCantLandBetweenDeleteAndRename() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(staleNameRenames: 1)
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let big = try macFile("IMG_2.jpg", 300 * 1024, in: src), after = try macFile("after.bin", 40, in: src)
        let progress = Progress()
        let task = Task {
            try await upload([big, after], answers: Self.replaceFirst, on: session, progress: { n in
                progress.total += n
                if progress.total >= 300 * 1024 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        let outcome = try await task.value

        #expect(outcome.cancelled && outcome.failed.isEmpty && outcome.leftovers.isEmpty)
        #expect(outcome.unfinished == ItemKey(top: 1))
        #expect(fake.renamedNames == ["IMG_2.jpg", "IMG_2.jpg"])
        #expect(fake.objects.filter { $0.name == "IMG_2.jpg" }.map(\.size) == [307_200])
        #expect(!fake.objects.contains { $0.handle == 5 || $0.name == "after.bin" || Transfer.isUploadTemp($0.name) })
    }

    /// D-11, Pitfall 3: on a phone whose storage ignores case, "img_2.jpg" Replace onto "IMG_2.jpg" deletes the
    /// original first, so the rename lands on a free name: one object, the incoming name, nothing clobbered.
    @Test func caseOnlyReplaceNeverClobbers() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(caseInsensitiveNames: true)
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let mac = try macFile("img_2.jpg", 500, in: src)
        let scan = try await Transfer.planUpload([mac], storage: Self.phone, parent: Self.root, session: session)
        #expect(scan.clashes.map(\.id) == [Self.first])
        let outcome = try await upload([mac], answers: Self.replaceFirst, on: session)

        #expect(outcome.failed.isEmpty && outcome.leftovers.isEmpty)
        let same = fake.objects.filter { Transfer.phoneKey($0.name) == "img_2.jpg" }
        #expect(same.map(\.name) == ["img_2.jpg"] && same.map(\.size) == [500])
        #expect(try await Data(session.readPartial(same[0].handle, offset: 0, length: 500)) == Data(contentsOf: mac))
        #expect(fake.clobbered.isEmpty)
    }

    /// D-24's single rule, on the phone as each cut left it (a fresh fake with the same objects and handles, as after a
    /// silent reconnect): C2 → the original keeps its name, the temp goes; C3, C4 → the complete temp takes the real
    /// name, the item is done; C5 → no temp, and its own handle has the real name at full size: done, nothing written
    /// (WR-02); a partial temp whose name is free (C1 without the original) → deleted. Nothing but the recorded temp is
    /// ever touched (D-25).
    @Test(arguments: [(Cut.c1, false), (.c2, false), (.c3, true), (.c4, true), (.c5, true)])
    func fixUpRule(cut: Cut, finishes: Bool) async throws {
        let (outcome, cutObjects) = try await replaceCut(cut)
        var objects = cutObjects
        if cut == .c1 { objects.removeAll { $0.handle == 5 } }
        let left = try #require(outcome.leftovers.first)
        let temp = objects.first { $0.name == left.temp }
        let others = objects.filter { $0.handle != temp?.handle }.map(describe)
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: objects)
        let session = try await openedSession(fake)
        let children = try await session.children(storage: left.storage, parent: left.folder)

        #expect(try await Transfer.fixUp(left, children: children, session: session) == (finishes ? left.handle : nil))
        #expect(fake.objects.filter { $0.handle != temp?.handle }.map(describe) == others)
        #expect(!fake.objects.contains { Transfer.isUploadTemp($0.name) })
        if finishes {
            let file = try #require(fake.objects.first { $0.handle == left.handle })
            #expect(file.name == "IMG_2.jpg" && file.size == left.size)
        } else {
            #expect(!fake.objects.contains { $0.handle == temp?.handle })
            #expect(fake.renamedNames.isEmpty)
        }
        if cut == .c5 { #expect(fake.opCounts[0x100B] == nil && fake.renamedNames.isEmpty) }
    }

    /// WR-02, D-16: after C5 (the rename landed, its answer lost) a silent reconnect keeps the handles, so the fix-up
    /// finds the temp's own object under the real name and the item is done: the continuation sends nothing, never an
    /// unasked "new 2.txt". After a replug the handles are new and the item stays retryable (Pitfall 17).
    @Test func aRenameThatLandedBeforeASilentReconnectIsDone() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(dropResponseAfter: [0x9804: 0])
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let mac = try macFile("new.txt", 500, in: src)
        let first = try await upload([mac], on: session)
        let left = try #require(first.leftovers.first)
        let landed = try #require(fake.objects.first { $0.name == "new.txt" })
        #expect(first.lost != nil && left.handle == landed.handle)

        nonisolated(unsafe) let replugged = fake.replugged()
        let other = try await openedSession(replugged)
        let renumbered = try await other.children(storage: left.storage, parent: left.folder)
        #expect(try await Transfer.fixUp(left, children: renumbered, session: other) == nil)

        let again = try await openedSession(fake)
        let children = try await again.children(storage: left.storage, parent: left.folder)
        #expect(try await Transfer.fixUp(left, children: children, session: again) == landed.handle)
        let next = try await Transfer.planUpload([mac], storage: Self.phone, parent: Self.root, settled: [left.key],
                                                 unanswered: .keepBoth, session: again)
        #expect(next.steps.isEmpty && next.clashes.isEmpty)
        #expect(fake.objects.filter { $0.name.hasPrefix("new") }.map(\.name) == ["new.txt"])
    }

    // MARK: Retry and the D-16 continuation: only what isn't done (XFER-10, D-08, D-10, D-17, D-19, D-28)

    /// A phone folder or file for the retry fixtures, on internal storage.
    private static func object(_ handle: UInt32, in parent: UInt32, _ name: String, folder: Bool = false) -> FakeObject {
        FakeObject(handle: handle, storageID: phone, parent: parent, name: name, format: folder ? 0x3001 : 0x3000,
                   size: folder ? 0 : UInt64(handle) * 100, modified: "20260314T120000")
    }

    /// The phone folder "Camera" (1) holding p1.jpg (2) and p2.jpg (3).
    static let camera = [object(1, in: root, "Camera", folder: true), object(2, in: 1, "p1.jpg"), object(3, in: 1, "p2.jpg")]

    /// Two phone folders "Album" (3 in X, 4 in Y): a.jpg (5) in the first, b.jpg (6) and c.jpg (7) in the second.
    static let albums = [object(1, in: root, "X", folder: true), object(2, in: root, "Y", folder: true),
                         object(3, in: 1, "Album", folder: true), object(4, in: 2, "Album", folder: true),
                         object(5, in: 3, "a.jpg"), object(6, in: 4, "b.jpg"), object(7, in: 4, "c.jpg")]

    /// A first attempt copying "Camera" into `dest`, where a file has that name: the type clash is answered Keep Both,
    /// so it lands as "Camera 2"; p1.jpg is copied and p2.jpg fails (a short read).
    private func keptBothCamera(into dest: URL) async throws -> (TransferOutcome, ClashAnswers) {
        try macFile("Camera", in: dest)
        let session = try await openedSession(FakeAndroidResponder(objects: Self.camera, shortReadHandles: [3]))
        let answers = ClashAnswers(byItem: [Self.first: .keepBoth])
        let outcome = await run(try await answered([1], into: dest, answers: answers, on: session), on: session)
        return (outcome, answers)
    }

    /// Retry plans only the failed file, on a new session; the finished one meets no clash about its own copy.
    @Test func retryCopiesOnlyWhatIsNotDone() async throws {
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let cut = try await openedSession(FakeAndroidResponder(shortReadHandles: [5]))
        let first = await run(try await Transfer.planDownload(try await entries([5, 6], on: cut), into: dest, session: cut),
                              on: cut)
        #expect(first.settled == [ItemKey(top: 1)])
        #expect(first.failed == [TransferFailure(name: "IMG_2.jpg", detail: "The phone sent less data than expected.",
                                                 key: Self.first)])

        let session = try await openedSession()
        let retry = try await Transfer.planDownload(try await entries([5, 6], on: session), into: dest,
                                                    settled: first.settled, session: session)
        #expect(retry.clashes.isEmpty)
        #expect(retry.steps.map(\.key) == [Self.first])
        #expect(await run(retry, on: session).problems == TransferOutcome())
        #expect(try names(in: dest) == ["IMG_10.jpg", "IMG_2.jpg"])
        #expect(try Data(contentsOf: dest.appending(component: "IMG_2.jpg")) == fakeBytes(5, 2_345_678))
    }

    /// DCIM (made), Music (merged into the Mac's own), IMG_2.jpg, Pictures (an empty folder) and IMG_10.jpg (Skip),
    /// planned into `dest`.
    private func mixedJob(into dest: URL, on session: DeviceSession) async throws -> TransferPlan {
        _ = try macFolder("Music", in: dest)
        try macFile("IMG_10.jpg", in: dest)
        return try await Transfer.planDownload(try await entries([1, 3, 5, 4, 6], on: session), into: dest,
                                               answers: ClashAnswers(byItem: [ItemKey(top: 4): .skip]),
                                               unanswered: .keepBoth, session: session)
    }

    /// A stop or a pull mid-job lists the item in flight and every step after it, folder steps included, in plan order;
    /// `settled` holds only the finished files and the Skips, never a folder; `folders` every folder made or merged.
    @Test func aStopListsWhatItDidNotReach() async throws {
        let done: Set<ItemKey> = [ItemKey(top: 4), ItemKey(top: 0, path: ["inside.jpg"])]
        let folders = [Self.first: "DCIM", ItemKey(top: 1): "Music"]
        do {                                                                    // a stop during IMG_2.jpg
            let session = try await openedSession()
            let dest = try tempFolder()
            defer { try? FileManager.default.removeItem(at: dest) }
            let plan = try await mixedJob(into: dest, on: session)
            #expect(plan.settled == [ItemKey(top: 4)] && plan.folders == [ItemKey(top: 1): "Music"])
            let progress = Progress()
            let outcome = await Task {
                await Transfer.run(plan, session: session, chunk: Self.chunk) { n in
                    progress.total += n
                    if progress.total >= 1_234 + 65_536 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }.value

            #expect(outcome.cancelled && outcome.failed.isEmpty && outcome.lost == nil)
            #expect(outcome.settled == done && outcome.folders == folders)
            #expect(outcome.unreached == [TransferFailure(name: "IMG_2.jpg", key: ItemKey(top: 2)),
                                          TransferFailure(name: "Pictures", key: ItemKey(top: 3))])
        }
        do {                                                                    // a pull during IMG_2.jpg
            let session = try await openedSession(FakeAndroidResponder(goneAfter: [0x95C1: 2]))
            let dest = try tempFolder()
            defer { try? FileManager.default.removeItem(at: dest) }
            let outcome = await run(try await mixedJob(into: dest, on: session), on: session)

            let gone = MTPError.deviceGone.detail
            #expect(outcome.lost == .deviceGone && !outcome.cancelled)
            #expect(outcome.failed == [TransferFailure(name: "IMG_2.jpg", detail: gone, key: ItemKey(top: 2))])
            #expect(outcome.unreached == [TransferFailure(name: "Pictures", detail: gone, key: ItemKey(top: 3))])
            #expect(outcome.settled == done && outcome.folders == folders)
        }
    }

    /// D-17: a stored Replace still replaces on Retry, with no question.
    @Test func retryReusesAnswers() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        try macFile("IMG_2.jpg", in: dest)
        let retry = try await Transfer.planDownload(try await entries([5], on: session), into: dest,
                                                    answers: Self.replaceFirst, session: session)

        #expect(retry.clashes.isEmpty && retry.steps.count == 1)
        #expect(retry.steps.allSatisfy { if case .file(_, _, _, true) = $0 { true } else { false } })
        #expect(await run(retry, on: session).problems == TransferOutcome())
        #expect(try Data(contentsOf: dest.appending(component: "IMG_2.jpg")) == fakeBytes(5, 2_345_678))
    }

    /// D-28: a clash that wasn't there the first time is answered by the job's Apply to All, with no question.
    @Test func retryAppliesApplyToAllToNewClashes() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        for name in ["IMG_2.jpg", "IMG_2 2.jpg", "IMG_10.jpg"] { try macFile(name, in: dest) }   // IMG_10.jpg is new
        let retry = try await Transfer.planDownload(try await entries([5, 6], on: session), into: dest,
                                                    answers: ClashAnswers(byItem: [Self.first: .keepBoth], all: .keepBoth),
                                                    settled: [Self.first], session: session)

        #expect(retry.clashes.isEmpty)
        #expect(retry.steps.map(\.url.lastPathComponent) == ["IMG_10 2.jpg"])
    }

    /// D-17: a new clash no answer covers is asked; the settled item is not.
    @Test func retryAsksAnUncoveredNewClash() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        for name in ["IMG_2.jpg", "IMG_10.jpg"] { try macFile(name, in: dest) }
        let retry = try await Transfer.planDownload(try await entries([5, 6], on: session), into: dest,
                                                    answers: Self.replaceFirst, settled: [Self.first], session: session)

        #expect(retry.clashes.map(\.id) == [ItemKey(top: 1)])
        #expect(retry.steps.isEmpty)
    }

    /// D-10 on Retry: the settled first "IMG.jpg" still claims its name, so the failed second one is kept both again
    /// with no question about the first one's copy.
    @Test func retryKeepsDuplicatesKeptBoth() async throws {
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let cut = try await openedSession(FakeAndroidResponder(objects: ConflictTests.twins, shortReadHandles: [4]))
        let first = await run(try await Transfer.planDownload(try await entries([5, 4], on: cut), into: dest, session: cut),
                              on: cut)
        #expect(first.settled == [Self.first] && first.failed.map(\.key) == [ItemKey(top: 1)])

        let session = try await openedSession(FakeAndroidResponder(objects: ConflictTests.twins))
        let retry = try await Transfer.planDownload(try await entries([5, 4], on: session), into: dest,
                                                    settled: first.settled, session: session)
        #expect(retry.clashes.isEmpty)
        #expect(retry.steps.map(\.url.lastPathComponent) == ["IMG 2.jpg"])
        _ = await run(retry, on: session)
        #expect(try names(in: dest) == ["IMG 2.jpg", "IMG.jpg"])
        #expect(try Data(contentsOf: dest.appending(component: "IMG 2.jpg")) == fakeBytes(4, 100))
    }

    /// D-08, D-17: a folder kept both as "Camera 2" is continued, by a Retry's scan (`.ask`) and by a continuation
    /// (`.keepBoth`) alike: only p2.jpg goes, into "Camera 2", and no "Camera 3" is made.
    @Test(arguments: [Unanswered.ask, .keepBoth])
    func retryContinuesAKeptBothFolder(unanswered: Unanswered) async throws {
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let (first, answers) = try await keptBothCamera(into: dest)
        #expect(first.folders == [Self.first: "Camera 2"])
        #expect(first.settled == [ItemKey(top: 0, path: ["p1.jpg"])])
        #expect(first.failed.map(\.key) == [ItemKey(top: 0, path: ["p2.jpg"])])

        let session = try await openedSession(FakeAndroidResponder(objects: Self.camera))
        let retry = try await Transfer.planDownload(try await entries([1], on: session), into: dest, answers: answers,
                                                    settled: first.settled, folders: first.folders,
                                                    unanswered: unanswered, session: session)
        #expect(retry.clashes.isEmpty)
        #expect(retry.steps.map(\.url) == [dest.appending(path: "Camera 2/p2.jpg")])
        #expect(await run(retry, on: session).problems == TransferOutcome())
        #expect(try names(in: dest) == ["Camera", "Camera 2"])
        #expect(try names(in: dest.appending(component: "Camera 2")) == ["p1.jpg", "p2.jpg"])
        #expect(try Data(contentsOf: dest.appending(path: "Camera 2/p2.jpg")) == fakeBytes(3, 300))
    }

    /// D-10, D-17: two phone folders "Album" land as "Album" and "Album 2"; the one failed file inside the second goes
    /// back into "Album 2", and no "Album 3" is made.
    @Test(arguments: [Unanswered.ask, .keepBoth])
    func retryContinuesADuplicateFolder(unanswered: Unanswered) async throws {
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let cut = try await openedSession(FakeAndroidResponder(objects: Self.albums, shortReadHandles: [7]))
        let first = await run(try await Transfer.planDownload(try await entries([3, 4], on: cut), into: dest, session: cut),
                              on: cut)
        #expect(first.folders == [Self.first: "Album", ItemKey(top: 1): "Album 2"])
        #expect(first.failed.map(\.key) == [ItemKey(top: 1, path: ["c.jpg"])])

        let session = try await openedSession(FakeAndroidResponder(objects: Self.albums))
        let retry = try await Transfer.planDownload(try await entries([3, 4], on: session), into: dest,
                                                    settled: first.settled, folders: first.folders,
                                                    unanswered: unanswered, session: session)
        #expect(retry.clashes.isEmpty)
        #expect(retry.steps.map(\.url) == [dest.appending(path: "Album 2/c.jpg")])
        _ = await run(retry, on: session)
        #expect(try names(in: dest) == ["Album", "Album 2"])
        #expect(try names(in: dest.appending(component: "Album 2")) == ["b.jpg", "c.jpg"])
    }

    /// D-10, D-17 on the phone: "three/Album" and "four/album" upload as "Album" and "album 2"; an unreadable file in
    /// the second fails, and once readable it is sent into "album 2", found again by name on a new session.
    @Test func uploadRetryContinuesADuplicateFolder() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let three = try macFolder("Album", in: try macFolder("three", in: src))
        try macFile("x.jpg", 10, in: three)
        let four = try macFolder("album", in: try macFolder("four", in: src))
        try macFile("y.jpg", 20, in: four)
        let z = try macFile("z.jpg", 30, in: four)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: z.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: z.path) }
        let first = try await upload([three, four], on: session)
        #expect(first.folders == [Self.first: "Album", ItemKey(top: 1): "album 2"])
        #expect(first.failed.map(\.key) == [ItemKey(top: 1, path: ["z.jpg"])])

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: z.path)
        nonisolated(unsafe) let replugged = FakeAndroidResponder(objects: fake.objects)
        let again = try await openedSession(replugged)
        let retry = try await Transfer.planUpload([three, four], storage: Self.phone, parent: Self.root,
                                                  settled: first.settled, folders: first.folders, session: again)
        let album2 = try #require(replugged.objects.first { $0.name == "album 2" })
        #expect(retry.clashes.isEmpty && retry.failed.isEmpty)
        #expect(retry.steps.map(\.name) == ["z.jpg"])
        #expect(retry.steps.allSatisfy {
            if case .send(_, _, _, .existing(album2.handle), _, _, ["album 2"]) = $0 { true } else { false }
        })
        #expect(await run(retry, on: again).failed.isEmpty)
        #expect(replugged.objects.filter { $0.parent == album2.handle }.map(\.name).sorted() == ["y.jpg", "z.jpg"])
        #expect(!replugged.objects.contains { Transfer.phoneKey($0.name) == "album 3" })
    }

    /// CR-01: a first run's Stop that lands while the phone refuses a folder's mkdir (its name taken since planning)
    /// never cuts inside that folder, so its files aren't settled: the row lists the folder, and the Retry, merging
    /// into the folder now there, copies both files before the row goes.
    @Test func aStopDuringARefusedMkdirLeavesItsFilesToRetry() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let wire = StopOnSendObjectInfo(fake)
        let session = DeviceSession(transport: wire)
        _ = try await session.openSession()
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let f = try macFolder("F", in: src)
        try macFile("a.txt", 10, in: f)
        try macFile("b.txt", 20, in: f)
        var jobs = TransferJobs()
        let job = TransferJob(names: ["F"], destinationName: "Internal shared storage",
                              request: .upload([f], storage: Self.phone, parent: Self.root, path: []),
                              phone: PhoneID(serial: "FAKE0001", name: "Pixel 9"), session: session)
        jobs.add(job)
        let plan = try await Transfer.planUpload([f], storage: Self.phone, parent: Self.root, session: session)
        jobs.scanned(job.id, clashes: plan.clashes)
        _ = jobs.startNext()
        jobs.begin(job.id, total: plan.totalBytes)
        _ = try await session.makeFolder(storage: Self.phone, parent: Self.root, name: "F")
        wire.armed = true
        let outcome = await Task { await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in } }.value

        #expect(outcome.failed.map(\.key) == [Self.first] && outcome.unreached.isEmpty && outcome.settled.isEmpty)
        #expect(jobs.stop(job.id) == true)
        jobs.finish(job.id, outcome: outcome)
        let row = try #require(jobs.all.first)
        #expect(row.state == .failed && row.failures.map(\.key) == [Self.first] && row.settled.isEmpty)

        #expect(jobs.retry(job.id) == true)
        let retry = try await Transfer.planUpload([f], storage: Self.phone, parent: Self.root, settled: row.excluded,
                                                  folders: row.folders, session: session)
        #expect(retry.clashes.isEmpty && retry.steps.map(\.key) == [ItemKey(top: 0, path: ["a.txt"]),
                                                                    ItemKey(top: 0, path: ["b.txt"])])
        jobs.scanned(job.id, clashes: retry.clashes)
        _ = jobs.startNext()
        jobs.begin(job.id, total: retry.totalBytes)
        jobs.finish(job.id, outcome: await run(retry, on: session))
        #expect(jobs.isEmpty)
        let folder = try #require(fake.objects.first { $0.name == "F" && $0.parent == Self.root })
        #expect(fake.objects.filter { $0.parent == folder.handle }.map(\.name).sorted() == ["a.txt", "b.txt"])
    }

    /// D-17: the folder an earlier attempt made is gone, so its unfinished item is listed, not copied into a new folder.
    @Test func aVanishedFolderIsListedNotSkipped() async throws {
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let (first, answers) = try await keptBothCamera(into: dest)
        try FileManager.default.removeItem(at: dest.appending(component: "Camera 2"))

        let session = try await openedSession(FakeAndroidResponder(objects: Self.camera))
        let retry = try await Transfer.planDownload(try await entries([1], on: session), into: dest, answers: answers,
                                                    settled: first.settled, folders: first.folders, session: session)
        #expect(retry.steps.isEmpty && retry.clashes.isEmpty)
        #expect(retry.failed == [TransferFailure(name: "Camera", detail: TransferText.folderMoved, key: Self.first,
                                                 retryable: false)])
        _ = await run(retry, on: session)
        #expect(try names(in: dest) == ["Camera"])
    }

    /// D-19: a settled folder (Skipped, or cut off by a first run's Stop) gets no step and its subtree isn't listed.
    @Test func aSkippedFolderIsNotWalked() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let items = try await entries([1, 3, 5], on: session)           // DCIM (settled), Music (walked), IMG_2.jpg
        let listed = fake.opCounts[0x1007, default: 0]
        let plan = try await Transfer.planDownload(items, into: dest, settled: [Self.first], session: session)

        #expect(plan.clashes.isEmpty)
        #expect(plan.steps.map(\.key) == [ItemKey(top: 1), ItemKey(top: 2)])
        #expect(fake.opCounts[0x1007, default: 0] == listed + 1)          // Music only
    }

    /// D-27 then Retry: the fix-up finishes the kept temp, and the re-plan, with that item settled, uploads nothing.
    @Test func retryFinishesAKeptTempInsteadOfUploadingAgain() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(staleNameRenames: 7)
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let mac = try macFile("IMG_2.jpg", 500, in: src)
        let first = try await upload([mac], answers: Self.replaceFirst, on: session)
        let left = try #require(first.leftovers.first)
        #expect(first.failed.map(\.key) == [Self.first] && first.failed.allSatisfy(\.retryable))

        let children = try await session.children(storage: left.storage, parent: left.folder)
        #expect(try await Transfer.fixUp(left, children: children, session: session) == left.handle)
        let retry = try await Transfer.planUpload([mac], storage: Self.phone, parent: Self.root, answers: Self.replaceFirst,
                                                  settled: [left.key], session: session)
        #expect(retry.steps.isEmpty && retry.clashes.isEmpty && retry.failed.isEmpty)
        #expect(fake.objects.filter { $0.name == "IMG_2.jpg" }.map(\.size) == [500])
        #expect(!fake.objects.contains { Transfer.isUploadTemp($0.name) })
    }

    // MARK: A pulled cable, then the same phone again (XFER-09, XFER-10, D-13, D-14, D-24; RESEARCH Pattern 5)

    /// SC3: a pull mid-download lists the item in flight and every item it hadn't reached, in plan order, keyed and
    /// retryable, and leaves no partial file and no temp on the Mac. IMG_2.jpg is 36 chunks: cut on its third, on its
    /// last (XFER-09 adjacency: it fails, its temp deleted), and once its rename landed (it counts as copied).
    @Test(arguments: [2, 35, 36])
    func aPullMidDownloadListsWhatItDidNotCopy(chunksBeforePull: Int) async throws {
        let session = try await openedSession(FakeAndroidResponder(goneAfter: [0x95C1: chunksBeforePull]))
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let items = try await entries([5, 6, 7], on: session)               // IMG_2.jpg, IMG_10.jpg, empty.txt
        let outcome = await run(try await Transfer.planDownload(items, into: dest, session: session), on: session)

        let gone = MTPError.deviceGone.detail
        let cut = chunksBeforePull < 36 ? 0 : 1                             // the item in flight
        #expect(outcome.lost == .deviceGone && !outcome.cancelled)
        #expect(outcome.failed == [TransferFailure(name: items[cut].name, detail: gone, key: ItemKey(top: cut))])
        #expect(outcome.unreached == (cut + 1...2).map { TransferFailure(name: items[$0].name, detail: gone, key: ItemKey(top: $0)) })
        let listed = outcome.failed + outcome.unreached
        #expect(listed.allSatisfy { $0.retryable })
        #expect(outcome.settled == (cut == 0 ? [] : [Self.first]))
        #expect(try names(in: dest) == (cut == 0 ? [] : ["IMG_2.jpg"]))
    }

    /// RESEARCH Pattern 5: the walk by name on a replugged phone (new handles): the exact name, else the one case
    /// variant (T-04-33); nil for a missing level, a file on the way, or two case variants with no exact match.
    @Test func findWalksAPathByName() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder().replugged()
        let session = try await openedSession(fake)
        let inside = try #require(try await Transfer.find(["DCIM", "inside.jpg"], storage: Self.phone, session: session))
        #expect(inside.map(\.name) == ["DCIM", "inside.jpg"])
        #expect(inside.map(\.id) == ["DCIM", "inside.jpg"].map { name in fake.objects.first { $0.name == name }?.handle })
        #expect(!inside.map(\.id).contains(9))
        #expect(try await Transfer.find(["dcim"], storage: Self.phone, session: session)?.map(\.name) == ["DCIM"])
        #expect(try await Transfer.find(["DCIM", "gone.jpg"], storage: Self.phone, session: session) == nil)
        #expect(try await Transfer.find(["Nope", "inside.jpg"], storage: Self.phone, session: session) == nil)
        #expect(try await Transfer.find(["IMG_2.jpg", "x"], storage: Self.phone, session: session) == nil)
        #expect(try await Transfer.find([], storage: Self.phone, session: session) == [])

        let twins = try await openedSession(FakeAndroidResponder(objects: [Self.object(1, in: Self.root, "Photos", folder: true),
                                                                           Self.object(2, in: Self.root, "PHOTOS", folder: true)]))
        #expect(try await Transfer.find(["photos"], storage: Self.phone, session: twins) == nil)
        #expect(try await Transfer.find(["PHOTOS"], storage: Self.phone, session: twins)?.map(\.id) == [2])
    }

    /// D-14: a download picked on the old session is found again on the replugged phone, each item in its slot with
    /// its new handle; one deleted meanwhile keeps its slot as handle 0, which planDownload lists as gone (not
    /// retryable) without asking the phone, every other key unchanged.
    @Test func resolveFindsADownloadAgainByPath() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let old = try await openedSession(fake)
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let items = try await entries([5, 6], on: old) + old.entries([9], parent: 1)   // IMG_2.jpg, IMG_10.jpg, DCIM/inside.jpg
        let request = TransferJob.Request.download(items, paths: [["IMG_2.jpg"], ["IMG_10.jpg"], ["DCIM", "inside.jpg"]],
                                                   to: dest)
        try await old.delete(6)

        nonisolated(unsafe) let replugged = fake.replugged()
        let session = try await openedSession(replugged)
        let (resolved, missing) = try await Transfer.resolve(request, session: session)
        #expect(!missing)
        guard case let .download(found, paths, folder) = resolved else { Issue.record("not a download"); return }
        #expect(found.map(\.name) == ["IMG_2.jpg", "IMG_10.jpg", "inside.jpg"])
        #expect(found.map(\.id) == [1_005, 0, 1_009])
        #expect(paths == [["IMG_2.jpg"], ["IMG_10.jpg"], ["DCIM", "inside.jpg"]] && folder == dest)

        let asked = replugged.opCounts[MTPOp.getObjectInfo, default: 0]
        let plan = try await Transfer.planDownload(found, into: dest, session: session)
        #expect(replugged.opCounts[MTPOp.getObjectInfo, default: 0] == asked + 2)     // never about handle 0
        #expect(plan.failed == [TransferFailure(name: "IMG_10.jpg", detail: TransferText.itemGone, key: ItemKey(top: 1),
                                                retryable: false)])
        #expect(plan.steps.map(\.key) == [Self.first, ItemKey(top: 2)])
    }

    /// D-14: an upload's destination folder is found again by its path ([] = the storage root); a missing one is
    /// reported, never replaced by another folder.
    @Test func resolveFindsAnUploadDestinationAgain() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder().replugged()
        let session = try await openedSession(fake)
        let urls = [URL(filePath: "/tmp/a.jpg")]
        let dcim = try #require(fake.objects.first { $0.name == "DCIM" })
        let found = try await Transfer.resolve(.upload(urls, storage: Self.phone, parent: 1, path: ["DCIM"]), session: session)
        #expect(found.request == .upload(urls, storage: Self.phone, parent: dcim.handle, path: ["DCIM"]))
        #expect(!found.missingDestination)
        let root = try await Transfer.resolve(.upload(urls, storage: Self.phone, parent: 1, path: []), session: session)
        #expect(root.request == .upload(urls, storage: Self.phone, parent: Self.root, path: []) && !root.missingDestination)
        let gone = try await Transfer.resolve(.upload(urls, storage: Self.phone, parent: 1, path: ["DCIM", "Gone"]),
                                              session: session)
        #expect(gone.missingDestination)
    }

    /// D-24 after a replug: a Replace cut at C4 inside "DCIM/Album" records that folder's path; on the replugged phone,
    /// with a new session and new handles, the folder is found by it and the complete temp renamed into place.
    @Test func aLeftoverIsFoundByPathAfterAReplug() async throws {
        let album = Self.object(11, in: 1, "Album", folder: true), original = Self.object(12, in: 11, "IMG_2.jpg")
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: FakeAndroidResponder.defaultObjects + [album, original],
                                                            goneAfter: [0x9804: 0])
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let plan = try await Transfer.planUpload([try macFile("IMG_2.jpg", 500, in: src)], storage: Self.phone, parent: 11,
                                                 path: ["DCIM", "Album"], answers: Self.replaceFirst, session: session)
        let outcome = await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in }
        let left = try #require(outcome.leftovers.first)
        #expect(outcome.lost == .deviceGone && left.folder == 11 && left.folderPath == ["DCIM", "Album"])

        nonisolated(unsafe) let replugged = fake.replugged()
        let again = try await openedSession(replugged)
        let folder = try #require(try await Transfer.find(left.folderPath, storage: left.storage, session: again)?.last)
        #expect(folder.name == "Album" && folder.id != 11)
        let children = try await again.children(storage: left.storage, parent: folder.id)
        #expect(try await Transfer.fixUp(left, children: children, session: again) != nil)
        #expect(replugged.objects.filter { $0.parent == folder.id }.map(\.name) == ["IMG_2.jpg"])
        #expect(replugged.objects.first { $0.parent == folder.id }?.size == 500)
    }

    /// D-08, D-14, D-17: "Album" uploads kept both as "Album 2" beside a phone file named "Album"; a pull cuts its
    /// second file at C4, so that file and the third aren't copied. On the replugged phone the leftover's folder path is
    /// "Album 2" and found, and the Retry plans the second and third files into "Album 2" (by name, its new handle),
    /// with no "Album 3".
    @Test func aRetryAfterAReplugContinuesTheFolderItMade() async throws {
        let file = FakeObject(handle: 11, storageID: Self.phone, parent: Self.root, name: "Album", format: 0x3000, size: 4,
                              modified: "20260301T090000")
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: FakeAndroidResponder.defaultObjects + [file],
                                                            goneAfter: [0x9804: 1])
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let album = try macFolder("Album", in: src)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try macFile(name, 100, in: album) }
        let scan = try await Transfer.planUpload([album], storage: Self.phone, parent: Self.root, session: session)
        #expect(scan.clashes.map(\.id) == [Self.first])
        let answers = ClashAnswers(byItem: [Self.first: .keepBoth])
        let first = try await upload([album], answers: answers, on: session)
        let a = ItemKey(top: 0, path: ["a.jpg"]), b = ItemKey(top: 0, path: ["b.jpg"]), c = ItemKey(top: 0, path: ["c.jpg"])
        #expect(first.lost == .deviceGone && first.folders == [Self.first: "Album 2"] && first.settled == [a])
        #expect(first.failed.map(\.key) == [b] && first.unreached.map(\.key) == [c])
        let left = try #require(first.leftovers.first)
        #expect(left.key == b && left.folderPath == ["Album 2"])

        nonisolated(unsafe) let replugged = fake.replugged()
        let again = try await openedSession(replugged)
        let album2 = try #require(try await Transfer.find(left.folderPath, storage: Self.phone, session: again)?.last)
        #expect(album2.isFolder && album2.id == replugged.objects.first { $0.name == "Album 2" }?.handle)
        #expect(try await again.children(storage: Self.phone, parent: album2.id).contains { $0.name == left.temp })
        let retry = try await Transfer.planUpload([album], storage: Self.phone, parent: Self.root, answers: answers,
                                                  settled: first.settled, folders: first.folders, session: again)
        #expect(retry.clashes.isEmpty && retry.failed.isEmpty)
        #expect(retry.steps.map(\.name) == ["b.jpg", "c.jpg"])
        #expect(retry.steps.allSatisfy {
            if case .send(_, _, _, .existing(album2.id), _, _, ["Album 2"]) = $0 { true } else { false }
        })
        #expect(!replugged.objects.contains { Transfer.phoneKey($0.name) == "album 3" })
    }
}

/// Forwards to the fake; once `armed`, the next SendObjectInfo command cancels the task sending it: a Stop that lands
/// while the phone handles that command.
private final class StopOnSendObjectInfo: MTPTransport, @unchecked Sendable {
    private let inner: FakeAndroidResponder
    var armed = false
    var maxPacketSize: Int { inner.maxPacketSize }

    init(_ inner: FakeAndroidResponder) { self.inner = inner }

    func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
        if armed, bytes.count >= 8, bytes[4] == 1, UInt16(bytes[6]) | UInt16(bytes[7]) << 8 == MTPOp.sendObjectInfo {
            armed = false
            withUnsafeCurrentTask { $0?.cancel() }
        }
        try inner.write(bytes, timeout: timeout)
    }

    func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] {
        try inner.read(maxLength: maxLength, timeout: timeout)
    }
}
