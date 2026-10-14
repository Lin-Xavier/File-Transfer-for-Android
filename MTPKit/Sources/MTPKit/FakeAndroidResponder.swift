import Foundation

// Debug builds only (tests, future SwiftUI previews): kept out of the signed Release app (IN-01).
#if DEBUG

public struct FakeStorage: Sendable {
    public var id: UInt32
    public var type: UInt16
    public var capacity: UInt64
    public var free: UInt64
    public var description: String

    public init(id: UInt32, type: UInt16, capacity: UInt64, free: UInt64, description: String) {
        self.id = id; self.type = type; self.capacity = capacity; self.free = free; self.description = description
    }
}

public struct FakeObject: Sendable {
    public var handle: UInt32
    public var storageID: UInt32
    public var parent: UInt32
    public var name: String
    public var format: UInt16
    public var size: UInt64
    public var modified: String               // AOSP form YYYYMMDDThhmmss, device local time

    public init(handle: UInt32, storageID: UInt32, parent: UInt32, name: String,
                format: UInt16, size: UInt64, modified: String) {
        self.handle = handle; self.storageID = storageID; self.parent = parent; self.name = name
        self.format = format; self.size = size; self.modified = modified
    }
}

/// A packet-faithful fake Android MTP responder with AOSP (MtpServer.cpp) semantics.
/// Replies are split into `maxPacketSize` bulk packets with a zero-length packet after
/// any container that fills its last packet exactly, so framing bugs show up headless.
/// Used by tests (and SwiftUI previews, when there are some). Host→device data phases are taken only as one
/// write holding the whole data container, as AOSP reads them with a single read.
public final class FakeAndroidResponder: MTPTransport {
    public let maxPacketSize: Int
    /// Zero-length packets the host wrote (after a data container that filled its last packet exactly).
    public private(set) var zlpCount = 0
    /// Command containers received, by operation code.
    public private(set) var opCounts: [UInt16: Int] = [:]
    /// The operation code of every command container received, in order.
    public private(set) var ops: [UInt16] = []
    /// The filename of every SendObjectInfo dataset received, in order.
    public private(set) var sentNames: [String] = []
    /// The new name of every SetObjectPropValue(ObjectFileName) received, in order, refused ones included.
    public private(set) var renamedNames: [String] = []
    private var sessionOpen: Bool
    private let model: String
    private let storages: [FakeStorage]
    /// The phone's objects as they are now, for tests to inspect after the session is gone.
    public private(set) var objects: [FakeObject]
    /// AOSP mNextObjectId: above every starting handle, only ever increments.
    private var nextHandle: UInt32
    /// A command with a host→device data phase, waiting for its data container.
    private var awaitingData: (op: UInt16, tid: UInt32, params: [UInt32])?
    private let failPropValue: Bool
    private let vanishedHandles: Set<UInt32>
    /// Objects the phone refuses to delete (Access Denied), e.g. a folder Android protects.
    private let protectedHandles: Set<UInt32>
    /// GetPartialObject64 for these answers one byte fewer than asked: a short read.
    private let shortReadHandles: Set<UInt32>
    /// GetStorageIDs answers empty this many more times, then lists the storages: a phone unlocked after N polls.
    private var lockedStorageReads: Int
    /// Once this many commands of an op were answered, later ones get no reply at all: a phone that stopped
    /// answering, so the host's read times out and the session drops itself.
    private let unansweredAfter: [UInt16: Int]
    /// Once this many commands of an op were received, the next command of that op is a cable pull: it never reaches
    /// the phone, and it and every later write or read throw `MTPError.deviceGone`, as IOUSBHost does after an unplug.
    private let goneAfter: [UInt16: Int]
    private var gone = false
    /// Once this many commands of an op were answered, the next one is executed but its response is never queued (a
    /// data-phase op after its data is taken), so the host times out and drops the session: "the phone did it, but the
    /// answer was lost" (RESEARCH Q2 cuts C3, C5). Unlike `unansweredAfter`, the op takes effect.
    private let dropResponseAfter: [UInt16: Int]
    /// After a successful DeleteObject, this many SetObjectPropValue or SendObjectInfo commands naming exactly the
    /// deleted object's name in its folder answer General Error, then the name is free: AOSP keeps a deleted name in
    /// its cache until the inotify event lands (FROZEN_ONESHOT_DEL, RESEARCH Pitfall 1).
    private let staleNameRenames: Int
    /// The name a delete left in the cache, and how many more commands it refuses.
    private var staleName: (storage: UInt32, parent: UInt32, name: String, left: Int)?
    /// AOSP checks names case-sensitively over a case-insensitive file system (RESEARCH Pitfall 3, Pitfall 16): when
    /// true, a SendObjectInfo or rename onto a case variant of a sibling's name succeeds and that sibling's file is
    /// lost; it is removed and its handle recorded in `clobbered`.
    private let caseInsensitiveNames: Bool
    /// Objects lost to a case-variant create or rename (`caseInsensitiveNames`), in order.
    public private(set) var clobbered: [UInt32] = []
    /// The object the next SendObject fills, with its declared size (AOSP mSendObjectHandle; the next
    /// SendObjectInfo replaces it).
    private var pendingSend: (handle: UInt32, size: UInt64)?
    /// Objects opened with BeginEditObject.
    private var editing: Set<UInt32> = []
    /// Bytes written by SendObject / SendPartialObject, kept up to `storedLimit` per object; other files read back
    /// synthesized content.
    private var stored: [UInt32: [UInt8]] = [:]
    private static let storedLimit = 64 << 20
    private var packets: [[UInt8]] = []
    /// The phone's clock zone (seconds east of UTC): created objects are stamped with the current wall clock at this
    /// offset, with no suffix, as Android does. Nil: stamped with a fixed old date.
    private let phoneUTCOffset: Int?

    public static let defaultStorages: [FakeStorage] = [
        FakeStorage(id: 0x0001_0001, type: 0x0003, capacity: 128_000_000_000, free: 12_400_000_000,
                    description: "Internal shared storage"),
        FakeStorage(id: 0x0002_0001, type: 0x0004, capacity: 64_000_000_000, free: 30_000_000_000,
                    description: "SD card"),
    ]
    public static let defaultObjects: [FakeObject] = {
        let phone: UInt32 = 0x0001_0001, sd: UInt32 = 0x0002_0001, root: UInt32 = 0xFFFF_FFFF
        func folder(_ h: UInt32, _ name: String) -> FakeObject {
            FakeObject(handle: h, storageID: phone, parent: root, name: name, format: 0x3001, size: 0, modified: "20260301T090000")
        }
        func file(_ h: UInt32, _ s: UInt32, _ parent: UInt32, _ name: String, _ size: UInt64, _ date: String) -> FakeObject {
            FakeObject(handle: h, storageID: s, parent: parent, name: name, format: 0x3000, size: size, modified: date)
        }
        return [
            folder(1, "DCIM"), folder(2, "Download"), folder(3, "Music"), folder(4, "Pictures"),
            file(5, phone, root, "IMG_2.jpg", 2_345_678, "20260312T184005"),
            file(6, phone, root, "IMG_10.jpg", 3_456_789, "20260313T101500"),
            file(7, phone, root, "empty.txt", 0, "20250101T000000"),
            file(8, phone, root, "big-video.mp4", 5_000_000_000, "20260320T220130"),
            file(9, phone, 1, "inside.jpg", 1_234, "20260314T120000"),
            file(10, sd, root, "sd-note.txt", 1_024, "20260201T080000"),
        ]
    }()

    public init(maxPacketSize: Int = 512, sessionAlreadyOpen: Bool = false, model: String = "Pixel 9",
                storages: [FakeStorage] = FakeAndroidResponder.defaultStorages,
                objects: [FakeObject] = FakeAndroidResponder.defaultObjects,
                failPropValue: Bool = false, vanishedHandles: Set<UInt32> = [], protectedHandles: Set<UInt32> = [],
                lockedStorageReads: Int = 0, shortReadHandles: Set<UInt32> = [], unansweredAfter: [UInt16: Int] = [:],
                goneAfter: [UInt16: Int] = [:], dropResponseAfter: [UInt16: Int] = [:], staleNameRenames: Int = 0,
                caseInsensitiveNames: Bool = false, phoneUTCOffset: Int? = nil) {
        self.maxPacketSize = maxPacketSize
        self.sessionOpen = sessionAlreadyOpen
        self.model = model
        self.storages = storages
        self.objects = objects
        self.nextHandle = (objects.map(\.handle).max() ?? 0) + 1
        self.failPropValue = failPropValue
        self.vanishedHandles = vanishedHandles
        self.protectedHandles = protectedHandles
        self.lockedStorageReads = lockedStorageReads
        self.shortReadHandles = shortReadHandles
        self.unansweredAfter = unansweredAfter
        self.goneAfter = goneAfter
        self.dropResponseAfter = dropResponseAfter
        self.staleNameRenames = staleNameRenames
        self.caseInsensitiveNames = caseInsensitiveNames
        self.phoneUTCOffset = phoneUTCOffset
    }

    /// The same phone plugged in again (RESEARCH Q1: a new MtpDatabase per server start): the same storages, model and
    /// object tree with every handle renumbered (parents remapped, the root kept), its session closed and no knobs.
    /// Written bytes stay with their object; synthesized ones follow the new handle.
    public func replugged() -> FakeAndroidResponder {
        func renumbered(_ handle: UInt32) -> UInt32 { handle == 0xFFFF_FFFF ? handle : handle + 1000 }
        let fake = FakeAndroidResponder(maxPacketSize: maxPacketSize, model: model, storages: storages,
                                        objects: objects.map { o in
                                            var o = o
                                            o.handle = renumbered(o.handle)
                                            o.parent = renumbered(o.parent)
                                            return o
                                        }, phoneUTCOffset: phoneUTCOffset)
        for (handle, bytes) in stored { fake.stored[renumbered(handle)] = bytes }
        return fake
    }

    /// Whether this command's response is lost (`dropResponseAfter`); the current command is already counted.
    private func dropsResponse(_ op: UInt16) -> Bool {
        dropResponseAfter[op].map { opCounts[op, default: 0] == $0 + 1 } ?? false
    }

    /// Whether `name` in that folder is still held by a just-deleted object (`staleNameRenames`); counts the refusal.
    private func stillCached(_ name: String, storage: UInt32, parent: UInt32) -> Bool {
        guard let s = staleName, s.left > 0, s.storage == storage, s.parent == parent, s.name == name else { return false }
        staleName?.left -= 1
        return true
    }

    /// `caseInsensitiveNames`: a case variant of a sibling's name lands on that sibling's file, which is lost.
    private func clobber(_ name: String, storage: UInt32, parent: UInt32, except handle: UInt32? = nil) {
        guard caseInsensitiveNames else { return }
        let lost = objects.filter {
            $0.storageID == storage && $0.parent == parent && $0.handle != handle && $0.name != name
                && $0.name.lowercased() == name.lowercased()
        }.map(\.handle)
        objects.removeAll { lost.contains($0.handle) }
        for h in lost { stored[h] = nil }
        clobbered += lost
    }

    /// Whether the phone has stopped answering this op (`unansweredAfter`); the current command is already counted.
    private func silenced(_ op: UInt16) -> Bool {
        opCounts[op, default: 0] > unansweredAfter[op, default: .max]
    }

    // MARK: MTPTransport

    public func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
        if gone { throw MTPError.deviceGone }
        if bytes.isEmpty { zlpCount += 1; return }
        var r = Reader(bytes)
        let length = try r.u32(), type = try r.u16(), op = try r.u16(), tid = try r.u32()
        if type == ContainerType.data, let command = awaitingData {
            // A header written apart from its payload would end AOSP's data phase as a short packet.
            guard op == command.op, tid == command.tid, Int(length) == bytes.count else {
                throw MTPError.malformed("fake expects one write holding the whole data container")
            }
            awaitingData = nil
            if silenced(op) { return }
            let (code, responseParams) = receive(op: op, params: command.params, data: Array(bytes.dropFirst(12)))
            if dropsResponse(op) { return }
            var payload = Payload()
            responseParams.forEach { payload.u32($0) }
            enqueue(type: ContainerType.response, code: code, tid: tid, payload: payload.bytes)
            return
        }
        guard type == ContainerType.command, Int(length) == bytes.count, awaitingData == nil else {
            throw MTPError.malformed("fake expects a command container")
        }
        if opCounts[op, default: 0] >= goneAfter[op, default: .max] {
            gone = true
            throw MTPError.deviceGone
        }
        opCounts[op, default: 0] += 1
        ops.append(op)
        var params: [UInt32] = []
        while r.remaining >= 4 { params.append(try r.u32()) }
        if [MTPOp.sendObjectInfo, MTPOp.setObjectPropValue, MTPOp.sendObject, MTPOp.sendPartialObject].contains(op) {
            awaitingData = (op, tid, params)            // the response follows the data container
            return
        }
        if silenced(op) { return }

        let (data, code, responseParams) = handle(op: op, params: params)
        if dropsResponse(op) { return }
        if let data { enqueue(type: ContainerType.data, code: op, tid: tid, payload: data) }
        var payload = Payload()
        responseParams.forEach { payload.u32($0) }
        enqueue(type: ContainerType.response, code: code, tid: tid, payload: payload.bytes)
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] {
        precondition(maxLength % maxPacketSize == 0, "bulk-IN reads must be a multiple of wMaxPacketSize")
        if gone { throw MTPError.deviceGone }
        guard !packets.isEmpty else { throw MTPError.io(operation: "Read", code: 0xE000_02D6) }  // timeout
        var out: [UInt8] = []
        while !packets.isEmpty {
            let packet = packets.removeFirst()
            out += packet
            if out.count >= maxLength || packet.count < maxPacketSize { break }
        }
        return out
    }

    // MARK: Responder

    private func handle(op: UInt16, params: [UInt32]) -> (data: [UInt8]?, code: UInt16, params: [UInt32]) {
        let p0 = params.first ?? 0
        if !sessionOpen && op != MTPOp.getDeviceInfo && op != MTPOp.openSession {
            return (nil, MTPCode.sessionNotOpen, [])
        }
        switch op {
        case MTPOp.getDeviceInfo:
            var d = Payload()
            d.u16(100); d.u32(6); d.u16(100)
            d.string("microsoft.com: 1.0; android.com: 1.0;")
            d.u16(0)
            d.u16Array(Array(0x1001...0x1009) + [0x100B, 0x100C, 0x100D, 0x9803, 0x9804, 0x9805,
                                                     0x95C1, 0x95C2, 0x95C4, 0x95C5, 0x1019])
            d.u16Array([]); d.u16Array([]); d.u16Array([]); d.u16Array([])
            d.string("Google"); d.string(model); d.string("1.0"); d.string("FAKE0001")
            return (d.bytes, MTPCode.ok, [])

        case MTPOp.openSession:
            if sessionOpen { return (nil, MTPCode.sessionAlreadyOpen, [1]) }
            sessionOpen = true
            return (nil, MTPCode.ok, [])

        case MTPOp.closeSession:
            sessionOpen = false
            return (nil, MTPCode.ok, [])

        case MTPOp.getStorageIDs:
            var d = Payload()
            if lockedStorageReads > 0 {
                lockedStorageReads -= 1
                d.u32Array([])
            } else {
                d.u32Array(storages.map(\.id))
            }
            return (d.bytes, MTPCode.ok, [])

        case MTPOp.getStorageInfo:
            guard let s = storages.first(where: { $0.id == p0 }) else { return (nil, MTPCode.invalidStorageID, []) }
            var d = Payload()
            d.u16(s.type); d.u16(0x0002); d.u16(0x0000)     // hierarchical FS, read-write
            d.u64(s.capacity); d.u64(s.free); d.u32(1024 * 1024 * 1024)
            d.string(s.description); d.string("")
            return (d.bytes, MTPCode.ok, [])

        case MTPOp.getObjectHandles:
            guard storages.contains(where: { $0.id == p0 }) else { return (nil, MTPCode.invalidStorageID, []) }
            let parent = params.count > 2 ? params[2] : 0
            // AOSP: parent 0 lists every object of the storage recursively.
            var handles = objects.filter { $0.storageID == p0 && (parent == 0 || $0.parent == parent) }.map(\.handle)
            // `vanishedHandles` are still listed at the first storage's root, then gone by GetObjectInfo,
            // like a photo deleted on the phone between the two calls.
            if p0 == storages.first?.id, parent == 0xFFFF_FFFF { handles += vanishedHandles.sorted() }
            var d = Payload()
            d.u32Array(handles)
            return (d.bytes, MTPCode.ok, [])

        case MTPOp.getObjectInfo:
            if vanishedHandles.contains(p0) { return (nil, MTPCode.invalidObjectHandle, []) }
            guard let o = objects.first(where: { $0.handle == p0 }) else { return (nil, MTPCode.invalidObjectHandle, []) }
            var d = Payload()
            d.u32(o.storageID); d.u16(o.format); d.u16(0)
            d.u32(o.size > 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(o.size))   // capped, as android_mtp_MtpDatabase.cpp
            d.u16(0)                                                     // thumb format
            for _ in 0..<6 { d.u32(0) }                                  // thumb size/w/h, image w/h/depth
            d.u32(o.parent == 0xFFFF_FFFF ? 0 : o.parent)                // AOSP reports root objects with parent 0
            d.u16(o.format == 0x3001 ? 1 : 0); d.u32(0); d.u32(0)        // association type/desc, sequence
            d.string(o.name); d.string(o.modified); d.string(o.modified); d.string("")
            return (d.bytes, MTPCode.ok, [])

        case MTPOp.getObjectPropValue:
            if failPropValue { return (nil, MTPCode.generalError, []) }
            if vanishedHandles.contains(p0) { return (nil, MTPCode.invalidObjectHandle, []) }
            guard let o = objects.first(where: { $0.handle == p0 }) else { return (nil, MTPCode.invalidObjectHandle, []) }
            guard params.count > 1, params[1] == 0xDC04 else { return (nil, MTPCode.operationNotSupported, []) }
            var d = Payload()
            d.u64(o.size)
            return (d.bytes, MTPCode.ok, [])

        case MTPOp.deleteObject:
            // AOSP MtpServer.doDeleteObject: an unknown handle is Invalid Object Handle; a folder goes with everything
            // in it (deleteRecursive, then rmdir) before the response.
            guard let deleted = objects.first(where: { $0.handle == p0 }) else { return (nil, MTPCode.invalidObjectHandle, []) }
            if protectedHandles.contains(p0) { return (nil, MTPCode.accessDenied, []) }
            var gone: Set<UInt32> = [p0], grew = true
            while grew {
                let more = objects.filter { gone.contains($0.parent) && !gone.contains($0.handle) }.map(\.handle)
                grew = !more.isEmpty
                gone.formUnion(more)
            }
            objects.removeAll { gone.contains($0.handle) }
            for h in gone { stored[h] = nil; editing.remove(h) }
            if staleNameRenames > 0 {
                staleName = (deleted.storageID, deleted.parent, deleted.name, staleNameRenames)
            }
            return (nil, MTPCode.ok, [])

        case MTPOp.moveObject:
            // AOSP MtpServer.doMoveObject (RESEARCH Pattern 5): the root is parent 0 and 0xFFFFFFFF is Invalid Object
            // Handle (getObject refuses it); a non-folder parent is Invalid Parent Object; an exact name in the new
            // parent (or one a delete left cached) is General Error (beginMoveObject's getChild); into its own subtree
            // is General Error (rename EINVAL); a case variant passes and rename(2) clobbers it. The handle is kept.
            guard params.count > 2, let i = objects.firstIndex(where: { $0.handle == p0 }) else {
                return (nil, MTPCode.invalidObjectHandle, [])
            }
            let o = objects[i], storage = params[1]
            var parent = params[2]
            if parent == 0 {
                parent = 0xFFFF_FFFF
            } else {
                guard parent != 0xFFFF_FFFF, let p = objects.first(where: { $0.handle == parent }) else {
                    return (nil, MTPCode.invalidObjectHandle, [])
                }
                guard p.format == 0x3001 else { return (nil, 0x201A, []) }
                var walk: UInt32? = parent                  // the new parent, up to the root: is the object on the way?
                while let h = walk, h != 0xFFFF_FFFF {
                    if h == p0 { return (nil, MTPCode.generalError, []) }
                    walk = objects.first { $0.handle == h }?.parent
                }
            }
            if objects.contains(where: { $0.storageID == storage && $0.parent == parent && $0.name == o.name })
                || stillCached(o.name, storage: storage, parent: parent) {
                return (nil, MTPCode.generalError, [])
            }
            clobber(o.name, storage: storage, parent: parent, except: p0)
            if let j = objects.firstIndex(where: { $0.handle == p0 }) { objects[j].parent = parent }
            return (nil, MTPCode.ok, [])

        case MTPOp.getPartialObject64:
            // AOSP MtpServer.doGetPartialObject: unknown handle → Invalid Object Handle, a folder → General Error;
            // the data is clipped to the file's end (empty past it), and the response carries the length sent.
            guard params.count > 3, let o = objects.first(where: { $0.handle == p0 }) else {
                return (nil, MTPCode.invalidObjectHandle, [])
            }
            guard o.format != 0x3001 else { return (nil, MTPCode.generalError, []) }
            let offset = UInt64(params[1]) | UInt64(params[2]) << 32
            var count = offset >= o.size ? 0 : Int(min(UInt64(params[3]), o.size - offset))
            if shortReadHandles.contains(p0), count > 0 { count -= 1 }
            let data = stored[p0].map { Array($0[Int(offset)..<Int(offset) + count]) }
                ?? Self.content(handle: p0, offset: offset, count: count)
            return (data, MTPCode.ok, [UInt32(count)])

        case MTPOp.beginEditObject:
            // AOSP MtpServer.doBeginEditObject: unknown handle → Invalid Object Handle; a folder can't be opened.
            guard let o = objects.first(where: { $0.handle == p0 }) else { return (nil, MTPCode.invalidObjectHandle, []) }
            guard o.format != 0x3001 else { return (nil, MTPCode.generalError, []) }
            editing.insert(p0)
            return (nil, MTPCode.ok, [])

        case MTPOp.endEditObject:
            guard editing.remove(p0) != nil else { return (nil, MTPCode.generalError, []) }
            return (nil, MTPCode.ok, [])

        default:
            return (nil, MTPCode.operationNotSupported, [])
        }
    }

    /// The fake's file bytes: a function of the handle and the absolute offset, so reads past 2^32 need no storage
    /// and a chunk written at the wrong offset shows up as different bytes.
    public static func content(handle: UInt32, offset: UInt64, count: Int) -> [UInt8] {
        (0..<UInt64(count)).map { i in
            let x = (offset &+ i) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(handle) &* 0xC2B2_AE3D_27D4_EB4F
            return UInt8(truncatingIfNeeded: x ^ x >> 29)
        }
    }

    /// A new object's DateModified: the wall clock now at `phoneUTCOffset` in AOSP form, or a fixed old date.
    private func stampNow() -> String {
        guard let offset = phoneUTCOffset, let zone = TimeZone(secondsFromGMT: offset) else { return "20261002T120000" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let d = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        return String(format: "%04d%02d%02dT%02d%02d%02d", d.year!, d.month!, d.day!, d.hour!, d.minute!, d.second!)
    }

    /// Operations with a host→device data phase.
    private func receive(op: UInt16, params: [UInt32], data: [UInt8]) -> (code: UInt16, params: [UInt32]) {
        guard sessionOpen else { return (MTPCode.sessionNotOpen, []) }
        switch op {
        case MTPOp.sendObjectInfo:
            // AOSP MtpServer.doSendObjectInfo: storage, then parent (root, or an existing folder), then the dataset;
            // a name already in the folder fails MtpStorageManager.beginSendObject (General Error). A folder is
            // made right here; the response carries [storage, parent (root as 0), new handle].
            guard params.count > 1, storages.contains(where: { $0.id == params[0] }) else { return (MTPCode.invalidStorageID, []) }
            let storage = params[0], parent = params[1]
            if parent != 0xFFFF_FFFF {
                guard let p = objects.first(where: { $0.handle == parent }) else { return (MTPCode.invalidObjectHandle, []) }
                guard p.format == 0x3001 else { return (0x201A, []) }                  // Invalid Parent Object
            }
            guard let info = try? ObjectInfo(decoding: data) else { return (0x201D, []) }   // Invalid Parameter
            sentNames.append(info.filename)
            if objects.contains(where: { $0.storageID == storage && $0.parent == parent && $0.name == info.filename })
                || stillCached(info.filename, storage: storage, parent: parent) {
                return (MTPCode.generalError, [])
            }
            clobber(info.filename, storage: storage, parent: parent)
            let handle = nextHandle
            nextHandle += 1
            objects.append(FakeObject(handle: handle, storageID: storage, parent: parent, name: info.filename,
                                      format: info.format, size: 0, modified: stampNow()))
            pendingSend = (handle, UInt64(info.compressedSize))
            return (MTPCode.ok, [storage, parent == 0xFFFF_FFFF ? 0 : parent, handle])
        case MTPOp.sendObject:
            // AOSP MtpServer.doSendObject: needs a SendObjectInfo first; a data phase of another length than the
            // declared size fails and the file is unlinked.
            guard let pending = pendingSend else { return (MTPCode.generalError, []) }
            pendingSend = nil
            guard UInt64(data.count) == pending.size else {
                objects.removeAll { $0.handle == pending.handle }
                return (MTPCode.generalError, [])
            }
            guard let i = objects.firstIndex(where: { $0.handle == pending.handle }) else { return (MTPCode.generalError, []) }
            objects[i].size = pending.size
            if data.count <= Self.storedLimit { stored[pending.handle] = data }
            return (MTPCode.ok, [])
        case MTPOp.sendPartialObject:
            // AOSP MtpServer.doSendPartialObject: offset = offset | (offset2 << 32); the object must be open for edit
            // and the write may not start past its end. The response's count drops the first read's 16,372 bytes
            // (AOSP `length -= initialData`), as the real phone does (Pitfall 6).
            guard params.count > 3, editing.contains(params[0]),
                  let i = objects.firstIndex(where: { $0.handle == params[0] }) else { return (MTPCode.generalError, []) }
            let offset = UInt64(params[1]) | UInt64(params[2]) << 32
            guard offset <= objects[i].size else { return (MTPCode.generalError, []) }
            let end = offset + UInt64(data.count)
            if end <= UInt64(Self.storedLimit) {
                var bytes = stored[params[0]] ?? Self.content(handle: params[0], offset: 0, count: Int(objects[i].size))
                if bytes.count < Int(end) { bytes += [UInt8](repeating: 0, count: Int(end) - bytes.count) }
                bytes.replaceSubrange(Int(offset)..<Int(end), with: data)
                stored[params[0]] = bytes
            } else {
                stored[params[0]] = nil
            }
            objects[i].size = max(objects[i].size, end)
            return (MTPCode.ok, [UInt32(max(0, data.count - 16_372))])
        case MTPOp.setObjectPropValue:
            // AOSP MtpDatabase.setObjectProperty / renameFile: only ObjectFileName is settable, a missing handle is
            // Invalid Object Handle, and a name already in the folder is a bare General Error.
            guard params.count > 1, params[1] == 0xDC07 else { return (0xA80A, []) }
            guard let i = objects.firstIndex(where: { $0.handle == params[0] }) else { return (MTPCode.invalidObjectHandle, []) }
            var r = Reader(data)
            guard let name = try? r.string() else { return (0x201D, []) }   // Invalid Parameter
            renamedNames.append(name)
            let o = objects[i]
            if objects.contains(where: { $0.storageID == o.storageID && $0.parent == o.parent && $0.name == name })
                || stillCached(name, storage: o.storageID, parent: o.parent) {
                return (MTPCode.generalError, [])
            }
            clobber(name, storage: o.storageID, parent: o.parent, except: o.handle)
            if let j = objects.firstIndex(where: { $0.handle == o.handle }) { objects[j].name = name }
            return (MTPCode.ok, [])
        default:
            return (MTPCode.operationNotSupported, [])
        }
    }

    private func enqueue(type: UInt16, code: UInt16, tid: UInt32, payload: [UInt8]) {
        var c = Payload()
        c.u32(UInt32(12 + payload.count)); c.u16(type); c.u16(code); c.u32(tid)
        let container = c.bytes + payload
        var i = 0
        while i < container.count {
            packets.append(Array(container[i..<min(i + maxPacketSize, container.count)]))
            i += maxPacketSize
        }
        if container.count % maxPacketSize == 0 { packets.append([]) }   // ZLP
    }
}

#endif
