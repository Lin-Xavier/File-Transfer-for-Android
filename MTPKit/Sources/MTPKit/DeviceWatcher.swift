import Foundation
import IOKit

/// The IORegistry facts the matcher needs about one USB interface.
public struct InterfaceProperties: Sendable, Equatable {
    public var interfaceClass, interfaceSubClass, interfaceProtocol, numEndpoints: UInt8
    public var interfaceString: String?
    public var vendorID: UInt16
    public init(interfaceClass: UInt8, interfaceSubClass: UInt8, interfaceProtocol: UInt8,
                numEndpoints: UInt8, interfaceString: String?, vendorID: UInt16) {
        self.interfaceClass = interfaceClass; self.interfaceSubClass = interfaceSubClass
        self.interfaceProtocol = interfaceProtocol; self.numEndpoints = numEndpoints
        self.interfaceString = interfaceString; self.vendorID = vendorID
    }
}

/// An Android MTP interface: 3 endpoints, interface string "MTP", class 06/01/01 (modern AOSP)
/// or FF/FF/00 (legacy f_mtp gadget). Rejects iPhones/cameras ("PTP" or no string) and Android in PTP mode.
public func isMTPInterface(_ p: InterfaceProperties) -> Bool {
    let triple = (p.interfaceClass, p.interfaceSubClass, p.interfaceProtocol)
    return p.numEndpoints == 3 && p.interfaceString == "MTP"
        && (triple == (0x06, 0x01, 0x01) || triple == (0xFF, 0xFF, 0x00))
}

public struct DeviceCandidate: Sendable, Equatable {
    public let registryID: UInt64            // of the MTP IOUSBHostInterface
    public let vendorID: UInt16
    public let productID: UInt16
    public let productName: String?
}

public enum DeviceEvent: Sendable, Equatable {
    case attached(DeviceCandidate)
    case detached(registryID: UInt64)
}

/// IOKit hotplug → `AsyncStream<DeviceEvent>`. Phones already plugged in are reported as `.attached`
/// when the stream starts; `.detached` is only reported for IDs previously reported as attached.
// Invariant that makes @unchecked Sendable sound: port, iterators and `known` are read and written
// only on `queue` (usb.watch) — start, the IOKit callbacks and teardown all run there.
public final class DeviceWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "usb.watch")
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private var known: Set<UInt64> = []

    private init(_ continuation: AsyncStream<DeviceEvent>.Continuation) { self.continuation = continuation }

    public static func events() -> AsyncStream<DeviceEvent> {
        let (stream, continuation) = AsyncStream<DeviceEvent>.makeStream()
        let watcher = DeviceWatcher(continuation)
        watcher.queue.async { watcher.start() }
        // Captures the watcher: it lives exactly as long as the stream.
        continuation.onTermination = { _ in watcher.queue.async { watcher.stop() } }
        return stream
    }

    /// On any setup failure the stream finishes (logged), so the app can show an error instead of waiting forever.
    private func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            usbLog.error("hotplug: IONotificationPortCreate failed")
            continuation.finish()
            return
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, queue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostInterface"),
                                                  { ctx, it in Unmanaged<DeviceWatcher>.fromOpaque(ctx!).takeUnretainedValue().drain(it, attached: true) },
                                                  ctx, &added)
        if kr == KERN_SUCCESS {
            drain(added, attached: true)            // arms the iterator and reports phones already plugged in
            kr = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostInterface"),
                                                  { ctx, it in Unmanaged<DeviceWatcher>.fromOpaque(ctx!).takeUnretainedValue().drain(it, attached: false) },
                                                  ctx, &removed)
        }
        guard kr == KERN_SUCCESS else {
            usbLog.error("hotplug: IOServiceAddMatchingNotification failed: \(String(format: "0x%08X", kr), privacy: .public)")
            continuation.finish()
            return
        }
        drain(removed, attached: false)
    }

    private func stop() {
        if added != 0 { IOObjectRelease(added); added = 0 }
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
    }

    private func drain(_ iterator: io_iterator_t, attached: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            if attached {
                if let candidate = Self.candidate(service, id: id), known.insert(id).inserted {
                    continuation.yield(.attached(candidate))
                }
            } else if known.remove(id) != nil {
                continuation.yield(.detached(registryID: id))
            }
        }
    }

    private static func candidate(_ service: io_service_t, id: UInt64) -> DeviceCandidate? {
        let props = interfaceProperties(service)
        guard isMTPInterface(props) else { return nil }
        return DeviceCandidate(registryID: id, vendorID: props.vendorID,
                               productID: (deviceProperty(service, "idProduct") as? NSNumber)?.uint16Value ?? 0,
                               productName: deviceProperty(service, "kUSBProductString") as? String)
    }

    /// The matcher's view of an IOUSBHostInterface service (also used by the hardware spike).
    static func interfaceProperties(_ service: io_service_t) -> InterfaceProperties {
        func u8(_ key: String) -> UInt8 { (interfaceProperty(service, key) as? NSNumber)?.uint8Value ?? 0 }
        return InterfaceProperties(interfaceClass: u8("bInterfaceClass"), interfaceSubClass: u8("bInterfaceSubClass"),
                                   interfaceProtocol: u8("bInterfaceProtocol"), numEndpoints: u8("bNumEndpoints"),
                                   interfaceString: interfaceProperty(service, "kUSBString") as? String,
                                   vendorID: (deviceProperty(service, "idVendor") as? NSNumber)?.uint16Value ?? 0)
    }

    static func interfaceProperty(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Device-level keys (idVendor, idProduct, kUSBProductString) live on the direct parent IOUSBHostDevice.
    /// Not a recursive search, which walks on past the device and can return a hub's product string (IN-07).
    static func deviceProperty(_ service: io_service_t, _ key: String) -> Any? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return interfaceProperty(parent, key)
    }
}
