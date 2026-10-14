import Foundation
import IOKit
import IOUSBHost
import os

let usbLog = Logger(subsystem: "com.xianglin.File-Transfer-for-Android", category: "usb")

/// Codes an unplug produces mid-transfer: NoDevice, Aborted, NotResponding, Offline.
private let unplugCodes: Set<UInt32> = [0xE000_02C0, 0xE000_02EB, 0xE000_02ED, 0xE000_02E3]

/// The phone's MTP interface over IOUSBHost. Opens ONLY the interface: never the IOUSBHostDevice,
/// never SetConfiguration or a reset, so ADB and other interfaces keep working.
/// Owned by one DeviceSession and never leaves it (IOUSBHost objects are not Sendable).
final class USBTransport: MTPTransport {
    private let iface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    /// The interrupt-IN pipe carrying events; nil when the interface has none (then there are no events).
    private let eventPipe: IOUSBHostPipe?
    private let ioQueue: DispatchQueue
    private var eventReader: EventReader?
    private var readBuffer: NSMutableData?
    /// wIndex of the GetDeviceStatus class request used by stall recovery.
    private let interfaceNumber: UInt16
    let maxPacketSize: Int
    /// e.g. "IN 0x81 bulk mps 512; OUT 0x01 bulk mps 512; INT 0x82 mps 28"
    let endpointSummary: String

    /// `seize` asks the current owner to let go (DeviceSeize). `ioQueue` defaults to a private queue,
    /// never the session actor's queue (a synchronous call blocking the IO queue may deadlock).
    init(registryID: UInt64, seize: Bool, ioQueue: DispatchQueue? = nil) throws {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard svc != 0 else { throw MTPError.deviceGone }
        defer { IOObjectRelease(svc) }

        let queue = ioQueue ?? DispatchQueue(label: "mtp.usb.io")
        let iface: IOUSBHostInterface
        do {
            iface = try IOUSBHostInterface(__ioService: svc, options: seize ? [.deviceSeize] : [],
                                           queue: queue,
                                           interestHandler: nil)
        } catch let e as NSError {
            usbLog.error("open (seize \(seize)) failed: domain \(e.domain, privacy: .public) code \(e.code)")
            // macOS 27 refuses a ptpcamerad-held interface with kIOReturnInternalError (0xE00002C9),
            // not kIOReturnExclusiveAccess (01-SPIKE-REPORT), so an owner on the interface also counts as busy.
            // An owner only on the parent device is no evidence: other failures would show as busy (IN-08).
            if isExclusiveAccess(e) || ExclusiveOwner.property(svc) != nil {
                throw MTPError.exclusiveAccess(owner: ExclusiveOwner.read(service: svc))
            }
            throw MTPError.io(operation: "Open interface", code: UInt32(truncatingIfNeeded: e.code))
        }

        do {
            var inEP: UnsafePointer<IOUSBEndpointDescriptor>?
            var outEP: UnsafePointer<IOUSBEndpointDescriptor>?
            var intEP: UnsafePointer<IOUSBEndpointDescriptor>?
            var cur: UnsafePointer<IOUSBDescriptorHeader>?
            while let ep = IOUSBGetNextEndpointDescriptor(iface.configurationDescriptor, iface.interfaceDescriptor, cur) {
                let isIn = ep.pointee.bEndpointAddress & 0x80 != 0
                switch ep.pointee.bmAttributes & 3 {
                case 2 where isIn: inEP = inEP ?? ep
                case 2: outEP = outEP ?? ep
                case 3 where isIn: intEP = intEP ?? ep         // events (BRWS-08)
                default: break
                }
                cur = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            }
            func mps(_ ep: UnsafePointer<IOUSBEndpointDescriptor>) -> Int { Int(ep.pointee.wMaxPacketSize & 0x7FF) }
            // A bulk endpoint claiming wMaxPacketSize 0 is broken or hostile (WR-05).
            guard let inEP, let outEP, mps(inEP) > 0, mps(outEP) > 0 else {
                throw MTPError.io(operation: "Find endpoints", code: 0xE000_02C7)
            }
            func addr(_ ep: UnsafePointer<IOUSBEndpointDescriptor>) -> String { String(format: "0x%02X", ep.pointee.bEndpointAddress) }
            var summary = "IN \(addr(inEP)) bulk mps \(mps(inEP)); OUT \(addr(outEP)) bulk mps \(mps(outEP))"
            if let intEP { summary += "; INT \(addr(intEP)) mps \(mps(intEP))" }

            bulkIn = try pipeCall("Open pipe") { try iface.copyPipe(withAddress: Int(inEP.pointee.bEndpointAddress)) }
            bulkOut = try pipeCall("Open pipe") { try iface.copyPipe(withAddress: Int(outEP.pointee.bEndpointAddress)) }
            eventPipe = try intEP.map { ep in
                try pipeCall("Open pipe") { try iface.copyPipe(withAddress: Int(ep.pointee.bEndpointAddress)) }
            }
            maxPacketSize = mps(outEP)                    // decides the ZLP after a host→device data container
            interfaceNumber = UInt16(iface.interfaceDescriptor.pointee.bInterfaceNumber)
            endpointSummary = summary
            self.iface = iface
            self.ioQueue = queue
        } catch {
            iface.destroy()
            throw error
        }
        usbLog.info("opened interface \(registryID) seize \(seize): \(self.endpointSummary, privacy: .public)")
    }

    deinit { iface.destroy() }                            // also aborts a pending event read: the reader stops

    func startEvents(_ yield: @escaping @Sendable ([UInt8]) -> Void) {
        guard eventReader == nil, let eventPipe else { return }
        do {
            let reader = try EventReader(pipe: eventPipe, buffer: pipeCall("Event buffer") { try iface.ioData(withCapacity: 64) },
                                         yield: yield)
            eventReader = reader
            ioQueue.async { reader.arm() }                    // first enqueue on the IO queue too (the invariant below)
        } catch {
            usbLog.error("events not started: \(String(describing: error), privacy: .public)")
        }
    }

    func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
        var n = 0
        guard !bytes.isEmpty else {                       // ZLP: nil data sends a zero-length packet (IOUSBHostPipe.h)
            try pipeCall("Bulk write") { try bulkOut.__sendIORequest(with: nil, bytesTransferred: &n, completionTimeout: timeout) }
            return
        }
        // ioData comes back autoreleased: without a pool here a caller's thread that never drains one keeps every
        // write buffer mapped for DMA, and an upload fails with kIOReturnNoMemory near 4 GiB (03-SPIKE-REPORT).
        try autoreleasepool {
            let d = try pipeCall("Bulk write") { try iface.ioData(withCapacity: bytes.count) }
            bytes.withUnsafeBytes { d.mutableBytes.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            try pipeCall("Bulk write") { try bulkOut.__sendIORequest(with: d, bytesTransferred: &n, completionTimeout: timeout) }
        }
    }

    /// Drains the abandoned reply from bulk-IN until 0.2 s of silence (bounded: 64 reads), which lets MtpServer's
    /// blocked write finish so it goes back to reading commands (G-02-7). No class Cancel (0x64) or Device Reset
    /// (0x66): on Android's FunctionFS backend both leave the in-flight aio request orphaned in the gadget, and
    /// later commands are then swallowed until a replug (G-02-17). Logs carry counts only (T-02-42).
    /// A stalled transfer (AOSP halts both bulk endpoints on a phone-side disk error) is recovered by
    /// `recoverStall()` (GetDeviceStatus + clearStall) before this drain runs.
    /// ponytail: a reply that starts after the drain ends is still left to openSession's one retry.
    func cancelTransaction(_ tid: UInt32) {
        var drained = 0
        for _ in 0..<64 {
            guard let bytes = try? read(maxLength: readChunk, timeout: 0.2) else { break }
            drained += bytes.count
        }
        usbLog.info("abandoned tid \(tid): drained \(drained) bytes")
    }

    /// AOSP halts both bulk endpoints when a phone-side disk read/write fails inside sendFile/receiveFile; its
    /// GetDeviceStatus then reports Transaction Cancelled (0x201F) (03-RESEARCH Pattern 3).
    /// One GetDeviceStatus (1 s timeout); on 0x201F, clearStall() on both bulk pipes, because AOSP's
    /// cancelTransaction() always halts both (MtpFfsHandle.cpp) and the listed values are not endpoint addresses:
    /// Linux FunctionFS's FUNCTIONFS_ENDPOINT_REVMAP returns a never-assigned ep->num, so the MIX 4 reports
    /// 0xFF, 0xFF (G-03-1). The values are logged only. Errors are logged and ignored; the session is dropped
    /// afterwards either way. This is the only class request sent: never Cancel 0x64 or Reset 0x66 (G-02-17).
    func recoverStall() {
        let data = NSMutableData(length: 20)!
        let req = IOUSBDeviceRequest(bmRequestType: 0xA1, bRequest: 0x67, wValue: 0, wIndex: interfaceNumber, wLength: 20)
        var n = 0
        do {
            try iface.__send(req, data: data, bytesTransferred: &n, completionTimeout: 1)
        } catch let e as NSError {
            usbLog.error("stall: device status failed: \(String(format: "0x%08X", UInt32(truncatingIfNeeded: e.code)), privacy: .public)")
            return
        }
        let status = DeviceStatus([UInt8](UnsafeRawBufferPointer(start: data.bytes, count: min(n, data.length))))
        let listed = status.endpoints.map { String(format: "0x%02X", $0) }.joined(separator: " ")
        usbLog.info("stall: device status \(String(format: "0x%04X", status.code), privacy: .public), endpoints \(listed, privacy: .public)")
        // ponytail: untested on hardware (IN-07): any status but 0x201F leaves a device-side halt for the reconnect
        // to hit. Phase 4/6 hardware checklist: force a phone-side disk error; clear the pipes on any status if it wedges.
        guard status.code == MTPCode.transactionCancelled else { return }
        var cleared = 0
        for pipe in [bulkIn, bulkOut] {
            do {
                try pipe.clearStall()
                cleared += 1
            } catch let e as NSError {
                usbLog.error("stall: clearStall failed: \(String(format: "0x%08X", UInt32(truncatingIfNeeded: e.code)), privacy: .public)")
            }
        }
        usbLog.info("stall: cleared \(cleared) endpoints")
    }

    func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] {
        // ioData buffers have a fixed length, so one is kept per request size (always readChunk in practice).
        let d: NSMutableData
        if let b = readBuffer, b.length == maxLength { d = b } else {
            d = try pipeCall("Bulk read") { try iface.ioData(withCapacity: maxLength) }
            readBuffer = d
        }
        var n = 0
        try pipeCall("Bulk read") { try bulkIn.__sendIORequest(with: d, bytesTransferred: &n, completionTimeout: timeout) }
        return [UInt8](UnsafeRawBufferPointer(start: d.bytes, count: min(n, maxLength)))
    }
}

/// Maps an IOUSBHost NSError to `MTPError`, so no raw NSError reaches the UI.
private func pipeCall<T>(_ operation: String, _ body: () throws -> T) throws -> T {
    do { return try body() } catch let e as NSError {
        let code = UInt32(truncatingIfNeeded: e.code)
        usbLog.error("\(operation, privacy: .public) failed: \(String(format: "0x%08X", code), privacy: .public)")
        if unplugCodes.contains(code) { throw MTPError.deviceGone }
        throw MTPError.io(operation: operation, code: code)
    }
}

/// A self-re-arming read on the interrupt pipe (RESEARCH Pattern 2). It holds no app state: it only hands
/// byte copies to `yield`. The IO queue is never the session actor's queue, so a pending interrupt read and a
/// synchronous bulk call never block each other.
// Invariant that makes @unchecked Sendable sound: `pipe` and `buffer` are touched only on the interface's IO
// queue — the first `arm()` is dispatched there, and IOUSBHost services every completion there.
final class EventReader: @unchecked Sendable {
    private let pipe: IOUSBHostPipe
    private let buffer: NSMutableData
    private let yield: @Sendable ([UInt8]) -> Void

    init(pipe: IOUSBHostPipe, buffer: NSMutableData, yield: @escaping @Sendable ([UInt8]) -> Void) {
        self.pipe = pipe; self.buffer = buffer; self.yield = yield
    }

    /// Any status but success (unplug, or `iface.destroy()` aborting the request) ends the reader for good: it
    /// never re-arms after an error, so an unplug can't spin the IO queue (T-02-22).
    func arm() {
        do {
            // completionTimeout must be 0 for interrupt pipes (IOUSBHostPipe.h).
            try pipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [self] status, n in
                guard status == kIOReturnSuccess else {
                    usbLog.info("event reader stopped: \(String(format: "0x%08X", UInt32(bitPattern: status)), privacy: .public)")
                    return
                }
                yield([UInt8](UnsafeRawBufferPointer(start: buffer.bytes, count: min(n, buffer.length))))
                arm()
            }
        } catch {
            usbLog.error("event read not queued: \(String(describing: error), privacy: .public)")
        }
    }
}
