import Foundation

/// A move on the phone worked out before anything is sent (FMGT-04): one step per top-level item, in drop order, and
/// the clashes still waiting for an answer. Built against a fresh listing of the destination (RESEARCH Pitfall 11).
public struct MovePlan: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// MoveObject as is: the name is free in the destination.
        case move(ObjectEntry)
        /// Rename in the item's own folder to `as` (free in both folders), then MoveObject (D-12, Pitfall 14).
        case keepBoth(ObjectEntry, as: String)
        /// Delete `existing` (a file the user chose to replace), then MoveObject (D-12; files over files only, D-13).
        case replace(ObjectEntry, existing: ObjectEntry)

        /// The item being moved.
        public var entry: ObjectEntry {
            switch self {
            case .move(let e), .keepBoth(let e, _), .replace(let e, _): e
            }
        }
    }

    public internal(set) var steps: [Step] = []
    public internal(set) var clashes: [Clash] = []
    /// Folders turned down on the Mac with nothing sent: the destination is the folder itself or inside it.
    public internal(set) var refused: [ObjectEntry] = []

    /// The failure-alert line for `refused` (05-MOVE-PROBE Own Subtree).
    public static let ownSubtreeReason = "A folder can’t be moved into itself."
}

/// Moves within one storage (D-08), planned with the copy engine's clash rules and run in an order that never loses
/// the item being moved (D-11, D-12, D-13; RESEARCH Pattern 5).
public enum Move {
    /// The steps for moving `items` (top-level, deduped by the caller with `DeletePlan.topLevel`, in drop order) into
    /// `folder` (0xFFFFFFFF = storage root). Nothing is changed on the phone.
    /// - An item already in `folder` is no step (D-11).
    /// - Names are compared by `phoneKey` against a fresh listing, so a case-only clash is a clash: AOSP checks names
    ///   case-sensitively and rename(2) would overwrite a case variant (Pitfall 11).
    /// - A name an earlier item of this move claimed is kept both without a question, as copies do (P4 D-10).
    /// - A folder that is the destination or one of its ancestors is refused with nothing sent: the phone refuses it
    ///   too, but then answers 0x0000 for that subtree until a new session (05-MOVE-PROBE Own Subtree).
    /// - A clash is answered by `answers`, else kept both when `unanswered == .keepBoth`, else reported with no step.
    ///   Replace only puts a file over a file; on a folder or a type clash it is Keep Both, so no folder is ever
    ///   replaced or merged (D-13).
    /// - A Keep Both name is free in the destination, in the item's own folder (the rename happens there, Pitfall 14)
    ///   and among every name this move claims.
    public static func plan(_ items: [ObjectEntry], storage: UInt32, into folder: UInt32,
                            answers: ClashAnswers = ClashAnswers(), unanswered: Unanswered = .ask,
                            session: DeviceSession) async throws -> MovePlan {
        var plan = MovePlan()
        var chain: Set<UInt32> = []         // the destination and its ancestors, read only when a folder moves
        if items.contains(where: \.isFolder) {
            var handle = folder
            for _ in 0..<256 where handle != 0xFFFF_FFFF && handle != 0 {   // bounded, in case a phone ever loops
                chain.insert(handle)
                guard let up = try await session.entry(handle)?.parent else { break }
                handle = up
            }
        }
        let listed = try await Transfer.list(storage: storage, parent: folder, session: session)
        let taken = Dictionary(listed.map { (Transfer.phoneKey($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        var claimed: [String] = []          // names this move gives in `folder`
        var claimedKeys: Set<String> = []
        // ponytail: one extra listing per source folder that needs a Keep Both name; fine for drag-sized moves.
        var sourceNames: [UInt32: [String]] = [:]
        for (i, item) in items.enumerated() where item.parent != folder {
            func keptBoth() async throws -> String {
                if sourceNames[item.parent] == nil {
                    sourceNames[item.parent] = try await Transfer.list(storage: storage, parent: item.parent,
                                                                       session: session).map(\.name)
                }
                return NameRules.keepBothName(item.name, isFolder: item.isFolder,
                                              among: listed.map(\.name) + (sourceNames[item.parent] ?? []) + claimed)
            }
            if chain.contains(item.id) {
                plan.refused.append(item)
                continue
            }
            let key = Transfer.phoneKey(item.name)
            var step = MovePlan.Step.move(item)
            if !claimedKeys.insert(key).inserted {
                step = .keepBoth(item, as: try await keptBoth())            // P4 D-10: only the first is asked
            } else if let there = taken[key] {
                let clash = Clash(id: ItemKey(top: i), existing: side(there), incoming: side(item))
                switch answers.answer(for: clash) ?? (unanswered == .keepBoth ? .keepBoth : nil) {
                case nil:
                    plan.clashes.append(clash)
                    continue
                case .skip?:
                    continue
                case .replace? where clash.allowsReplace:
                    step = .replace(item, existing: there)
                case .replace?, .keepBoth?:                                 // D-13: a folder is never replaced
                    step = .keepBoth(item, as: try await keptBoth())
                }
            }
            if case .keepBoth(_, let name) = step {
                claimed.append(name)
                claimedKeys.insert(Transfer.phoneKey(name))
            } else {
                claimed.append(item.name)
            }
            plan.steps.append(step)
        }
        return plan
    }

    private static func side(_ e: ObjectEntry) -> Clash.Side {
        Clash.Side(name: e.name, isFolder: e.isFolder, size: e.isFolder ? nil : e.size, modified: e.modified)
    }

    /// Runs one step. Its phone commands run in one unstructured Task, like `Transfer.finalize`, so a Stop can't land
    /// between them (RESEARCH Pitfall 8).
    /// - Keep Both renames in the item's own folder first, then moves; a refused move renames it back (best effort).
    ///   A cut between the two leaves the item in its own folder under the new name: nothing is lost.
    /// - Replace deletes the existing file (already gone counts as deleted; any other refusal moves nothing), then
    ///   moves, retrying only on General Error, 50 ms × 2ⁿ, at most 6 retries: AOSP keeps the deleted name cached
    ///   for a moment (FROZEN_ONESHOT_DEL). A cut between them loses only the file the user chose to replace.
    public static func perform(_ step: MovePlan.Step, storage: UInt32, into folder: UInt32,
                               session: DeviceSession) async throws {
        try await Task {
            switch step {
            case .move(let e):
                try await session.move(e.id, storage: storage, to: folder)
            case .keepBoth(let e, let name):
                try await session.rename(e.id, to: name, timeout: 120)
                do {
                    try await session.move(e.id, storage: storage, to: folder)
                } catch let error as MTPError where error.isResponse {
                    try? await session.rename(e.id, to: e.name, timeout: 120)
                    throw error
                }
            case .replace(let e, let existing):
                do {
                    try await session.delete(existing.id)
                } catch let error as MTPError where error.isInvalidObjectHandle {
                    // already gone on the phone
                }
                for retry in 0... {
                    do {
                        return try await session.move(e.id, storage: storage, to: folder)
                    } catch MTPError.response(code: MTPCode.generalError, op: _) where retry < 6 {
                        try? await Task.sleep(for: .milliseconds(50 << retry))
                    }
                }
            }
        }.value
    }
}
