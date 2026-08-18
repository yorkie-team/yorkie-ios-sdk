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

        if self.restoreSpans != nil || self.retombstoneSpans != nil {
            return try self.executeIdentityPreserving(root: root, text: text)
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
    private func executeIdentityPreserving(root: CRDTRoot, text: CRDTText) throws -> ExecutionResult {
        let isRetombstone = self.restoreMode == .retombstone
        let toRestore = (isRetombstone ? self.retombstoneSpans : self.restoreSpans) ?? []
        let toRetombstone = (isRetombstone ? self.restoreSpans : self.retombstoneSpans) ?? []

        let path = try root.createPath(createdAt: self.parentCreatedAt)
        var opInfos: [any OperationInfo] = []
        var totalDiff = DataSize(data: 0, meta: 0)

        // 1. Remove the content the reversed edit inserted (by identity).
        if !toRetombstone.isEmpty {
            let (pairs, changes, diff) = try text.retombstone(toRetombstone, self.executedAt)
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

        // Reverse keeps the same span sets and flips the direction.
        let reverseOp = EditOperation(
            parentCreatedAt: self.parentCreatedAt,
            fromPos: self.fromPos,
            toPos: self.toPos,
            content: "",
            attributes: nil,
            executedAt: TimeTicket.initial,
            isUndoOp: true,
            restoreSpans: self.restoreSpans,
            restoreMode: isRetombstone ? .restore : .retombstone,
            retombstoneSpans: self.retombstoneSpans
        )

        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
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
