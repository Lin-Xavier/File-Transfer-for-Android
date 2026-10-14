import CryptoKit
import Foundation
import IOKit
import Testing
@testable import MTPKit

// Hardware spike (D-20, D-22). Recording instruments: every finding line starts with "SPIKE ".
// Run from Terminal with the phone plugged in, unlocked and in File transfer mode:
//   MTP_HW=1 swift test --package-path MTPKit --filter HardwareSpike
//   MTP_HW_BUSY=1 swift test --package-path MTPKit --filter BusyDeviceSpike        (Photos open)
//   MTP_HW_BUSY=1 MTP_HW_NOSIGNAL=1 swift test --package-path MTPKit --filter BusyDeviceSpike
//   MTP_HW=1 swift test --package-path MTPKit --filter UploadEditSpike                (writes; needs 6 GB free)
//   MTP_HW=1 MTP_HW_BIG=1 swift test --package-path MTPKit --filter BigFileRoundTrip  (writes; ~20 min, 22 GB phone / 45 GB Mac)
//   MTP_HW=1 swift test --package-path MTPKit --filter ReplaceProbe   (writes only DCIM/AFTProbe; needs 2 GB free)
//     add MTP_HW_VIDEO=<path to a Mac video> to time the big rename on a real video's media scan
//   MTP_HW=1 swift test --package-path MTPKit --filter MoveProbe   (writes only DCIM/AFTMoveProbe, plus one hidden file at the storage root that it moves back; MTP_HW_MOVE_FILES=N sets the big folder's file count, default 1000)
// The HardwareSpike and BusyDeviceSpike suites are read-only. The UploadEditSpike suite writes only inside a
// folder named AFTSpike at the first storage's root: it deletes a leftover AFTSpike first and its own at the end.
// BigFileRoundTrip does the same with AFTBig, plus a scratch folder on the Mac (MTP_HW_SCRATCH or the temp dir).
// Nothing prints the serial number or personal file names.

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MTP_HW"] == "1"), .timeLimit(.minutes(5)))
struct HardwareSpike {
    @Test func descriptorsAndDeviceInfo() throws {
        let c = try findCandidate()
        print("SPIKE ptpcamerad pids=\(CameraDaemon.pids())")
        let t = try openPlainThenSeize(c.id)
        print("SPIKE endpoints \(t.endpointSummary); maxPacketSize=\(t.maxPacketSize)")

        let redacted = try redactSerial(transact(t, op: MTPOp.getDeviceInfo, tid: 0).data)
        let info = try DeviceInfo(decoding: redacted)
        try #require(info.serialNumber.allSatisfy { $0 == "X" })      // never write an unredacted fixture
        try writeFixture("pixel-deviceinfo.bin", redacted)
        print("SPIKE manufacturer=\(info.manufacturer) model=\(info.model) version=\(info.deviceVersion)")
        print("SPIKE vendorExtension=\(info.vendorExtensionDesc)")
        print("SPIKE ops " + info.operationsSupported.sorted().map { hex16($0) }.joined(separator: " "))
    }

    /// G-02-7: abandon a slow transaction with no Cancel (the pre-fix wedge), then reopen like Retry does.
    @Test func retryAfterAbandonedTransaction() async throws {
        let c = try findCandidate()
        do {
            let raw = try RawSession(openPlainThenSeize(c.id))
            var r = Reader(try raw.run(MTPOp.getStorageIDs))
            let storage = try #require(try r.u32Array().first, "no storages: is the phone unlocked?")
            // Parent 0 lists the whole storage recursively: slow on a real phone, so 0.1 s abandons it.
            #expect(throws: (any Error).self) {
                try transact(raw.transport, op: MTPOp.getObjectHandles, tid: raw.nextTID(),
                             params: [storage, 0, 0], timeout: 0.1)
            }
        }                                                   // transport released, no Cancel sent
        try await Task.sleep(for: .seconds(15))             // the phone finishes and blocks writing its reply

        let start = ContinuousClock.now
        let session = DeviceSession()
        try await session.openUSB(registryID: c.id, seize: true)
        _ = try await session.openSession()
        #expect(try await !session.storages().isEmpty)
        print("SPIKE retry after abandoned transaction recovered in \(ms(ContinuousClock.now - start)) ms")
        await session.close()
    }

    @Test func storagesAndRoot() async throws {
        let c = try findCandidate()
        let session = DeviceSession(transport: nil)
        try await session.openUSB(registryID: c.id, seize: true)
        _ = try await session.openSession()
        for s in try await session.storages() {
            print("SPIKE storage id=\(hex32(s.id)) type=\(s.storageType) free=\(s.freeSpace) capacity=\(s.maxCapacity) desc=\(s.description)")
        }
        await session.close()

        // Wire bytes of GetStorageIDs / GetStorageInfo for replay fixtures.
        var firstStorage: UInt32 = 0
        do {
            let rec = RecordingTransport(try USBTransport(registryID: c.id, seize: true))
            let raw = try RawSession(rec)
            rec.records = []
            let ids = try raw.run(MTPOp.getStorageIDs)
            try writeFixture("pixel-wire-getstorageids.bin", rec.records)
            try writeFixture("pixel-storageids.bin", ids)
            var r = Reader(ids)
            firstStorage = try #require(try r.u32Array().first, "no storages: is the phone unlocked?")
            rec.records = []
            let info = try raw.run(MTPOp.getStorageInfo, [firstStorage])
            try writeFixture("pixel-wire-getstorageinfo.bin", rec.records)
            try writeFixture("pixel-storageinfo.bin", info)
            raw.close()
        }

        let listing = DeviceSession(transport: nil)
        try await listing.openUSB(registryID: c.id, seize: true)
        _ = try await listing.openSession()
        let root = try await listing.children(storage: firstStorage)
        await listing.close()
        print("SPIKE root count=\(root.count) folders=\(root.filter(\.isFolder).count)")
        for e in root where e.size > 4_294_967_295 { print("SPIKE >4GB size=\(e.size)") }

        guard let dcim = root.first(where: { $0.name == "DCIM" && $0.isFolder }) else {
            print("SPIKE no DCIM at root"); return
        }
        let raw = try RawSession(USBTransport(registryID: c.id, seize: true))
        try writeFixture("pixel-objectinfo-dcim.bin", raw.run(MTPOp.getObjectInfo, [dcim.id]))
        raw.close()
    }

    @Test func dcimListingComparison() async throws {
        let c = try findCandidate()
        let session = DeviceSession(transport: nil)
        try await session.openUSB(registryID: c.id, seize: true)
        _ = try await session.openSession()
        let storage = try #require(try await session.storages().first)
        let dcim = try #require(try await session.children(storage: storage.id).first { $0.name == "DCIM" && $0.isFolder })
        let camera = try #require(try await session.children(storage: storage.id, parent: dcim.id).first { $0.name == "Camera" && $0.isFolder })
        let clock = ContinuousClock()
        var start = clock.now
        let perHandle = try await session.children(storage: storage.id, parent: camera.id)
        print("SPIKE per-handle count=\(perHandle.count) ms=\(ms(clock.now - start))")
        await session.close()

        // Pitfall 2: only ever a real folder handle here, never the all-objects handle.
        let cameraHandle = camera.id
        let raw = try RawSession(USBTransport(registryID: c.id, seize: true))
        start = clock.now
        let list = try transact(raw.transport, op: 0x9805, tid: raw.nextTID(), params: [cameraHandle, 0, 0xFFFF_FFFF, 0, 1], maxDataLength: 64 << 20, timeout: 60).data
        let elapsed = clock.now - start
        raw.close()
        print("SPIKE proplist count=\(try propListHandles(list).count) bytes=\(list.count) ms=\(ms(elapsed))")
    }

    /// BRWS-06 timing on a big folder, listed the way the app lists it: one GetObjectHandles, then `entries`
    /// in `Listing.batchSize` chunks. Make the folder with
    ///   adb shell 'mkdir -p /sdcard/BigTest && for i in $(seq 1 3000); do echo $i > /sdcard/BigTest/f$i.txt; done'
    /// GetObjectPropList is not timed: one all-or-nothing transaction conflicts with D-10 and BRWS-06.
    @Test func bigFolderListing() async throws {
        let c = try findCandidate()
        let session = DeviceSession(transport: nil)
        try await session.openUSB(registryID: c.id, seize: true)
        _ = try await session.openSession()
        let storage = try #require(try await session.storages().first)
        let name = ProcessInfo.processInfo.environment["MTP_BIG_FOLDER"] ?? "BigTest"
        let folder = try #require(try await session.children(storage: storage.id).first { $0.name == name && $0.isFolder },
                                  "no root folder named by MTP_BIG_FOLDER")
        let clock = ContinuousClock()
        let start = clock.now
        let handles = try await session.handles(storage: storage.id, parent: folder.id)
        let handlesDone = clock.now
        var firstBatch: Duration?
        var count = 0
        for i in stride(from: 0, to: handles.count, by: Listing.batchSize) {
            count += try await session.entries(Array(handles[i..<min(i + Listing.batchSize, handles.count)]),
                                               parent: folder.id).count
            if firstBatch == nil { firstBatch = clock.now - start }
        }
        let total = clock.now - start
        await session.close()
        let usPerItem = count == 0 ? 0 : Int(total / .microseconds(1)) / count
        print("SPIKE big-folder count=\(count) handles-ms=\(ms(handlesDone - start)) first-batch-ms=\(firstBatch.map(ms) ?? 0) total-ms=\(ms(total)) us-per-item=\(usPerItem)")
    }

    @Test func downloadThroughput() async throws {
        let c = try findCandidate()
        let session = DeviceSession(transport: nil)
        try await session.openUSB(registryID: c.id, seize: true)
        let info = try await session.openSession()
        let storage = try #require(try await session.storages().first)
        let dcim = try #require(try await session.children(storage: storage.id).first { $0.name == "DCIM" && $0.isFolder })
        let camera = try #require(try await session.children(storage: storage.id, parent: dcim.id).first { $0.name == "Camera" && $0.isFolder })
        let largest = try await session.children(storage: storage.id, parent: camera.id).filter { !$0.isFolder }.max { $0.size < $1.size }
        await session.close()

        let getPartialObject64: UInt16 = 0x95C1
        guard info.operationsSupported.contains(getPartialObject64) else { print("SPIKE no GetPartialObject64"); return }
        guard let file = largest else { print("SPIKE no files in DCIM/Camera"); return }

        let chunk: UInt64 = 8 << 20
        let total = min(file.size, 1 << 30)
        let raw = try RawSession(USBTransport(registryID: c.id, seize: true))
        let clock = ContinuousClock()
        let start = clock.now
        var offset: UInt64 = 0
        while offset < total {
            let want = min(chunk, total - offset)
            let got = try raw.run(getPartialObject64, [file.id, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), UInt32(want)],
                                  maxDataLength: Int(chunk))
            guard !got.isEmpty else { break }
            offset += UInt64(got.count)
        }
        let seconds = (clock.now - start) / .seconds(1)
        raw.close()
        print("SPIKE download fileSize=\(file.size) read=\(offset) ms=\(Int(seconds * 1000)) MB/s=\(String(format: "%.1f", Double(offset) / 1e6 / seconds))")
    }

    /// Declared last so it runs last: a hang here must not block the other findings.
    @Test func queueSharing() throws {
        let id = try findCandidate().id
        let queue = DispatchQueue(label: "spike.shared")
        let done = DispatchSemaphore(value: 0)
        queue.async {
            // Built inside the closure: the non-Sendable transport is never captured.
            do {
                let t = try USBTransport(registryID: id, seize: true, ioQueue: queue)
                print("SPIKE queue-sharing opened")
                _ = try transact(t, op: MTPOp.getDeviceInfo, tid: 0)
            } catch {
                print("SPIKE queue-sharing error \(error)")
            }
            done.signal()
        }
        print(done.wait(timeout: .now() + 10) == .success ? "SPIKE queue-sharing ok" : "SPIKE queue-sharing HANG")
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MTP_HW_BUSY"] == "1"), .timeLimit(.minutes(2)))
struct BusyDeviceSpike {
    @Test func busyRelease() async throws {
        let c = try findCandidate()
        print("SPIKE busy pids before=\(CameraDaemon.pids())")
        do {
            _ = try USBTransport(registryID: c.id, seize: false)        // released immediately
            print("SPIKE not-busy")
            return
        } catch let MTPError.exclusiveAccess(owner) {
            print("SPIKE busy plain-open exclusiveAccess owner=\(owner ?? "nil")")
        }
        let owners = ownerStrings(c.id)
        print("SPIKE busy owner iface=\(owners.iface ?? "nil") device=\(owners.device ?? "nil")")
        if ProcessInfo.processInfo.environment["MTP_HW_NOSIGNAL"] == "1" { return }   // observe only
        if owners.iface != nil || owners.device != nil {
            let text = "iface: \(owners.iface ?? "")\ndevice: \(owners.device ?? "")\n"
            try writeFixture("owner-busy.txt", Array(text.utf8))
        }

        do {
            _ = try USBTransport(registryID: c.id, seize: true)
            print("SPIKE busy seize-open ok")
            return
        } catch let MTPError.exclusiveAccess(owner) {
            print("SPIKE busy seize-open exclusiveAccess owner=\(owner ?? "nil")")
        }

        let pids = CameraDaemon.pids()
        guard !pids.isEmpty else { print("SPIKE busy no ptpcamerad pid"); return }
        for pid in pids { print("SPIKE sigterm pid=\(pid) errno=\(CameraDaemon.terminate(pid))") }

        let clock = ContinuousClock()
        let start = clock.now
        var lastError: (any Error)?
        for attempt in 1...20 {                                         // every 150 ms for ~3 s
            do {
                _ = try USBTransport(registryID: c.id, seize: false)
                print("SPIKE release-ok attempt=\(attempt) ms=\(ms(clock.now - start))")
                lastError = nil
                break
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        if let lastError { print("SPIKE release-failed last=\(lastError)") }
        print("SPIKE busy pids after=\(CameraDaemon.pids())")
    }
}

/// Phase 3 upload spike (03-02): the small path, the AOSP edit path (one past 4 GiB), a cancelled edit, and
/// 8 MiB-chunk upload throughput. Every object lives in AFTSpike and is deleted right after its readback, so at
/// most one 4 GiB + 1 file is on the phone at a time. Sends no class Cancel or Device Reset (T-03-08).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MTP_HW"] == "1"), .timeLimit(.minutes(20)))
struct UploadEditSpike {
    @Test func uploadPaths() throws {
        let id = try findCandidate().id
        var pass = false, outOfStep = false
        do {
            let spike = UploadSpike(try openDrained(id))
            spike.runAll()
            (pass, outOfStep) = (spike.pass, spike.outOfStep)
        }                                                   // interface released here
        if outOfStep {
            // Best effort through a fresh session; the next run also deletes a leftover AFTSpike first.
            print("SPIKE out of step: cleaning up through a fresh session")
            do {
                let cleanup = UploadSpike(try openDrained(id))
                cleanup.step("cleanup") { try cleanup.teardown() }
            } catch {
                print("SPIKE error step=cleanup-open detail=\((error as? MTPError)?.detail ?? String(describing: error))")
            }
        }
        print("SPIKE upload verdict \(pass ? "PASS" : "FAIL")")
        #expect(pass)
    }
}

/// ROADMAP SC3 / XFER-04 (03-08): 4 GiB − 1, 4 GiB, 4 GiB + 1 and 8 GiB files go Mac → phone → Mac through the app's
/// own engine (Transfer.planUpload/planDownload + Transfer.run), checked by ObjectSize and SHA-256. One file exists on
/// each side at a time; everything lives in AFTBig and a UUID scratch folder, both removed at the end (T-03-24/25).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MTP_HW"] == "1" && ProcessInfo.processInfo.environment["MTP_HW_BIG"] == "1"), .timeLimit(.minutes(120)))
struct BigFileRoundTrip {
    static let folderName = "AFTBig"
    static let sizes: [UInt64] = [4_294_967_295, 4_294_967_296, 4_294_967_297, 8_589_934_592]
    static let chunk = 8 << 20

    struct Failed: Error { var detail: String }

    @Test func roundTrip() async throws {
        let c = try findCandidate()
        let session = DeviceSession()
        try await session.openUSB(registryID: c.id, seize: true)
        _ = try await session.openSession()
        let storage = try #require(try await session.storages().first, "no storages: is the phone unlocked?")

        let base = ProcessInfo.processInfo.environment["MTP_HW_SCRATCH"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        let scratch = base.appending(component: UUID().uuidString)
        let up = scratch.appending(component: "up"), down = scratch.appending(component: "down")
        try FileManager.default.createDirectory(at: up, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: down, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let macFree = try scratch.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard storage.freeSpace >= 22_000_000_000, macFree >= 45_000_000_000 else {
            print("SPIKE big skip phone-free=\(storage.freeSpace) mac-free=\(macFree)")
            await session.close()
            return
        }

        // T-03-24: only a root folder named exactly AFTBig holding nothing but this test's big-*.bin files (a leftover
        // of this test) is ever deleted; one holding anything else may be the user's, so the test stops (IN-08).
        for old in try await session.children(storage: storage.id) where old.name == Self.folderName && old.isFolder {
            let inside = try await session.children(storage: storage.id, parent: old.id)
            guard inside.allSatisfy({ !$0.isFolder && $0.name.wholeMatch(of: /big-\d+\.bin/) != nil }) else {
                Issue.record("a root folder named AFTBig holds other items; move it away and run again")
                await session.close()
                return
            }
            try await session.delete(old.id)
            print("SPIKE big setup removed a leftover AFTBig")
        }
        let folder = try await session.makeFolder(storage: storage.id, parent: 0xFFFF_FFFF, name: Self.folderName)

        var pass = true
        for size in Self.sizes {
            do {
                if try await !roundTrip(size, storage: storage.id, folder: folder, up: up, down: down, session: session) {
                    pass = false
                }
            } catch {
                pass = false
                print("SPIKE error step=big-\(size) detail=\((error as? MTPError)?.detail ?? (error as? Failed)?.detail ?? String(describing: error))")
                if let e = error as? MTPError, !e.isResponse { break }   // out of step: the next run removes AFTBig
            }
        }
        do { try await session.delete(folder) } catch {
            pass = false
            print("SPIKE error step=big-teardown detail=\((error as? MTPError)?.detail ?? String(describing: error))")
        }
        await session.close()
        print("SPIKE big verdict \(pass ? "PASS" : "FAIL")")
        #expect(pass)
    }

    /// One size: write the Mac file, upload it, check ObjectSize, delete the source, download it back, hash it.
    /// True when both the size and the SHA-256 match. The phone object and the downloaded copy are deleted.
    private func roundTrip(_ size: UInt64, storage: UInt32, folder: UInt32, up: URL, down: URL,
                           session: DeviceSession) async throws -> Bool {
        let name = "big-\(size).bin"
        let source = up.appending(component: name)
        let sourceHash = try Self.write(source, size: size)
        let clock = ContinuousClock()

        let upPlan = try await Transfer.planUpload([source], storage: storage, parent: folder, session: session)
        var start = clock.now
        try Self.check(await Transfer.run(upPlan, session: session) { _ in }, "upload")
        let upSeconds = (clock.now - start) / .seconds(1)
        try FileManager.default.removeItem(at: source)

        let listed = try await session.children(storage: storage, parent: folder)
        let entry = try #require(listed.first { $0.name == name }, "uploaded file not listed")
        let sizeOK = entry.size == size                     // ObjectSize (0xDC04), not ObjectInfo's capped field

        let downPlan = try await Transfer.planDownload([entry], into: down, session: session)
        start = clock.now
        try Self.check(await Transfer.run(downPlan, session: session) { _ in }, "download")
        let downSeconds = (clock.now - start) / .seconds(1)
        let copy = down.appending(component: name)
        let shaOK = try Self.hash(copy) == sourceHash
        try FileManager.default.removeItem(at: copy)
        try await session.delete(entry.id)

        func mbps(_ s: Double) -> String { String(format: "%.1f", Double(size) / 1e6 / s) }
        print("SPIKE big size=\(size) up-MB/s=\(mbps(upSeconds)) down-MB/s=\(mbps(downSeconds)) size-ok=\(sizeOK) sha-match=\(shaOK)")
        return sizeOK && shaOK
    }

    /// The run finished every item with the session intact; a lost session is rethrown so the loop stops.
    private static func check(_ o: TransferOutcome, _ what: String) throws {
        #expect(o.failed.isEmpty && !o.cancelled)
        #expect(o.lost == nil)
        if let lost = o.lost { throw lost }
        if let f = o.failed.first {
            throw Failed(detail: "\(what): \(f.detail)")
        }
    }

    /// `size` bytes from one reused 8 MiB random block whose first 8 bytes carry the block index; returns the SHA-256.
    private static func write(_ url: URL, size: UInt64) throws -> SHA256.Digest {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw Failed(detail: "scratch file") }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        var rng = SystemRandomNumberGenerator()
        var block = (0..<chunk / 8).map { _ in rng.next() as UInt64 }.withUnsafeBytes { Data($0) }
        var hasher = SHA256()
        var index: UInt64 = 0, left = size
        while left > 0 {
            try autoreleasepool {                           // no autoreleased buffer outlives its block
                withUnsafeBytes(of: index.littleEndian) { block.replaceSubrange(0..<8, with: $0) }
                let piece = left >= UInt64(chunk) ? block : block.prefix(Int(left))
                hasher.update(data: piece)
                try file.write(contentsOf: piece)
                left -= UInt64(piece.count)
                index += 1
            }
        }
        return hasher.finalize()
    }

    /// SHA-256 of a file, streamed in 8 MiB reads.
    private static func hash(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: {
            guard let data = try file.read(upToCount: chunk), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize()
    }
}

/// Phase 4 replace probe (04-02): the AOSP behaviours the phone-side safe replace relies on (RESEARCH A1-A4, A10),
/// measured through the app's own DeviceSession. Everything is made inside DCIM/AFTProbe, removed at the end; a
/// leftover AFTProbe is deleted only when it holds nothing but probe files (T-04-07). Every finding line starts with
/// "SPIKE replace "; only the probe's own names are printed (T-04-08).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MTP_HW"] == "1"), .timeLimit(.minutes(20)))
struct ReplaceProbe {
    static let folderName = "AFTProbe"

    /// A probe file: `probe-…`, or a temp `.<UUID>.aft-upload` with an optional extension (the PASS-EXT form).
    static func isProbeFile(_ name: String) -> Bool {
        name.hasPrefix("probe-")
            || name.wholeMatch(of: /\.[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.aft-upload(\.[A-Za-z0-9]+)?/) != nil
    }

    @Test func probe() async throws {
        let c = try findCandidate()
        let session = DeviceSession()
        try await session.openUSB(registryID: c.id, seize: true)
        _ = try await session.openSession()
        let storage = try #require(try await session.storages().first, "no storages: is the phone unlocked?").id
        let dcim = try #require(try await session.children(storage: storage).first { $0.name == "DCIM" && $0.isFolder },
                                "no DCIM folder at the first storage's root").id

        // T-03-24 guard: only an AFTProbe holding nothing but probe files (a leftover of this probe) is deleted.
        for old in try await session.children(storage: storage, parent: dcim) where old.name == Self.folderName && old.isFolder {
            let inside = try await session.children(storage: storage, parent: old.id)
            guard inside.allSatisfy({ !$0.isFolder && Self.isProbeFile($0.name) }) else {
                Issue.record("DCIM/AFTProbe holds other items; move it away and run again")
                await session.close()
                return
            }
            try await session.delete(old.id)
            print("SPIKE replace setup removed a leftover AFTProbe")
        }
        let folder = try await session.makeFolder(storage: storage, parent: dcim, name: Self.folderName)
        print("SPIKE replace setup DCIM/AFTProbe created")

        let run = ReplaceRun(session, storage: storage, folder: folder)
        await run.runAll()

        // Teardown: through a fresh session if a step left this one out of step (handles survive Close/OpenSession).
        do {
            if run.outOfStep {
                print("SPIKE replace out of step: cleaning up through a fresh session")
                try await session.openUSB(registryID: c.id, seize: true)
                _ = try await session.openSession()
            }
            try await session.delete(folder)
            let left = try await session.children(storage: storage, parent: dcim).filter { $0.name == Self.folderName }.count
            print("SPIKE replace teardown left=\(left)")
            if left != 0 { print("SPIKE replace error step=teardown detail=AFTProbe still listed") }
        } catch {
            print("SPIKE replace error step=teardown detail=\((error as? MTPError)?.detail ?? String(describing: error))")
        }
        await session.close()

        let verdict = run.verdict
        print("SPIKE replace verdict \(verdict)")
        #expect(verdict != "FAIL")
    }
}

/// The ReplaceProbe steps over one DeviceSession. A step that fails prints `SPIKE replace error`; a non-response
/// error marks the session out of step and no further step runs.
private final class ReplaceRun {
    enum TempForm: String { case plain, ext }
    struct Failed: Error { var detail: String }
    static let chunk = 8 << 20

    let session: DeviceSession
    let storage: UInt32
    let folder: UInt32
    private let clock = ContinuousClock()
    private(set) var outOfStep = false

    // Findings behind the verdict.
    private var ontoExistingRefused = false
    private var handleKept = false
    private var smallForm: TempForm?, editForm: TempForm?
    private var smallRenamed = false, editRenamed = false
    private var raceOK = false
    private var bigOK = false

    init(_ session: DeviceSession, storage: UInt32, folder: UInt32) {
        self.session = session; self.storage = storage; self.folder = folder
    }

    /// PASS: AOSP behaviour throughout. PASS-EXT: the same, but DCIM took only the temp that keeps an extension.
    var verdict: String {
        guard ontoExistingRefused, handleKept, let smallForm, let editForm, smallRenamed, editRenamed, raceOK, bigOK
        else { return "FAIL" }
        return smallForm == .plain && editForm == .plain ? "PASS" : "PASS-EXT"
    }

    func runAll() async {
        await step("rename-onto-existing", renameOntoExisting)
        await step("rename-keeps-handle", renameKeepsHandle)
        await step("case-variant", caseVariant)
        await step("temp-small", tempSmall)
        await step("temp-edit", tempEdit)
        await step("delete-rename-race", deleteRenameRace)
        await step("small-files", smallFiles)
        await step("big-rename", bigRename)
    }

    private func step(_ name: String, _ body: () async throws -> Void) async {
        guard !outOfStep else { return }
        do { try await body() } catch {
            let mtp = error as? MTPError
            print("SPIKE replace error step=\(name) detail=\(mtp?.detail ?? (error as? Failed)?.detail ?? String(describing: error))")
            if let mtp, !mtp.isResponse { outOfStep = true }
        }
    }

    // MARK: Helpers

    /// The response code of one call (0x2001 on success); a non-response error is rethrown.
    private func code(_ body: () async throws -> Void) async throws -> UInt16 {
        do { try await body(); return MTPCode.ok } catch let MTPError.response(code, _) { return code }
    }

    private func list() async throws -> [ObjectEntry] { try await session.children(storage: storage, parent: folder) }

    private func create(_ name: String, size: Int) async throws -> UInt32 {
        try await session.createFile(storage: storage, parent: folder, name: name,
                                     contents: (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    }

    /// Every probe rename gets the finalize's 120 s, so a slow media scan can't poison the session mid-probe.
    private func rename(_ handle: UInt32, _ name: String) async throws {
        try await session.rename(handle, to: name, timeout: 120)
    }

    private func temp(_ form: TempForm, ext: String) -> String {
        form == .plain ? ".\(UUID().uuidString).aft-upload" : ".\(UUID().uuidString).aft-upload.\(ext)"
    }

    /// Edit-path upload of `size` bytes from `next` (≤ 8 MiB per call). A refused step closes the edit and deletes
    /// the object (D-09); a non-response error leaves it to the teardown.
    private func editUpload(_ name: String, size: UInt64, next: () throws -> [UInt8]) async throws -> UInt32 {
        let handle = try await session.createForEdit(storage: storage, parent: folder, name: name)
        do {
            var offset: UInt64 = 0
            while offset < size {
                let bytes = try next()
                guard !bytes.isEmpty else { throw Failed(detail: "source ended at \(offset) of \(size)") }
                try await session.writePartial(handle, offset: offset, bytes: bytes)
                offset += UInt64(bytes.count)
            }
            try await session.endEdit(handle)
        } catch {
            if let e = error as? MTPError, !e.isResponse { throw error }
            _ = try? await session.endEdit(handle)
            _ = try? await session.delete(handle)
            throw error
        }
        return handle
    }

    private lazy var pattern: [UInt8] = (0..<Self.chunk).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }

    // MARK: Steps

    /// A1: renaming onto a name already in the folder is refused (0x2002) and both objects stay.
    private func renameOntoExisting() async throws {
        let a = try await create("probe-a.txt", size: 10)
        let b = try await create("probe-b.txt", size: 20)
        let c = try await code { try await rename(b, "probe-a.txt") }
        let items = try await list()
        let ea = items.first { $0.id == a }, eb = items.first { $0.id == b }
        ontoExistingRefused = c == MTPCode.generalError && ea?.name == "probe-a.txt" && ea?.size == 10
            && eb?.name == "probe-b.txt" && eb?.size == 20
        print("SPIKE replace rename-onto-existing code=\(hex16(c)) a=\(ea.map { "\($0.name) size=\($0.size)" } ?? "gone") b=\(eb.map { "\($0.name) size=\($0.size)" } ?? "gone") both-kept=\(ontoExistingRefused)")
    }

    /// A1: a rename keeps the object's handle.
    private func renameKeepsHandle() async throws {
        guard let b = try await list().first(where: { $0.name == "probe-b.txt" })?.id else { throw Failed(detail: "probe-b.txt not listed") }
        let c = try await code { try await rename(b, "probe-c.txt") }
        let listed = try await list().first { $0.name == "probe-c.txt" }
        handleKept = c == MTPCode.ok && listed?.id == b
        print("SPIKE replace rename-keeps-handle code=\(hex16(c)) listed=\(listed != nil) handle-kept=\(handleKept)")
    }

    /// A3: what a case-variant rename does to the file it differs from only by case.
    private func caseVariant() async throws {
        let before = try await list()
        guard let src = before.first(where: { $0.name == "probe-c.txt" }),
              let a = before.first(where: { $0.name == "probe-a.txt" }) else { throw Failed(detail: "probe-c.txt or probe-a.txt not listed") }
        let c = try await code { try await rename(src.id, "PROBE-A.txt") }
        let after = try await list()
        let lower = after.first { $0.name == "probe-a.txt" }, upper = after.first { $0.name == "PROBE-A.txt" }
        let clobbered = c == MTPCode.ok && (lower == nil || lower?.size != a.size)
        print("SPIKE replace case-variant code=\(hex16(c)) probe-a.txt=\(lower.map { "listed size=\($0.size) handle-same=\($0.id == a.id)" } ?? "gone") PROBE-A.txt=\(upper.map { "listed size=\($0.size)" } ?? "absent") count=\(after.count) clobbered=\(clobbered)")
    }

    /// A2, D-22: a small-path temp in DCIM, then its rename to a visible .jpg.
    private func tempSmall() async throws {
        var made: (UInt32, TempForm)?
        for form in [TempForm.plain, .ext] {
            let name = temp(form, ext: "jpg")
            let c = try await code { made = (try await create(name, size: 1024), form) }
            print("SPIKE replace temp-small form=\(form) create=\(hex16(c))")
            if made != nil { break }
        }
        guard let (handle, form) = made else { return }
        smallForm = form
        let start = clock.now
        let c = try await code { try await rename(handle, "probe-small.jpg") }
        let elapsed = ms(clock.now - start)
        let kept = try await list().first { $0.name == "probe-small.jpg" }?.id == handle
        smallRenamed = c == MTPCode.ok && kept
        print("SPIKE replace temp-small rename code=\(hex16(c)) ms=\(elapsed) handle-kept=\(kept)")
    }

    /// A2, D-22: an edit-path temp (two 8 MiB chunks) in DCIM, then its rename to a visible .jpg.
    private func tempEdit() async throws {
        var made: (UInt32, TempForm)?
        for form in [TempForm.plain, .ext] {
            let name = temp(form, ext: "jpg")
            let c = try await code { made = (try await editUpload(name, size: UInt64(2 * Self.chunk)) { pattern }, form) }
            print("SPIKE replace temp-edit form=\(form) upload=\(hex16(c))")
            if made != nil { break }
        }
        guard let (handle, form) = made else { return }
        editForm = form
        let start = clock.now
        let c = try await code { try await rename(handle, "probe-edit.jpg") }
        let elapsed = ms(clock.now - start)
        let kept = try await list().first { $0.name == "probe-edit.jpg" }?.id == handle
        editRenamed = c == MTPCode.ok && kept
        print("SPIKE replace temp-edit rename code=\(hex16(c)) ms=\(elapsed) handle-kept=\(kept)")
    }

    /// A4, Pitfall 1, D-21/D-27: delete the original, then rename the temp onto its name, retrying only on 0x2002
    /// with waits of 50 ms × 2ⁿ, at most 6 retries (≈ 3.15 s of waiting).
    private func deleteRenameRace() async throws {
        guard let form = smallForm else { print("SPIKE replace delete-rename-race skipped: no temp form accepted"); return }
        var refusedRuns = 0, worstMs = 0, worstRetries = 0, neverRenamed = 0
        for run in 1...20 {
            let original = try await create("probe-race.jpg", size: 4096)
            let t = try await create(temp(form, ext: "jpg"), size: 4096)
            try await session.delete(original)
            let start = clock.now
            var retries = 0
            var c = try await code { try await rename(t, "probe-race.jpg") }
            while c == MTPCode.generalError, retries < 6 {
                try await Task.sleep(for: .milliseconds(50 << retries))
                retries += 1
                c = try await code { try await rename(t, "probe-race.jpg") }
            }
            let elapsed = ms(clock.now - start)
            print("SPIKE replace race run=\(run) retries=\(retries) code=\(hex16(c)) ms=\(elapsed)")
            if retries > 0 || c != MTPCode.ok { refusedRuns += 1 }
            if c != MTPCode.ok { neverRenamed += 1 }
            worstMs = max(worstMs, elapsed)
            worstRetries = max(worstRetries, retries)
            try await session.delete(t)                     // the result, or the temp if it never got the name
        }
        raceOK = neverRenamed == 0
        print("SPIKE replace race summary runs=20 refused-at-least-once=\(refusedRuns) worst-retries=\(worstRetries) worst-ms=\(worstMs) still-refused-after-6=\(neverRenamed)")
    }

    /// Open Question 5: 100 small files direct vs 100 through a temp + rename.
    private func smallFiles() async throws {
        guard let form = smallForm else { print("SPIKE replace small-files skipped: no temp form accepted"); return }
        var start = clock.now
        for i in 0..<100 { _ = try await create("probe-d-\(i).bin", size: 4096) }
        let direct = ms(clock.now - start)
        start = clock.now
        for i in 0..<100 {
            let t = try await create(temp(form, ext: "bin"), size: 4096)
            try await rename(t, "probe-t-\(i).bin")
        }
        let viaTemp = ms(clock.now - start)
        print("SPIKE replace small-files direct-ms-per-file=\(String(format: "%.1f", Double(direct) / 100)) temp-ms-per-file=\(String(format: "%.1f", Double(viaTemp) / 100)) ratio=\(String(format: "%.2f", Double(viaTemp) / Double(max(direct, 1))))")
    }

    /// A10: a ~1 GiB edit-path temp renamed to a visible .mp4 (or the MTP_HW_VIDEO file under its own extension;
    /// a real video's metadata scan is the slow case). The rename must finish within the finalize's 120 s.
    private func bigRename() async throws {
        guard let form = editForm else { print("SPIKE replace big-rename skipped: no temp form accepted"); return }
        let handle: UInt32, ext: String
        if let path = ProcessInfo.processInfo.environment["MTP_HW_VIDEO"] {
            let url = URL(filePath: path)
            ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
            let size = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).uint64Value
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            print("SPIKE replace big-rename source=video ext=\(ext) size=\(size)")
            let start = clock.now
            handle = try await editUpload(temp(form, ext: ext), size: size) {
                try autoreleasepool { try file.read(upToCount: Self.chunk).map { [UInt8]($0) } ?? [] }
            }
            print("SPIKE replace big-rename upload-ms=\(ms(clock.now - start))")
        } else {
            ext = "mp4"
            let size = UInt64(128 * Self.chunk)             // 1 GiB
            print("SPIKE replace big-rename source=random ext=\(ext) size=\(size)")
            let start = clock.now
            handle = try await editUpload(temp(form, ext: ext), size: size) { pattern }
            print("SPIKE replace big-rename upload-ms=\(ms(clock.now - start))")
        }
        let start = clock.now
        let c = try await code { try await rename(handle, "probe-big.\(ext)") }
        let elapsed = ms(clock.now - start)
        bigOK = c == MTPCode.ok && elapsed < 120_000
        print("SPIKE replace big-rename code=\(hex16(c)) rename-ms=\(elapsed)")
    }
}

/// Phase 5 move probe (05-02): the AOSP doMoveObject behaviours Move.plan/perform rely on (RESEARCH A1, A2), measured
/// through the app's own DeviceSession. Everything is made inside DCIM/AFTMoveProbe and removed at the end, plus one
/// hidden `.probe-root-<UUID>.txt` that visits the storage root and comes back. A leftover AFTMoveProbe is deleted only
/// when it holds nothing but probe items (T-03-24). Every finding line starts with "SPIKE move "; only the probe's own
/// names are printed (T-05-08).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MTP_HW"] == "1"), .timeLimit(.minutes(30)))
struct MoveProbe {
    static let folderName = "AFTMoveProbe"
    static let probeFolders: Set<String> = ["A", "B", "Sub", "Many"]

    static func isRootProbe(_ name: String) -> Bool {
        name.wholeMatch(of: /\.probe-root-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.txt/) != nil
    }

    /// Whether everything under `folder` carries a probe name (`probe-` any case, the root visitor, the probe folders).
    private func onlyProbeItems(_ session: DeviceSession, storage: UInt32, in folder: UInt32) async throws -> Bool {
        for item in try await session.children(storage: storage, parent: folder) {
            if item.isFolder {
                guard Self.probeFolders.contains(item.name),
                      try await onlyProbeItems(session, storage: storage, in: item.id) else { return false }
            } else if !item.name.lowercased().hasPrefix("probe-") && !Self.isRootProbe(item.name) {
                return false
            }
        }
        return true
    }

    @Test func probe() async throws {
        let c = try findCandidate()
        let session = DeviceSession()
        try await session.openUSB(registryID: c.id, seize: true)
        _ = try await session.openSession()
        let storage = try #require(try await session.storages().first, "no storages: is the phone unlocked?").id
        let dcim = try #require(try await session.children(storage: storage).first { $0.name == "DCIM" && $0.isFolder },
                                "no DCIM folder at the first storage's root").id

        // T-03-24 guard: only an AFTMoveProbe holding nothing but probe items (a leftover of this probe) is deleted.
        for old in try await session.children(storage: storage, parent: dcim) where old.name == Self.folderName && old.isFolder {
            guard try await onlyProbeItems(session, storage: storage, in: old.id) else {
                Issue.record("DCIM/AFTMoveProbe holds other items; move it away and run again")
                await session.close()
                return
            }
            try await session.delete(old.id)
            print("SPIKE move setup removed a leftover AFTMoveProbe")
        }
        let folder = try await session.makeFolder(storage: storage, parent: dcim, name: Self.folderName)
        let run = MoveRun(session, storage: storage, folder: folder)
        await run.setUp()
        await run.runAll()

        // Teardown: through a fresh session if a step left this one out of step (handles survive Close/OpenSession).
        do {
            if run.outOfStep {
                print("SPIKE move out of step: cleaning up through a fresh session")
                try await session.openUSB(registryID: c.id, seize: true)
                _ = try await session.openSession()
            }
            try await session.delete(folder)
            for visitor in try await session.children(storage: storage) where Self.isRootProbe(visitor.name) {
                try await session.delete(visitor.id)
                print("SPIKE move teardown removed the root visitor")
            }
            let left = try await session.children(storage: storage, parent: dcim).filter { $0.name == Self.folderName }.count
            print("SPIKE move teardown left=\(left)")
            if left != 0 { print("SPIKE move error step=teardown detail=AFTMoveProbe still listed") }
        } catch {
            print("SPIKE move error step=teardown detail=\((error as? MTPError)?.detail ?? String(describing: error))")
        }
        await session.close()

        let verdict = run.verdict
        print("SPIKE move verdict \(verdict)")
        #expect(verdict != "FAIL")
    }
}

/// The MoveProbe steps over one DeviceSession. A step that fails prints `SPIKE move error`; a non-response error marks
/// the session out of step and no further step runs.
private final class MoveRun {
    struct Failed: Error { var detail: String }
    static let root = UInt32(0xFFFF_FFFF)

    let session: DeviceSession
    let storage: UInt32
    let folder: UInt32
    private let clock = ContinuousClock()
    private(set) var outOfStep = false
    private var a: UInt32 = 0, b: UInt32 = 0, sub: UInt32 = 0, many: UInt32 = 0
    private var ready = false

    // Findings behind the verdict.
    private var fileHandleKept = false
    private var rootOK = false
    private var exactRefused = false
    private var subtreeRefused = false
    private var raceOK = false
    private var bigOK = false

    init(_ session: DeviceSession, storage: UInt32, folder: UInt32) {
        self.session = session; self.storage = storage; self.folder = folder
    }

    /// PASS: AOSP behaviour throughout. The case-variant result is recorded, not judged: Move.plan never sends one.
    var verdict: String {
        fileHandleKept && rootOK && exactRefused && subtreeRefused && raceOK && bigOK ? "PASS" : "FAIL"
    }

    func setUp() async {
        await step("setup") {
            a = try await session.makeFolder(storage: storage, parent: folder, name: "A")
            b = try await session.makeFolder(storage: storage, parent: folder, name: "B")
            sub = try await session.makeFolder(storage: storage, parent: a, name: "Sub")
            many = try await session.makeFolder(storage: storage, parent: a, name: "Many")
            _ = try await create("probe-1.txt", in: a, size: 10)
            _ = try await create("probe-2.txt", in: a, size: 20)
            _ = try await create("probe-2.txt", in: b, size: 30)
            _ = try await create("probe-case.txt", in: a, size: 40)
            _ = try await create("PROBE-CASE.txt", in: b, size: 50)
            let count = Int(ProcessInfo.processInfo.environment["MTP_HW_MOVE_FILES"] ?? "") ?? 1000
            let start = clock.now
            for i in 0..<count { _ = try await create("probe-many-\(i).bin", in: many, size: 1024) }
            print("SPIKE move setup DCIM/AFTMoveProbe created many-files=\(count) many-ms=\(ms(clock.now - start))")
            ready = true
        }
    }

    func runAll() async {
        guard ready else { return }
        await step("move-file", moveFile)
        await step("move-root", moveRoot)
        await step("exact-clash", exactClash)
        await step("delete-then-move", deleteThenMove)
        await step("big-folder", bigFolder)
        // Last: on the MIX 4 these left the phone answering 0x0000 to later ops (05-MOVE-PROBE run 1).
        await step("own-subtree", ownSubtree)
        await step("case-variant", caseVariant)
    }

    private func step(_ name: String, _ body: () async throws -> Void) async {
        guard !outOfStep else { return }
        do { try await body() } catch {
            let mtp = error as? MTPError
            print("SPIKE move error step=\(name) detail=\(mtp?.detail ?? (error as? Failed)?.detail ?? String(describing: error))")
            if let mtp, !mtp.isResponse { outOfStep = true }
        }
    }

    // MARK: Helpers

    /// The response code of one call (0x2001 on success); a non-response error is rethrown.
    private func code(_ body: () async throws -> Void) async throws -> UInt16 {
        do { try await body(); return MTPCode.ok } catch let MTPError.response(code, _) { return code }
    }

    private func create(_ name: String, in parent: UInt32, size: Int) async throws -> UInt32 {
        try await session.createFile(storage: storage, parent: parent, name: name,
                                     contents: (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    }

    private func list(_ parent: UInt32) async throws -> [ObjectEntry] { try await session.children(storage: storage, parent: parent) }

    private func named(_ name: String, in parent: UInt32) async throws -> ObjectEntry {
        guard let e = try await list(parent).first(where: { $0.name == name }) else { throw Failed(detail: "\(name) not listed") }
        return e
    }

    private func move(_ handle: UInt32, to parent: UInt32) async throws {
        try await session.move(handle, storage: storage, to: parent)
    }

    // MARK: Steps

    /// A1: a move keeps the handle; how many events the phone sends for the app's own move (RESEARCH: none).
    private func moveFile() async throws {
        let h = try await named("probe-1.txt", in: a).id
        let events = session.events
        let arrivals = Task {
            var at: [ContinuousClock.Instant] = []
            for await _ in events { at.append(ContinuousClock.now) }
            return at
        }
        try await Task.sleep(for: .milliseconds(200))       // any backlog from the setup arrives before `start`
        let start = clock.now
        let c = try await code { try await move(h, to: b) }
        let elapsed = ms(clock.now - start)
        try await Task.sleep(for: .seconds(2))
        arrivals.cancel()
        let count = await arrivals.value.filter { $0 >= start }.count
        let parent = try await session.entry(h)?.parent
        fileHandleKept = c == MTPCode.ok && parent == b
        print("SPIKE move move-file code=\(hex16(c)) ms=\(elapsed) handle-kept=\(fileHandleKept) events-2s=\(count)")
    }

    /// Pitfall 10: the storage root is parent 0 (DeviceSession.move sends 0 for 0xFFFFFFFF); then back again.
    private func moveRoot() async throws {
        let h = try await named("probe-1.txt", in: b).id
        let visitor = ".probe-root-\(UUID().uuidString).txt"
        try await session.rename(h, to: visitor, timeout: 120)
        let c = try await code { try await move(h, to: Self.root) }
        let atRoot = try await session.entry(h)?.parent == Self.root
        let back = try await code { try await move(h, to: b) }
        let renamed = try await code { try await session.rename(h, to: "probe-1.txt", timeout: 120) }
        rootOK = c == MTPCode.ok && atRoot && back == MTPCode.ok && renamed == MTPCode.ok
        print("SPIKE move move-root code=\(hex16(c)) at-root=\(atRoot) back=\(hex16(back)) renamed-back=\(hex16(renamed))")
    }

    /// A1: an exact name in the destination is refused (0x2002) and both objects stay.
    private func exactClash() async throws {
        let h = try await named("probe-2.txt", in: a).id
        let c = try await code { try await move(h, to: b) }
        let inA = try await list(a).first { $0.name == "probe-2.txt" }, inB = try await list(b).first { $0.name == "probe-2.txt" }
        exactRefused = c == MTPCode.generalError && inA?.size == 20 && inB?.size == 30
        print("SPIKE move exact-clash code=\(hex16(c)) a=\(inA.map { "size=\($0.size)" } ?? "gone") b=\(inB.map { "size=\($0.size)" } ?? "gone") both-kept=\(exactRefused)")
    }

    /// Pitfall 11: does a case-variant move overwrite, as AOSP's rename(2) would? Recorded, not judged.
    private func caseVariant() async throws {
        let h = try await named("probe-case.txt", in: a).id
        let c = try await code { try await move(h, to: b) }
        let inB = try await list(b)
        let upper = inB.first { $0.name == "PROBE-CASE.txt" }, lower = inB.first { $0.name == "probe-case.txt" }
        print("SPIKE move case-variant code=\(hex16(c)) PROBE-CASE.txt=\(upper.map { "listed size=\($0.size)" } ?? "gone") probe-case.txt-in-B=\(lower != nil) clobbered=\(c == MTPCode.ok && upper?.size != 50)")
    }

    /// RESEARCH Pattern 5 fact 5: a folder into its own subtree is refused and nothing changes.
    private func ownSubtree() async throws {
        let c = try await code { try await move(a, to: sub) }
        print("SPIKE move own-subtree move-code=\(hex16(c))")
        do {
            let aParent = try await session.entry(a)?.parent, subParent = try await session.entry(sub)?.parent
            subtreeRefused = c != MTPCode.ok && aParent == folder && subParent == a
            print("SPIKE move own-subtree code=\(hex16(c)) unchanged=\(aParent == folder && subParent == a)")
        } catch let e as MTPError where !e.isResponse {
            // Refused, then 0x0000 (MTPError.malformed): the MIX 4 behaviour Move.swift treats as a lost session.
            subtreeRefused = c != MTPCode.ok
            print("SPIKE move own-subtree follow-up read lost the session: \(e.detail)")
            outOfStep = true                            // the teardown opens a fresh session
        }
    }

    /// FROZEN_ONESHOT_DEL: delete a name in B, then move the same name in from A, retrying only on 0x2002 with waits
    /// of 50 ms × 2ⁿ, at most 6 retries (Move.perform's Replace rule).
    private func deleteThenMove() async throws {
        var failedRuns = 0
        for run in 1...5 {
            let name = "probe-race-\(run).txt"         // a fresh name per run: the last run's delete may still be cached
            let old = try await create(name, in: b, size: 60)
            let h = try await create(name, in: a, size: 70)
            try await session.delete(old)
            let start = clock.now
            var retries = 0
            var c = try await code { try await move(h, to: b) }
            while c == MTPCode.generalError, retries < 6 {
                try await Task.sleep(for: .milliseconds(50 << retries))
                retries += 1
                c = try await code { try await move(h, to: b) }
            }
            print("SPIKE move race run=\(run) refusals=\(retries) code=\(hex16(c)) ms=\(ms(clock.now - start))")
            if c != MTPCode.ok { failedRuns += 1 }
            try await session.delete(h)                      // the moved file, or the one left in A
        }
        raceOK = failedRuns == 0
        print("SPIKE move race summary runs=5 still-refused-after-6=\(failedRuns)")
    }

    /// A2: a big folder's move finishes within the 120 s timeout and keeps its handle.
    private func bigFolder() async throws {
        let start = clock.now
        let c = try await code { try await move(many, to: b) }
        let elapsed = ms(clock.now - start)
        let kept = try await session.entry(many)?.parent == b
        bigOK = c == MTPCode.ok && elapsed < 120_000 && kept
        print("SPIKE move big-folder code=\(hex16(c)) ms=\(elapsed) handle-kept=\(kept)")
    }
}

// MARK: - Helpers

private struct Candidate { let id: UInt64; let props: InterfaceProperties }

/// Logs every non-Apple USB interface and returns the MTP one (or the RESEARCH Pattern 5 fallback).
private func findCandidate() throws -> Candidate {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iter) == KERN_SUCCESS else {
        throw MTPError.deviceGone
    }
    defer { IOObjectRelease(iter) }
    var match: Candidate?
    var fallback: Candidate?
    while case let s = IOIteratorNext(iter), s != 0 {
        defer { IOObjectRelease(s) }
        let p = DeviceWatcher.interfaceProperties(s)
        guard p.vendorID != 0x05AC else { continue }
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(s, &id)
        let product = (DeviceWatcher.deviceProperty(s, "idProduct") as? NSNumber)?.uint16Value ?? 0
        let name = DeviceWatcher.deviceProperty(s, "kUSBProductString") as? String
        let owner = DeviceWatcher.interfaceProperty(s, "UsbExclusiveOwner") as? String
        print("SPIKE iface class=\(hex8(p.interfaceClass))/\(hex8(p.interfaceSubClass))/\(hex8(p.interfaceProtocol)) endpoints=\(p.numEndpoints) string=\(p.interfaceString ?? "nil") vendor=\(hex16(p.vendorID)) product=\(hex16(product)) productName=\(name ?? "nil") registryID=\(hex64(id)) owner=\(owner ?? "nil")")
        let c = Candidate(id: id, props: p)
        if match == nil, isMTPInterface(p) { match = c }
        if fallback == nil, (p.interfaceClass, p.interfaceSubClass, p.interfaceProtocol) == (0x06, 0x01, 0x01), p.numEndpoints == 3 {
            fallback = c
        }
    }
    if let match { return match }
    let fb = try #require(fallback, "no MTP interface: plug in, unlock, and choose File transfer on the phone")
    print("SPIKE MATCHER MISS \(fb.props)")
    return fb
}

private func openPlainThenSeize(_ id: UInt64) throws -> USBTransport {
    do {
        let t = try USBTransport(registryID: id, seize: false)
        print("SPIKE plain-open ok")
        return t
    } catch let MTPError.exclusiveAccess(owner) {
        print("SPIKE plain-open exclusive owner=\(owner ?? "nil")")
    }
    do {
        let t = try USBTransport(registryID: id, seize: true)
        print("SPIKE seize-open ok")
        return t
    } catch {
        print("SPIKE seize-open failed \(error)")
        throw error
    }
}

/// UsbExclusiveOwner read separately from the interface and from its parent device.
private func ownerStrings(_ id: UInt64) -> (iface: String?, device: String?) {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
    guard svc != 0 else { return (nil, nil) }
    defer { IOObjectRelease(svc) }
    let iface = DeviceWatcher.interfaceProperty(svc, "UsbExclusiveOwner") as? String
    var parent: io_registry_entry_t = 0
    guard IORegistryEntryGetParentEntry(svc, kIOServicePlane, &parent) == KERN_SUCCESS else { return (iface, nil) }
    defer { IOObjectRelease(parent) }
    return (iface, DeviceWatcher.interfaceProperty(parent, "UsbExclusiveOwner") as? String)
}

/// Overwrites every UTF-16 unit of the DeviceInfo serial number (the last string) with "X",
/// keeping the trailing NUL, so the fixture can be committed.
private func redactSerial(_ bytes: [UInt8]) throws -> [UInt8] {
    var r = Reader(bytes)
    _ = try r.u16(); _ = try r.u32(); _ = try r.u16(); _ = try r.string(); _ = try r.u16()
    for _ in 0..<5 { _ = try r.u16Array() }
    for _ in 0..<3 { _ = try r.string() }          // manufacturer, model, device version
    let start = r.i
    _ = try r.string()                               // bounds-checks the serial before editing
    let n = Int(bytes[start])
    var out = bytes
    let hasNUL = n > 0 && bytes[start + 2 * n - 1] == 0 && bytes[start + 2 * n] == 0
    for k in 0..<(hasNUL ? n - 1 : n) {
        out[start + 1 + 2 * k] = 0x58
        out[start + 2 + 2 * k] = 0x00
    }
    return out
}

/// Distinct object handles in an ObjectPropList dataset.
private func propListHandles(_ bytes: [UInt8]) throws -> Set<UInt32> {
    var r = Reader(bytes)
    let count = try r.u32()
    var handles = Set<UInt32>()
    for _ in 0..<count {
        handles.insert(try r.u32())
        _ = try r.u16()                              // property code
        let type = try r.u16()
        switch type {
        case 0xFFFF:
            _ = try r.string()
        case let t where t & 0x4000 != 0:
            let n = Int(try r.u32())
            try skip(&r, n * scalarSize(t & ~0x4000))
        default:
            try skip(&r, scalarSize(type))
        }
    }
    return handles
}

private func scalarSize(_ type: UInt16) throws -> Int {
    switch type {
    case 0x0001, 0x0002: return 1
    case 0x0003, 0x0004: return 2
    case 0x0005, 0x0006: return 4
    case 0x0007, 0x0008: return 8
    case 0x0009, 0x000A: return 16
    default: throw MTPError.malformed("datatype \(hex16(type))")
    }
}

private func skip(_ r: inout Reader, _ n: Int) throws {
    guard n >= 0, n <= r.remaining else { throw MTPError.malformed("truncated") }
    r.i += n
}

private func writeFixture(_ name: String, _ bytes: [UInt8]) throws {
    let dir = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(bytes).write(to: dir.appending(path: name))
    print("SPIKE fixture \(name) \(bytes.count) bytes")
}

/// Opens a RawSession after draining any reply a previous run left the phone blocked writing (G-02-7).
private func openDrained(_ id: UInt64) throws -> RawSession {
    let t = try USBTransport(registryID: id, seize: true)
    t.cancelTransaction(0)
    return try RawSession(t)
}

private func ms(_ d: Duration) -> Int { Int(d / .milliseconds(1)) }
private func hex8(_ v: UInt8) -> String { String(format: "0x%02X", v) }
private func hex16(_ v: UInt16) -> String { String(format: "0x%04X", v) }
private func hex32(_ v: UInt32) -> String { String(format: "0x%08X", v) }
private func hex64(_ v: UInt64) -> String { String(format: "0x%016llX", v) }

/// A bare MTP session over one transport (OpenSession recovering 0x201E, then numbered transactions).
private final class RawSession {
    let transport: any MTPTransport
    private var tid: UInt32 = 1

    init(_ transport: any MTPTransport) throws {
        self.transport = transport
        do {
            _ = try transact(transport, op: MTPOp.openSession, tid: 0, params: [1])
        } catch MTPError.response(code: MTPCode.sessionAlreadyOpen, op: _) {
            _ = try transact(transport, op: MTPOp.closeSession, tid: 0)
            _ = try transact(transport, op: MTPOp.openSession, tid: 0, params: [1])
        }
    }

    func nextTID() -> UInt32 { defer { tid += 1 }; return tid }

    func run(_ op: UInt16, _ params: [UInt32] = [], dataOut: [UInt8]? = nil, maxDataLength: Int = 16 << 20,
             timeout: TimeInterval = 5) throws -> [UInt8] {
        try call(op, params, dataOut: dataOut, maxDataLength: maxDataLength, timeout: timeout).data
    }

    /// `run` that also returns the response parameters.
    func call(_ op: UInt16, _ params: [UInt32] = [], dataOut: [UInt8]? = nil, maxDataLength: Int = 16 << 20,
              timeout: TimeInterval = 5) throws -> (data: [UInt8], params: [UInt32]) {
        try transact(transport, op: op, tid: nextTID(), params: params, dataOut: dataOut,
                     maxDataLength: maxDataLength, timeout: timeout)
    }

    func close() { _ = try? transact(transport, op: MTPOp.closeSession, tid: nextTID()) }
}

// MARK: - Upload spike

private enum UploadOp {
    static let sendObject: UInt16 = 0x100D
    static let sendPartialObject: UInt16 = 0x95C2
    static let beginEditObject: UInt16 = 0x95C4
    static let endEditObject: UInt16 = 0x95C5
}

/// The UploadEditSpike steps over one RawSession. `pass` turns false on any mismatch or error; `outOfStep` on a
/// non-response error, after which no further step runs.
private final class UploadSpike {
    static let folderName = "AFTSpike"
    static let chunk = 8 << 20

    let raw: RawSession
    private let clock = ContinuousClock()
    private var storage: UInt32 = 0
    private var folder: UInt32 = 0
    private(set) var pass = true
    private(set) var outOfStep = false
    /// Deterministic content: block i is this 8 MiB pattern with i (u64 LE) in its first 8 bytes.
    private let pattern: [UInt8] = (0..<UploadSpike.chunk).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }

    init(_ raw: RawSession) { self.raw = raw }

    func runAll() {
        guard step("setup", setUp) else { return }
        for n in [0, 500, 16_372, 16_373, Self.chunk] { step("small-\(n)") { try small(n) } }
        for n: UInt64 in [500, 16_372, 16_373, UInt64(Self.chunk), (20 << 20) + 3, 4_294_967_297] {
            step("edit-\(n)") { try edit(n) }
        }
        step("cancel", cancel)
        step("edit-gap", gapProbe)                        // last before teardown: it sends a deliberately bad chunk
        step("teardown", teardown)
        if !outOfStep { raw.close() }
    }

    /// Runs one step; prints `SPIKE error` on failure. Returns false if it failed or the session is out of step.
    @discardableResult
    func step(_ name: String, _ body: () throws -> Void) -> Bool {
        guard !outOfStep else { return false }
        do { try body(); return true } catch {
            pass = false
            let mtp = error as? MTPError
            print("SPIKE error step=\(name) detail=\(mtp?.detail ?? String(describing: error))")
            if mtp?.isResponse != true { outOfStep = true }
            return false
        }
    }

    private func setUp() throws {
        for handle in try spikeFolders() {
            _ = try raw.run(MTPOp.deleteObject, [handle], timeout: 120)
            print("SPIKE setup removed a leftover AFTSpike")
        }
        folder = try sendInfo(name: Self.folderName, format: 0x3001, size: 0, parent: 0xFFFF_FFFF)
        print("SPIKE setup storage=\(hex32(storage)) AFTSpike created")
    }

    func teardown() throws {
        let found = try spikeFolders()
        for handle in found { _ = try raw.run(MTPOp.deleteObject, [handle], timeout: 120) }
        let left = try spikeFolders().count
        print("SPIKE teardown removed=\(found.count) left=\(left)")
        if left != 0 { pass = false }
    }

    /// Root objects of the first storage named exactly AFTSpike (T-03-11: nothing else is ever deleted).
    private func spikeFolders() throws -> [UInt32] {
        if storage == 0 {
            var r = Reader(try raw.run(MTPOp.getStorageIDs))
            guard let first = try r.u32Array().first else { throw MTPError.malformed("no storages: is the phone unlocked?") }
            storage = first
        }
        var r = Reader(try raw.run(MTPOp.getObjectHandles, [storage, 0, 0xFFFF_FFFF], timeout: 30))
        return try r.u32Array().filter {
            try ObjectInfo(decoding: raw.run(MTPOp.getObjectInfo, [$0])).filename == Self.folderName
        }
    }

    /// SendObjectInfo with no dates (D-15), like `DeviceSession.makeFolder`; returns the new handle.
    private func sendInfo(name: String, format: UInt16 = 0x3000, size: UInt32, parent: UInt32? = nil) throws -> UInt32 {
        let parent = parent ?? folder
        var p = Payload()
        p.u32(storage); p.u16(format); p.u16(0)         // storage, format, protection
        p.u32(size); p.u16(0)                           // compressed size, thumb format
        for _ in 0..<6 { p.u32(0) }                     // thumb size/w/h, image w/h/depth
        p.u32(parent); p.u16(format == 0x3001 ? 1 : 0); p.u32(0); p.u32(0)
        p.string(name); p.string(""); p.string(""); p.string("")
        let ps = try raw.call(MTPOp.sendObjectInfo, [storage, parent], dataOut: p.bytes).params
        guard ps.count >= 3 else { throw MTPError.malformed("SendObjectInfo response has \(ps.count) params") }
        return ps[2]
    }

    private func block(_ index: Int, count: Int) -> [UInt8] {
        var b = Array(pattern.prefix(count))
        withUnsafeBytes(of: UInt64(index).littleEndian) { i in for k in 0..<min(8, count) { b[k] = i[k] } }
        return b
    }

    /// ObjectSize (0xDC04, u64) and the SHA-256 of the object read back in 8 MiB GetPartialObject64 chunks.
    private func readback(_ handle: UInt32) throws -> (size: UInt64, hash: SHA256.Digest) {
        var r = Reader(try raw.run(MTPOp.getObjectPropValue, [handle, 0xDC04]))
        let size = try r.u64()
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < size {
            let want = UInt32(min(UInt64(Self.chunk), size - offset))
            let got = try raw.run(MTPOp.getPartialObject64, [handle, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), want],
                                  maxDataLength: Int(want), timeout: 10)
            guard !got.isEmpty else { break }
            hasher.update(data: got)
            offset += UInt64(got.count)
        }
        return (size, hasher.finalize())
    }

    private func delete(_ handle: UInt32) throws { _ = try raw.run(MTPOp.deleteObject, [handle], timeout: 120) }

    /// Small path: SendObjectInfo with the exact size, then the whole file in one SendObject (Pattern 5).
    private func small(_ n: Int) throws {
        let data = block(0, count: n)
        let start = clock.now
        let handle = try sendInfo(name: "small-\(n).bin", size: UInt32(n))
        _ = try raw.run(UploadOp.sendObject, dataOut: data, timeout: 120)      // waits for the MediaStore scan (Pitfall 7)
        let elapsed = ms(clock.now - start)
        let back = Result { try readback(handle) }
        try delete(handle)
        let (size, hash) = try back.get()
        let sizeOK = size == UInt64(n), hashOK = hash == SHA256.hash(data: data)
        print("SPIKE small size=\(n) size-ok=\(sizeOK) hash-ok=\(hashOK) ms=\(elapsed)")
        if !(sizeOK && hashOK) { pass = false }
    }

    /// Edit path: an empty object (size 0 + empty SendObject), opened with BeginEditObject.
    private func createForEdit(_ name: String) throws -> UInt32 {
        let handle = try sendInfo(name: name, size: 0)
        _ = try raw.run(UploadOp.sendObject, dataOut: [], timeout: 120)
        _ = try raw.run(UploadOp.beginEditObject, [handle])
        return handle
    }

    /// One SendPartialObject: u64 offset as low and high u32. 10 s: the production chunk bound (D-10).
    private func writePartial(_ handle: UInt32, _ offset: UInt64, _ data: [UInt8]) throws -> [UInt32] {
        try raw.call(UploadOp.sendPartialObject, [handle, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), UInt32(data.count)],
                     dataOut: data, timeout: 10).params
    }

    private func endEdit(_ handle: UInt32) throws { _ = try raw.run(UploadOp.endEditObject, [handle], timeout: 120) }

    private func edit(_ size: UInt64) throws {
        let handle = try createForEdit("edit-\(size).bin")
        var offset: UInt64 = 0, index = 0, maxHigh: UInt32 = 0
        var hasher = SHA256()
        let start = clock.now
        do {
            while offset < size {
                let n = Int(min(UInt64(Self.chunk), size - offset))
                let data = block(index, count: n)
                hasher.update(data: data)
                let ps = try writePartial(handle, offset, data)
                if index == 0 { print("SPIKE edit first-chunk-param=\(ps.first.map { String($0) } ?? "none") sent=\(n)") }
                maxHigh = max(maxHigh, UInt32(offset >> 32))
                offset += UInt64(n)
                index += 1
            }
        } catch let e as MTPError where e.isResponse {      // refused chunk: close the edit and drop the object (D-09)
            _ = try? endEdit(handle); _ = try? delete(handle)
            throw e
        }
        let seconds = (clock.now - start) / .seconds(1)
        let endStart = clock.now
        try endEdit(handle)
        let endMs = ms(clock.now - endStart)
        let back = Result { try readback(handle) }
        try delete(handle)
        let (got, hash) = try back.get()
        let sizeOK = got == size, hashOK = hash == hasher.finalize()
        print("SPIKE edit size=\(size) size-ok=\(sizeOK) hash-ok=\(hashOK) upload-MB/s=\(String(format: "%.1f", Double(size) / 1e6 / seconds)) endEdit-ms=\(endMs) offset-high-max=\(maxHigh)")
        if !(sizeOK && hashOK) { pass = false }
    }

    /// The response code of one transaction (0x2001 on success); a non-response error is rethrown.
    private func code(_ body: () throws -> Void) throws -> UInt16 {
        do { try body(); return MTPCode.ok } catch let MTPError.response(code, _) { return code }
    }

    /// An edit-path upload toward 64 MiB stopped after 3 chunks and cleaned up the D-09 way: EndEdit + Delete.
    private func cancel() throws {
        let handle = try createForEdit("cancel.bin")
        for i in 0..<3 { _ = try writePartial(handle, UInt64(i * Self.chunk), block(i, count: Self.chunk)) }
        let endEditCode = try code { try endEdit(handle) }
        let deleteCode = try code { try delete(handle) }
        let gone = try code { _ = try raw.run(MTPOp.getObjectInfo, [handle]) } == MTPCode.invalidObjectHandle
        let start = clock.now
        _ = try raw.run(MTPOp.getStorageIDs)
        let nextMs = ms(clock.now - start)
        print("SPIKE cancel endEdit=\(hex16(endEditCode)) delete=\(hex16(deleteCode)) gone=\(gone) next-command-ms=\(nextMs)")
        if !(gone && nextMs < 1000) { pass = false }
    }

    /// AOSP refuses a chunk starting past the object's end (offset > size), and answers before reading the data
    /// phase: the phone then blocks writing its response while the host blocks writing the data container. So
    /// this one transaction is run by hand: the (empty) data container gets 2 s, then the response is read either
    /// way, which also unblocks the phone. An empty container also keeps AOSP from parsing it as a malformed request.
    private func gapProbe() throws {
        let handle = try createForEdit("gap.bin")
        let tid = raw.nextTID(), t = raw.transport
        try t.write(commandContainer(op: UploadOp.sendPartialObject, tid: tid, params: [handle, 1, 0, 0]), timeout: 5)
        var c = Payload()
        c.u32(12); c.u16(ContainerType.data); c.u16(UploadOp.sendPartialObject); c.u32(tid)
        let accepted = (try? t.write(c.bytes, timeout: 2)) != nil
        var r = Reader(try t.read(maxLength: readChunk, timeout: 5))
        _ = try r.u32()
        let type = try r.u16(), gap = try r.u16(), rtid = try r.u32()
        guard type == ContainerType.response, rtid == tid else { throw MTPError.malformed("gap reply type \(type) tid \(rtid)") }
        let endEditCode = try code { try endEdit(handle) }
        try delete(handle)
        print("SPIKE edit-gap code=\(hex16(gap)) data-phase-accepted=\(accepted) endEdit-after=\(hex16(endEditCode))")
    }
}

/// Forwards to a real transport and records every bulk write (direction 0) and bulk-IN read (1)
/// as u8 direction, u32 LE length, bytes — the replay format Plan 01-03 consumes.
private final class RecordingTransport: MTPTransport {
    let inner: any MTPTransport
    var records: [UInt8] = []
    init(_ inner: any MTPTransport) { self.inner = inner }

    var maxPacketSize: Int { inner.maxPacketSize }

    func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
        try inner.write(bytes, timeout: timeout)
        record(0, bytes)
    }

    func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] {
        let bytes = try inner.read(maxLength: maxLength, timeout: timeout)
        record(1, bytes)
        return bytes
    }

    private func record(_ direction: UInt8, _ bytes: [UInt8]) {
        var p = Payload()
        p.bytes.append(direction)
        p.u32(UInt32(bytes.count))
        records += p.bytes + bytes
    }
}
