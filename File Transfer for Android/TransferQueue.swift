import AppKit
import MTPKit
import Observation
import SwiftUI
import os

/// Copy jobs and the Copy window that shows them (D-01, D-03). Every job is scanned as soon as it is added and asks
/// about name clashes on a sheet before any byte moves (P4 D-01, D-05); answered jobs copy one at a time, the oldest
/// first (D-02). The engine (MTPKit `Transfer`) runs off the MainActor; this store only tracks rows and alerts.
@Observable
final class TransferQueue {
    typealias Job = TransferJob

    /// Every job, in the order it was added; every transition goes through `TransferJobs`. The Copy window
    /// closes when it has no row at all (a failed row keeps it open, D-12), and the Mac stays awake while any job
    /// but a failed row exists (XFER-11, RESEARCH Pitfall 7).
    private(set) var jobs = TransferJobs() {
        didSet {
            fireEnds(was: oldValue)
            dropStaging()
            if jobs.isEmpty { window?.orderOut(nil) }
            if !jobs.hasActive {
                if let activity { ProcessInfo.processInfo.endActivity(activity) }
                activity = nil
            } else if activity == nil {
                // .userInitiated includes idle-system-sleep-disabled and turns App Nap off.
                activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Copying files")
            }
        }
    }
    /// A copy in progress (scanning to canceling); failed rows aren't one: they don't keep the Mac awake, make quitting
    /// ask, hold up Stop & Quit or block the browser's file operations (D-18, RESEARCH Pitfall 7).
    var hasActive: Bool { jobs.hasActive }
    /// The no-space refusals (D-04) and `show(_:)`'s alerts, oldest first. Every other end of a job is its failed row
    /// (D-12).
    private(set) var alerts: [AlertText] = []
    /// Each copying job's bottom line ("X of Y (R/s) – time"), redrawn at most once a second so it doesn't flicker.
    private(set) var lines: [Job.ID: String] = [:]
    /// Each copying job's rate meter and when its line was last redrawn (`systemUptime` seconds).
    @ObservationIgnored private var meters: [Job.ID: (meter: RateMeter, redrawn: Double)] = [:]
    /// Each drag-out job's end callback, called once when the job leaves or turns into a failed row (D-05), with the
    /// report of which items landed (G-05-1-2).
    @ObservationIgnored private var onEnds = JobLedger<Job.ID, (id: Job.ID, end: (EndReport) -> Void)>()
    /// Each promise drop's staging folder (05-08), or a drag out's download temps folder (G-05-1-2): deleted only when
    /// the ledger says no drop or job needs it (D-10).
    @ObservationIgnored private var staged = StagingLedger<Job.ID>()

    /// A job's session dropped its transport (any non-response error); never called for a stop or a refusal.
    @ObservationIgnored var onSessionLost: (any Error, DeviceSession) -> Void = { _, _ in }
    /// An upload job ended with an outcome (finished, stopped or lost): the phone folders it added to (D-03), and the
    /// objects it made there (WR-02).
    @ObservationIgnored var onUploaded: (DeviceSession, Set<FolderKey>, Set<UInt32>) -> Void = { _, _, _ in }
    /// An uploaded file's rename landed: its handle, and the original it replaced, if any (D-23). The phone sends no
    /// event for the app's own rename, so the browser re-reads that one object now (RESEARCH Pitfall 10).
    @ObservationIgnored var onLanded: (DeviceSession, UInt32, UInt32?) -> Void = { _, _, _ in }
    /// The connected phone and its session (`connected` / `disconnected`, from AppModel). A failed row's Retry needs
    /// its job's own phone (D-14); no job starts without a session (RESEARCH Pitfall 12).
    private(set) var phone: PhoneID?
    private(set) var session: DeviceSession?
    /// Each job's scan or copy task: cancelling one stops only that job (D-06).
    @ObservationIgnored private var tasks: [Job.ID: Task<Void, Never>] = [:]
    /// Each failed job's reconnect fix-up while it runs, with the session it runs on; a Retry's scan and its attempt
    /// wait for it, so no temp is ever acted on by two fix-ups at once (D-24, T-04-31).
    @ObservationIgnored private var fixUps: [Job.ID: (session: DeviceSession, task: Task<Void, Never>)] = [:]
    /// The clash sheet on the Copy window, while one is up.
    @ObservationIgnored private var question: (job: Job.ID, clash: ItemKey, alert: NSAlert)? {
        didSet { askingJob = question?.job }
    }
    /// The job whose clash sheet is up, if one is.
    private(set) var askingJob: Job.ID?
    /// A clash sheet is up: the Show sheet waits for it (and a question waits for the Show sheet, `askNext`).
    var isAsking: Bool { askingJob != nil }
    /// The content height the Copy window keeps while a sheet is attached, 0 otherwise (S5): CopyView's minimum height,
    /// so `sizingOptions = .preferredContentSize` grows the window, top edge fixed, and shrinks it back (measured).
    private(set) var sheetRoom: CGFloat = 0
    /// Each row's bottom edge in CopyView, measured by CopyView: a clash sheet attaches below its row (S5).
    @ObservationIgnored var rowBottoms: [Job.ID: CGFloat] = [:]
    /// The sleep-prevention token, held while `hasActive`.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var window: CopyWindow?
    /// The browser window, set by `CloseGuardInstaller`; the quit question attaches here (D-11).
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// Held here because `NSWindow.delegate` is weak and the queue lives as long as the app.
    @ObservationIgnored fileprivate var closeGuard: CloseGuard?
    @ObservationIgnored private let log = Logger(subsystem: "com.xianglin.File-Transfer-for-Android", category: "transfer")

    func dismissAlert() {
        if !alerts.isEmpty { alerts.removeFirst() }
    }

    /// An alert from outside a job (a drop's failed promises, O-16..O-19), shown by RootView's end-of-job queue, one at
    /// a time.
    func show(_ alert: AlertText) { alerts.append(alert) }

    /// Copies `entries` (already reduced to top-level items, D-21) into the Mac folder `folder`; `paths` are their
    /// phone paths, for a Retry after a replug (D-14). `onEnd` runs once when the job leaves or fails (a drag out's
    /// promise completions, D-05). `temps`: the app's own folder for its download temps (a drag out's, G-05-1-2).
    func download(_ entries: [ObjectEntry], paths: [[String]], to folder: URL, phone: PhoneID, session: DeviceSession,
                  temps: URL? = nil, onEnd: ((EndReport) -> Void)? = nil) {
        let job = Job(names: entries.map(\.name), destinationName: folder.lastPathComponent,
                      request: .download(entries, paths: paths, to: folder), phone: phone, session: session)
        if let onEnd { onEnds.record((job.id, onEnd), for: job.id) }
        if let temps { staged.record(temps, for: job.id) }
        enqueue(job)
    }

    /// D-05: finished, stopped, refused for free space, failed or cut by a disconnect all leave `live` here; a later
    /// Retry of a failed row has nothing left to call. `endReport` says which items landed: a stop or a refusal gets
    /// the silent one, a failed row an error for each item that didn't land.
    private func fireEnds(was old: TransferJobs) {
        let live = Set(jobs.all.filter { $0.state != .failed }.map(\.id))
        for (id, end) in onEnds.takeEnded(live: live) { end(jobs.endReport(for: id, was: old)) }
    }

    /// Copies the Mac items `urls` into the phone folder `parent` of `storage` (D-18), whose names from the root are
    /// `path`; `destinationName` labels the row. `staging` is the promise drop's folder the items sit in (05-08): it
    /// stays while this job, or its failed row for Retry, is listed (P4 D-14).
    func upload(_ urls: [URL], storage: UInt32, parent: UInt32, path: [String], destinationName: String, phone: PhoneID,
                session: DeviceSession, staging: URL? = nil) {
        let job = Job(names: urls.map(\.lastPathComponent), destinationName: destinationName,
                      request: .upload(urls, storage: storage, parent: parent, path: path), phone: phone, session: session)
        if let staging { staged.record(staging, for: job.id) }
        enqueue(job)
    }

    /// A promise drop opened `folder`: nothing in it goes until `releaseStaging` (D-10, T-05-32).
    func holdStaging(_ folder: URL) { staged.hold(folder) }

    /// The promise drop is finished: `folder` goes now unless a job of it is still listed (then it goes with that job).
    func releaseStaging(_ folder: URL) {
        if let folder = staged.release(folder) { removeStaging(folder) }
    }

    /// Deletes the staging folders whose last job just left the list (finished, or a failed row dismissed).
    private func dropStaging() {
        for folder in staged.jobsLeft(live: Set(jobs.all.map(\.id))) { removeStaging(folder) }
    }

    private func removeStaging(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            log.error("staging folder not deleted: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The phone is connected (AppModel's `becomeConnected`). Jobs paused for a silent reconnect of this same phone
    /// carry on (D-16): a paused scan starts again; the rest find their items again by path when they start (04-08).
    /// Each failed row of this same phone gets the temps it recorded fixed up now, with no prompt (D-14, D-24), one
    /// fix-up per job at a time; then the next question and the next job.
    func connected(_ phone: PhoneID, session: DeviceSession) {
        self.phone = phone
        self.session = session
        for id in jobs.resumed(phone) { tasks[id] = Task { await scan(id) } }
        for job in jobs.all where job.state == .failed && !job.leftovers.isEmpty && job.phone.isSame(as: phone)
            && fixUps[job.id]?.session !== session {
            let id = job.id, previous = fixUps[id]?.task
            fixUps[id] = (session, Task {
                await previous?.value
                do {
                    try await fixUpLeftovers(id, session: session)
                } catch {
                    if case .lost = TransferEnd(error) { onSessionLost(error, session) }
                }
                if fixUps[id]?.session === session { fixUps[id] = nil }
            })
        }
        askNext()
        startNext()
    }

    /// A silent reconnect began (AppModel, D-16): every job the user isn't stopping pauses until the same phone is back.
    /// A scan is cancelled (`connected` starts it again). A running attempt is left to end on the dead session: its
    /// `endJob` moves the job on, and a Stop or a pull meanwhile cancels it through `stop` / `ended`. A question sheet
    /// stays up: answers are keyed by item, not handle. Nothing starts until `connected` (no session).
    func paused() {
        for id in jobs.paused() { tasks.removeValue(forKey: id)?.cancel() }
    }

    /// The session ended (AppModel's `resetDeviceState`); jobs were already ended through `ended(disconnected:)` or
    /// paused through `paused()`.
    func disconnected() {
        phone = nil
        session = nil
    }

    /// P4 D-05: the scan starts at once, even behind a copying job; it interleaves with that job's chunks on the
    /// session actor, the way browsing does.
    private func enqueue(_ job: Job) {
        jobs.add(job)
        showWindow()                         // every new copy brings back a window the user closed
        tasks[job.id] = Task { await scan(job.id) }
    }

    /// A failed row's Retry (D-14, D-17, D-28): only from a failed row of the connected phone, so a second press
    /// starts nothing. It scans at once like a new job, asking only a clash the job's answers don't cover, then waits
    /// behind the jobs already waiting (`jobs.retry` moved it to the end).
    func retry(_ id: Job.ID) {
        guard jobs.canRetry(id, connected: phone), jobs.retry(id) else { return }
        showWindow()
        tasks[id] = Task { await scan(id) }
    }

    /// × on a failed row (D-18).
    func dismiss(_ id: Job.ID) {
        jobs.dismiss(id)
    }

    /// × on a failed row: a row still holding a phone temp asks first (D-01), as `RootView.askDelete` does: Cancel
    /// takes Return and Escape, only a click on the red Remove from List drops the row and with it the only way to
    /// finish that temp (T-06-14). A row without temps goes at once. A question that waited behind the sheet goes up
    /// after it.
    func confirmDismiss(_ id: Job.ID) {
        guard let job = job(id), !job.leftovers.isEmpty else { return dismiss(id) }
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = TransferText.removeQuestion(names: job.leftovers.map(\.name))
        alert.informativeText = TransferText.removeDetail
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        alert.addButton(withTitle: TransferText.removeFromList).hasDestructiveAction = true
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === alert.window else { return event }
            cancel.performClick(nil)
            return nil
        }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if let escape { NSEvent.removeMonitor(escape) }
            if response == .alertSecondButtonReturn { dismiss(id) }
            askNext()
        }
    }

    /// The row's stop button or the sheet's Stop, no confirmation (D-05): a scanning job's scan is cancelled, an
    /// asking or waiting job just leaves, the running one turns Canceling… and stops at the next chunk boundary.
    /// Other jobs are untouched (D-06). A Retry stopped while asking is a failed row again, so its sheet comes down.
    /// The task handle goes with the cancel: a scan cancelled here never touches the job again (`scan`), so a Retry
    /// pressed before it unwinds owns the slot.
    func stop(_ id: Job.ID) {
        if jobs.stop(id) { tasks.removeValue(forKey: id)?.cancel() }
        endQuestionIfGone()
    }

    /// Stop & Quit (D-11): every waiting job leaves, the running one turns Canceling… and cleans up.
    func stopAll() {
        for job in jobs.all { stop(job.id) }
    }

    /// True once every job has ended (failed rows don't count), false if `limit` passes first.
    /// ponytail: polls every 100 ms; a phone that doesn't answer within `limit` may leave a hidden temp behind, never
    /// under a real name: a Mac `.aft-download` (the next download into that folder sweeps it, WR-04) or a phone
    /// `.aft-upload` (hidden and left alone, D-25). Await the job tasks instead if 100 ms of quit latency ever matters.
    func settled(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while jobs.hasActive {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// The session was replaced or unplugged (Pitfall 11): every job the user isn't already stopping becomes a failed
    /// row (D-13), scanning, asking and waiting ones at once (their scans cancelled, a sheet about one taken down,
    /// Pitfall 14), a running one when its task returns (through `endJob`).
    func ended(disconnected: Bool) {
        for id in jobs.ended(disconnected: disconnected) { tasks.removeValue(forKey: id)?.cancel() }
        endQuestionIfGone()
        askNext()
        startNext()
    }

    /// Orders the Copy window front without taking focus from the browser window. When the app is not active (a drag
    /// out just dropped in Finder) it comes above the other app anyway: the Copy window is the one place a drag out's
    /// progress shows (D-02).
    func showWindow() {
        if window == nil {
            let host = NSHostingController(rootView: CopyView(queue: self))
            host.sizingOptions = .preferredContentSize
            let window = CopyWindow(contentViewController: host)
            window.title = "Copy"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.setFrameAutosaveName("Copy")
            window.sheetOffset = { [weak self] in self?.askingJob.flatMap { self?.rowBottoms[$0] } ?? 0 }
            self.window = window
            observeSheets(on: window)
        }
        if NSApp.isActive { window?.orderFront(nil) } else { window?.orderFrontRegardless() }
    }

    /// S5, D-11. Sheet fit: every sheet on the Copy window (clash, Show, × confirmation) gets room for itself plus
    /// 40 pt below where it attaches; the sheet's frame is read a turn after willBegin, since `attachedSheet` is still
    /// nil then (measured). Buried question: while a clash sheet is up and the app is active, the browser becoming key
    /// orders the Copy window back just above it without making it key, so the browser stays usable (D-01). The
    /// window and the queue live as long as the app, so the observers are never removed.
    private func observeSheets(on window: CopyWindow) {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let sheet = window.attachedSheet else { return }
                    self.sheetRoom = window.sheetOffset() + sheet.frame.height + 40
                }
            }
        }
        center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sheetRoom = 0 }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let key = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.isAsking, NSApp.isActive, let main = self.mainWindow, key == ObjectIdentifier(main)
                else { return }
                // Next turn: the browser is made key before it is ordered front, which would bury this again (measured).
                DispatchQueue.main.async { window.order(.above, relativeTo: main.windowNumber) }
            }
        }
    }

    /// Only while a session is live (RESEARCH Pitfall 12): a job that ends after `disconnected()` or during a
    /// reconnect can't start the next one on a dead session; `connected` starts it once the phone is back.
    private func startNext() {
        guard session != nil, let job = jobs.startNext() else { return }
        tasks[job.id] = Task { await attempt(job.id) }
    }

    private func job(_ id: Job.ID) -> Job? { jobs.all.first { $0.id == id } }

    /// The job as the queue holds it now (after the attempt's rebind and fix-up), with its plan: its answers so far,
    /// and what earlier attempts finished or a reconnect already listed as failed, and the folders they made, so a
    /// Retry or a continuation copies only what isn't done, inside those folders (D-16, D-17, 04-06). `unanswered` is
    /// how a clash nobody answered is planned (P4 D-01). Gone: it was stopped.
    private func plan(_ id: Job.ID, unanswered: Unanswered) async throws -> (Job, TransferPlan) {
        guard let job = job(id) else { throw CancellationError() }
        switch job.request {
        case let .download(entries, _, folder):
            return (job, try await Transfer.planDownload(entries, into: folder, answers: job.answers,
                                                       settled: job.excluded, folders: job.folders,
                                                       unanswered: unanswered, session: job.session))
        case let .upload(urls, storage, parent, path):
            return (job, try await Transfer.planUpload(urls, storage: storage, parent: parent, path: path,
                                                     answers: job.answers, settled: job.excluded, folders: job.folders,
                                                     unanswered: unanswered, session: job.session))
        }
    }

    /// D-14: a job planned on an earlier session (a Retry after a replug: new handles, RESEARCH Pitfall 12) is found
    /// again by path on the connected one and rebound to it, so `plan(id)` plans, checks space and runs there and
    /// `endJob` reports a loss on it. False: its destination folder is gone, and the job has ended with that.
    private func rebound(_ id: Job.ID) async throws -> Bool {
        guard let job = job(id), let session, job.session !== session else { return true }
        let resolved: (request: Job.Request, missingDestination: Bool)
        do {
            resolved = try await Transfer.resolve(job.request, session: session)
        } catch {
            // Not rebound yet, so endJob would report this on the job's old session.
            if case .lost = TransferEnd(error) { onSessionLost(error, session) }
            throw error
        }
        try Task.checkCancellation()
        guard resolved.missingDestination else {
            jobs.rebind(id, session: session, request: resolved.request)
            return true
        }
        // Its temps were inside the destination and went with it, as for a folder the fix-up doesn't find. Each item
        // not copied is listed as not retryable, covering what a Retry listed under it (04-06's rule): Retry would
        // only fail the same way.
        jobs.fixedUp(id, handled: job.leftovers, finished: [])
        let failed = job.names.indices.map { ItemKey(top: $0) }.filter { !job.settled.contains($0) }.map {
            TransferFailure(name: job.names[$0.top], detail: TransferText.folderGone, key: $0, retryable: false)
        }
        endJob(id, outcome: TransferOutcome(failed: failed))
        return false
    }

    /// D-24: each temp the job recorded, found by its folder's path on `session` (never the recorded handle: it may
    /// date from an earlier session), is finished or deleted by `Transfer.fixUp` and forgotten at once, so a later loss
    /// never fixes it up twice. A folder no longer there took its temp with it: forgotten too, with no phone write, so
    /// it never keeps Retry offered. An error response keeps that temp recorded; a stop or a lost session is thrown.
    /// The leftovers are read from `jobs` when it starts, so one another fix-up already handled is never acted on again.
    private func fixUpLeftovers(_ id: Job.ID, session: DeviceSession) async throws {
        for left in job(id)?.leftovers ?? [] {
            try Task.checkCancellation()
            guard self.session === session else { return }      // replaced meanwhile: the next connect fixes it up
            do {
                guard let path = try await Transfer.find(left.folderPath, storage: left.storage, session: session),
                      path.last?.isFolder ?? true else {
                    jobs.fixedUp(id, handled: [left], finished: [])
                    continue
                }
                let children = try await Transfer.list(storage: left.storage, parent: path.last?.id ?? 0xFFFF_FFFF,
                                                       session: session)
                let finished = try await Transfer.fixUp(left, children: children, session: session)
                jobs.fixedUp(id, handled: [left], finished: finished == nil ? [] : [left.key])
                // No event comes for the app's own rename, so the browser re-reads the file as for a landed upload (WR-03).
                if let finished { onLanded(session, finished, nil) }
            } catch let error as MTPError where error.isResponse {
                log.error("fix-up of a phone temp failed: \(error.detail, privacy: .public)")
            }
        }
    }

    /// The scan: every clash becomes a question, asked before any byte moves; with none the job waits for its turn.
    /// A Retry first waits for its job's reconnect fix-up, so it never asks about the job's own just-finished file, and
    /// is found again on the connected session if it was planned on an earlier one.
    private func scan(_ id: Job.ID) async {
        do {
            await fixUps[id]?.task.value
            guard try await rebound(id) else { return }
            let (_, plan) = try await self.plan(id, unanswered: .ask)
            try Task.checkCancellation()
            tasks[id] = nil
            jobs.scanned(id, clashes: plan.clashes)
            askNext()
            startNext()
        } catch {
            // Cancelled only by a stop or a session end, which already closed the job; a Retry may be scanning it again.
            guard !Task.isCancelled else { return }
            tasks[id] = nil
            let (outcome, fallback) = outcome(of: error)
            endJob(id, outcome: outcome, fallback: fallback)
        }
    }

    /// D-01/D-02: the oldest open question as `ClashSheet` on the Copy window, which comes forward; the browser stays
    /// usable. It waits while the Show sheet is up; CopyView asks again when that closes.
    func askNext() {
        guard question == nil, let (id, clash) = jobs.nextQuestion else { return }
        showWindow()
        guard let window, window.attachedSheet == nil else { return }
        if NSApp.isActive { window.makeKeyAndOrderFront(nil) }     // inactive: ClashSheet raises it (G-05-14)
        // Immediate, so `question` is set before askNext can run again (the sheet goes up before the first suspension).
        Task.immediate {
            let reply = await ClashSheet.present(clash, verb: "copying", on: window) { question = (id, clash.id, $0) }
            question = nil
            switch reply {
            case .answer(let answer, let applyToAll): jobs.answer(id, clash: clash.id, with: answer, applyToAll: applyToAll)
            case .stop: stop(id)
            case .none: break                               // a sheet ended because its job left answers nothing
            }
            askNext()
            startNext()
        }
    }

    /// A sheet whose job is gone or no longer asking (stopped, or its session ended) is taken down, answering nothing;
    /// its completion asks the next question (RESEARCH Pitfall 14).
    private func endQuestionIfGone() {
        guard let question, jobs.all.first(where: { $0.id == question.job })?.state != .asking else { return }
        window?.endSheet(question.alert.window)
    }

    /// Copies a scanned, answered job. A Retry first waits for its reconnect fix-up, is found again on the connected
    /// session if need be (D-14), and fixes up the temps its job still records (D-24, D-27). It is then planned again
    /// from the job as it stands, with its answers, since the destination may have changed since the scan (an earlier
    /// job may have made a name): a new clash gets the job's Apply to All answer if that covers it, else Keep Both, so
    /// nothing is overwritten without an answer (CONTEXT discretion). A lost session ends the job below.
    private func attempt(_ id: Job.ID) async {
        do {
            await fixUps[id]?.task.value
            guard try await rebound(id) else { return }
            if let job = job(id) { try await fixUpLeftovers(id, session: job.session) }
            let (job, plan) = try await self.plan(id, unanswered: .keepBoth)
            try Task.checkCancellation()     // a stop during planning ends here, before the row says Copying
            // D-04: checked as the job starts, so earlier jobs' bytes are already on the destination. A Replace's
            // new copy sits beside the original until the rename, so its size is not subtracted.
            let available = try await Transfer.availableSpace(for: plan, session: job.session)
            try Task.checkCancellation()     // a stop during the check is a plain stop: no refusal alert
            guard plan.totalBytes <= available else {
                alerts.append(TransferText.noSpace(names: job.names, needed: plan.totalBytes, available: available))
                endJob(id, outcome: TransferOutcome())
                return
            }
            jobs.begin(id, total: plan.totalBytes)
            let now = ProcessInfo.processInfo.systemUptime
            var meter = RateMeter()
            meter.add(done: 0, at: now)
            meters[id] = (meter, now)
            lines[id] = TransferText.progress(done: 0, total: plan.totalBytes, bytesPerSecond: nil)
            let session = job.session
            // Only a download's ledger folder holds temps; an upload's is its promise drop's staged source files.
            let temps = job.direction == .download ? staged.folder(for: id) : nil
            let outcome = await Transfer.run(plan, session: session, temps: temps, landed: { [weak self] handle, replaced in
                self?.onLanded(session, handle, replaced)
            }) { [weak self] bytes in
                self?.copied(bytes, for: id)
            }
            endJob(id, outcome: outcome)
        } catch {
            let (outcome, fallback) = outcome(of: error)
            endJob(id, outcome: outcome, fallback: fallback)
        }
    }

    /// A thrown planning error as an outcome: a stop, a lost session (which goes to the app), or a failure whose detail
    /// is the fallback, which lists each top-level item of a first run and leaves a Retry's list as it was.
    private func outcome(of error: any Error) -> (TransferOutcome, fallback: String?) {
        switch TransferEnd(error) {
        case .stopped:
            return (TransferOutcome(cancelled: true), nil)
        case let .lost(e):
            return (TransferOutcome(lost: e), nil)
        case let .failed(detail):
            log.error("planning failed: \(detail, privacy: .private)")
            return (TransferOutcome(), detail)
        }
    }

    /// The one way every job ends. A lost session goes to the app before the job is finished (03-07's reconnect
    /// relies on that order); an upload re-lists what it touched and refreshes free space (D-03); then the job leaves
    /// or becomes its failed row (`TransferJobs.finish`) and the next job starts. A stop or a failure never reaches
    /// `onSessionLost`. The job is read from the queue (a job already gone reports nothing).
    private func endJob(_ id: Job.ID, outcome: TransferOutcome, fallback: String? = nil) {
        if let job = job(id) {
            if let lost = outcome.lost { onSessionLost(lost, job.session) }
            if job.direction == .upload { onUploaded(job.session, outcome.touched, outcome.created) }
        }
        tasks[id] = nil
        meters[id] = nil
        lines[id] = nil
        jobs.finish(id, outcome: outcome, fallback: fallback)
        startNext()
    }

    /// One chunk landed: the bar moves now; the rate and time remaining are redrawn at most once a second.
    private func copied(_ bytes: UInt64, for id: Job.ID) {
        jobs.add(bytes: bytes, to: id)
        guard let job = job(id), var m = meters[id] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        m.meter.add(done: job.done, at: now)
        if now - m.redrawn >= 1 {
            m.redrawn = now
            lines[id] = TransferText.progress(done: job.done, total: job.total, bytesPerSecond: m.meter.bytesPerSecond)
        }
        meters[id] = m
    }
}

/// Every main-window close (red button, ⌘W) goes through `NSApp.terminate`, so P1 D-18's close-quits and D-11's
/// question share one path; `applicationShouldTerminate` alone runs only after the window has already closed
/// (RESEARCH Pattern 4). Everything else goes to SwiftUI's own delegate.
final class CloseGuard: NSObject, NSWindowDelegate {
    nonisolated(unsafe) weak var original: (any NSWindowDelegate)?

    init(_ original: (any NSWindowDelegate)?) { self.original = original }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // After the close finishes, from a run-loop timer rather than a main-queue block: a main-queue callout
        // blocks the main queue (and every MainActor job) for as long as terminate runs.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        return false
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }
}

/// Installs the `CloseGuard` on whatever window hosts it (the main window's title changes with navigation, so it is
/// never looked up by title) and hands that window to the queue.
struct CloseGuardInstaller: NSViewRepresentable {
    var queue: TransferQueue

    func makeNSView(context: Context) -> InstallerView { InstallerView(queue: queue) }
    func updateNSView(_ view: InstallerView, context: Context) {}

    final class InstallerView: NSView {
        let queue: TransferQueue

        init(queue: TransferQueue) {
            self.queue = queue
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            queue.mainWindow = window
            guard !(window.delegate is CloseGuard) else { return }
            let closeGuard = CloseGuard(window.delegate)
            queue.closeGuard = closeGuard
            window.delegate = closeGuard
        }
    }
}

/// D-11: quitting while a copy is in progress asks first (failed rows alone don't, D-18). Stop & Quit stops every job,
/// waits up to 10 s for their temp cleanup, then quits with no further alert (D-29): nothing partial is ever under a
/// real name on either side, and a temp left by the quit is hidden on both sides and left alone (D-25).
/// Every reply is immediate (see `QuitGate`), so this works whether terminate came from ⌘Q, a timer or a main-queue
/// block: the question is shown before returning, and its answer runs after terminate has already returned.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var transfers: TransferQueue?
    private var gate = QuitGate()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch gate.request(copying: transfers?.hasActive ?? false) {   // only failed rows: no question (D-18)
        case .quit: return .terminateNow
        case .refuse: return .terminateCancel
        case .ask: break
        }
        let alert = NSAlert()
        alert.messageText = TransferText.quitQuestion
        alert.addButton(withTitle: "Stop & Quit")
        alert.addButton(withTitle: "Cancel")                // titled Cancel, so Escape picks it
        // A sheet can't queue behind another sheet (a picker) or show on a minimized window: ask modally then.
        if let window = transfers?.mainWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { self.answered($0) }
        } else {
            answered(alert.runModal())
        }
        return .terminateCancel
    }

    private func answered(_ response: NSApplication.ModalResponse) {
        let stop = response == .alertFirstButtonReturn
        gate.answered(stop: stop)
        guard stop, let transfers else { return }
        transfers.stopAll()
        Task {
            _ = await transfers.settled(within: .seconds(10))
            gate.stopped()
            NSApp.terminate(nil)                            // the gate now answers .terminateNow
        }
    }
}

/// Never main: clicking the Copy window (a stop button) leaves the browser window main, so the folder picker and
/// every `NSApp.mainWindow` sheet still attach there.
final class CopyWindow: NSWindow, NSWindowDelegate {
    /// How far below the content top a sheet attaches (S5): below the asking row, so its "Waiting for your answer…"
    /// stays in sight; 0 = AppKit's place.
    var sheetOffset: () -> CGFloat = { 0 }

    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        delegate = self                                     // nothing else sets one (measured: nil)
    }

    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        rect.offsetBy(dx: 0, dy: -sheetOffset())
    }
}

/// One row per job (D-01): icon, label, byte-based bar, "X of Y", stop; a failed row instead says what couldn't be
/// copied, with Retry, Show and × (D-12). No glass on rows (CLAUDE.md).
struct CopyView: View {
    var queue: TransferQueue
    /// The failed row whose Show sheet is up.
    @State private var shown: TransferJob.ID?
    private static let rows = "rows"

    var body: some View {
        VStack(spacing: 0) {
            ForEach(queue.jobs.all) { job in
                if job.id != queue.jobs.all.first?.id { Divider() }
                row(job)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.rows)).maxY } action: {
                        queue.rowBottoms[job.id] = $0
                    }
                    .onDisappear { queue.rowBottoms[job.id] = nil }
            }
        }
        .coordinateSpace(.named(Self.rows))
        .frame(width: 440)
        .frame(minHeight: queue.sheetRoom, alignment: .top)
        // RootView's delete-sheet binding style; the sheet goes when its row does. SwiftUI calls onDismiss while the
        // sheet is still the window's attachedSheet (measured), so the waiting question is asked on the next turn.
        .sheet(isPresented: Binding(get: { shownJob != nil }, set: { if !$0 { shown = nil } }),
               onDismiss: { Task { queue.askNext() } }) {
            if let job = shownJob { failuresSheet(job) }
        }
    }

    private var shownJob: TransferJob? { queue.jobs.all.first { $0.id == shown && $0.state == .failed } }

    /// What a failed row lists: its failures, or, on a row left with only phone temps to tidy (D-24), their names.
    private static func listed(_ job: TransferJob) -> [TransferFailure] {
        job.failures.isEmpty ? job.leftovers.map { TransferFailure(name: $0.name, key: $0.key) } : job.failures
    }

    private func row(_ job: TransferJob) -> some View {
        HStack(spacing: 12) {
            if job.state == .failed {
                // The only warning glyph in the app (UI-SPEC S5); the title already says it failed.
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.title2)
                    .accessibilityHidden(true)
                failedRow(job)
            } else {
                Image(systemName: job.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                progressRow(job)
            }
        }
        .padding(12)
    }

    /// "N items couldn’t be copied" and where to; Retry only when something can be retried (a row of only
    /// non-retryable items offers Show and ×), enabled only while the job's own phone is connected; until then the
    /// row says which phone to connect (D-14). A phone with no serial is never known again (Pitfall 13), so its row
    /// offers no Retry rather than asking to connect the phone that is connected (IN-02).
    @ViewBuilder private func failedRow(_ job: TransferJob) -> some View {
        let offersRetry = !job.phone.serial.isEmpty
            && (job.failures.contains(where: \.retryable) || !job.leftovers.isEmpty)
        let waitsForPhone = offersRetry && !job.phone.isSame(as: queue.phone)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: TransferText.failedTitle(Self.listed(job), names: job.names))
                .lineLimit(1)
                .truncationMode(.middle)
            // Where it was going stays visible; the connect hint is a third line while the phone is away (S5).
            secondaryLine("To “\(job.destinationName)”")
            if waitsForPhone { secondaryLine(TransferText.connectToRetry(job.phone.name)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if offersRetry {
            Button("Retry") { queue.retry(job.id) }
                .controlSize(.small)
                .disabled(!queue.jobs.canRetry(job.id, connected: queue.phone))
                .help(waitsForPhone ? TransferText.connectToRetry(job.phone.name) : "")
        }
        Button("Show") { shown = job.id }
            .controlSize(.small)
            .disabled(queue.isAsking)
        Button { queue.confirmDismiss(job.id) } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .help(TransferText.removeFromList)
            .accessibilityLabel(TransferText.removeFromList)
            .disabled(queue.isAsking)
    }

    private func secondaryLine(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// Show (D-12): each item by its path within the job, in the job's order, and why, with the MTP code line where
    /// there is one (P2 D-26). `.fitted`: a ScrollView in a sheet otherwise collapses to nothing (measured).
    private func failuresSheet(_ job: TransferJob) -> some View {
        let listed = Self.listed(job)
        return VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: TransferText.failedTitle(listed, names: job.names))
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(listed.indices, id: \.self) { i in
                        let failure = listed[i]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: failure.key.map { TransferText.itemPath($0, names: job.names) } ?? failure.name)
                            let why = [failure.detail, failure.retryable ? "" : "Can’t be retried"].filter { !$0.isEmpty }
                            if !why.isEmpty {
                                Text(verbatim: why.joined(separator: "\n"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Done") { shown = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .presentationSizing(.fitted)
    }

    @ViewBuilder private func progressRow(_ job: TransferJob) -> some View {
        // Scanned, asking and planned under one Preparing… label and bar; a job stopped before copying keeps it. A
        // reconnecting job keeps its copy title over a bar that just moves (D-16).
        let scanning = [.scanning, .asking, .preparing].contains(job.state)
            || (job.state == .canceling && queue.lines[job.id] == nil)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: scanning
                 ? TransferText.preparing(destination: job.destinationName)
                 : TransferText.title(names: job.names, destination: job.destinationName))
                .lineLimit(1)
                .truncationMode(.middle)
            if scanning || job.state == .reconnecting {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                HStack(spacing: 8) {
                    ProgressView(value: Double(min(job.done, job.total)), total: Double(max(job.total, 1)))
                    Text(verbatim: "\(TransferText.percent(done: job.done, total: job.total))%")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text(verbatim: bottomLine(job))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        Button { queue.stop(job.id) } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .help("Stop")
            .accessibilityLabel("Stop")
            .disabled(job.state == .canceling)
    }

    private func bottomLine(_ job: TransferJob) -> String {
        switch job.state {
        case .asking: TransferText.asking
        case .waiting: TransferText.waiting
        case .canceling: TransferText.canceling
        case .reconnecting: TransferText.reconnecting
        case .scanning, .preparing, .copying, .failed: queue.lines[job.id] ?? ""
        }
    }
}

/// Finder's name-clash sheet, shared by copies (on the Copy window) and moves (on the main window, D-12). Return = Keep
/// Both, so a stray Return never overwrites (P4 D-26); Escape = Stop, through a key monitor scoped to the sheet as in
/// the delete sheet (G-02-5); no Replace on a folder or a type clash (D-08, D-13).
enum ClashSheet {
    enum Reply: Equatable {
        case answer(ClashAnswer, applyToAll: Bool)
        case stop
        /// The sheet was taken down (`endSheet`) without an answer.
        case none
    }

    /// `verb`: "copying" or "moving", for “…the newer one you’re moving?”. `shown` gets the alert as it goes up, before
    /// the first suspension, so the caller can take it down. While the app is inactive (the user switched to Finder)
    /// the window is raised once the sheet is attached and the Dock icon bounces, so the question isn't buried
    /// (04-UI-REVIEW W-E2, Pitfall 5); raised before, the sheet drops it back behind the active app (G-05-14).
    static func present(_ clash: Clash, verb: String, on window: NSWindow, shown: (NSAlert) -> Void = { _ in }) async -> Reply {
        let text = TransferText.clash(clash, verb: verb)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.detail ?? ""
        alert.addButton(withTitle: "Keep Both")             // NSAlert gives its first button Return
        if clash.allowsReplace { alert.addButton(withTitle: "Replace") }
        alert.addButton(withTitle: "Skip")
        let stopButton = alert.addButton(withTitle: "Stop")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to All"
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === alert.window else { return event }
            stopButton.performClick(nil)
            return nil
        }
        shown(alert)
        if !NSApp.isActive {
            DispatchQueue.main.async {                      // the next turn: the sheet below is attached by then
                window.orderFrontRegardless()
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
        let response = await alert.beginSheetModal(for: window)
        if let escape { NSEvent.removeMonitor(escape) }
        // Button order as added; nil = Stop. A response matching no button: the sheet was ended from outside.
        let buttons: [ClashAnswer?] = clash.allowsReplace ? [.keepBoth, .replace, .skip, nil] : [.keepBoth, .skip, nil]
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard buttons.indices.contains(index) else { return .none }
        return buttons[index].map { .answer($0, applyToAll: alert.suppressionButton?.state == .on) } ?? .stop
    }
}
