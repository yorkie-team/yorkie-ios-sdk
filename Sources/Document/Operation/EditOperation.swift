/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

/// `RestoreMode` selects the identity-preserving path for undo/redo of pure
/// deletions: `restore` revives spans, `retombstone` re-deletes them.
enum RestoreMode {
    case restore
    case retombstone
}

/// `EditOperation` is an operation representing editing Text.
///
/// It is a `class` (reference type) because undo/redo mutates its range in place — `refinePos`
/// remaps the range to the current split chain, and `reconcileOperation` shifts it when remote
/// edits occur while the operation sits on the undo/redo stack.
final class EditOperation: Operation {
    var parentCreatedAt: TimeTicket
    var executedAt: TimeTicket

    /// `fromPos` returns the start point of the editing range.
    private(set) var fromPos: RGATreeSplitPos
    /// `toPos` returns the end point of the editing range.
    private(set) var toPos: RGATreeSplitPos

    /// `content` returns the content of RichEdit.
    private(set) var content: String

    /// `attributes` returns the attributes of this Edit.
    private(set) var attributes: [String: String]?

    /// Whether this operation was produced as the reverse of an edit (i.e. lives on a history stack).
    private let isUndoOp: Bool

    /// `restoreSpans` returns the identity-preserving restore payload, if this
    /// is a restore/retombstone operation.
    private(set) var restoreSpans: [RestoreSpan<CRDTTextValue>]?

    /// `restoreMode` returns the identity-preserving mode of this Edit.
    private(set) var restoreMode: RestoreMode?

    /// `retombstoneSpans` is the companion span set for an identity-preserving
    /// reverse op. `restoreSpans` describes content the reversed edit removed;
    /// `retombstoneSpans` describes content the reversed edit inserted (non-empty
    /// only for the reverse of a replace). `restoreMode` picks the direction:
    /// `restore` revives `restoreSpans` and re-removes `retombstoneSpans`; a
    /// `retombstone` op (the redo) does the opposite. Reversing an edit that both
    /// inserts and deletes as two identity operations — rather than
    /// copy-reinserting the deleted text as a fresh node — keeps a later revived
    /// neighbour in its original relative order.
    private(set) var retombstoneSpans: [RestoreSpan<CRDTTextValue>]?

    init(
        parentCreatedAt: TimeTicket,
        fromPos: RGATreeSplitPos,
        toPos: RGATreeSplitPos,
        content: String,
        attributes: [String: String]?,
        executedAt: TimeTicket,
        isUndoOp: Bool = false,
        restoreSpans: [RestoreSpan<CRDTTextValue>]? = nil,
        restoreMode: RestoreMode? = nil,
        retombstoneSpans: [RestoreSpan<CRDTTextValue>]? = nil
    ) {
        self.parentCreatedAt = parentCreatedAt
        self.fromPos = fromPos
        self.toPos = toPos
        self.content = content
        self.attributes = attributes
        self.executedAt = executedAt
        self.isUndoOp = isUndoOp
        self.restoreSpans = restoreSpans
        self.restoreMode = restoreMode
        self.retombstoneSpans = retombstoneSpans
    }

    /**
     * `execute` executes this operation on the given document(`root`).
     */
    @discardableResult
    func execute(
        root: CRDTRoot,
        versionVector: VersionVector? = nil,
        source: OpSource = .local
    ) throws -> ExecutionResult? {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let text = parent as? CRDTText else {
            let log: String
            if let parent {
                log = "fail to execute, only Text can execute edit: \(parent)"
            } else {
                log = "fail to find \(self.parentCreatedAt)"
            }
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        // The identity-preserving path is selected by the mode, not by the spans being present: a
        // reverse whose span sets both came out empty is still an identity op and must run as a
        // no-op here. Falling through to the positional path below would read its positions as an
        // ordinary edit range.
        if self.restoreMode != nil {
            return try self.executeIdentityPreserving(
                root: root,
                text: text,
                source: source,
                versionVector: versionVector
            )
        }

        // An undo edit that inserts nothing changes nothing wherever it sits, but its position can
        // name an offset the text no longer has: stacked entries are reconciled against remote
        // positional edits, not against remote undos and redos, which change the text by identity.
        // Run it as the no-op it is, moved to the head so the copy that goes out to other replicas
        // resolves on every one of them.
        if self.isUndoOp, self.content.isEmpty {
            self.fromPos = Self.headPos
            self.toPos = Self.headPos
            return ExecutionResult(opInfos: [], reverseOp: source == .remote ? nil : self.emptyReverse())
        }

        // When replaying a reverse edit, the range may reference a split chain that has since
        // changed; refine it back onto the current chain before editing.
        //
        // `isUndoOp` normally marks that, but an identity-preserving reverse op that
        // arrives from a peer or server older than 0.7.13 has its restore fields
        // (proto 8-10) stripped, so `restoreMode` — and with it `isUndoOp` — is lost,
        // leaving only the head-anchored base range that `normalizePos` produced.
        // Detect that shape directly: only `normalizePos` yields a position on the
        // head sentinel with a non-zero offset, because the head holds no content, so
        // no forward edit can reference it. Without this the range reaches
        // `splitNode` unresolved and throws, which escapes the sync loop and makes
        // the change re-pull and re-fail indefinitely.
        let isHeadAnchored = self.fromPos.id == RGATreeSplitNodeID.initial && self.fromPos.relativeOffset > 0
        if self.isUndoOp || isHeadAnchored {
            self.fromPos = try text.refinePos(self.fromPos)
            self.toPos = try text.refinePos(self.toPos)
        }

        let (changes, pairs, diff, _, removedValues, removedSpans) = try text.edit(
            (self.fromPos, self.toPos),
            self.content,
            self.executedAt,
            self.attributes,
            versionVector
        )

        let reverseOp = try self.toReverseOperation(removedValues, text.normalizePos(self.fromPos), removedSpans)

        root.acc(diff)

        for pair in pairs {
            root.registerGCPair(pair)
        }

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        let opInfos: [any OperationInfo] = changes.compactMap {
            EditOpInfo(path: path, from: $0.from, to: $0.to, attributes: $0.attributes?.createdDictionary, content: $0.content)
        }

        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
    }

    /// Executes an identity-preserving reverse op. `restoreMode` picks the
    /// direction: an undo (`restore`) revives `restoreSpans` and re-removes
    /// `retombstoneSpans`; the redo (`retombstone`) does the opposite. Both sets
    /// are revived/removed by their original identity, never re-inserted as
    /// fresh nodes, so relative order is preserved across chained undo.
    private func executeIdentityPreserving(
        root: CRDTRoot,
        text: CRDTText,
        source: OpSource,
        versionVector: VersionVector?
    ) throws -> ExecutionResult {
        let isRetombstone = self.restoreMode == .retombstone
        let toRestore = (isRetombstone ? self.retombstoneSpans : self.restoreSpans) ?? []
        let toRetombstone = (isRetombstone ? self.restoreSpans : self.retombstoneSpans) ?? []

        let path = try root.createPath(createdAt: self.parentCreatedAt)
        var opInfos: [any OperationInfo] = []
        var totalDiff = DataSize(data: 0, meta: 0)

        // The spans about to be re-tombstoned are what the reverse op will have to restore, and a
        // replica that purged them rebuilds the nodes from that payload alone. Re-snapshot them
        // against the live content first: the span set was captured when the reversed edit ran, so
        // an attribute applied to the run since is missing from it and a purged replica would
        // recreate the run without it while a replica that un-tombstones keeps it. Taken before the
        // removal below, and only when the reverse is kept: a remote change discards it.
        let refreshed = source != .remote && !toRetombstone.isEmpty
            ? text.rgaTreeSplit.refreshSpans(toRetombstone)
            : nil

        // 1. Remove the content the reversed edit inserted (by identity). The reverse names only the
        // pieces the removal was recorded on: naming it on a piece someone else removed would
        // cancel a removal that piece never had, and a replica that purged the piece could not tell.
        var recorded: [RestoreSpan<CRDTTextValue>]?
        if !toRetombstone.isEmpty {
            let (pairs, changes, diff, spans) = try text.retombstone(
                refreshed ?? toRetombstone,
                self.executedAt,
                versionVector
            )
            recorded = spans
            totalDiff.addDataSizes(others: diff)
            for pair in pairs {
                root.registerGCPair(pair)
            }
            opInfos.append(contentsOf: changes.compactMap {
                EditOpInfo(path: path, from: $0.from, to: $0.to, attributes: $0.attributes?.createdDictionary, content: $0.content)
            })
        }

        // 2. Revive the content the reversed edit removed (by identity).
        if !toRestore.isEmpty {
            let (untombstoned, _, changes, liveDiff, pendingGCPairs) = try text.restore(
                toRestore,
                self.executedAt,
                self.fromPos
            )
            if text.hasCancelledRemovals {
                root.registerLedgerHolder(text)
            }
            // Register first: a `pendingGCPairs` entry whose child ended up in
            // `untombstoned` was never registered under its own id (it was born
            // by splitting a larger tombstone), so the unregister loop below can
            // only walk its size from gc back to live if it's registered here
            // first.
            for pair in pendingGCPairs {
                root.registerGCPair(pair)
            }
            for node in untombstoned {
                root.unregisterGCPair(GCPair(parent: text.rgaTreeSplit, child: node))
            }
            totalDiff.addDataSizes(others: liveDiff)
            opInfos.append(contentsOf: changes.compactMap {
                EditOpInfo(path: path, from: $0.from, to: $0.to, attributes: $0.attributes?.createdDictionary, content: $0.content)
            })
        }

        root.acc(totalDiff)

        // Reverse keeps the same span sets and flips the direction. The re-removed set is the pieces
        // the removal was recorded on, taken from the spans refreshed against live attributes (a
        // purged replica rebuilds from them).
        let reverseOp = self.identityReverse(
            restoreSpans: isRetombstone ? (recorded ?? self.restoreSpans) : self.restoreSpans,
            restoreMode: isRetombstone ? .restore : .retombstone,
            retombstoneSpans: !isRetombstone ? (recorded ?? self.retombstoneSpans) : self.retombstoneSpans
        )

        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
    }

    /// The position at the start of the head node, the one node of a text GC never purges.
    private static var headPos: RGATreeSplitPos {
        RGATreeSplitPos(RGATreeSplitNodeID.initial, 0)
    }

    /// Builds the reverse of an identity-preserving edit, or -- when both of its span sets came out
    /// empty -- an ordinary no-op edit anchored at the text's head.
    ///
    /// A reverse with no spans has nothing to revive and nothing to re-remove, but it still has to
    /// exist: dropping it would leave the undo stack one entry short of the redo stack, so a later
    /// redo would replay the wrong entry. It cannot be kept in identity form either -- the
    /// converter writes a restore mode only with spans, so it would go out as a positional edit of
    /// its stale range -- so it degrades to the same shape an edit that removed and inserted
    /// nothing reverses to.
    private func identityReverse(
        restoreSpans: [RestoreSpan<CRDTTextValue>]?,
        restoreMode: RestoreMode,
        retombstoneSpans: [RestoreSpan<CRDTTextValue>]?
    ) -> EditOperation {
        if (restoreSpans?.isEmpty ?? true), (retombstoneSpans?.isEmpty ?? true) {
            return self.emptyReverse()
        }
        return EditOperation(
            parentCreatedAt: self.parentCreatedAt,
            fromPos: self.fromPos,
            toPos: self.toPos,
            content: "",
            attributes: nil,
            executedAt: TimeTicket.initial,
            isUndoOp: true,
            restoreSpans: restoreSpans,
            restoreMode: restoreMode,
            retombstoneSpans: retombstoneSpans
        )
    }

    /// Returns an empty undo edit at the head of this op's text: the reverse of an edit that
    /// changes nothing.
    private func emptyReverse() -> EditOperation {
        EditOperation(
            parentCreatedAt: self.parentCreatedAt,
            fromPos: Self.headPos,
            toPos: Self.headPos,
            content: "",
            attributes: nil,
            executedAt: TimeTicket.initial,
            isUndoOp: true
        )
    }

    /// Builds the reverse edit: re-inserts the removed content over the range that this edit's
    /// inserted content now occupies.
    private func toReverseOperation(
        _ removedValues: [CRDTTextValue],
        _ fromPos: RGATreeSplitPos,
        _ removedSpans: [RestoreSpan<CRDTTextValue>]
    ) -> Operation {
        if !removedSpans.isEmpty || !self.content.isEmpty {
            // Reverse any edit by identity: revive what it removed (restoreSpans)
            // and re-remove what it inserted (retombstoneSpans), both by original
            // identity, rather than copy-reinserting or position-deleting. A fresh
            // copy-reinserted node sorts ahead of an as-yet-unrevived neighbour and
            // corrupts order across chained undo/redo; a position-based delete of
            // the inserted range reconciles onto the wrong node under a concurrent
            // remote edit (e.g. two clients concurrently insert and delete, then
            // undo). Identity addressing avoids both.
            var insertedSpans: [RestoreSpan<CRDTTextValue>]?
            if !self.content.isEmpty {
                let value = CRDTTextValue(self.content)
                // Carry the attributes the edit applied, stamped with the same ticket
                // `CRDTText.edit` used. The undo only re-tombstones this span, so its value is
                // unread there -- but the redo flips `restoreMode` and the span becomes the content
                // to restore. A replica that purged the node rebuilds it from this value alone, so
                // an empty attribute map here makes it diverge from a replica that still
                // un-tombstones the original.
                for (key, attrValue) in self.attributes ?? [:] {
                    _ = value.setAttr(key: key, value: attrValue, updatedAt: self.executedAt)
                }
                insertedSpans = [
                    RestoreSpan(
                        createdAt: self.executedAt,
                        start: 0,
                        end: Int32(value.count),
                        value: value
                    )
                ]
            }

            return EditOperation(
                parentCreatedAt: self.parentCreatedAt,
                fromPos: fromPos,
                toPos: fromPos,
                content: "",
                attributes: nil,
                executedAt: TimeTicket.initial,
                isUndoOp: true,
                restoreSpans: removedSpans.isEmpty ? nil : removedSpans,
                restoreMode: .restore,
                retombstoneSpans: insertedSpans
            )
        }

        let reverseContent = removedValues.isEmpty ? "" : removedValues.map { $0.toString }.joined()

        var reverseAttributes: [String: String]?
        if removedValues.count == 1 {
            let attrs = removedValues[0].getAttributes()
            if !attrs.isEmpty {
                reverseAttributes = attrs.mapValues { $0.value }
            }
        }

        let contentLength = Int32((self.content as NSString).length)
        // executedAt is reassigned just before execution when Document.undo() is called.
        return EditOperation(
            parentCreatedAt: self.parentCreatedAt,
            fromPos: fromPos,
            toPos: RGATreeSplitPos(fromPos.id, fromPos.relativeOffset + contentLength),
            content: reverseContent,
            attributes: reverseAttributes,
            executedAt: TimeTicket.initial,
            isUndoOp: true
        )
    }

    /// `normalizePos` returns the absolute `(from, to)` offsets of this edit's range.
    func normalizePos(_ root: CRDTRoot) throws -> (Int, Int) {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let text = parent as? CRDTText else {
            throw YorkieError(code: .errInvalidArgument, message: "only Text can normalize edit")
        }

        let rangeFrom = try text.normalizePos(self.fromPos).relativeOffset
        let rangeTo = try text.normalizePos(self.toPos).relativeOffset
        return (Int(rangeFrom), Int(rangeTo))
    }

    /// `reconcileOperation` shifts this (undo) edit's range when a remote edit changes the text
    /// while the operation is parked on the undo/redo stack, so a later undo lands in the right spot.
    /// NOTE: restoreSpans ops address content by identity (createdAt + offset),
    /// so `fromPos`/`toPos` are never used to locate the restored range itself.
    /// But `fromPos` is also passed as the fallback anchor for when every related
    /// piece has been GC'd (see `findRestoreAnchor`), so it still needs to track
    /// concurrent remote edits like any other undo position — only the identity
    /// payload (`restoreSpans`) must stay untouched, which the reconciliation
    /// below never reads.
    func reconcileOperation(_ remoteFrom: Int, _ remoteTo: Int, _ contentLen: Int) {
        guard self.isUndoOp, remoteFrom <= remoteTo else {
            return
        }

        let remoteRangeLen = remoteTo - remoteFrom
        let localFrom = Int(self.fromPos.relativeOffset)
        let localTo = Int(self.toPos.relativeOffset)

        func apply(_ na: Int, _ nb: Int) {
            self.fromPos = RGATreeSplitPos(self.fromPos.id, Int32(max(0, na)))
            self.toPos = RGATreeSplitPos(self.toPos.id, Int32(max(0, nb)))
        }

        // Case 1: remote edit entirely left of the undo range.
        if remoteTo <= localFrom {
            apply(localFrom - remoteRangeLen + contentLen, localTo - remoteRangeLen + contentLen)
            return
        }
        // Case 2: remote edit entirely right of the undo range.
        if localTo <= remoteFrom {
            return
        }
        // Case 3: undo range contained within the remote range.
        if remoteFrom <= localFrom, localTo <= remoteTo, remoteFrom != remoteTo {
            apply(remoteFrom, remoteFrom)
            return
        }
        // Case 4: remote range contained within the undo range.
        if localFrom <= remoteFrom, remoteTo <= localTo, localFrom != localTo {
            apply(localFrom, localTo - remoteRangeLen + contentLen)
            return
        }
        // Case 5: remote range overlaps the start of the undo range.
        if remoteFrom < localFrom, localFrom < remoteTo, remoteTo < localTo {
            apply(remoteFrom, remoteFrom + (localTo - remoteTo))
            return
        }
        // Case 6: remote range overlaps the end of the undo range.
        if localFrom < remoteFrom, remoteFrom < localTo, localTo < remoteTo {
            apply(localFrom, remoteFrom)
            return
        }
    }

    /**
     * `effectedCreatedAt` returns the creation time of the effected element.
     */
    var effectedCreatedAt: TimeTicket {
        self.parentCreatedAt
    }

    /**
     * `toTestString` returns a string containing the meta data.
     */
    var toTestString: String {
        let parent = self.parentCreatedAt.toTestString
        let fromPos = self.fromPos.toTestString
        let toPos = self.toPos.toTestString
        let content = self.content
        return "\(parent).EDIT(\(fromPos),\(toPos),\(content)"
    }
}
