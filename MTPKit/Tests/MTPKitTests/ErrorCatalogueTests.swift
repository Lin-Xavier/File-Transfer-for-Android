import Foundation
import Testing
@testable import MTPKit

/// The one place final user-visible copy is pinned to exact literals (RESEARCH Pitfall 4). Later plans add their rows
/// here; 06-12 updates them after the humanizer pass.
@Suite struct ErrorCatalogueTests {
    // MARK: Welcome sheet and no-device screen (UI-SPEC W-01..W-04, C-02)

    @Test func welcomeCopy() {
        #expect(ConnectionText.steps.count == 3)
        #expect(ConnectionText.steps[0] == "Connect your phone to this Mac with a USB cable.")
        #expect(ConnectionText.steps[1] == "Unlock your phone.")
        #expect(ConnectionText.steps[2] == "On your phone, tap the USB notification and choose File Transfer.")
        #expect(ConnectionText.welcomeTitle == "Welcome to File Transfer for Android")
        #expect(ConnectionText.imageCaptureTip == "To keep Photos and Image Capture from taking your phone when you "
            + "plug it in, open Image Capture, select your phone, click ⋯ in the toolbar and set “Connecting this "
            + "camera opens:” to No application. Then quit Image Capture.")
        #expect(ConnectionText.dragTip == "Drag files and folders between this window and Finder to copy them.")
    }

    // MARK: Connection and storage failures (UI-SPEC E-09..E-15, O-07, O-08; D-08, D-09, D-11)

    @Test func connectionCopy() {
        #expect(ConnectionText.connectFailedTitle == "Can’t connect to your phone")
        #expect(ConnectionText.lostContactTitle == "Lost contact with your phone")
        #expect(ConnectionText.retryBody == "Try reconnecting or restarting your phone.")
        #expect(ConnectionText.storageUnavailableTitle == "Can’t read this storage")
        #expect(ConnectionText.storageUnavailableBody("SD card")
            == "Your phone isn’t sharing “SD card” right now. If it’s an SD card, check that it’s inserted, then click Retry.")
    }

    @Test func storageUnavailableClassifier() {
        #expect(MTPError.response(code: 0x2008, op: 0x1007).isStorageUnavailable)
        #expect(MTPError.response(code: 0x2013, op: 0x1007).isStorageUnavailable)
        #expect(!MTPError.response(code: 0x2009, op: 0x1007).isStorageUnavailable)
        #expect(!MTPError.response(code: 0x2002, op: 0x1007).isStorageUnavailable)
        #expect(!MTPError.deviceGone.isStorageUnavailable)
        #expect(!MTPError.malformed("x").isStorageUnavailable)
    }

    @Test func removedStorageListingIsStorageUnavailable() async throws {
        let session = DeviceSession(transport: FakeAndroidResponder(storages: [FakeAndroidResponder.defaultStorages[0]]))
        _ = try await session.openSession()
        do {
            _ = try await session.handles(storage: 0x0002_0001, parent: 0xFFFF_FFFF)
            Issue.record("listing a removed storage succeeded")
        } catch let error as MTPError {
            #expect(error.isStorageUnavailable)
            #expect(error.detail == "GetObjectHandles failed: 0x2008 (Invalid StorageID)")
        }
    }

    @Test func otherRefusalIsLostContact() {
        let error = MTPError.response(code: 0x2002, op: 0x1007)
        #expect(!error.isStorageUnavailable)
        #expect(error.detail == "GetObjectHandles failed: 0x2002 (General Error)")
    }

    @Test func droppedTransportReadsPhoneDisconnected() async throws {
        let session = DeviceSession(transport: FakeAndroidResponder())
        _ = try await session.openSession()
        await session.close()
        do {
            _ = try await session.storages()
            Issue.record("a closed session listed storages")
        } catch let error as MTPError {
            #expect(error == .deviceGone)
            #expect(error.detail == "The phone was disconnected.")
        }
    }

    @Test func malformedDetail() {
        #expect(MTPError.malformed("x").detail == "Unexpected data from the phone (x)")
    }

    @Test func interruptedCopy() {
        #expect(TransferText.interrupted("Moving “a.jpg”") == "Moving “a.jpg” didn’t finish because the phone was disconnected.")
    }

    // MARK: Operation failures (UI-SPEC S4, O-01..O-19; D-10, D-11)

    /// O-01..O-03: Finder's wording plus the MTP code line; O-02 gains its next step.
    @Test func operationAlertCopy() {
        #expect(OperationAlert.text(for: .response(code: 0x200C, op: 0x9804), name: "X")
            == AlertText(message: "The phone is full. Delete some items on the phone, then try again.",
                         detail: "MTP error 0x200C (Store Full)"))
        #expect(OperationAlert.text(for: .response(code: 0x200F, op: 0x9804), name: "X").message
            == "The phone doesn’t allow changing “X”.")
        #expect(OperationAlert.text(for: .response(code: 0x2002, op: 0x9804), name: "X").message
            == "The operation can’t be completed because an unexpected error occurred.")
    }

    /// O-06a..e; POSIX ENOENT (a download's destination folder gone) stays the system's text (RESEARCH Pitfall 6).
    @Test(arguments: [
        (CocoaError(.fileWriteNoPermission) as any Error, "You don’t have permission to save to this folder."),
        (POSIXError(.EACCES), "You don’t have permission to save to this folder."),
        (POSIXError(.EPERM), "You don’t have permission to save to this folder."),
        (CocoaError(.fileWriteOutOfSpace), "There isn’t enough free space on this Mac."),
        (POSIXError(.ENOSPC), "There isn’t enough free space on this Mac."),
        (CocoaError(.fileWriteVolumeReadOnly), "The disk you’re copying to is read-only."),
        (POSIXError(.EROFS), "The disk you’re copying to is read-only."),
        (CocoaError(.fileReadNoSuchFile), "The item is no longer on this Mac."),
        (CocoaError(.fileReadNoPermission), "You don’t have permission to read this item."),
        (POSIXError(.ENOENT), POSIXError(.ENOENT).localizedDescription),
        (CocoaError(.fileReadCorruptFile), CocoaError(.fileReadCorruptFile).localizedDescription),
    ] as [(any Error, String)])
    func macReasons(error: any Error, reason: String) {
        #expect(TransferText.macReason(error) == reason)
    }

    @Test func transferEndUsesMacReason() {
        #expect(TransferEnd(CocoaError(.fileWriteOutOfSpace)) == .failed("There isn’t enough free space on this Mac."))
    }

    @Test func connectionResetCopy() {
        #expect(TransferText.connectionReset == "The connection to the phone was reset.")
    }

    /// O-10..O-13, O-15 (O-14 is pinned in PreviewTests).
    @Test func previewCopy() {
        #expect(PreviewText.noApp("a.xyz") == AlertText(
            message: "There is no application set to open the document “a.xyz”.",
            detail: "Use the Download button to copy it to this Mac, then open it from Finder with Open With."))
        #expect(PreviewText.noSpace("a.mov", needed: 5_000_000_000, available: 1_200_000_000) == AlertText(
            message: "“a.mov” can’t be opened because there isn’t enough free space on this Mac.",
            detail: "It needs 5 GB, but only 1.2 GB is available."))
        #expect(PreviewText.previewNoSpace("a.mov", needed: 5_000_000_000, available: 1_200_000_000)
            == "“a.mov” can’t be previewed because there isn’t enough free space on this Mac. "
            + "It needs 5 GB, but only 1.2 GB is available.")
        #expect(PreviewText.previewFailed("a.mov", detail: "d") == "“a.mov” couldn’t be previewed. d")
    }

    /// O-16..O-19: one collected alert per drop, singular and plural.
    @Test func promiseCopy() {
        #expect(TransferText.promiseFailed(names: ["a.pdf"]) == AlertText(
            message: "“a.pdf” couldn’t be copied.",
            detail: "The app you dragged from didn’t hand over the file. Save it to a folder on this Mac first, "
                + "then drag it here."))
        #expect(TransferText.promiseFailed(names: ["a", "b", "c"]) == AlertText(
            message: "3 items couldn’t be copied.",
            detail: "The app you dragged from didn’t hand over the files. Save them to a folder on this Mac first, "
                + "then drag them here."))
        #expect(TransferText.promiseTimedOut(count: 1) == AlertText(
            message: "1 item couldn’t be copied.",
            detail: "The app you dragged from didn’t hand it over within 10 minutes. Save it to a folder on this Mac "
                + "first, then drag it here."))
        #expect(TransferText.promiseTimedOut(count: 2) == AlertText(
            message: "2 items couldn’t be copied.",
            detail: "The app you dragged from didn’t hand them over within 10 minutes. Save them to a folder on this "
                + "Mac first, then drag them here."))
    }

    /// D-01, D-02c, D-03b: × on a failed row that still holds a phone temp.
    @Test func copyWindowCopy() {
        #expect(TransferText.removeQuestion(names: ["a.mov"]) == "Remove this row without finishing “a.mov”?")
        #expect(TransferText.removeQuestion(names: ["a", "b", "c"]) == "Remove this row without finishing 3 items?")
        #expect(TransferText.removeDetail == "Part of the copy is still on the phone under a hidden name. "
            + "Retry finishes it, but once you remove the row, the app can’t.")
        #expect(TransferText.replaceRefused == "The phone didn’t allow replacing the item, so the original was kept.")
        #expect(TransferText.removeFromList == "Remove from List")
    }

    /// P-01: the move sheet's line while the move is checked.
    @Test func movePreparingCopy() {
        #expect(TransferText.preparingMove(names: ["a.jpg"]) == "Preparing to move “a.jpg”…")
        #expect(TransferText.preparingMove(names: ["a", "b", "c"]) == "Preparing to move 3 items…")
    }
}
