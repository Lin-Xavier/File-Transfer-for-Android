import Foundation

/// One MTP session with one device. The actor's serial executor is the protocol lock:
/// every method runs whole transactions synchronously, with no `await` between a command and its response.
public actor DeviceSession {
    private let queue = DispatchSerialQueue(label: "mtp.session")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var transport: (any MTPTransport)?
    private var tid: UInt32 = 0
    private var sessionOpen = false
    /// Why `run` dropped the transport. Later calls rethrow it, so a timeout isn't reported as an unplug (WR-01).
    private var lost: (any Error)?
    private let continuation: AsyncStream<MTPEvent>.Continuation

    /// The phone's events for this session, from OpenSession until `close()`. One consumer per session: the
    /// app's (AppModel). The newest 4096 are kept if the consumer falls behind; ⌘R recovers the rest (T-02-21).
    public nonisolated let events: AsyncStream<MTPEvent>

    private let clockStore: PhoneClockStore?
    private let macZone: TimeZone
    private var serial = ""
    /// The zone zoneless phone dates are read in, learned from objects this app creates (quick 261007-cyl): a fixed
    /// offset, or nil for the Mac's zone (unknown, or learned equal to it), so its DST rules and any later change of the
    /// Mac's zone apply (CR-01, re-review WR-01).
    public private(set) var phoneZone: TimeZone?

    /// `macZone`: the Mac's zone, injectable so tests don't depend on the machine's.
    public init(transport: sending (any MTPTransport)? = nil, clockStore: PhoneClockStore? = nil, macZone: TimeZone = .current) {
        self.transport = transport
        self.clockStore = clockStore
        self.macZone = macZone
        (events, continuation) = AsyncStream.makeStream(of: MTPEvent.self, bufferingPolicy: .bufferingNewest(4096))
    }

    /// Opens the phone's MTP interface (`seize` = DeviceSeize). The transport is created here, inside
    /// the actor, so no IOUSBHost object ever crosses an isolation boundary. Throws
    /// `MTPError.exclusiveAccess(owner:)` when another process holds the interface.
    public func openUSB(registryID: UInt64, seize: Bool) throws {
        transport = nil                                   // destroys any previous interface first
        lost = nil
        tid = 0
        sessionOpen = false
        transport = try USBTransport(registryID: registryID, seize: seize)
    }

    /// GetDeviceInfo, then OpenSession(1). A stale session left by a previous launch (0x201E)
    /// is closed and reopened, so relaunching with the phone plugged in still connects.
    /// A reopened interface whose phone is still stuck on an abandoned reply (the first command times out)
    /// is recovered by draining that reply, then GetDeviceInfo is tried once more (G-02-7).
    public func openSession() throws -> DeviceInfo {
        guard let transport else { throw MTPError.deviceGone }
        let infoData: [UInt8]
        do {
            infoData = try transact(transport, op: MTPOp.getDeviceInfo, tid: 0).data
        } catch let error as MTPError {
            switch error {
            case .response, .deviceGone: throw error
            default:
                transport.cancelTransaction(0)          // 0 is the GetDeviceInfo just tried
                infoData = try transact(transport, op: MTPOp.getDeviceInfo, tid: 0).data
            }
        }
        let info = try DeviceInfo(decoding: infoData)
        serial = info.serialNumber
        phoneZone = serial.isEmpty ? nil : clockStore?.load(serial)
        do {
            _ = try transact(transport, op: MTPOp.openSession, tid: 0, params: [1])
        } catch MTPError.response(code: MTPCode.sessionAlreadyOpen, op: _) {
            _ = try transact(transport, op: MTPOp.closeSession, tid: 0)
            _ = try transact(transport, op: MTPOp.openSession, tid: 0, params: [1])
        }
        tid = 1
        sessionOpen = true
        // Malformed packets are dropped without stopping the reader (T-02-20).
        transport.startEvents { [continuation] bytes in
            if let event = try? MTPEvent.parse(bytes) { continuation.yield(event) }
        }
        return info
    }

    /// Every storage in GetStorageIDs order. Empty usually means the phone is locked.
    public func storages() throws -> [StorageInfo] {
        var r = try Reader(run(MTPOp.getStorageIDs).data)
        let ids = try r.u32Array()
        return try ids.map { try StorageInfo(id: $0, decoding: run(MTPOp.getStorageInfo, [$0]).data) }
    }

    /// The direct children of `parent` (0xFFFFFFFF = storage root; never 0, which Android walks recursively),
    /// in one call. The app lists in batches through `handles` + `entries` instead.
    public func children(storage: UInt32, parent: UInt32 = 0xFFFF_FFFF) throws -> [ObjectEntry] {
        try entries(handles(storage: storage, parent: parent), parent: parent)
    }

    /// One GetObjectHandles. 30 s: a big folder can take the phone longer than the 5 s default, and a
    /// timeout would poison the session (RESEARCH Pitfall 1, A1). Callers then fetch `entries` in batches,
    /// so cancellation and other calls interleave between short actor calls (BRWS-06).
    public func handles(storage: UInt32, parent: UInt32) throws -> [UInt32] {
        var r = try Reader(run(MTPOp.getObjectHandles, [storage, 0, parent], timeout: 30).data)
        return try r.u32Array()
    }

    /// The entries for `handles`, listed under `parent`. Sizes are exact u64: when ObjectInfo caps the size at
    /// 0xFFFFFFFF, ObjectSize (0xDC04) is read in the same isolated call, and if that lookup fails the call
    /// throws rather than show a capped size. A handle deleted on the phone since GetObjectHandles (0x2009)
    /// is skipped, so one vanished photo doesn't fail the folder (RESEARCH Pattern 3).
    public func entries(_ handles: [UInt32], parent: UInt32) throws -> [ObjectEntry] {
        var out: [ObjectEntry] = []
        out.reserveCapacity(handles.count)
        for handle in handles {
            do {
                // Android reports root objects with parent 0 in ObjectInfo; keep the handle we listed.
                out.append(try decode(handle, parent: parent))
            } catch MTPError.response(code: MTPCode.invalidObjectHandle, op: _) {
                continue
            }
        }
        return out
    }

    /// One object read back on its own, for an event: its parent comes from ObjectInfo, with Android's root
    /// parent 0 mapped to 0xFFFFFFFF. Nil when the phone no longer has it (0x2009).
    public func entry(_ handle: UInt32) throws -> ObjectEntry? {
        do {
            return try decode(handle, parent: nil)
        } catch MTPError.response(code: MTPCode.invalidObjectHandle, op: _) {
            return nil
        }
    }

    /// GetObjectInfo, plus ObjectSize (0xDC04) when the size is capped. `parent` nil: take it from ObjectInfo.
    private func decode(_ handle: UInt32, parent: UInt32?) throws -> ObjectEntry {
        let info = try ObjectInfo(decoding: run(MTPOp.getObjectInfo, [handle]).data)
        var size = UInt64(info.compressedSize)
        if info.compressedSize == 0xFFFF_FFFF {
            var v = try Reader(run(MTPOp.getObjectPropValue, [handle, 0xDC04]).data)
            size = try v.u64()
        }
        let modified = parsePTPDate(info.dateModified, zone: phoneZone ?? macZone)
        return ObjectEntry(id: handle, storageID: info.storageID, parent: parent ?? (info.parent == 0 ? 0xFFFF_FFFF : info.parent),
                           format: info.format, name: info.filename, size: size, modified: modified)
    }

    /// Renames an object: SetObjectPropValue(ObjectFileName). Callers validate with `NameRules` first: AOSP's
    /// rename has no path check, and `Payload.string` would truncate past 254 UTF-16 units, so a longer name
    /// is refused here rather than sent as a different name.
    /// `timeout`: the browser's renames keep 5 s. The copy engine's finalize and fix-up renames pass 120 s: AOSP
    /// answers a rename only after two blocking MediaStore scans (old and new path), a big video's included, and a
    /// timeout poisons the session (RESEARCH Pitfall 2, CR-01).
    public func rename(_ handle: UInt32, to name: String, timeout: TimeInterval = 5) throws {
        guard !name.isEmpty, name.utf16.count <= 254 else { throw MTPError.malformed("name length \(name.utf16.count)") }
        var p = Payload()
        p.string(name)
        _ = try run(MTPOp.setObjectPropValue, [handle, 0xDC07], dataOut: p.bytes, timeout: timeout)
    }

    /// Creates a folder in `parent` (0xFFFFFFFF = storage root) and returns its handle. One SendObjectInfo with an
    /// Association dataset: AOSP makes the directory right there, and no SendObject follows for folders.
    public func makeFolder(storage: UInt32, parent: UInt32, name: String) throws -> UInt32 {
        let handle = try sendObjectInfo(storage: storage, parent: parent, name: name, format: 0x3001, size: 0)
        try learnClock(handle)
        return handle
    }

    /// A file of up to one chunk (0 bytes included): SendObjectInfo with the exact size, then SendObject with the
    /// whole file, in this one actor call so no other transaction lands between them (AOSP keeps the pending handle
    /// only until the next SendObjectInfo, RESEARCH Pitfall 2). 120 s: the response waits for the phone's media
    /// scan (Pitfall 7).
    public func createFile(storage: UInt32, parent: UInt32, name: String, contents: [UInt8]) throws -> UInt32 {
        // One data container: its u32 length includes the 12-byte header (IN-02). Checked before SendObjectInfo.
        guard contents.count <= Int(UInt32.max) - 12 else { throw MTPError.malformed("file of \(contents.count) bytes") }
        let handle = try sendObjectInfo(storage: storage, parent: parent, name: name, format: 0x3000,
                                        size: UInt32(contents.count))
        _ = try run(MTPOp.sendObject, dataOut: contents, timeout: 120)
        try learnClock(handle)
        return handle
    }

    /// A big file's empty object, opened for edit (03-SPIKE-REPORT ## Decision): SendObjectInfo with size 0 (a
    /// non-zero size would make the phone wait for that many bytes), an empty SendObject, then BeginEditObject.
    /// A refused BeginEdit deletes the empty object it made, so nothing is left behind.
    public func createForEdit(storage: UInt32, parent: UInt32, name: String) throws -> UInt32 {
        let handle = try sendObjectInfo(storage: storage, parent: parent, name: name, format: 0x3000, size: 0)
        _ = try run(MTPOp.sendObject, dataOut: [], timeout: 120)
        do {
            _ = try run(MTPOp.beginEditObject, [handle])
        } catch let e as MTPError where e.isResponse {
            _ = try? run(MTPOp.deleteObject, [handle], timeout: 120)
            throw e
        }
        try learnClock(handle)
        return handle
    }

    /// One SendPartialObject chunk at the 64-bit `offset` (low and high u32, as AOSP rebuilds it). Offsets must be
    /// sequential: the phone refuses a gap. The response's byte count under-reports by up to 16,372 and is ignored
    /// (Pitfall 6). 10 s: about 50× an 8 MiB chunk's measured time, so a hung chunk reaches the reconnect fast (D-10).
    public func writePartial(_ handle: UInt32, offset: UInt64, bytes: [UInt8]) throws {
        guard bytes.count <= Int(UInt32.max) - 12 else { throw MTPError.malformed("chunk of \(bytes.count) bytes") }   // IN-02
        _ = try run(MTPOp.sendPartialObject,
                    [handle, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), UInt32(bytes.count)],
                    dataOut: bytes, timeout: 10)
    }

    /// EndEditObject: the phone commits the file and rescans it, so 120 s (Pitfall 7).
    public func endEdit(_ handle: UInt32) throws {
        _ = try run(MTPOp.endEditObject, [handle], timeout: 120)
    }

    /// Reads a just-created object's DateModified (phone-local wall clock, no zone) against the Mac's clock and, when
    /// it gives a plausible offset, uses and stores the phone's zone. An offset equal to the Mac's right now means the
    /// Mac's zone, stored as nil so dates follow its DST rules and whatever zone the Mac is in later (CR-01, re-review
    /// WR-01); any other is a fixed offset. A refused read
    /// never fails the creation that already succeeded; one that drops the transport (through `run`) is rethrown, so
    /// the loss lands on this item rather than the next one, or on none (WR-02).
    /// ponytail: one extra GetObjectInfo per created object, refreshed every creation per the user decision; limit to
    /// once per session if per-file upload overhead ever shows.
    /// ponytail: MTP never sends the phone's zone name, so a phone in another DST-observing zone reads an hour off
    /// across its DST change, and one in a zone sharing the Mac's offset today gets the Mac's rules. Fix if seen.
    private func learnClock(_ handle: UInt32) throws {
        let now = Date()
        let data: [UInt8]
        do {
            data = try run(MTPOp.getObjectInfo, [handle]).data
        } catch let e as MTPError where e.isResponse {
            return
        }
        guard let info = try? ObjectInfo(decoding: data),
              let offset = inferPhoneUTCOffset(wallClock: info.dateModified, macNow: now) else { return }
        let zone = offset == macZone.secondsFromGMT(for: now) ? nil : TimeZone(secondsFromGMT: offset)
        phoneZone = zone
        if !serial.isEmpty { clockStore?.save(serial, zone) }
    }

    /// The one SendObjectInfo builder. The dataset carries the three trailing strings even empty, or AOSP answers
    /// Invalid Parameter; the date strings stay empty, so no Mac date is ever sent (D-15). `Payload.string` would
    /// truncate past 254 UTF-16 units onto another name, so such a name (or an empty one) is refused before sending.
    private func sendObjectInfo(storage: UInt32, parent: UInt32, name: String, format: UInt16, size: UInt32) throws -> UInt32 {
        guard !name.isEmpty, name.utf16.count <= 254 else { throw MTPError.malformed("name length \(name.utf16.count)") }
        var p = Payload()
        p.u32(storage); p.u16(format); p.u16(0)         // storage, format, protection
        p.u32(size); p.u16(0)                           // compressed size, thumb format
        for _ in 0..<6 { p.u32(0) }                     // thumb size/w/h, image w/h/depth
        p.u32(parent); p.u16(format == 0x3001 ? 1 : 0)  // parent, association type (1 = folder)
        p.u32(0); p.u32(0)                              // association desc, sequence
        p.string(name); p.string(""); p.string(""); p.string("")   // filename, created, modified, keywords
        let ps = try run(MTPOp.sendObjectInfo, [storage, parent], dataOut: p.bytes).params
        guard ps.count >= 3 else { throw MTPError.malformed("SendObjectInfo response has \(ps.count) params") }
        return ps[2]
    }

    /// Deletes an object. AOSP deletes a folder and everything in it before it answers, so this waits up to 120 s:
    /// a timeout would poison the session (RESEARCH Pitfall 1, A1). An unplug still fails fast through IOUSBHost.
    public func delete(_ handle: UInt32) throws {
        _ = try run(MTPOp.deleteObject, [handle], timeout: 120)
    }

    /// Moves an object into `parent` within its own storage (MoveObject 0x1019; moves never cross storages, D-08).
    /// AOSP takes the storage root only as parent 0 and answers 0xFFFFFFFF with Invalid Object Handle, the opposite
    /// of SendObjectInfo, so this is the one place the app's root handle is translated (RESEARCH Pitfall 10). 120 s:
    /// AOSP answers only after two blocking MediaStore scans, and a timeout poisons the session (Pitfall 12, CR-01).
    public func move(_ handle: UInt32, storage: UInt32, to parent: UInt32, timeout: TimeInterval = 120) throws {
        _ = try run(MTPOp.moveObject, [handle, storage, parent == 0xFFFF_FFFF ? 0 : parent], timeout: timeout)
    }

    /// One GetPartialObject64 chunk: up to `length` bytes of `handle` from the 64-bit `offset` (sent as low and
    /// high u32, which AOSP rebuilds as `offset | (offset2 << 32)`). One chunk per actor call, so listings queued
    /// by the browser run between chunks (D-22, RESEARCH Pattern 1). The reply is capped at `length` (T-03-05);
    /// callers check the returned length. 10 s: about 50× an 8 MiB chunk's normal time, so a hung chunk reaches
    /// the silent reconnect within seconds (D-10).
    public func readPartial(_ handle: UInt32, offset: UInt64, length: UInt32) throws -> [UInt8] {
        try run(MTPOp.getPartialObject64, [handle, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), length],
                maxDataLength: Int(length), timeout: 10).data
    }

    /// Whether calls can reach the phone: false before `openUSB`, and once `run` dropped the transport or `close()` ran.
    var isLive: Bool { transport != nil }

    /// Best-effort CloseSession, then drop the transport.
    public func close() {
        if sessionOpen, let transport {
            _ = try? transact(transport, op: MTPOp.closeSession, tid: tid)
        }
        transport = nil
        sessionOpen = false
        continuation.finish()
    }

    private func run(_ op: UInt16, _ params: [UInt32] = [], dataOut: [UInt8]? = nil,
                     maxDataLength: Int = 16 << 20, timeout: TimeInterval = 5) throws -> (data: [UInt8], params: [UInt32]) {
        guard let transport else { throw lost ?? MTPError.deviceGone }
        let id = tid
        tid &+= 1
        do {
            return try transact(transport, op: op, tid: id, params: params, dataOut: dataOut,
                                maxDataLength: maxDataLength, timeout: timeout)
        } catch {
            // An error response means the device answered and the pipe is still in step. Anything else
            // (timeout, I/O, bad framing) can leave a late reply queued, so this session runs no further
            // transactions: the transport is dropped and the app reconnects with a fresh session (CR-01).
            // First the abandoned reply is drained, so the next session's first command is not NAKed (G-02-7). An unplugged phone gets no requests, so unplug stays fast.
            // A pipe stall (kUSBHostReturnPipeStalled) means the phone halted its endpoints: clear them before the drain (WR-04).
            if case .response? = error as? MTPError { throw error }
            if case .io(_, 0xE000_5000)? = error as? MTPError { transport.recoverStall() }
            // ponytail: untested on hardware (IN-07): a write that times out mid-data-phase gets only this bulk-IN
            // drain, so the phone may still sit in receiveFile and take the next session's commands as file data.
            // Phase 4/6 hardware checklist: stall a SendPartialObject chunk; if it wedges, clear the bulk-OUT halt here.
            if error as? MTPError != .deviceGone { transport.cancelTransaction(id) }
            self.transport = nil
            sessionOpen = false
            lost = error
            throw error
        }
    }
}
