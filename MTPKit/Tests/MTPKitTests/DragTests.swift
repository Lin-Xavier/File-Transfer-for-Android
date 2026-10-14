import Foundation
import Testing
@testable import MTPKit

/// One job per drag out (D-01) and every promise completion called exactly once (D-05).
@Suite struct DragTests {
    @Test func startsOnceWhenEveryPromiseArrived() {
        var batch = PromiseBatch(expected: 3)
        #expect(batch.arrive() == .wait)
        #expect(batch.arrive() == .wait)
        #expect(batch.arrive() == .start)
        #expect(batch.arrive() == .startAlone)
        #expect(batch.arrived == 4)
    }

    @Test func flushStartsWhatArrived() {
        var batch = PromiseBatch(expected: 3)
        #expect(batch.arrive() == .wait)
        #expect(batch.arrive() == .wait)
        #expect(batch.flush() == .start)
        #expect(batch.flush() == .wait)
        #expect(batch.arrive() == .startAlone)
    }

    @Test func flushWithNothingArrivedStartsNothing() {
        var batch = PromiseBatch(expected: 1)
        #expect(batch.flush() == .wait)
        #expect(batch.arrive() == .start)
    }

    @Test func oneItemStartsAtOnce() {
        var batch = PromiseBatch(expected: 1)
        #expect(batch.arrive() == .start)
    }

    @Test func endedJobsAreTakenOnce() {
        var ledger = JobLedger<String, String>()
        ledger.record("A", for: "a")
        ledger.record("B", for: "b")
        ledger.record("C", for: "c")
        #expect(Set(ledger.takeEnded(live: ["b"])) == ["A", "C"])
        #expect(ledger.takeEnded(live: ["b"]).isEmpty)
        #expect(ledger.takeEnded(live: []) == ["B"])
        #expect(ledger.takeEnded(live: []).isEmpty)
    }

    /// What the promises of a three-item drag out are told: `setup` brings its job to the state it ends from, `end`
    /// takes it out of the live jobs (the queue's last change before `fireEnds`).
    private func report(_ setup: (inout TransferJobs, TransferJob.ID) -> Void = { _, _ in },
                        end: (inout TransferJobs, TransferJob.ID) -> Void) -> EndReport {
        var jobs = TransferJobs()
        let job = TransferJob(names: ["a", "b", "c"], destinationName: "Downloads",
                              request: .download([], paths: [], to: URL(filePath: "/d")),
                              phone: PhoneID(serial: "FAKE0001", name: "Pixel 9"),
                              session: DeviceSession(transport: FakeAndroidResponder()))
        jobs.add(job)
        setup(&jobs, job.id)
        let old = jobs
        end(&jobs, job.id)
        #expect(!jobs.all.contains { $0.id == job.id && $0.state != .failed })
        return jobs.endReport(for: job.id, was: old)
    }

    private func copying(_ jobs: inout TransferJobs, _ id: TransferJob.ID) {
        jobs.scanned(id, clashes: [])
        _ = jobs.startNext()
        jobs.begin(id, total: 3)
    }

    @Test func aFinishedDragOutReportsEveryItemLanded() {
        let all: Set<ItemKey> = [ItemKey(top: 0), ItemKey(top: 1), ItemKey(top: 2)]
        let r = report(copying) { $0.finish($1, outcome: TransferOutcome(settled: all)) }
        #expect(r == .landed)
        #expect(r.error(top: 1) == nil)
    }

    @Test func aStopOrARefusalReportsTheSilentOne() {
        let stoppedCopying = report({ copying(&$0, $1); _ = $0.stop($1) }) {
            $0.finish($1, outcome: TransferOutcome(cancelled: true))
        }
        let clash = Clash(id: ItemKey(top: 0), existing: Clash.Side(name: "a"), incoming: Clash.Side(name: "a"))
        let stoppedAsking = report({ $0.scanned($1, clashes: [clash]) }) { _ = $0.stop($1) }
        let refused = report({ $0.scanned($1, clashes: []); _ = $0.startNext() }) {   // no space: ends from preparing
            $0.finish($1, outcome: TransferOutcome())
        }
        #expect([stoppedCopying, stoppedAsking, refused] == [.silent, .silent, .silent])
        #expect((refused.error(top: 0) as? CocoaError)?.code == .userCancelled)
    }

    /// Revised D-05: a partly failed job errors only the items that didn't land (G-05-1-2, WR-01).
    @Test func aFailedRowErrorsOnlyTheItemsThatDidNotLand() {
        let failed = TransferFailure(name: "IMG.jpg", detail: "No", key: ItemKey(top: 1, path: ["IMG.jpg"]))
        let r = report(copying) {
            $0.finish($1, outcome: TransferOutcome(failed: [failed], settled: [ItemKey(top: 0), ItemKey(top: 2)]))
        }
        #expect(r == .failed(tops: [1]))
        #expect(r.error(top: 0) == nil && r.error(top: 2) == nil)
        #expect((r.error(top: 1) as? CocoaError)?.code == .fileWriteUnknown)
    }

    @Test func anUnplugErrorsWhatDidNotLand() {
        let r = report({ copying(&$0, $1); _ = $0.ended(disconnected: true) }) {
            $0.finish($1, outcome: TransferOutcome(settled: [ItemKey(top: 0)], cancelled: true))
        }
        #expect(r == .failed(tops: [1, 2]))
    }

    @Test func aFailureNamingNoItemErrorsEveryItem() {
        let r = report(copying) { $0.finish($1, outcome: TransferOutcome(failed: [TransferFailure(detail: "No")])) }
        #expect(r == .failed(tops: nil))
        #expect([0, 1, 2].allSatisfy { r.error(top: $0) != nil })
    }

    @Test func groupsByPromisedFolder() {
        let a = URL(filePath: "/d/a"), b = URL(filePath: "/e/b"), c = URL(filePath: "/d/c")
        #expect(PromiseBatch.byFolder([a, b, c], url: { $0 }) == [[a, c], [b]])
        #expect(PromiseBatch.byFolder([a, c], url: { $0 }) == [[a, c]])
    }

    @Test func stagingStaysWhileItsDropOrAJobNeedsIt() {
        var ledger = StagingLedger<Int>()
        let f = URL(filePath: "/tmp/staging/F"), g = URL(filePath: "/tmp/staging/G")
        ledger.hold(f)
        ledger.record(f, for: 1)
        #expect(ledger.jobsLeft(live: []).isEmpty)  // the drop still holds F
        #expect(ledger.release(f) == f)
        ledger.hold(g)
        ledger.record(g, for: 2)
        #expect(ledger.release(g) == nil)  // j2 still listed: running, or a failed row kept for Retry
        #expect(ledger.jobsLeft(live: [2]).isEmpty)
        ledger.record(g, for: 3)  // a late file's own job
        #expect(ledger.jobsLeft(live: [3]).isEmpty)
        #expect(ledger.jobsLeft(live: []) == [g])
        #expect(ledger.jobsLeft(live: []).isEmpty)
    }

    @Test func aDropWithNoJobIsFreedAtRelease() {
        var ledger = StagingLedger<Int>()
        let h = URL(filePath: "/tmp/staging/H")
        ledger.hold(h)
        #expect(ledger.release(h) == h)
    }
}
