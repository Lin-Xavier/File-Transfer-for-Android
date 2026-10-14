import AppKit
import Foundation
import MTPKit
import Observation
import os

/// The connection state machine: DeviceWatcher events in, DeviceSession calls out, one phone at a time.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case noDevice, opening, claimed(BusyScreen), locked, failed(String), connected
    }

    /// 01-SPIKE-REPORT ## Decision: guidance-only. ptpcamerad ignored SIGTERM 4/4 on macOS 27, so the app
    /// never signals it and BusyPolicy never offers Release (D-05). ## Busy Device: ptpcamerad lets go on its
    /// own ~10 s after its client app quits, so Retry from the C-06b guidance connects without a replug.
    static let releaseSupported = false

    /// Each phone's learned zone, kept across launches under `phoneZone.<serial>` as a fixed zone name (`GMT+0800`), or
    /// "" for the Mac's zone (quick 261007-cyl, CR-01, re-review WR-01). An offset saved by 261007-cyl under
    /// `phoneUTCOffset.<serial>` still loads until the next creation replaces it, unless it is one of the Mac zone's
    /// winter or summer offsets: that one is left to the Mac's zone (re-review WR-02).
    /// The closures run on the session's queue, so they only touch `UserDefaults.standard` inside (it isn't Sendable).
    private nonisolated static let clockStore = PhoneClockStore(
        load: { serial in
            let defaults = UserDefaults.standard
            if let name = defaults.string(forKey: "phoneZone." + serial) { return TimeZone(identifier: name) }
            guard let old = defaults.object(forKey: "phoneUTCOffset." + serial) as? Int else { return nil }
            let gregorian = Calendar(identifier: .gregorian)   // WR-01: month 1 and 7 must mean January and July
            let year = gregorian.component(.year, from: .now)
            let seasons = [1, 7].compactMap { DateComponents(calendar: gregorian, year: year, month: $0, day: 1).date }
            guard !seasons.contains(where: { TimeZone.current.secondsFromGMT(for: $0) == old }) else { return nil }
            return TimeZone(secondsFromGMT: old)
        },
        save: { UserDefaults.standard.set($1?.identifier ?? "", forKey: "phoneZone." + $0) })

    private(set) var phase: Phase = .noDevice {
        didSet { if phase != oldValue { log.info("phase \(String(describing: self.phase), privacy: .public)") } }
    }
    private(set) var deviceName = ""
    private(set) var storages: [StorageInfo] = []
    /// Navigation and listing for the connected session; nil otherwise, which drops its cache (D-15).
    private(set) var browser: BrowserModel?
    /// Photos, Image Capture or Preview when one was running as the phone came back busy (C-06/C-06b {App}).
    private(set) var photoAppName: String?
    var selectedStorageID: UInt32?
    /// D-09: the selected storage left the list (StoreRemoved or a refresh) while others remain. Shown as the
    /// storage-unavailable state until the user picks another storage or a refresh finds it again, which reselects it.
    private(set) var unavailableStorage: StorageInfo?
    /// The welcome sheet; first launch only (D-01). RootView sets the flag on dismiss, not on show, so quitting with
    /// the sheet open shows it again; Help > Welcome sets this without touching the flag.
    var showWelcome = !UserDefaults.standard.bool(forKey: "WelcomeShown")
    /// "Deleting 3 items didn’t finish because the phone was disconnected." (O-07) One slot, set once in `disconnect()`;
    /// `resetDeviceState()` never clears it, so it survives the detach-vs-error race (D-35, Pitfall 8).
    private(set) var interruptedAlert: String?

    var selectedStorage: StorageInfo? { storages.first { $0.id == selectedStorageID } }
    /// Copy jobs and the Copy window. App lifetime: not reset with the session.
    let transfers = TransferQueue()
    /// Open's temp copies of phone files (PREV-02). App lifetime: its copies, not the store, go with the session.
    let previews = PreviewStore()

    /// Every attached phone in plug-in order. The first is the one shown; the rest wait their turn (D-16).
    @ObservationIgnored private var attached: [DeviceCandidate] = []
    private var candidate: DeviceCandidate? { attached.first }
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// The one consumer of the session's event stream. Only `resetDeviceState` and `listenForEvents` cancel it:
    /// cancelling the task iterating an AsyncStream ends that stream for good.
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var watcherFailed = false
    /// DeviceInfo serial number of the connected phone ("" when none or not reported).
    @ObservationIgnored private var deviceSerial = ""
    /// Where the user was when the phone went away, by folder names; reopened if the same serial comes back (D-36).
    @ObservationIgnored private var lastPlace: (serial: String, storage: UInt32, names: [String])?
    /// Silent reconnects (a spurious drop, or a session lost during a copy): the third within a minute shows the
    /// connection error instead (WR-06, D-10).
    @ObservationIgnored private var reconnects = ReconnectLimit()
    @ObservationIgnored private let log = Logger(subsystem: "com.xianglin.File-Transfer-for-Android", category: "app")

    init() {
        transfers.onSessionLost = { [weak self] error, session in self?.sessionLost(error, from: session) }
        previews.onSessionLost = { [weak self] error, session in self?.sessionLost(error, from: session) }
        transfers.onUploaded = { [weak self] session, keys, created in
            guard let self, self.session === session else { return }
            browser?.uploaded(into: keys, created: created)
        }
        // D-23: each uploaded file shows under its real name as its rename lands, through the browser's own event
        // handling (one GetObjectInfo, upserted into its folder); a replaced original goes first, so it never shows
        // beside its replacement. The end-of-job re-read above stays (WR-02).
        transfers.onLanded = { [weak self] session, handle, replaced in
            guard let self, self.session === session, let browser else { return }
            Task {
                if let replaced { await browser.handle(.objectRemoved(replaced)) }
                await browser.handle(.objectInfoChanged(handle))
            }
        }
    }

    /// Upload…: copies Mac items into the phone folder `key` of `origin`, the session the folder was picked on;
    /// `name` labels the Copy row, `path` is the folder's names for a Retry after a replug (D-14). Handles are
    /// session-scoped (Pitfall 11): if `origin` was replaced while the picker was open (a reconnect, a replug, another
    /// phone), nothing is copied and the Mac beeps (CR-02).
    /// `staging` is a promise drop's folder (05-08); a refusal records no job and deletes nothing, so the drop's own
    /// release removes it once nothing more can arrive.
    func upload(_ urls: [URL], into key: FolderKey, name: String, path: [String], from origin: DeviceSession,
                staging: URL? = nil) {
        guard let session, session === origin else { return NSSound.beep() }
        transfers.upload(urls, storage: key.storage, parent: key.folder, path: path, destinationName: name, phone: phone,
                         session: session, staging: staging)
    }

    /// Download to…: copies phone entries of `origin` into a Mac folder, refused as `upload` is when `origin` is gone.
    /// `onEnd` runs once when the job ends, and at once on a refusal, so a drag out's promises never wait (Pitfall 18);
    /// `stageTemps` (a drag out) keeps its temps in the app's own folder, out of the receiver's (G-05-1-2).
    func download(_ entries: [ObjectEntry], paths: [[String]], to folder: URL, from origin: DeviceSession,
                  stageTemps: Bool = false, onEnd: ((EndReport) -> Void)? = nil) {
        guard let session, session === origin else {
            onEnd?(.silent)
            return NSSound.beep()
        }
        transfers.download(entries, paths: paths, to: folder, phone: phone, session: session,
                           temps: stageTemps ? previews.stagingFolder() : nil, onEnd: onEnd)
    }

    /// The connected phone as copy jobs know it: a Retry needs the same serial (D-14); a silent reconnect also knows a
    /// serial-less phone by its registry ID, since no replug happened (D-16, RESEARCH Pitfall 13).
    private var phone: PhoneID { PhoneID(serial: deviceSerial, name: deviceName, registryID: candidate?.registryID ?? 0) }

    /// Runs for the window's lifetime: phones already plugged in arrive as `.attached` first.
    func start() async {
        for await event in DeviceWatcher.events() {
            switch event {
            case .attached(let c):
                attached.append(c)
                if attached.count == 1 { connect() }              // first phone wins (D-16)
            case .detached(let id):
                guard let i = attached.firstIndex(where: { $0.registryID == id }) else { continue }
                attached.remove(at: i)
                guard i == 0 else { continue }                    // a waiting phone left
                reconnects = ReconnectLimit()
                disconnect()
                if candidate != nil { connect() }                 // the next phone still plugged in (WR-02)
            }
        }
        // The stream only ends early when USB notifications could not be set up (IN-09).
        guard !Task.isCancelled else { return }
        watcherFailed = true
        phase = .failed("Watching for USB devices failed")
    }

    func retry() {
        reconnects = ReconnectLimit()
        if watcherFailed {                                        // restart the watcher, not just the screen (UI-REVIEW #2)
            watcherFailed = false
            phase = .noDevice
            attached = []                                         // the new watcher re-delivers every phone (IN-05)
            Task { await start() }
        } else if case .claimed = phase {
            // ptpcamerad lets go ~10 s after its client quits (spike ## Busy Device), so keep trying that long
            // instead of bouncing straight back to the busy screen (UI-REVIEW #1).
            connect(patience: .seconds(12))
        } else if candidate != nil {
            connect()
        } else {
            phase = .noDevice
        }
    }

    func dismissInterruptedAlert() { interruptedAlert = nil }

    /// The sidebar selection changed: show that storage's root.
    func storageChanged() {
        guard let id = selectedStorageID else { return }
        if id != unavailableStorage?.id { unavailableStorage = nil }
        browser?.show(storage: id)
    }

    /// Re-reads every storage's free space (GetStorageIDs + GetStorageInfo) after a change to the phone (D-17).
    /// The selected storage stays selected; one that left the list is reported, never swapped for another (D-09).
    func refreshStorages() {
        guard let session else { return }
        Task {
            do {
                let found = try await session.storages()
                guard self.session === session, phase == .connected else { return }
                if found.isEmpty { return storagesVanished(session) }                 // locked meanwhile (A6)
                let gone = selectedStorage.flatMap { s in found.contains { $0.id == s.id } ? nil : s }
                storages = found
                if let gone {
                    unavailableStorage = gone                                     // an SD card taken out: say so
                } else if let back = unavailableStorage, found.contains(where: { $0.id == back.id }) {
                    unavailableStorage = nil
                    browser?.storageReturned(back.id)
                    selectedStorageID = back.id
                }
            } catch let error as MTPError where error.isResponse {
                log.error("storage refresh failed: \(error.detail, privacy: .public)")
            } catch {
                sessionLost(error, from: session)
            }
        }
    }

    /// The third-party holder's name for C-07/C-08: the running app for its PID, else the owner string without
    /// PID noise, else nil ("another app"). Display only; never used to decide what to signal.
    func ownerDisplayName(_ screen: BusyScreen) -> String? {
        guard case .otherOwner(let owner?) = screen else { return nil }
        if let pid = owner.pid, let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        return owner.processName
    }

    // MARK: - Connect / disconnect

    /// `patience`: how long to keep re-trying while the phone is held exclusively (Retry from a busy screen).
    /// `pausing`: a silent reconnect during a copy, whose jobs pause and carry on once the phone is back (D-16).
    private func connect(patience: Duration = .zero, pausing: Bool = false) {
        guard let candidate else { phase = .noDevice; return }
        connectTask?.cancel()
        let old = session
        if old != nil {                                          // its handles die with it (Pitfall 11)
            if pausing { transfers.paused() } else { transfers.ended(disconnected: false) }
        }
        let session = DeviceSession(clockStore: Self.clockStore)
        self.session = session
        resetDeviceState()
        phase = .opening
        let previous = connectTask
        connectTask = Task {
            // One connect flow at a time: a cancelled attempt may still be opening the interface, and a second
            // open would find our own process holding it (WR-01).
            await previous?.value
            await old?.close()
            do {
                let deadline = ContinuousClock.now + patience
                while true {
                    do {
                        do {
                            try Task.checkCancellation()
                            try await session.openUSB(registryID: candidate.registryID, seize: false)
                        } catch MTPError.exclusiveAccess(owner: _) {
                            try Task.checkCancellation()
                            try await session.openUSB(registryID: candidate.registryID, seize: true)   // silent (D-01)
                        }
                        break
                    } catch MTPError.exclusiveAccess(owner: _) where ContinuousClock.now < deadline {
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                try await finishOpening(session, candidate: candidate)
            } catch {
                guard !Task.isCancelled, self.session === session else { return }
                guard case let MTPError.exclusiveAccess(owner) = error else {                 // after the seize (D-01)
                    return sessionLost(error, from: session)                                  // D-15
                }
                photoAppName = Self.runningPhotoApp()
                phase = .claimed(BusyPolicy.screen(owner: owner.map(ExclusiveOwner.init(raw:)),
                                                   releasesThisPlugIn: 0,                     // nothing is ever released
                                                   releaseSupported: Self.releaseSupported,
                                                   lastReleaseFailed: false))
                await retryWhileBusy(session, candidate: candidate)
            }
        }
    }

    /// After the interface opened: the MTP session and its event consumer, then the storages, or the locked screen
    /// and its poll when there are none (D-13, D-33).
    private func finishOpening(_ session: DeviceSession, candidate: DeviceCandidate) async throws {
        try Task.checkCancellation()
        let info = try await session.openSession()
        if self.session === session { listenForEvents(session) }   // a superseded attempt must not take over
        try Task.checkCancellation()
        let found = try await session.storages()
        guard !Task.isCancelled, self.session === session else { return }
        deviceName = [info.model, candidate.productName ?? ""].first { !$0.isEmpty } ?? "Android Device"
        deviceSerial = info.serialNumber
        if found.isEmpty {
            phase = .locked
            try await pollUntilUnlocked(session)
        } else {
            await becomeConnected(found, session: session)
        }
    }

    /// Storages listed: the browser on the first storage (D-07), or, when the same phone comes back, on the storage
    /// and folder it was showing (D-36). A different phone starts at the first storage's root.
    private func becomeConnected(_ found: [StorageInfo], session: DeviceSession) async {
        guard let firstID = found.first?.id else { return }
        let place = lastPlace.flatMap { p in
            !p.serial.isEmpty && p.serial == deviceSerial && found.contains { $0.id == p.storage } ? p : nil
        }
        lastPlace = nil
        let storageID = place?.storage ?? firstID
        storages = found
        // Weak: AppModel owns the browser, which keeps these closures.
        let browser = BrowserModel(session: session, storage: storageID,
                                   onSessionLost: { [weak self] error in self?.sessionLost(error, from: session) },
                                   refreshStorages: { [weak self] in self?.refreshStorages() },
                                   transfersActive: { [weak self] in self?.transfers.hasActive ?? false })
        self.browser = browser
        transfers.connected(phone, session: session)    // Retry, the leftover fix-up, the next job (D-14, D-24)
        phase = .connected
        selectedStorageID = storageID
        if let place { await browser.restore(names: place.names) }
    }

    /// Remembers the browsed storage and folder names for D-36 (names only: handles change across sessions).
    private func rememberPlace() {
        guard !deviceSerial.isEmpty, let browser else { return }
        lastPlace = (deviceSerial, browser.storage, browser.location.path.map(\.name))
    }

    /// D-33: one GetStorageIDs every 2 s on the open session until the phone lists its storages. It runs inside
    /// `connectTask`, so a detach or Retry cancels it before anything new starts (T-02-25). An error response keeps
    /// polling (a locked phone may answer Store Not Available); anything else ends it and is thrown.
    private func pollUntilUnlocked(_ session: DeviceSession) async throws {
        while true {
            try await Task.sleep(for: .seconds(2))
            let found: [StorageInfo]
            do {
                found = try await session.storages()
            } catch let error as MTPError where error.isResponse {
                continue
            }
            guard !Task.isCancelled, self.session === session else { return }
            if !found.isEmpty { return await becomeConnected(found, session: session) }
        }
    }

    /// D-34: the busy screen stays up while a normal open is re-tried every 2.5 s (T-02-24); ptpcamerad lets go
    /// ~10 s after its client quits. Never seizes, never signals anything (Phase 1: guidance-only).
    private func retryWhileBusy(_ session: DeviceSession, candidate: DeviceCandidate) async {
        do {
            while true {
                try await Task.sleep(for: .milliseconds(2500))
                do {
                    try await session.openUSB(registryID: candidate.registryID, seize: false)
                    break
                } catch MTPError.exclusiveAccess(owner: _) {
                    guard self.session === session else { return }
                    photoAppName = Self.runningPhotoApp()          // no phase change: no flicker (Pitfall 6)
                }
            }
            try await finishOpening(session, candidate: candidate)
        } catch {
            guard !Task.isCancelled, self.session === session else { return }
            sessionLost(error, from: session)
        }
    }

    /// The storages went away while connected (StoreRemoved or an empty refresh, A6): the locked guidance and its
    /// poll on the same session. The event consumer keeps running; the browser built after unlock gets its events.
    private func storagesVanished(_ session: DeviceSession) {
        rememberPlace()
        browser?.close()
        browser = nil
        storages = []
        selectedStorageID = nil
        unavailableStorage = nil
        phase = .locked
        connectTask?.cancel()
        let previous = connectTask
        connectTask = Task {
            await previous?.value
            do {
                try await pollUntilUnlocked(session)
            } catch {
                guard !Task.isCancelled, self.session === session else { return }
                sessionLost(error, from: session)
            }
        }
    }

    private func disconnect() {
        if let op = browser?.pendingOperation {
            interruptedAlert = TransferText.interrupted(op)
        }
        rememberPlace()
        connectTask?.cancel()
        let old = session
        if old != nil { transfers.ended(disconnected: true) }
        session = nil
        resetDeviceState()
        phase = .noDevice                                                                     // D-14
        Task { await old?.close() }          // off the hotplug loop: a stuck session must not block events (WR-04)
    }

    /// One for-await over `session.events` per session (BRWS-08), forwarding each event to whichever browser is
    /// current, so a browser rebuilt on the same session still gets events. Events with no browser are dropped;
    /// the lock poll and ⌘R cover them.
    private func listenForEvents(_ session: DeviceSession) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in session.events {
                guard let self, self.session === session else { return }
                await self.browser?.handle(event)
            }
        }
    }

    /// Every disconnect and reconnect passes here. Open's temp copies go first (D-20, read-only so nothing is lost,
    /// D-18), while the browser still exists, so a Quick Look panel can close on its data source (Pitfall 17).
    private func resetDeviceState() {
        previews.clear()
        transfers.disconnected()
        eventTask?.cancel()
        eventTask = nil
        browser?.close()
        browser = nil
        storages = []
        selectedStorageID = nil
        unavailableStorage = nil
        deviceName = ""
        deviceSerial = ""
        photoAppName = nil
    }

    /// A copy, listing or operation failed with anything but an error response: the session dropped its transport
    /// (DeviceSession.run, CR-01). Unplugged: the no-device screen, plus the interrupted-change alert (D-35); if the
    /// phone is still attached 2 s later the drop was spurious, so connect again. Any other loss while a copy exists
    /// (a stop the phone didn't settle, a stall, a timeout; whichever call saw it first) reconnects silently back to
    /// the same folder, and the old session's jobs pause and carry on by themselves once the same phone is back (D-16).
    /// Both reconnects share one bound of three a minute; past it, and for a loss with no copy, the connection error,
    /// whose Retry reconnects (WR-06), and every job, paused ones included, becomes a failed row (D-10, D-13).
    private func sessionLost(_ error: any Error, from session: DeviceSession) {
        guard self.session === session else { return }
        let detail = Self.detail(error)
        guard case .deviceGone? = error as? MTPError else {
            guard transfers.hasActive else { phase = .failed(detail); return }      // failed rows aren't copies
            if reconnects.allow(at: .now) {
                log.info("session lost during a copy, reconnecting: \(detail, privacy: .public)")
                rememberPlace()
                connect(pausing: true)
            } else {
                transfers.ended(disconnected: false)
                phase = .failed(detail)
            }
            return
        }
        let gone = candidate
        disconnect()
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard phase == .noDevice, let gone, candidate == gone else { return }
            if reconnects.allow(at: .now) { connect() } else { phase = .failed(detail) }
        }
    }

    /// First running app among Photos, Image Capture, Preview (UI-SPEC {App} rule), else nil.
    private static func runningPhotoApp() -> String? {
        let running = NSWorkspace.shared.runningApplications
        return ["com.apple.Photos", "com.apple.Image_Capture", "com.apple.Preview"].lazy
            .compactMap { id in running.first { $0.bundleIdentifier == id }?.localizedName }.first
    }

    private static func detail(_ error: any Error) -> String {
        (error as? MTPError)?.detail ?? String(describing: error)
    }
}
