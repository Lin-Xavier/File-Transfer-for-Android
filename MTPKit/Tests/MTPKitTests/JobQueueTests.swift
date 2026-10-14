import Foundation
import Testing
@testable import MTPKit

/// The queue's pure transitions (TransferJobs): every job scans and asks at once, jobs copy one at a time (D-05, P3 D-02).
@Suite struct JobQueueTests {
    private func job(_ name: String, session: DeviceSession = DeviceSession(transport: FakeAndroidResponder())) -> TransferJob {
        job([name], session: session)
    }

    private func job(_ names: [String], session: DeviceSession = DeviceSession(transport: FakeAndroidResponder()),
                     phone: PhoneID = JobQueueTests.pixel) -> TransferJob {
        TransferJob(names: names, destinationName: "Downloads",
                    request: .upload([], storage: 0x0001_0001, parent: 0xFFFF_FFFF, path: []), phone: phone, session: session)
    }

    /// The phone every job here copies with unless a test says otherwise.
    static let pixel = PhoneID(serial: "FAKE0001", name: "Pixel 9")

    private func row(_ id: TransferJob.ID, _ jobs: TransferJobs) -> TransferJob? {
        jobs.all.first { $0.id == id }
    }

    /// The keys a row lists, in order.
    private func listed(_ id: TransferJob.ID, _ jobs: TransferJobs) -> [ItemKey]? {
        row(id, jobs)?.failures.compactMap(\.key)
    }

    private func state(_ id: TransferJob.ID, _ jobs: TransferJobs) -> TransferJob.State? {
        jobs.all.first { $0.id == id }?.state
    }

    private func questions(_ id: TransferJob.ID, _ jobs: TransferJobs) -> [ItemKey]? {
        jobs.all.first { $0.id == id }?.questions.map(\.id)
    }

    /// Adds `job` and finishes its scan with no clash, so it waits for its turn.
    private func ready(_ jobs: inout TransferJobs, _ job: TransferJob) {
        jobs.add(job)
        jobs.scanned(job.id, clashes: [])
    }

    /// A file onto a file (Replace offered) and a file onto a folder (no Replace, D-08).
    private func fileClash(_ top: Int, _ name: String = "IMG.jpg") -> Clash {
        Clash(id: ItemKey(top: top), existing: Clash.Side(name: name, size: 4), incoming: Clash.Side(name: name, size: 9))
    }

    private func typeClash(_ top: Int, _ name: String = "Photos") -> Clash {
        Clash(id: ItemKey(top: top), existing: Clash.Side(name: name, isFolder: true), incoming: Clash.Side(name: name, size: 9))
    }

    // MARK: scanning and asking (D-01, D-05, XFER-07)

    @Test func aScannedJobAsksItsClashesInOrderOrWaits() {
        var jobs = TransferJobs()
        let a = job("a"), b = job("b")
        jobs.add(a)
        jobs.add(b)
        #expect(state(a.id, jobs) == .scanning && state(b.id, jobs) == .scanning)
        jobs.scanned(a.id, clashes: [])
        #expect(state(a.id, jobs) == .waiting)
        let clashes = [fileClash(2), typeClash(0), fileClash(1)]
        jobs.scanned(b.id, clashes: clashes)
        #expect(state(b.id, jobs) == .asking)
        #expect(questions(b.id, jobs) == clashes.map(\.id))
    }

    @Test func questionsComeOneAtATimeOldestJobFirst() {
        var jobs = TransferJobs()
        let a = job("a"), b = job("b")
        jobs.add(a)
        jobs.add(b)
        #expect(jobs.nextQuestion == nil)                       // nothing scanned yet
        jobs.scanned(b.id, clashes: [fileClash(0, "b.jpg")])
        jobs.scanned(a.id, clashes: [fileClash(0, "a1.jpg"), fileClash(1, "a2.jpg")])
        #expect(jobs.nextQuestion?.job == a.id && jobs.nextQuestion?.clash.existing.name == "a1.jpg")
        jobs.answer(a.id, clash: ItemKey(top: 0), with: .skip, applyToAll: false)
        #expect(jobs.nextQuestion?.job == a.id && jobs.nextQuestion?.clash.existing.name == "a2.jpg")
        jobs.answer(a.id, clash: ItemKey(top: 1), with: .keepBoth, applyToAll: false)
        #expect(jobs.nextQuestion?.job == b.id && jobs.nextQuestion?.clash.existing.name == "b.jpg")
        jobs.answer(b.id, clash: ItemKey(top: 0), with: .replace, applyToAll: false)
        #expect(jobs.nextQuestion == nil)
    }

    @Test func onlyTheFirstQuestionCanBeAnsweredAndTheLastOneMakesTheJobWait() {
        var jobs = TransferJobs()
        let a = job("a")
        jobs.add(a)
        jobs.scanned(a.id, clashes: [fileClash(0), fileClash(1)])
        jobs.answer(a.id, clash: ItemKey(top: 1), with: .replace, applyToAll: false)
        #expect(questions(a.id, jobs) == [ItemKey(top: 0), ItemKey(top: 1)])
        #expect(jobs.all.first?.answers == ClashAnswers())
        jobs.answer(a.id, clash: ItemKey(top: 0), with: .skip, applyToAll: false)
        #expect(state(a.id, jobs) == .asking)
        jobs.answer(a.id, clash: ItemKey(top: 1), with: .replace, applyToAll: false)
        #expect(state(a.id, jobs) == .waiting)
        #expect(jobs.all.first?.answers == ClashAnswers(byItem: [ItemKey(top: 0): .skip, ItemKey(top: 1): .replace]))
    }

    @Test(arguments: [
        (ClashAnswer.keepBoth, [Int]()),
        (.replace, [1]),                                        // the type clash still gets its own sheet (D-08)
        (.skip, []),
    ])
    func applyToAllAnswersEveryQuestionItCovers(answer: ClashAnswer, left: [Int]) {
        var jobs = TransferJobs()
        let a = job("a")
        jobs.add(a)
        jobs.scanned(a.id, clashes: [fileClash(0), typeClash(1), fileClash(2)])
        jobs.answer(a.id, clash: ItemKey(top: 0), with: answer, applyToAll: true)
        #expect(questions(a.id, jobs) == left.map { ItemKey(top: $0) })
        #expect(state(a.id, jobs) == (left.isEmpty ? .waiting : .asking))
        #expect(jobs.all.first?.answers.all == answer)
        if !left.isEmpty {
            #expect(jobs.nextQuestion?.clash.allowsReplace == false)
            jobs.answer(a.id, clash: ItemKey(top: 1), with: .keepBoth, applyToAll: true)
            #expect(state(a.id, jobs) == .waiting)
        }
    }

    // MARK: one job copies at a time (D-05, P3 D-02, Open Question 9)

    @Test func aJobAddedWhileAnotherCopiesAsksAtOnceThenWaitsItsTurn() {
        var jobs = TransferJobs()
        let a = job("a"), b = job("b")
        ready(&jobs, a)
        _ = jobs.startNext()
        jobs.begin(a.id, total: 100)
        jobs.add(b)
        #expect(state(b.id, jobs) == .scanning)
        jobs.scanned(b.id, clashes: [fileClash(0)])
        #expect(jobs.nextQuestion?.job == b.id)                 // asked while a copies
        jobs.answer(b.id, clash: ItemKey(top: 0), with: .replace, applyToAll: false)
        #expect(state(b.id, jobs) == .waiting)
        #expect(jobs.startNext() == nil)
        jobs.finish(a.id, outcome: TransferOutcome())
        let next = jobs.startNext()
        #expect(next?.id == b.id)
        #expect(next?.answers.byItem[ItemKey(top: 0)] == .replace)
    }

    @Test func startNextPassesOverJobsStillScanningOrAsking() {
        var jobs = TransferJobs()
        let a = job("a"), b = job("b"), c = job("c")
        jobs.add(a)
        jobs.add(b)
        jobs.scanned(b.id, clashes: [fileClash(0)])
        ready(&jobs, c)
        #expect(jobs.startNext()?.id == c.id)
        #expect(state(a.id, jobs) == .scanning && state(b.id, jobs) == .asking)
    }

    @Test func jobsStartOneAtATimeInOrder() {
        var jobs = TransferJobs()
        let a = job("a"), b = job("b")
        ready(&jobs, a)
        ready(&jobs, b)
        #expect(state(b.id, jobs) == .waiting)
        #expect(jobs.startNext()?.id == a.id)
        #expect(state(a.id, jobs) == .preparing)
        #expect(jobs.startNext() == nil)
        jobs.begin(a.id, total: 100)
        #expect(state(a.id, jobs) == .copying)
        #expect(jobs.all.first?.total == 100)
        #expect(jobs.startNext() == nil)
        #expect(jobs.stop(a.id) == true)
        #expect(jobs.startNext() == nil)                    // canceling still holds the queue
        jobs.finish(a.id, outcome: TransferOutcome(cancelled: true))
        #expect(jobs.startNext()?.id == b.id)
        #expect(jobs.all.map(\.id) == [b.id])
    }

    // MARK: stop (D-03, D-15)

    @Test func stopInEveryState() {
        var jobs = TransferJobs()
        let scanning = job("s"), asking = job("q"), waiting = job("w"), copying = job("c")
        ready(&jobs, copying)
        _ = jobs.startNext()
        jobs.begin(copying.id, total: 10)
        jobs.add(scanning)
        jobs.add(asking)
        jobs.scanned(asking.id, clashes: [fileClash(0)])
        ready(&jobs, waiting)

        #expect(jobs.stop(scanning.id) == true)                 // the caller cancels its scan
        #expect(jobs.stop(asking.id) == false)
        #expect(jobs.stop(waiting.id) == false)
        #expect(jobs.all.map(\.id) == [copying.id])
        #expect(jobs.nextQuestion == nil)
        #expect(jobs.stop(copying.id) == true)
        #expect(state(copying.id, jobs) == .canceling)
        #expect(jobs.stop(copying.id) == false)
    }

    @Test func stoppingAWaitingJobRemovesOnlyIt() {
        var jobs = TransferJobs()
        let a = job("a"), b = job("b"), c = job("c")
        [a, b, c].forEach { ready(&jobs, $0) }
        _ = jobs.startNext()
        jobs.add(bytes: 5, to: a.id)
        #expect(jobs.stop(b.id) == false)
        #expect(jobs.all.map(\.id) == [a.id, c.id])
        #expect(state(a.id, jobs) == .preparing)
        #expect(jobs.all.first?.done == 5)
        #expect(state(c.id, jobs) == .waiting)
    }

    @Test func stoppingTheRunningJobCancelsItOnce() {
        var jobs = TransferJobs()
        let a = job("a")
        ready(&jobs, a)
        _ = jobs.startNext()
        #expect(jobs.stop(a.id) == true)
        #expect(state(a.id, jobs) == .canceling)
        #expect(jobs.stop(a.id) == false)
        #expect(state(a.id, jobs) == .canceling)
        #expect(jobs.stop(UUID()) == false)
    }

    @Test func scanResultsAndAnswersForAGoneOrStoppedJobChangeNothing() {
        var jobs = TransferJobs()
        let gone = job("gone"), asked = job("asked"), running = job("running")
        jobs.scanned(UUID(), clashes: [fileClash(0)])
        jobs.answer(UUID(), clash: ItemKey(top: 0), with: .replace, applyToAll: true)
        #expect(jobs.isEmpty)

        jobs.add(gone)
        #expect(jobs.stop(gone.id) == true)
        jobs.scanned(gone.id, clashes: [fileClash(0)])          // the scan finished after its stop
        #expect(jobs.isEmpty)

        jobs.add(asked)
        jobs.scanned(asked.id, clashes: [fileClash(0)])
        #expect(jobs.stop(asked.id) == false)
        jobs.answer(asked.id, clash: ItemKey(top: 0), with: .replace, applyToAll: false)   // the sheet's late answer
        #expect(jobs.isEmpty)

        ready(&jobs, running)
        _ = jobs.startNext()
        _ = jobs.stop(running.id)
        jobs.scanned(running.id, clashes: [fileClash(0)])
        jobs.answer(running.id, clash: ItemKey(top: 0), with: .replace, applyToAll: false)
        #expect(state(running.id, jobs) == .canceling)
        #expect(questions(running.id, jobs) == [])
        #expect(jobs.all.first?.answers == ClashAnswers())
    }

    @Test func aPlanningResultNeverOverwritesAStop() {
        var jobs = TransferJobs()
        let a = job("a")
        ready(&jobs, a)
        _ = jobs.startNext()
        _ = jobs.stop(a.id)
        jobs.begin(a.id, total: 100)
        #expect(state(a.id, jobs) == .canceling)
        #expect(jobs.all.first?.total == 0)
    }

    @Test func progressAddsUpPerJob() {
        var jobs = TransferJobs()
        let a = job("a")
        ready(&jobs, a)
        _ = jobs.startNext()
        jobs.begin(a.id, total: 100)
        jobs.add(bytes: 10, to: a.id)
        jobs.add(bytes: 10, to: a.id)
        jobs.add(bytes: 10, to: UUID())
        #expect(jobs.all.first?.done == 20)
    }

    // MARK: failed rows: one rule for every way an attempt ends (D-12, D-13, D-15, D-17, D-19)

    static let k0 = ItemKey(top: 0), k1 = ItemKey(top: 1), k2 = ItemKey(top: 2)
    static let gone = MTPError.deviceGone.detail
    static let reset = TransferText.connectionReset
    static let leftover = PhoneLeftover(storage: 0x0001_0001, folder: 7, temp: ".x.aft-upload", name: "x.bin", size: 3,
                                        key: ItemKey(top: 1))

    private func failure(_ key: ItemKey, _ detail: String = "MTP error 0x2009") -> TransferFailure {
        TransferFailure(name: key.path.last ?? "item \(key.top)", detail: detail, key: key)
    }

    /// What a run lists after an early end: empty detail on a stop, the loss's on a loss.
    private func cutOff(_ keys: [ItemKey], _ detail: String = "") -> [TransferFailure] {
        keys.map { TransferFailure(name: $0.path.last ?? "item \($0.top)", detail: detail, key: $0) }
    }

    /// One failure per top-level item, as a job that never copied lists them.
    private func perItem(_ names: [String], _ detail: String) -> [TransferFailure] {
        names.indices.map { TransferFailure(name: names[$0], detail: detail, key: ItemKey(top: $0)) }
    }

    /// p10…p20 inside the top-level folder "Camera", each with its own detail.
    static let cameraItems = (10...20).map {
        TransferFailure(name: "p\($0).jpg", detail: "d\($0)", key: ItemKey(top: 0, path: ["p\($0).jpg"]))
    }
    static let cameraKeys = cameraItems.compactMap(\.key)

    /// Moves a job that is scanning (just added, or just retried) on to `target`.
    private func advance(_ jobs: inout TransferJobs, _ id: TransferJob.ID, to target: TransferJob.State) {
        switch target {
        case .asking: jobs.scanned(id, clashes: [fileClash(0)])
        case .waiting: jobs.scanned(id, clashes: [])
        case .preparing, .copying:
            jobs.scanned(id, clashes: [])
            _ = jobs.startNext()
            if target == .copying { jobs.begin(id, total: 100) }
        default: break
        }
        #expect(state(id, jobs) == target)
    }

    /// A first run of `names`, added and moved on to `target`.
    private func firstRun(_ names: [String] = ["a", "b", "c"], at target: TransferJob.State = .copying,
                          in jobs: inout TransferJobs,
                          session: DeviceSession = DeviceSession(transport: FakeAndroidResponder()),
                          phone: PhoneID = JobQueueTests.pixel) -> TransferJob.ID {
        let a = job(names, session: session, phone: phone)
        jobs.add(a)
        advance(&jobs, a.id, to: target)
        return a.id
    }

    /// A Retry of a "Camera" row listing p10…p20 (its first run lost the session there), moved on to `target`.
    private func retrying(at target: TransferJob.State, in jobs: inout TransferJobs) -> TransferJob.ID {
        let id = firstRun(["Camera"], in: &jobs)
        jobs.finish(id, outcome: TransferOutcome(failed: Self.cameraItems, folders: [Self.k0: "Camera"], lost: .deviceGone))
        #expect(row(id, jobs)?.failures == Self.cameraItems)
        #expect(jobs.retry(id) == true)
        advance(&jobs, id, to: target)
        return id
    }

    @Test func finishingWithFailuresKeepsARow() {
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs)
        jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k0)], settled: [Self.k1, Self.k2]))
        #expect(state(a, jobs) == .failed && row(a, jobs)?.failures == [failure(Self.k0)])

        var clean = TransferJobs()
        let b = firstRun(in: &clean)
        clean.finish(b, outcome: TransferOutcome(settled: [Self.k0, Self.k1, Self.k2]))
        #expect(clean.isEmpty)

        var kept = TransferJobs()
        let c = firstRun(in: &kept)
        kept.finish(c, outcome: TransferOutcome(settled: [Self.k0, Self.k2], leftovers: [Self.leftover]))
        #expect(state(c, kept) == .failed && listed(c, kept) == [] && row(c, kept)?.leftovers == [Self.leftover])
    }

    @Test func finishLeavesAFailedRowAlone() {
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs)
        jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k0)]))
        jobs.finish(a, outcome: TransferOutcome())
        jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k1)], settled: [Self.k0]))
        jobs.finish(a, outcome: TransferOutcome(lost: .deviceGone), fallback: "x")
        jobs.finish(UUID(), outcome: TransferOutcome())
        #expect(state(a, jobs) == .failed && row(a, jobs)?.failures == [failure(Self.k0)])
        #expect(row(a, jobs)?.settled.isEmpty == true)
    }

    /// D-19: Skips are settled, so a job whose only non-copies are Skips leaves.
    @Test func onlySkipsEndCleanly() {
        var jobs = TransferJobs()
        let a = job(["a", "b", "c"])
        jobs.add(a)
        jobs.scanned(a.id, clashes: [fileClash(1)])
        jobs.answer(a.id, clash: Self.k1, with: .skip, applyToAll: false)
        _ = jobs.startNext()
        jobs.begin(a.id, total: 100)
        jobs.finish(a.id, outcome: TransferOutcome(settled: [Self.k0, Self.k1, Self.k2]))
        #expect(jobs.isEmpty)
    }

    /// D-15: a first run's Stop settles what it cut off; only real failures from before the Stop stay listed.
    @Test func aStopWithEarlierFailuresKeepsOnlyThoseFailures() {
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs)
        #expect(jobs.stop(a) == true)
        jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k0)], unreached: cutOff([Self.k1, Self.k2]),
                                                cancelled: true))
        #expect(state(a, jobs) == .failed && listed(a, jobs) == [Self.k0])
        #expect(row(a, jobs)?.settled.isSuperset(of: [Self.k1, Self.k2]) == true)
    }

    @Test func aStopWithNoFailureRemovesTheRow() {
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs)
        #expect(jobs.stop(a) == true)
        jobs.finish(a, outcome: TransferOutcome(unreached: cutOff([Self.k1, Self.k2]), settled: [Self.k0], cancelled: true))
        #expect(jobs.isEmpty)
    }

    /// P3 D-10, D-15, T-04-37: a Stop whose cleanup lost the session is still a Stop, with or without a session end
    /// between the stop and the run's report.
    @Test func aStopWhoseCleanupLosesTheSessionStaysAStop() {
        for endedBetween in [false, true] {
            for (failed, leftovers, expected) in [
                ([failure(Self.k0)], [], [Self.k0]),
                ([], [Self.leftover], []),
                ([], [], nil),
            ] as [([TransferFailure], [PhoneLeftover], [ItemKey]?)] {
                var jobs = TransferJobs()
                let a = firstRun(in: &jobs)
                #expect(jobs.stop(a) == true)
                if endedBetween { #expect(jobs.ended(disconnected: false).isEmpty) }
                jobs.finish(a, outcome: TransferOutcome(failed: failed, unreached: cutOff([Self.k1, Self.k2]), cancelled: true,
                                                        lost: .deviceGone, leftovers: leftovers))
                #expect(listed(a, jobs) == expected, "ended between: \(endedBetween)")
                #expect(row(a, jobs).map { $0.leftovers == leftovers && $0.settled.isSuperset(of: [Self.k1, Self.k2]) } ?? true)
            }
        }
    }

    /// D-13, D-15: a stopped Retry never lists less than it had, minus what it finished.
    @Test func aStoppedRetryKeepsWhatItHadNotFinished() {
        do {                                                            // stopped mid-copy
            var jobs = TransferJobs()
            let a = retrying(at: .copying, in: &jobs)
            #expect(jobs.stop(a) == true)
            let rest = Array(Self.cameraKeys.dropFirst())
            jobs.finish(a, outcome: TransferOutcome(unreached: cutOff(rest), settled: [Self.cameraKeys[0]], cancelled: true))
            #expect(state(a, jobs) == .failed && listed(a, jobs) == rest)
            #expect(row(a, jobs)?.failures.map(\.detail) == (11...20).map { "d\($0)" })   // their earlier details
            #expect(row(a, jobs)?.settled.isDisjoint(with: rest) == true)
        }
        for (target, cancels) in [(TransferJob.State.scanning, true), (.asking, false), (.waiting, false)] {
            var jobs = TransferJobs()
            let a = retrying(at: target, in: &jobs)
            #expect(jobs.stop(a) == cancels)
            #expect(state(a, jobs) == .failed && row(a, jobs)?.failures == Self.cameraItems, "\(target)")
        }
        do {                                                            // stopped while it plans
            var jobs = TransferJobs()
            let a = retrying(at: .preparing, in: &jobs)
            #expect(jobs.stop(a) == true)
            jobs.finish(a, outcome: TransferOutcome(cancelled: true))
            #expect(state(a, jobs) == .failed && row(a, jobs)?.failures == Self.cameraItems)
        }
        for target in [TransferJob.State.scanning, .asking, .waiting, .preparing] {   // a first run just leaves
            var jobs = TransferJobs()
            let a = firstRun(at: target, in: &jobs)
            _ = jobs.stop(a)
            jobs.finish(a, outcome: TransferOutcome(cancelled: true))
            #expect(jobs.isEmpty, "\(target)")
        }
    }

    /// D-04 with a Retry: the refusal alerts, and the row keeps its list.
    @Test func aRetryOutOfSpaceKeepsItsRow() {
        var jobs = TransferJobs()
        let a = retrying(at: .preparing, in: &jobs)
        jobs.finish(a, outcome: TransferOutcome())
        #expect(state(a, jobs) == .failed && row(a, jobs)?.failures == Self.cameraItems)

        var first = TransferJobs()
        let b = firstRun(at: .preparing, in: &first)
        first.finish(b, outcome: TransferOutcome())
        #expect(first.isEmpty)
    }

    /// D-13: a pull keeps everything a Retry listed, never one failure for its top-level folder.
    @Test func aPulledRetryKeepsWhatItListed() {
        for target in [TransferJob.State.scanning, .asking, .waiting] {
            var jobs = TransferJobs()
            let a = retrying(at: target, in: &jobs)
            #expect(jobs.ended(disconnected: true) == (target == .scanning ? [a] : []))
            #expect(state(a, jobs) == .failed && listed(a, jobs) == Self.cameraKeys, "\(target)")
        }
        for (outcome, fallback) in [(TransferOutcome(cancelled: true), nil), (TransferOutcome(lost: .deviceGone), nil),
                                    (TransferOutcome(), "x")] as [(TransferOutcome, String?)] {
            var jobs = TransferJobs()
            let a = retrying(at: .preparing, in: &jobs)
            #expect(jobs.ended(disconnected: true) == [a])
            jobs.finish(a, outcome: outcome, fallback: fallback)
            #expect(state(a, jobs) == .failed && listed(a, jobs) == Self.cameraKeys)
        }
        do {                                                            // pulled mid-copy
            var jobs = TransferJobs()
            let a = retrying(at: .copying, in: &jobs)
            #expect(jobs.ended(disconnected: true) == [a])
            let rest = Array(Self.cameraKeys.dropFirst())
            jobs.finish(a, outcome: TransferOutcome(unreached: cutOff(rest), settled: [Self.cameraKeys[0]], cancelled: true))
            #expect(listed(a, jobs) == rest)
            #expect(row(a, jobs)?.failures.allSatisfy { $0.detail == Self.gone } == true)
        }
    }

    /// D-13: a loss lists the item in flight and everything after it; a job that never copied lists each top-level item.
    @Test func aLossListsWhatWasNotCopied() {
        do {
            var jobs = TransferJobs()
            let a = firstRun(in: &jobs)
            jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k1, Self.gone)], unreached: cutOff([Self.k2], Self.gone),
                                                    settled: [Self.k0], lost: .deviceGone))
            #expect(row(a, jobs)?.failures == [failure(Self.k1, Self.gone)] + cutOff([Self.k2], Self.gone))
        }
        do {                                                            // lost before it copied anything
            var jobs = TransferJobs()
            let a = firstRun(at: .preparing, in: &jobs)
            jobs.finish(a, outcome: TransferOutcome(lost: .deviceGone))
            #expect(row(a, jobs)?.failures == perItem(["a", "b", "c"], Self.gone))
        }
        do {                                                            // its planning failed
            var jobs = TransferJobs()
            let a = firstRun(at: .preparing, in: &jobs)
            jobs.finish(a, outcome: TransferOutcome(), fallback: "x")
            #expect(row(a, jobs)?.failures == perItem(["a", "b", "c"], "x"))
        }
        do {                                                            // a Retry's planning failed
            var jobs = TransferJobs()
            let a = retrying(at: .preparing, in: &jobs)
            jobs.finish(a, outcome: TransferOutcome(), fallback: "x")
            #expect(row(a, jobs)?.failures == Self.cameraItems)
        }
    }

    /// D-13: a pull or a reset ends every job the user isn't already stopping; scans and running copies are cancelled.
    @Test func endedFailsEveryJobThatIsNotStopping() {
        for running in [TransferJob.State.preparing, .copying] {
            var jobs = TransferJobs()
            let failed = firstRun(["f"], in: &jobs)
            jobs.finish(failed, outcome: TransferOutcome(failed: [failure(Self.k0)]))
            let r = firstRun(["r"], at: running, in: &jobs)
            let s = firstRun(["s1", "s2"], at: .scanning, in: &jobs)
            let q = job(["q1", "q2"])
            jobs.add(q)
            jobs.scanned(q.id, clashes: [fileClash(0), fileClash(1)])
            jobs.answer(q.id, clash: Self.k0, with: .keepBoth, applyToAll: false)
            let older = DeviceSession(transport: FakeAndroidResponder())
            let w = firstRun(["w"], at: .waiting, in: &jobs, session: older)

            #expect(jobs.ended(disconnected: true) == [r, s])
            #expect(state(r, jobs) == .canceling && row(r, jobs)?.endedDetail == Self.gone)
            #expect(state(s, jobs) == .failed && row(s, jobs)?.failures == perItem(["s1", "s2"], Self.gone))
            #expect(state(q.id, jobs) == .failed && row(q.id, jobs)?.failures == perItem(["q1", "q2"], Self.gone))
            #expect(row(q.id, jobs)?.answers.byItem == [Self.k0: .keepBoth] && row(q.id, jobs)?.questions.isEmpty == true)
            #expect(state(w, jobs) == .failed && row(w, jobs)?.failures == perItem(["w"], Self.gone))
            #expect(row(failed, jobs)?.failures == [failure(Self.k0)] && row(failed, jobs)?.endedDetail == nil)
            #expect(jobs.all.filter { $0.state == .failed }.allSatisfy { $0.failures.allSatisfy(\.retryable) })
        }
        var stopping = TransferJobs()
        let a = firstRun(in: &stopping)
        _ = stopping.stop(a)
        #expect(stopping.ended(disconnected: true).isEmpty)                 // the user's own stop wins
        #expect(state(a, stopping) == .canceling && row(a, stopping)?.endedDetail == nil)

        var reset = TransferJobs()
        let w = firstRun(["w"], at: .waiting, in: &reset)
        #expect(reset.ended(disconnected: false).isEmpty)
        #expect(row(w, reset)?.failures == perItem(["w"], Self.reset))
    }

    /// XFER-09 ordering edge: once a pull made a row, whatever the cancelled scan reports changes nothing.
    @Test func anEndedScanningJobStaysFailedWhenItsScanEnds() {
        var jobs = TransferJobs()
        let a = firstRun(at: .scanning, in: &jobs)
        #expect(jobs.ended(disconnected: true) == [a])
        #expect(row(a, jobs)?.failures == perItem(["a", "b", "c"], Self.gone))
        jobs.finish(a, outcome: TransferOutcome(cancelled: true))
        jobs.finish(a, outcome: TransferOutcome(lost: .deviceGone))
        #expect(state(a, jobs) == .failed && row(a, jobs)?.failures == perItem(["a", "b", "c"], Self.gone))
    }

    /// XFER-09 empty edge: a job pulled while it plans lists every top-level item it didn't skip, with the pull's detail,
    /// whatever its task reports.
    @Test func anEndedJobCutWhilePreparingListsEveryItem() {
        for (outcome, fallback) in [(TransferOutcome(cancelled: true), nil), (TransferOutcome(lost: .deviceGone), nil),
                                    (TransferOutcome(), "x")] as [(TransferOutcome, String?)] {
            var jobs = TransferJobs()
            let a = job(["a", "b", "c"])
            jobs.add(a)
            jobs.scanned(a.id, clashes: [fileClash(1)])
            jobs.answer(a.id, clash: Self.k1, with: .skip, applyToAll: false)
            _ = jobs.startNext()
            #expect(jobs.ended(disconnected: true) == [a.id])
            jobs.finish(a.id, outcome: outcome, fallback: fallback)
            #expect(state(a.id, jobs) == .failed)
            #expect(row(a.id, jobs)?.failures == [TransferFailure(name: "a", detail: Self.gone, key: Self.k0),
                                                  TransferFailure(name: "c", detail: Self.gone, key: Self.k2)])
        }
    }

    /// A pulled run lists what it didn't finish with the pull's detail; the same run stopped by the user leaves (D-15).
    @Test func anEndedCopyingJobListsWhatItsStoppedRunDidNotFinish() {
        let outcome = TransferOutcome(unreached: cutOff([Self.k1, Self.k2]), settled: [Self.k0], cancelled: true)
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs)
        #expect(jobs.ended(disconnected: true) == [a])
        jobs.finish(a, outcome: outcome)
        #expect(row(a, jobs)?.failures == cutOff([Self.k1, Self.k2], Self.gone))
        #expect(row(a, jobs)?.settled.contains(Self.k0) == true)

        var stopped = TransferJobs()
        let b = firstRun(in: &stopped)
        #expect(stopped.stop(b) == true)
        stopped.finish(b, outcome: outcome)
        #expect(stopped.isEmpty)
    }

    /// XFER-09 ordering edge: a run that finished before the pull reached it lists nothing.
    @Test func aRunThatFinishedBeforeThePullListsNothing() {
        var jobs = TransferJobs()
        let a = firstRun(["IMG.jpg", "Album"], in: &jobs)
        #expect(jobs.ended(disconnected: true) == [a])
        jobs.finish(a, outcome: TransferOutcome(settled: [Self.k0, ItemKey(top: 1, path: ["x.jpg"])],
                                                folders: [Self.k1: "Album"]))
        #expect(jobs.isEmpty)

        var retried = TransferJobs()
        let b = firstRun(["Album"], in: &retried)
        retried.finish(b, outcome: TransferOutcome(settled: [ItemKey(top: 0, path: ["x.jpg"])], folders: [Self.k0: "Album"],
                                                   leftovers: [Self.leftover]))
        #expect(state(b, retried) == .failed && listed(b, retried) == [])
        #expect(retried.retry(b) == true)
        #expect(retried.ended(disconnected: true) == [b])
        #expect(state(b, retried) == .failed && listed(b, retried) == [] && row(b, retried)?.leftovers == [Self.leftover])
    }

    /// D-17: a listed folder gives way once the attempt accounts for its contents; a failed folder covers what was
    /// listed inside it, so the row offers no Retry that could only repeat it.
    @Test func aListedFolderGivesWayToItsContents() {
        let p1 = ItemKey(top: 0, path: ["p1"]), p2 = ItemKey(top: 0, path: ["p2"]), p3 = ItemKey(top: 0, path: ["p3"])
        var jobs = TransferJobs()
        let a = firstRun(["Camera"], at: .preparing, in: &jobs)
        jobs.finish(a, outcome: TransferOutcome(), fallback: "x")
        #expect(listed(a, jobs) == [Self.k0])
        #expect(jobs.retry(a) == true)
        advance(&jobs, a, to: .copying)
        jobs.finish(a, outcome: TransferOutcome(unreached: cutOff([p2]), settled: [p1], folders: [Self.k0: "Camera"]))
        #expect(listed(a, jobs) == [p2])

        let session = DeviceSession(transport: FakeAndroidResponder())
        var moved = TransferJobs()
        let b = firstRun(["Camera"], in: &moved, session: session)
        moved.finish(b, outcome: TransferOutcome(failed: [failure(p2), failure(p3)], folders: [Self.k0: "Camera"]))
        #expect(moved.retry(b) == true)
        advance(&moved, b, to: .copying)
        let folderGone = TransferFailure(name: "Camera", detail: TransferText.folderMoved, key: Self.k0, retryable: false)
        moved.finish(b, outcome: TransferOutcome(failed: [folderGone]))
        #expect(row(b, moved)?.failures == [folderGone])
        #expect(!moved.canRetry(b, connected: Self.pixel))
    }

    /// D-19: a Skip, and every question Apply to All Skip covers, is settled, so a pull never lists it.
    @Test func skipAnswersAreSettled() {
        var jobs = TransferJobs()
        let a = job(["a", "b", "c"])
        jobs.add(a)
        jobs.scanned(a.id, clashes: [fileClash(0), fileClash(2)])
        jobs.answer(a.id, clash: Self.k0, with: .skip, applyToAll: false)
        #expect(row(a.id, jobs)?.settled == [Self.k0])
        _ = jobs.ended(disconnected: true)
        #expect(listed(a.id, jobs) == [Self.k1, Self.k2])

        var all = TransferJobs()
        let b = job(["a", "b", "c"])
        all.add(b)
        all.scanned(b.id, clashes: [fileClash(0), fileClash(1), typeClash(2)])
        all.answer(b.id, clash: Self.k0, with: .keepBoth, applyToAll: false)
        all.answer(b.id, clash: Self.k1, with: .skip, applyToAll: true)
        #expect(state(b.id, all) == .waiting && row(b.id, all)?.settled == [Self.k1, Self.k2])
        _ = all.ended(disconnected: true)
        #expect(listed(b.id, all) == [Self.k0])
    }

    @Test func foldersAndSettledAreKeptOnEveryEnd() {
        for end in ["finish", "stop", "loss", "ended"] {
            var jobs = TransferJobs()
            let a = firstRun(in: &jobs)
            var outcome = TransferOutcome(failed: [failure(Self.k0)], settled: [Self.k1], folders: [Self.k2: "F"])
            switch end {
            case "stop": _ = jobs.stop(a); outcome.cancelled = true
            case "loss": outcome.lost = .deviceGone
            case "ended": _ = jobs.ended(disconnected: true); outcome.cancelled = true
            default: break
            }
            jobs.finish(a, outcome: outcome)
            #expect(state(a, jobs) == .failed, "\(end)")
            #expect(row(a, jobs)?.settled.contains(Self.k1) == true && row(a, jobs)?.folders == [Self.k2: "F"], "\(end)")
        }
    }

    /// D-17, D-18: Retry only from a failed row; it keeps everything the job knows and queues behind waiting jobs.
    @Test func retryOnlyFromAFailedRow() {
        var jobs = TransferJobs()
        let a = job(["a", "b"])
        jobs.add(a)
        jobs.scanned(a.id, clashes: [fileClash(0)])
        jobs.answer(a.id, clash: Self.k0, with: .replace, applyToAll: false)
        _ = jobs.startNext()
        jobs.begin(a.id, total: 100)
        jobs.add(bytes: 40, to: a.id)
        let b = job("b")
        ready(&jobs, b)
        let folders = [ItemKey(top: 1, path: ["d"]): "d"]
        #expect(jobs.retry(a.id) == false && state(a.id, jobs) == .copying)
        jobs.finish(a.id, outcome: TransferOutcome(failed: [failure(Self.k1)], settled: [Self.k0], folders: folders,
                                                   leftovers: [Self.leftover]))
        #expect(jobs.retry(b.id) == false && state(b.id, jobs) == .waiting)
        #expect(jobs.retry(UUID()) == false)

        #expect(jobs.retry(a.id) == true)
        #expect(jobs.retry(a.id) == false)                                  // already scanning: a second press does nothing
        let retried = row(a.id, jobs)
        #expect(retried?.state == .scanning && jobs.all.map(\.id) == [b.id, a.id])
        #expect(retried?.answers.byItem == [Self.k0: .replace] && retried?.settled == [Self.k0])
        #expect(retried?.folders == folders && retried?.leftovers == [Self.leftover])
        #expect(retried?.failures == [failure(Self.k1)] && retried?.done == 0)
        jobs.scanned(a.id, clashes: [])
        #expect(jobs.startNext()?.id == b.id)                               // the job already waiting goes first
        #expect(jobs.retry(b.id) == false && state(b.id, jobs) == .preparing)
    }

    @Test func dismissRemovesOnlyAFailedRow() {
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs)
        jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k0)]))
        let w = firstRun(["w"], at: .waiting, in: &jobs)
        jobs.dismiss(w)
        jobs.dismiss(UUID())
        #expect(jobs.all.map(\.id) == [a, w])
        jobs.dismiss(a)
        #expect(jobs.all.map(\.id) == [w])
    }

    /// RESEARCH Pitfall 7, D-18: a failed row is a row (the window stays) but not activity, and never starts.
    @Test func failedRowsAreNotActivity() {
        var jobs = TransferJobs()
        #expect(!jobs.hasActive && jobs.isEmpty)
        let a = firstRun(in: &jobs)
        #expect(jobs.hasActive)
        jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k0)]))
        #expect(!jobs.hasActive && !jobs.isEmpty)
        #expect(jobs.startNext() == nil && state(a, jobs) == .failed)
        let w = firstRun(["w"], at: .waiting, in: &jobs)
        #expect(jobs.hasActive)
        #expect(jobs.startNext()?.id == w)
    }

    /// D-14, RESEARCH Pitfall 13: Retry follows the phone by its non-empty serial, not the session (a replugged phone
    /// has a new one), and needs a retryable item or a leftover. Another phone, one with no serial, or none never counts.
    @Test func canRetryNeedsTheSamePhone() {
        let link = TransferFailure(name: "l", detail: TransferText.linkNotCopied, key: Self.k0, retryable: false)
        let replugged = PhoneID(serial: Self.pixel.serial, name: "Pixel")
        for (outcome, retryable) in [(TransferOutcome(failed: [failure(Self.k0)]), true),
                                     (TransferOutcome(failed: [link], leftovers: [Self.leftover]), true),
                                     (TransferOutcome(failed: [link]), false)] {
            var jobs = TransferJobs()
            let a = firstRun(in: &jobs)
            #expect(!jobs.canRetry(a, connected: Self.pixel))                   // still copying
            jobs.finish(a, outcome: outcome)
            #expect(jobs.canRetry(a, connected: Self.pixel) == retryable)
            #expect(jobs.canRetry(a, connected: replugged) == retryable)        // a new session, the same phone
            #expect(!jobs.canRetry(a, connected: PhoneID(serial: "OTHER", name: "Pixel 9")))
            #expect(!jobs.canRetry(a, connected: nil))
        }
        let blank = PhoneID(serial: "", name: "Phone")
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs, phone: blank)
        jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k0)]))
        #expect(!jobs.canRetry(a, connected: blank))
        #expect(!blank.isSame(as: blank) && Self.pixel.isSame(as: replugged) && !Self.pixel.isSame(as: nil))
    }

    /// D-24: a fix-up that finished an item settles it and drops its failure; only the leftovers it handled are forgotten.
    @Test func fixedUpSettlesAndForgets() {
        let other = PhoneLeftover(storage: 0x0001_0001, folder: 8, temp: ".y.aft-upload", name: "y.bin", size: 5, key: Self.k2)
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs)
        jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k0), failure(Self.k1), failure(Self.k2)],
                                                leftovers: [Self.leftover, other]))
        jobs.fixedUp(a, handled: [Self.leftover], finished: [Self.k1])
        #expect(listed(a, jobs) == [Self.k0, Self.k2])
        #expect(row(a, jobs)?.settled == [Self.k1] && row(a, jobs)?.leftovers == [other])
    }

    /// D-24: a fix-up that leaves a failed row listing nothing, with nothing left on the phone, removes the row; one
    /// still listing something stays; a job that isn't a failed row (a Retry's attempt-start fix-up) is never removed.
    @Test func fixedUpRemovesAnEmptiedFailedRowOnly() {
        do {                                                            // it finished the one item the row listed
            var jobs = TransferJobs()
            let a = firstRun(in: &jobs)
            jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k1)], settled: [Self.k0, Self.k2],
                                                    leftovers: [Self.leftover]))
            jobs.fixedUp(a, handled: [Self.leftover], finished: [Self.k1])
            #expect(jobs.isEmpty)
        }
        do {                                                            // only a temp, whose folder is gone
            var jobs = TransferJobs()
            let a = firstRun(in: &jobs)
            jobs.finish(a, outcome: TransferOutcome(settled: [Self.k0, Self.k1, Self.k2], leftovers: [Self.leftover]))
            #expect(state(a, jobs) == .failed)
            jobs.fixedUp(a, handled: [Self.leftover], finished: [])
            #expect(jobs.isEmpty)
        }
        do {                                                            // something is still listed
            var jobs = TransferJobs()
            let a = firstRun(in: &jobs)
            jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k0), failure(Self.k1)], leftovers: [Self.leftover]))
            jobs.fixedUp(a, handled: [Self.leftover], finished: [Self.k1])
            #expect(state(a, jobs) == .failed && listed(a, jobs) == [Self.k0])
        }
        do {                                                            // a Retry's attempt-start fix-up
            var jobs = TransferJobs()
            let a = firstRun(in: &jobs)
            jobs.finish(a, outcome: TransferOutcome(failed: [failure(Self.k1)], settled: [Self.k0, Self.k2],
                                                    leftovers: [Self.leftover]))
            #expect(jobs.retry(a) == true)
            advance(&jobs, a, to: .preparing)
            jobs.fixedUp(a, handled: [Self.leftover], finished: [Self.k1])
            #expect(state(a, jobs) == .preparing && listed(a, jobs) == [] && row(a, jobs)?.leftovers == [])
        }
    }

    /// D-14: re-resolution after a replug moves a job to the new session with its items found again by path; nothing
    /// else about it changes.
    @Test func rebindMovesAJobToTheNewSession() {
        var jobs = TransferJobs()
        let a = firstRun(at: .preparing, in: &jobs)
        let session = DeviceSession(transport: FakeAndroidResponder())
        let request = TransferJob.Request.upload([URL(filePath: "/tmp/x.jpg")], storage: 0x0001_0001, parent: 1_001,
                                                 path: ["DCIM"])
        jobs.rebind(a, session: session, request: request)
        #expect(row(a, jobs)?.session === session && row(a, jobs)?.request == request)
        #expect(state(a, jobs) == .preparing && row(a, jobs)?.names == ["a", "b", "c"])
        jobs.rebind(UUID(), session: session, request: request)
        #expect(jobs.all.count == 1)
    }

    // MARK: silent reconnect: pause, resume, and every later end through the one rule (D-16)

    static let timeout = MTPError.io(operation: "Bulk IN", code: 0xE000_02D6)
    static let lost = timeout.detail
    static let k3 = ItemKey(top: 3)

    /// What a run a silent reconnect cut reports: `inFlight` lost with the loss's detail, `rest` not reached.
    private func cut(at inFlight: ItemKey, rest: [ItemKey] = [], failed: [TransferFailure] = [],
                     settled: Set<ItemKey> = [], folders: [ItemKey: String] = [:],
                     leftovers: [PhoneLeftover] = []) -> TransferOutcome {
        TransferOutcome(failed: failed + [failure(inFlight, Self.lost)], unreached: cutOff(rest, Self.lost), settled: settled,
                        folders: folders, lost: Self.timeout, unfinished: inFlight, leftovers: leftovers)
    }

    /// Resumes on the same phone and starts `id` again (the first job waiting), now copying.
    private func continueCopying(_ id: TransferJob.ID, in jobs: inout TransferJobs) {
        _ = jobs.resumed(Self.pixel)
        #expect(jobs.startNext()?.id == id)
        jobs.begin(id, total: 100)
    }

    /// A first run of "Camera", paused mid-copy: K1 failed for real before the reconnect, p6 was in flight and p7 not
    /// reached; resumed and copying again.
    private func carrying(in jobs: inout TransferJobs) -> (TransferJob.ID, k1: ItemKey, p6: ItemKey, p7: ItemKey) {
        let k1 = ItemKey(top: 0, path: ["k1.jpg"]), p6 = ItemKey(top: 0, path: ["p6.jpg"]), p7 = ItemKey(top: 0, path: ["p7.jpg"])
        let a = firstRun(["Camera"], in: &jobs)
        _ = jobs.paused()
        jobs.finish(a, outcome: cut(at: p6, rest: [p7], failed: [failure(k1)], folders: [Self.k0: "Camera"]))
        continueCopying(a, in: &jobs)
        #expect(row(a, jobs)?.carried == [failure(k1)] && row(a, jobs)?.pending.compactMap(\.key) == [p6, p7])
        return (a, k1, p6, p7)
    }

    /// D-16, RESEARCH Pitfall 12: a silent reconnect pauses every job that isn't failed or being stopped. A scan is
    /// cancelled, an attempt still out is waited for, an asking job keeps its sheet and its last answer leaves it paused,
    /// not waiting; nothing starts while paused, nor for another phone.
    @Test func pausedJobsWaitForTheSamePhone() {
        for running in [TransferJob.State.preparing, .copying] {
            var jobs = TransferJobs()
            let failed = firstRun(["f"], in: &jobs)
            jobs.finish(failed, outcome: TransferOutcome(failed: [failure(Self.k0)]))
            let r = firstRun(["r"], at: running, in: &jobs)
            let s = firstRun(["s"], at: .scanning, in: &jobs)
            let q = firstRun(["q"], at: .asking, in: &jobs)
            let w = firstRun(["w"], at: .waiting, in: &jobs)

            #expect(jobs.paused() == [s])
            for (id, from) in [(r, running), (s, .scanning), (w, .waiting)] {
                #expect(state(id, jobs) == .reconnecting && row(id, jobs)?.pausedFrom == from, "\(from)")
                #expect(row(id, jobs)?.isPaused == true && row(id, jobs)?.awaitingRun == (id == r), "\(from)")
            }
            #expect(state(q, jobs) == .asking && row(q, jobs)?.isPaused == true && jobs.nextQuestion?.job == q)
            #expect(state(failed, jobs) == .failed && row(failed, jobs)?.isPaused == false)
            #expect(jobs.startNext() == nil)
            jobs.answer(q, clash: Self.k0, with: .keepBoth, applyToAll: false)
            #expect(state(q, jobs) == .reconnecting && row(q, jobs)?.pausedFrom == .waiting)
            #expect(row(q, jobs)?.answers.byItem == [Self.k0: .keepBoth])
            #expect(jobs.resumed(PhoneID(serial: "OTHER", name: "Pixel 9")).isEmpty)
            #expect([r, s, q, w].allSatisfy { state($0, jobs) == .reconnecting && row($0, jobs)?.isPaused == true })
            #expect(jobs.startNext() == nil)
        }
    }

    /// RESEARCH Pitfall 12: `paused` takes no session. A resume doesn't rebind (the attempt re-resolves by path), so a job
    /// it left on an older session is paused like the rest.
    @Test func pausedCoversJobsLeftOnAnOlderSession() {
        var jobs = TransferJobs()
        let older = DeviceSession(transport: FakeAndroidResponder())
        let w = firstRun(["w"], at: .waiting, in: &jobs, session: older)
        _ = jobs.paused()
        #expect(jobs.resumed(Self.pixel).isEmpty)
        #expect(state(w, jobs) == .waiting && row(w, jobs)?.session === older)
        let s = firstRun(["s"], at: .scanning, in: &jobs)
        #expect(jobs.paused() == [s])
        #expect(state(w, jobs) == .reconnecting && row(w, jobs)?.isPaused == true)
    }

    /// D-16: the run a reconnect cut keeps what it finished and made, carries its real failures, counts the loss of the
    /// item in flight, and lists for the continuation what it didn't get to: earlier pending items it didn't reach,
    /// then the item in flight, then what it didn't reach.
    @Test func aLossWhileReconnectingIsCounted() {
        let x0 = ItemKey(top: 0, path: ["x"]), y0 = ItemKey(top: 0, path: ["y"])
        var jobs = TransferJobs()
        let a = firstRun(["a", "b", "c", "d"], in: &jobs)
        _ = jobs.paused()
        jobs.finish(a, outcome: cut(at: Self.k1, rest: [Self.k2, Self.k3], failed: [failure(x0)], settled: [y0],
                                    folders: [Self.k0: "a"]))
        #expect(state(a, jobs) == .reconnecting && row(a, jobs)?.awaitingRun == false)
        #expect(row(a, jobs)?.settled == [y0] && row(a, jobs)?.folders == [Self.k0: "a"])
        #expect(row(a, jobs)?.lostCount == [Self.k1: 1] && row(a, jobs)?.carried == [failure(x0)])
        #expect(row(a, jobs)?.pending == [failure(Self.k1, Self.lost)] + cutOff([Self.k2, Self.k3], Self.lost))
        #expect(row(a, jobs)?.excluded == [y0, x0])

        continueCopying(a, in: &jobs)
        _ = jobs.paused()
        jobs.finish(a, outcome: cut(at: Self.k3, settled: [Self.k1]))           // it never reached k2
        #expect(state(a, jobs) == .reconnecting && row(a, jobs)?.settled == [y0, Self.k1])
        #expect(row(a, jobs)?.lostCount == [Self.k1: 1, Self.k3: 1] && row(a, jobs)?.carried == [failure(x0)])
        #expect(row(a, jobs)?.pending == cutOff([Self.k2], Self.lost) + [failure(Self.k3, Self.lost)])
    }

    /// D-16: once the same phone is back, each paused job picks up where it was: a cut copy waits again in its place, a
    /// scan starts again, an asking job keeps its questions and answers. What the cut run left stays on the job.
    @Test func resumedJobsPickUpWhereTheyWere() {
        var jobs = TransferJobs()
        let c = firstRun(["c1", "c2"], in: &jobs)
        let s = firstRun(["s"], at: .scanning, in: &jobs)
        let q = job(["q1", "q2"])
        jobs.add(q)
        jobs.scanned(q.id, clashes: [fileClash(0), fileClash(1)])
        jobs.answer(q.id, clash: Self.k0, with: .replace, applyToAll: false)
        let w = firstRun(["w"], at: .waiting, in: &jobs)
        #expect(jobs.paused() == [s])
        jobs.finish(c, outcome: cut(at: Self.k1, settled: [Self.k0]))

        #expect(jobs.resumed(Self.pixel) == [s])
        #expect(state(c, jobs) == .waiting && state(s, jobs) == .scanning && state(w, jobs) == .waiting)
        #expect(state(q.id, jobs) == .asking && questions(q.id, jobs) == [Self.k1])
        #expect(row(q.id, jobs)?.answers.byItem == [Self.k0: .replace])
        #expect([c, s, q.id, w].allSatisfy { row($0, jobs)?.isPaused == false && row($0, jobs)?.pausedFrom == nil })
        #expect(row(c, jobs)?.pending == [failure(Self.k1, Self.lost)] && row(c, jobs)?.settled == [Self.k0])
        #expect(jobs.startNext()?.id == c)                                      // ahead of w, as before the drop
        #expect(jobs.resumed(Self.pixel).isEmpty)                               // nothing is paused any more
    }

    /// T-04-34, RESEARCH Pitfall 13: only the same phone resumes: the same serial, or with no serial the same IOKit
    /// registry ID (a silent reconnect isn't a replug). Another phone, or a serial-less one across a replug, never does,
    /// and Retry after a replug still needs a serial.
    @Test func resumeNeedsTheSameDevice() {
        let blank = PhoneID(serial: "", name: "Phone", registryID: 0x1234)
        for (phone, other, resumes) in [
            (Self.pixel, PhoneID(serial: "OTHER", name: "Pixel 9"), false),
            (Self.pixel, PhoneID(serial: Self.pixel.serial, name: "Pixel", registryID: 9), true),
            (blank, PhoneID(serial: "", name: "Phone", registryID: 0x1234), true),
            (blank, PhoneID(serial: "", name: "Phone", registryID: 0x5678), false),           // replugged
            (PhoneID(serial: "", name: "Phone"), PhoneID(serial: "", name: "Phone"), false),  // no registry ID
        ] {
            var jobs = TransferJobs()
            let w = firstRun(["w"], at: .waiting, in: &jobs, phone: phone)
            _ = jobs.paused()
            _ = jobs.resumed(other)
            #expect(state(w, jobs) == (resumes ? .waiting : .reconnecting), "\(phone) / \(other)")
        }
        #expect(blank.isSameDevice(as: blank) && !blank.isSame(as: blank))
        #expect(!blank.isSameDevice(as: nil) && Self.pixel.isSameDevice(as: Self.pixel))
    }

    /// D-16: the item in flight gets one more try; lost again, it is listed (with the loss's detail) and excluded, and
    /// the job moves on to the rest.
    @Test func anItemLostTwiceIsListedAndTheJobMovesOn() {
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs)
        _ = jobs.paused()
        jobs.finish(a, outcome: cut(at: Self.k1, rest: [Self.k2], settled: [Self.k0]))
        #expect(row(a, jobs)?.excluded == [Self.k0])                              // tried once more

        continueCopying(a, in: &jobs)
        _ = jobs.paused()
        jobs.finish(a, outcome: cut(at: Self.k1, rest: [Self.k2]))
        #expect(row(a, jobs)?.lostCount == [Self.k1: 2])
        #expect(row(a, jobs)?.carried == [failure(Self.k1, Self.lost)])
        #expect(row(a, jobs)?.pending == cutOff([Self.k2], Self.lost))
        #expect(row(a, jobs)?.excluded == [Self.k0, Self.k1])

        continueCopying(a, in: &jobs)
        jobs.finish(a, outcome: TransferOutcome(settled: [Self.k2]))
        #expect(state(a, jobs) == .failed && row(a, jobs)?.failures == [failure(Self.k1, Self.lost)])
        #expect(jobs.canRetry(a, connected: Self.pixel))
    }

    /// D-13, D-16: a continuation ended before it ran lists what it still had to copy, not one failure per top-level
    /// item and not the folder its first run made.
    @Test func aContinuationEndedBeforeItRanListsWhatWasPending() {
        let p = (1...20).map { ItemKey(top: 0, path: ["p\($0).jpg"]) }
        for target in [TransferJob.State.waiting, .preparing] {
            var jobs = TransferJobs()
            let a = firstRun(["Camera"], in: &jobs)
            _ = jobs.paused()
            jobs.finish(a, outcome: cut(at: p[5], rest: Array(p[6...]), settled: Set(p[..<5]), folders: [Self.k0: "Camera"]))
            _ = jobs.resumed(Self.pixel)
            if target == .preparing { #expect(jobs.startNext()?.id == a) }
            #expect(jobs.ended(disconnected: true) == (target == .preparing ? [a] : []))
            jobs.finish(a, outcome: TransferOutcome(cancelled: true))
            #expect(state(a, jobs) == .failed && listed(a, jobs) == Array(p[5...]), "\(target)")
            #expect(row(a, jobs)?.failures.allSatisfy { $0.detail == Self.lost } == true)
        }
    }

    /// P3 D-02, D-15, D-24, T-04-38: an attempt still out when its job was paused is waited for, never overlapped: the
    /// job holds the one copy slot until that run reports. A Stop or a pull meanwhile stops that run and lets its report
    /// end the job, so its leftovers and real failures are kept.
    @Test func aRunStillOutWhenPausedIsNeverOverlappedOrDropped() {
        do {
            var jobs = TransferJobs()
            let a = firstRun(["a", "b", "c", "d"], in: &jobs)
            let b = firstRun(["b"], at: .waiting, in: &jobs)
            _ = jobs.paused()
            #expect(jobs.resumed(Self.pixel).isEmpty)
            #expect(state(a, jobs) == .reconnecting && state(b, jobs) == .waiting)
            #expect(jobs.startNext() == nil)                                    // no second attempt, and b waits
            jobs.finish(a, outcome: cut(at: Self.k3, settled: [Self.k0], leftovers: [Self.leftover]))
            #expect(state(a, jobs) == .waiting && row(a, jobs)?.awaitingRun == false)
            #expect(row(a, jobs)?.pending.compactMap(\.key) == [Self.k3] && row(a, jobs)?.leftovers == [Self.leftover])
            #expect(jobs.startNext()?.id == a)
        }
        let late = TransferOutcome(failed: [failure(Self.k1)], unreached: cutOff([Self.k3, Self.k2]), cancelled: true,
                                   leftovers: [Self.leftover])
        do {                                                                    // stopped before it reported
            var jobs = TransferJobs()
            let a = firstRun(["a", "b", "c", "d"], in: &jobs)
            _ = jobs.paused()
            #expect(jobs.stop(a) == true && state(a, jobs) == .canceling)
            jobs.finish(a, outcome: late)
            #expect(state(a, jobs) == .failed && listed(a, jobs) == [Self.k1] && row(a, jobs)?.leftovers == [Self.leftover])
            #expect(row(a, jobs)?.settled.isSuperset(of: [Self.k3, Self.k2]) == true)
        }
        do {                                                                    // pulled before it reported
            var jobs = TransferJobs()
            let a = firstRun(["a", "b", "c", "d"], in: &jobs)
            _ = jobs.paused()
            #expect(jobs.ended(disconnected: true) == [a] && state(a, jobs) == .canceling)
            jobs.finish(a, outcome: late)
            #expect(row(a, jobs)?.failures == [failure(Self.k1)] + cutOff([Self.k3, Self.k2], Self.gone))
            #expect(state(a, jobs) == .failed && row(a, jobs)?.leftovers == [Self.leftover])
        }
    }

    /// D-13, D-16: a pull (or the reconnect bound) while jobs are paused makes every one whose cut run has reported a
    /// failed row with what it listed, carried and had pending, keeping its answers. With none of those, it lists each
    /// top-level item it didn't skip or make; a job whose cut run had copied everything leaves.
    @Test func aTerminalLossFailsReconnectingJobs() {
        for disconnected in [true, false] {
            let detail = disconnected ? Self.gone : Self.reset
            var jobs = TransferJobs()
            let r = firstRun(in: &jobs)
            let q = job(["q1", "q2"])
            jobs.add(q)
            jobs.scanned(q.id, clashes: [fileClash(0), fileClash(1)])
            jobs.answer(q.id, clash: Self.k0, with: .keepBoth, applyToAll: false)
            let w = job(["w1", "w2", "w3"])
            jobs.add(w)
            jobs.scanned(w.id, clashes: [fileClash(1)])
            jobs.answer(w.id, clash: Self.k1, with: .skip, applyToAll: false)
            #expect(jobs.paused() == [])
            jobs.finish(r, outcome: cut(at: Self.k1, rest: [Self.k2], failed: [failure(Self.k0)]))
            #expect(state(w.id, jobs) == .reconnecting && state(q.id, jobs) == .asking)

            #expect(jobs.ended(disconnected: disconnected) == [])
            #expect(state(r, jobs) == .failed && listed(r, jobs) == [Self.k0, Self.k1, Self.k2])
            #expect(state(q.id, jobs) == .failed && row(q.id, jobs)?.failures == perItem(["q1", "q2"], detail))
            #expect(row(q.id, jobs)?.answers.byItem == [Self.k0: .keepBoth])
            #expect(row(w.id, jobs)?.failures == [TransferFailure(name: "w1", detail: detail, key: Self.k0),
                                                  TransferFailure(name: "w3", detail: detail, key: Self.k2)])
            #expect(jobs.all.allSatisfy { !$0.isPaused && $0.carried.isEmpty && $0.pending.isEmpty })
        }
        var done = TransferJobs()
        let a = firstRun(["IMG.jpg", "Album"], in: &done)
        _ = done.paused()
        done.finish(a, outcome: TransferOutcome(settled: [Self.k0, ItemKey(top: 1, path: ["x.jpg"])], folders: [Self.k1: "Album"]))
        #expect(state(a, done) == .reconnecting)
        #expect(done.ended(disconnected: true) == [])
        #expect(done.isEmpty)
    }

    /// D-13: a Retry paused while it scans (no outcome yet, so nothing carried or pending) and then pulled keeps
    /// everything it listed.
    @Test func aPulledPausedRetryKeepsWhatItListed() {
        var jobs = TransferJobs()
        let a = retrying(at: .scanning, in: &jobs)
        #expect(jobs.paused() == [a])
        #expect(row(a, jobs)?.carried == [] && row(a, jobs)?.pending == [])
        #expect(jobs.ended(disconnected: true) == [])
        #expect(state(a, jobs) == .failed && row(a, jobs)?.failures == Self.cameraItems)
    }

    /// D-13, D-15, D-16: a real failure from before the reconnect stays on the job through every end of its
    /// continuation; what it still had pending is listed unless the user's Stop settled it or it was copied.
    @Test func carriedFailuresSurviveEveryEnd() {
        do {                                                                    // pulled
            var jobs = TransferJobs()
            let (a, k1, p6, p7) = carrying(in: &jobs)
            #expect(jobs.ended(disconnected: true) == [a])
            jobs.finish(a, outcome: TransferOutcome(cancelled: true))
            #expect(state(a, jobs) == .failed && listed(a, jobs) == [k1, p6, p7])
        }
        do {                                                                    // lost, not paused again
            var jobs = TransferJobs()
            let (a, k1, p6, p7) = carrying(in: &jobs)
            jobs.finish(a, outcome: TransferOutcome(failed: [failure(p7, Self.gone)], settled: [p6], lost: .deviceGone,
                                                    unfinished: p7))
            #expect(state(a, jobs) == .failed && listed(a, jobs) == [k1, p7])
        }
        do {                                                                    // the user's Stop
            var jobs = TransferJobs()
            let (a, k1, p6, p7) = carrying(in: &jobs)
            #expect(jobs.stop(a) == true)
            jobs.finish(a, outcome: TransferOutcome(unreached: cutOff([p6, p7]), cancelled: true, unfinished: p6))
            #expect(state(a, jobs) == .failed && listed(a, jobs) == [k1])
            #expect(row(a, jobs)?.settled.isSuperset(of: [p6, p7]) == true)
        }
        do {                                                                    // copied the rest
            var jobs = TransferJobs()
            let (a, k1, p6, p7) = carrying(in: &jobs)
            jobs.finish(a, outcome: TransferOutcome(settled: [p6, p7]))
            #expect(state(a, jobs) == .failed && listed(a, jobs) == [k1])
        }
    }

    /// D-15: stopping a reconnecting job whose cut run has reported ends it now (no task to cancel): a first run keeps
    /// only its real failures and settles what it had pending; a Retry keeps everything it listed, carried or had
    /// pending, minus what it finished.
    @Test func stoppingAReconnectingJob() {
        do {
            var jobs = TransferJobs()
            let a = firstRun(in: &jobs)
            _ = jobs.paused()
            jobs.finish(a, outcome: cut(at: Self.k1, rest: [Self.k2], settled: [Self.k0]))
            #expect(jobs.stop(a) == false)
            #expect(jobs.isEmpty)
        }
        do {
            var jobs = TransferJobs()
            let a = firstRun(in: &jobs)
            _ = jobs.paused()
            jobs.finish(a, outcome: cut(at: Self.k1, rest: [Self.k2], failed: [failure(Self.k0)]))
            #expect(jobs.stop(a) == false)
            #expect(state(a, jobs) == .failed && row(a, jobs)?.failures == [failure(Self.k0)])
            #expect(row(a, jobs)?.settled.isSuperset(of: [Self.k1, Self.k2]) == true)
        }
        do {
            let p = Self.cameraKeys
            var jobs = TransferJobs()
            let a = retrying(at: .copying, in: &jobs)
            _ = jobs.paused()
            jobs.finish(a, outcome: cut(at: p[2], rest: Array(p[3...]), failed: [failure(p[1])], settled: [p[0]]))
            #expect(jobs.stop(a) == false)
            #expect(state(a, jobs) == .failed && listed(a, jobs) == Array(p.dropFirst()))
            #expect(row(a, jobs)?.failures.first == failure(p[1]))
        }
    }

    /// P3 D-10, D-15: a job the user is already stopping isn't paused; if its cleanup loses the session, its report is
    /// still the user's Stop.
    @Test func aStopWhoseCleanupLosesTheSessionDuringAReconnectStaysAStop() {
        for (failed, expected) in [([failure(Self.k0)], [Self.k0]), ([], nil)] as [([TransferFailure], [ItemKey]?)] {
            var jobs = TransferJobs()
            let a = firstRun(in: &jobs)
            #expect(jobs.stop(a) == true)
            #expect(jobs.paused() == [])
            #expect(state(a, jobs) == .canceling && row(a, jobs)?.isPaused == false)
            jobs.finish(a, outcome: TransferOutcome(failed: failed, unreached: cutOff([Self.k1, Self.k2]), cancelled: true,
                                                    lost: Self.timeout, unfinished: Self.k1))
            #expect(listed(a, jobs) == expected)
            #expect(row(a, jobs).map { $0.settled.isSuperset(of: [Self.k1, Self.k2]) } ?? true)
        }
    }

    /// SC4, D-14: a failed row built from carried failures (one real, one lost twice) lists both, and its Retry plans
    /// both again: at a Retry only finished or skipped items are excluded.
    @Test func aFailedRowBuiltFromCarriedFailuresPlansThemOnRetry() {
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs)
        _ = jobs.paused()
        jobs.finish(a, outcome: cut(at: Self.k2, failed: [failure(Self.k1)], settled: [Self.k0]))
        continueCopying(a, in: &jobs)
        _ = jobs.paused()
        jobs.finish(a, outcome: cut(at: Self.k2))
        #expect(row(a, jobs)?.excluded == [Self.k0, Self.k1, Self.k2])
        #expect(jobs.ended(disconnected: true) == [])
        #expect(state(a, jobs) == .failed && listed(a, jobs) == [Self.k1, Self.k2])

        #expect(jobs.retry(a) == true)
        let retried = row(a, jobs)
        #expect(retried?.excluded == retried?.settled && retried?.excluded == [Self.k0])
        #expect(retried?.carried == [] && retried?.pending == [] && retried?.lostCount == [:])
        #expect(retried?.isPaused == false && retried?.pausedFrom == nil)
        #expect(listed(a, jobs) == [Self.k1, Self.k2])                          // kept if this attempt ends early
    }

    /// D-18 inverse: a reconnecting job is a copy in progress (the Mac stays awake, quitting asks), but it never starts
    /// itself, and while its cut run is out nothing starts.
    @Test func reconnectingIsActivity() {
        var jobs = TransferJobs()
        let a = firstRun(in: &jobs)
        _ = jobs.paused()
        #expect(jobs.hasActive && jobs.startNext() == nil)
        jobs.finish(a, outcome: cut(at: Self.k1))
        #expect(state(a, jobs) == .reconnecting && jobs.hasActive)
        #expect(jobs.startNext() == nil && state(a, jobs) == .reconnecting)
        #expect(TransferText.reconnecting == "Reconnecting…")
    }

    // MARK: reconnect bound and quit (D-10, D-11)

    @Test func quitWording() {
        #expect(TransferText.quitQuestion == "A copy is in progress. Stop it and quit?")
    }

    @Test func reconnectLimitAllowsTwoAMinute() {
        var limit = ReconnectLimit()
        let t = ContinuousClock.now
        #expect(limit.allow(at: t) == true)
        #expect(limit.allow(at: t + .seconds(10)) == true)
        #expect(limit.allow(at: t + .seconds(20)) == false)     // the third within a minute
        #expect(limit.allow(at: t + .seconds(90)) == true)      // the older ones have expired
    }

    @Test func quitGateAsksOnceThenQuitsAfterStopping() {
        var gate = QuitGate()
        #expect(gate.request(copying: false) == .quit)          // no copy: quit at once
        #expect(gate.request(copying: true) == .ask)
        #expect(gate.request(copying: true) == .refuse)         // a second ⌘Q while the question is up
        gate.answered(stop: false)                              // Cancel
        #expect(gate.request(copying: true) == .ask)            // the next quit asks again
        gate.answered(stop: true)                               // Stop & Quit
        #expect(gate.request(copying: true) == .refuse)         // still cleaning up
        gate.stopped()
        #expect(gate.request(copying: true) == .quit)           // even if an upload never settled
    }
}
