import Foundation
import Testing
@testable import MTPKit

@Suite struct PolicyTests {
    // MARK: Exclusive-access classification

    @Test func exclusiveAccessMatchesSignedAndUnsignedCodes() {
        #expect(isExclusiveAccess(NSError(domain: "x", code: Int(Int32(bitPattern: 0xE000_02C5)))))
        #expect(isExclusiveAccess(NSError(domain: "x", code: Int(0xE000_02C5))))
        #expect(!isExclusiveAccess(NSError(domain: "x", code: Int(0xE000_02D8))))
    }

    @Test func exclusiveAccessDetailLine() {
        // macOS 27 refuses a held interface with 0xE00002C9, not 0xE00002C5 (01-SPIKE-REPORT): name no code.
        #expect(MTPError.exclusiveAccess(owner: "pid 1, ptpcamerad").detail
                == "Open interface failed: in use by pid 1, ptpcamerad")
        #expect(MTPError.exclusiveAccess(owner: nil).detail == "Open interface failed: in use by another process")
    }

    // MARK: Owner parsing (data only, never executed)

    @Test(arguments: [
        ("ptpcamerad", true, nil),
        ("PTPCAMERAD", true, nil),
        ("812 com.apple.ptpcamerad", true, 812),
        ("OpenMTP (4411)", false, 4411),
        ("Smart Switch 4, pid 812", false, 812),
        ("", false, nil),
        ("0", false, nil),
    ] as [(String, Bool, Int32?)])
    func ownerParsing(raw: String, isCameraDaemon: Bool, pid: Int32?) {
        let owner = ExclusiveOwner(raw: raw)
        #expect(owner.raw == raw)
        #expect(owner.isCameraDaemon == isCameraDaemon)
        #expect(owner.pid == pid)
    }

    @Test(arguments: [
        ("OpenMTP (4411)", "OpenMTP"),
        ("pid 61256, ptpcamerad", "ptpcamerad"),
        ("812 com.apple.ptpcamerad", "com.apple.ptpcamerad"),
        ("Smart Switch [pid 77]", "Smart Switch"),
    ] as [(String, String)])
    func processNameDropsPIDNoise(raw: String, name: String) {
        #expect(ExclusiveOwner(raw: raw).processName == name)
    }

    @Test(arguments: ["", "  ", "4411", "pid 4411", "(4411)"])
    func processNameIsNilWithoutAName(raw: String) {
        #expect(ExclusiveOwner(raw: raw).processName == nil)
    }

    /// owner-busy.txt lines are `label: <UsbExclusiveOwner>`; the device line is empty (01-SPIKE-REPORT).
    @Test func processNameOfSpikeFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "owner-busy", withExtension: "txt", subdirectory: "Fixtures"))
        let owners = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .compactMap { $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
        #expect(!owners.isEmpty)
        for raw in owners {
            let name = try #require(ExclusiveOwner(raw: raw).processName)
            #expect(!name.isEmpty)
            #expect(name.rangeOfCharacter(from: .decimalDigits) == nil)
        }
    }

    // MARK: Busy policy (D-02..D-05)

    private static let daemon = ExclusiveOwner(raw: "pid 61256, ptpcamerad")

    @Test func firstBusyScreenOffersRelease() {
        #expect(BusyPolicy.screen(owner: Self.daemon, releasesThisPlugIn: 0, releaseSupported: true,
                                  lastReleaseFailed: false) == .cameraDaemonCanRelease)
    }

    @Test(arguments: [1, 2, 5])
    func noSecondReleasePerPlugIn(releases: Int) {
        #expect(BusyPolicy.maxReleasesPerPlugIn == 1)
        #expect(BusyPolicy.screen(owner: Self.daemon, releasesThisPlugIn: releases, releaseSupported: true,
                                  lastReleaseFailed: false) == .cameraDaemonReclaimed)
    }

    @Test func releaseUnsupportedMeansGuidance() {
        #expect(BusyPolicy.screen(owner: Self.daemon, releasesThisPlugIn: 0, releaseSupported: false,
                                  lastReleaseFailed: false) == .cameraDaemonReleaseUnavailable)
    }

    @Test func failedSignalMeansGuidance() {
        #expect(BusyPolicy.screen(owner: Self.daemon, releasesThisPlugIn: 1, releaseSupported: true,
                                  lastReleaseFailed: true) == .cameraDaemonReleaseUnavailable)
    }

    @Test func unknownOwnerIsOtherOwner() {
        #expect(BusyPolicy.screen(owner: nil, releasesThisPlugIn: 0, releaseSupported: true,
                                  lastReleaseFailed: false) == .otherOwner(nil))
    }

    @Test(arguments: ["OpenMTP (4411)", "Smart Switch", "pid 12, camerad", ""], [0, 1, 5])
    func thirdPartyOwnersAreNeverReleasable(raw: String, releases: Int) {
        let owner = ExclusiveOwner(raw: raw)
        for supported in [true, false] {
            for failed in [true, false] {
                #expect(BusyPolicy.screen(owner: owner, releasesThisPlugIn: releases, releaseSupported: supported,
                                          lastReleaseFailed: failed) == .otherOwner(owner))
            }
        }
    }

    // MARK: CameraDaemon safety

    @Test func cameraDaemonPathIsExact() {
        #expect(CameraDaemon.path == "/usr/libexec/ptpcamerad")
    }

    @Test func terminateRefusesAnyOtherProcess() {
        let me = ProcessInfo.processInfo.processIdentifier
        #expect(CameraDaemon.terminate(me) != 0)
        #expect(kill(me, 0) == 0)          // still alive: no signal was sent
    }

    @Test func pidsNeverIncludeThisProcess() {
        #expect(!CameraDaemon.pids().contains(ProcessInfo.processInfo.processIdentifier))
    }

    // MARK: MTP interface matcher

    private static func iface(_ c: UInt8, _ s: UInt8, _ p: UInt8, _ eps: UInt8, _ name: String?, _ vendor: UInt16) -> InterfaceProperties {
        InterfaceProperties(interfaceClass: c, interfaceSubClass: s, interfaceProtocol: p,
                            numEndpoints: eps, interfaceString: name, vendorID: vendor)
    }

    @Test(arguments: [
        iface(0x06, 0x01, 0x01, 3, "MTP", 0x18D1),     // modern AOSP (Pixel)
        iface(0xFF, 0xFF, 0x00, 3, "MTP", 0x04E8),     // legacy f_mtp gadget (Samsung)
    ])
    func matcherAcceptsMTPInterfaces(_ p: InterfaceProperties) {
        #expect(isMTPInterface(p))
    }

    @Test(arguments: [
        iface(0x06, 0x01, 0x01, 3, "PTP", 0x05AC),     // iPhone
        iface(0x06, 0x01, 0x01, 3, nil, 0x18D1),       // Android in PTP mode
        iface(0x06, 0x01, 0x01, 2, "MTP", 0x18D1),     // wrong endpoint count
        iface(0xFF, 0x42, 0x01, 2, "ADB Interface", 0x18D1),
    ])
    func matcherRejectsEverythingElse(_ p: InterfaceProperties) {
        #expect(!isMTPInterface(p))
    }

    // MARK: List sorting and formatting

    private static func entry(_ id: UInt32, _ name: String, size: UInt64 = 0, folder: Bool = false,
                              modified: Date? = nil) -> ObjectEntry {
        ObjectEntry(id: id, storageID: 0x0001_0001, parent: 0xFFFF_FFFF, format: folder ? 0x3001 : 0x3000,
                    name: name, size: size, modified: modified)
    }

    @Test func nameSortIsNaturalAndDescendingIsExactReverse() {
        let items = [Self.entry(1, "IMG_10.jpg"), Self.entry(2, "a.txt"), Self.entry(3, "IMG_2.jpg"), Self.entry(4, "B.txt")]
        let up = items.sorted(by: .name, ascending: true).map(\.name)
        #expect(up == ["a.txt", "B.txt", "IMG_2.jpg", "IMG_10.jpg"])
        #expect(items.sorted(by: .name, ascending: false).map(\.name) == up.reversed())
    }

    @Test func sizeSortPutsFoldersFirstAndBreaksTiesByName() {
        let items = [Self.entry(1, "one", size: 1), Self.entry(2, "zero", size: 0), Self.entry(3, "dir", folder: true),
                     Self.entry(4, "b", size: 5), Self.entry(5, "a", size: 5)]
        #expect(items.sorted(by: .size, ascending: true).map(\.name) == ["dir", "zero", "one", "a", "b"])
        #expect(items.sorted(by: .size, ascending: false).map(\.name) == ["a", "b", "one", "zero", "dir"])
    }

    @Test func dateSortPutsMissingDatesFirstAndBreaksTiesByName() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [Self.entry(1, "late", modified: d.addingTimeInterval(60)), Self.entry(2, "y", modified: d),
                     Self.entry(3, "none"), Self.entry(4, "x", modified: d)]
        #expect(items.sorted(by: .date, ascending: true).map(\.name) == ["none", "x", "y", "late"])
    }

    @Test(arguments: [ObjectSortKey.name, .size, .date], [true, false])
    func duplicateNamesBreakTiesByHandle(key: ObjectSortKey, ascending: Bool) {
        let items = [Self.entry(7, "dup.jpg", size: 100), Self.entry(3, "dup.jpg", size: 100)]
        #expect(items.sorted(by: key, ascending: ascending).map(\.id) == [3, 7])
    }

    @Test func caseVariantsFollowLocalizedStandardCompare() {
        let items = [Self.entry(3, "A.jpg"), Self.entry(7, "a.jpg")]
        let order = "a.jpg".localizedStandardCompare("A.jpg")
        #expect(order != .orderedSame)
        let expected: [UInt32] = order == .orderedAscending ? [7, 3] : [3, 7]
        #expect(items.sorted(by: .name, ascending: true).map(\.id) == expected)
        #expect(items.sorted(by: .name, ascending: false).map(\.id) == expected.reversed())
    }

    @Test func sizeFormatting() {
        #expect(EntryFormat.size(Self.entry(1, "dir", folder: true)) == "--")
        #expect(EntryFormat.size(Self.entry(2, "empty", size: 0)) == "Zero bytes")
        let big = EntryFormat.size(Self.entry(3, "big.mp4", size: 5_000_000_000))
        #expect(big == ByteCountFormatter.string(fromByteCount: 5_000_000_000, countStyle: .file))
        #expect(big != ByteCountFormatter.string(fromByteCount: 4_294_967_295, countStyle: .file))
    }

    @Test func missingDateFormatsAsDashes() {
        #expect(EntryFormat.date(nil) == "--")
        #expect(EntryFormat.date(Date()) != "--")
    }
}
