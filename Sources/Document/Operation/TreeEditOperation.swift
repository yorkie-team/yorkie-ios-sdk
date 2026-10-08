/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
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

/// `cloneAndDropPreTombstoned` deep-copies `node` and drops descendants whose ID is in
/// `preTombstoned` — i.e., descendants that were already tombstoned before this edit ran.
/// Those descendants represent the user's earlier delete intent and must not be resurrected
/// by undoing this edit.
///
/// For nodes kept in the clone, `removedAt` is cleared so the redo re-inserts them as live.
/// iOS tracks a single visible `size` per node (unlike the JS SDK's separate `visibleSize` /
/// `totalSize`). The traversal clears tombstones and recomputes `size` bottom-up: element
/// nodes derive size from their children's `paddedSize`; text nodes keep their value-length
/// size unchanged.
///
/// - Parameters:
///   - node: The node to deep-copy and filter.
///   - preTombstoned: IDs of nodes already tombstoned before this edit.
/// - Returns: A deep copy of `node` with pre-tombstoned descendants removed and
///   `removedAt` cleared on surviving nodes.
private func cloneAndDropPreTombstoned(_ node: CRDTTreeNode, _ preTombstoned: Set<String>) -> CRDTTreeNode? {
    guard let clone = node.deepcopy() else { return nil }
    filterChildren(clone, preTombstoned)
    // Post-order: clear tombstone on every survivor and recompute size from its
    // (already-resized) children. The deepcopy carried the original node's size;
    // after filterChildren dropped descendants that size is stale and must be
    // recomputed bottom-up.
    traverseAll(node: clone) { node, _ in
        node.removedAt = nil
        if node.isText == false {
            node.size = node.innerChildren.reduce(0) { $0 + $1.paddedSize }
        }
    }
    return clone
}

/// `filterChildren` walks `node.innerChildren` and drops descendants whose IDs are in
/// `preTombstoned`. Used by ``cloneAndDropPreTombstoned(_:_:)`` to keep only nodes that
/// this edit actually transitioned from visible to tombstoned.
///
/// - Parameters:
///   - node: The node (within a deep copy) whose children to filter.
///   - preTombstoned: IDs of nodes already tombstoned before this edit.
private func filterChildren(_ node: CRDTTreeNode, _ preTombstoned: Set<String>) {
    var kept = [CRDTTreeNode]()
    for child in node.innerChildren {
        if preTombstoned.contains(child.toIDString) {
            // Already tombstoned before this edit — drop from reverseOp.
            continue
        }
        filterChildren(child, preTombstoned)
        kept.append(child)
    }
    node.innerChildren = kept
}

/// `mergedAwayIDs` returns the ids of the elements a merge removed, innermost first -- the order a
/// split re-creating them issues tickets in, since it splits from the innermost level out.
///
/// `mergedNodes` is the merge-boundary set ``CRDTTree/edit(_:_:_:_:_:_:)`` reports, NOT every node
/// the edit tombstoned: the split reversing the merge re-creates exactly one element per boundary
/// it crossed, so anything else in the removed set -- a whole element deleted inside the range, a
/// cascade-deleted descendant, a node already tombstoned -- would shift the positional pairing
/// with the split's tickets and bind an unrelated element to one of them.
private func mergedAwayIDs(_ mergedNodes: [CRDTTreeNode]) -> [CRDTTreeNodeID] {
    func depth(of node: CRDTTreeNode) -> Int {
        var depth = 0
        var current = node.parent
        while let parent = current {
            depth += 1
            current = parent.parent
        }
        return depth
    }

    return mergedNodes
        .filter { $0.isText == false }
        .map { (node: $0, depth: depth(of: $0)) }
        .sorted { $0.depth > $1.depth }
        .map { $0.node.id }
}

/// `TreeEditOperation` is an operation representing Tree editing.
///
/// It is a `class` (reference type) because undo/redo mutates its range in place — at undo
/// execution time the stored integer indices are converted to ``CRDTTreePos``, and
/// ``reconcileOperation(_:_:_:)`` shifts those indices when a remote edit occurs while the
/// operation sits on the undo/redo stack.
final class TreeEditOperation: Operation {
    var parentCreatedAt: TimeTicket
    var executedAt: TimeTicket

    /// `fromPos` returns the start point of the editing range.
    private(set) var fromPos: CRDTTreePos
    /// `toPos` returns the end point of the editing range.
    private(set) var toPos: CRDTTreePos
    /// `contents` returns the content of Edit.
    let contents: [CRDTTreeNode]?
    let splitLevel: Int32

    /// Whether this operation was produced as the reverse of an edit (i.e. lives on a history stack).
    private let isUndoOp: Bool
    /// The reconciled start index of an undo op's range, used to recompute ``fromPos`` at undo time.
    private var fromIdx: Int?
    /// The reconciled end index of an undo op's range, used to recompute ``toPos`` at undo time.
    private var toIdx: Int?
    /// The pre-edit start index captured by the most recent `execute`, used to reconcile parked ops.
    private var lastFromIdx: Int?
    /// The pre-edit end index captured by the most recent `execute`, used to reconcile parked ops.
    private var lastToIdx: Int?
    /// The tree-index token count the tree actually accepted from ``contents`` on the most recent
    /// `execute`. The tree drops content whose ID it already holds, so this can be smaller than the
    /// content this operation carries; a reverse range covering a dropped copy would delete a
    /// neighbour on redo.
    private var insertedContentSize: Int?
    /// What the identity-preserving restore/retombstone path changed the last time it ran: one
    /// `(from, to, insertedSize)` per node that left or came back, in the order it did, each measured
    /// against the tree as it stood at that moment. `nil` for every other edit, which reports its
    /// single range through ``normalizePos()``/``getContentSize()`` instead (see ``getExecutedRanges()``).
    private var executedRanges: [(Int, Int, Int)]?
    /// The visible-index size the boundaries this execution's forward `edit` opened: two tokens per
    /// element it split, zero for a split with no visible effect. A split creates boundaries rather
    /// than inserting nodes, so ``insertedContentSize`` never sees them; reconciliation needs both,
    /// and reads their sum through ``getContentSize()``.
    private var splitSize: Int?
    /// Set on boundary-deletion ops that were generated to reverse a split. When this op executes
    /// (as undo), ``toReverseOperation(_:_:_:)`` uses this value to regenerate a proper split op
    /// for redo, rather than re-inserting the tombstoned boundary nodes as content.
    fileprivate var redoSplitLevel: Int32?

    // Identity-preserving Tree undo/redo (mirrors ``EditOperation``): a reverse
    // op carries the deleted nodes' spans and a mode. `.restore` revives
    // `restoreSpans` and re-removes `retombstoneSpans`; `.retombstone` (the redo)
    // does the opposite. Nodes are revived/removed by original identity, never
    // copy-reinserted, so concurrent undos converge. Empty/nil for ordinary edits
    // and for the copy-reinsert reverse of merge/split edits.
    private(set) var restoreSpans: [TreeRestoreSpan]?
    private(set) var restoreMode: RestoreMode?
    private(set) var retombstoneSpans: [TreeRestoreSpan]?

    /// The tickets the originating replica issued for the nodes an element split creates, in issue
    /// order. A replica applying the operation consumes them instead of reconstructing them, so
    /// neither side depends on the other's allocation staying in step. Empty for a change written
    /// before the field existed, which falls back to the reconstruction.
    private var splitTickets: [TimeTicket] = []
    /// `replacedIDs` is set on a split that re-creates elements a merge removed -- the redo of a
    /// split, or the undo of a merge. It names those elements, innermost first, in the order the
    /// split mints their replacements. The replacements get new ids (see ``setSplitTickets(_:)``),
    /// so whoever runs this split re-points every recorded operation at them. Local to the replica
    /// that recorded it; never encoded.
    private(set) var replacedIDs: [CRDTTreeNodeID] = []
    /// How many of ``splitTickets`` the current execution has handed to the tree -- fewer than
    /// `splitLevel` when the split loop ran out of ancestors, and zero before it starts. Doubles as
    /// the index reported to ``splitTicketConsumedHandler``.
    private var consumedSplitTickets = 0
    /// What the last execution's split re-created, as `(removed element, its replacement)` pairs.
    /// See ``getSplitRecreatedIDs()``.
    private var splitRecreatedIDs: [(CRDTTreeNodeID, CRDTTreeNodeID)] = []
    /// Notified as each recorded split ticket is handed to the tree, with its index in
    /// ``splitTickets``. A split stops as soon as it runs out of ancestors, so how many elements it
    /// really mints is only knowable from inside the split -- and re-pointing anything at a ticket
    /// the split never consumed would leave it naming a node that was never created. Undo/redo
    /// registers a handler here so the re-pointing happens per minted element, while the operations
    /// that follow in the same change are still waiting to run. Local to the replica that
    /// registered it; never encoded, and never copied to another operation.
    private var splitTicketConsumedHandler: ((Int) -> Void)?

    init(parentCreatedAt: TimeTicket,
         fromPos: CRDTTreePos,
         toPos: CRDTTreePos,
         contents: [CRDTTreeNode]?,
         splitLevel: Int32,
         executedAt: TimeTicket,
         isUndoOp: Bool = false,
         fromIdx: Int? = nil,
         toIdx: Int? = nil,
         restoreSpans: [TreeRestoreSpan]? = nil,
         restoreMode: RestoreMode? = nil,
         retombstoneSpans: [TreeRestoreSpan]? = nil)
    {
        self.parentCreatedAt = parentCreatedAt
        self.fromPos = fromPos
        self.toPos = toPos
        self.contents = contents
        self.splitLevel = splitLevel
        self.executedAt = executedAt
        self.isUndoOp = isUndoOp
        self.fromIdx = fromIdx
        self.toIdx = toIdx
        self.restoreSpans = restoreSpans
        self.restoreMode = restoreMode
        self.retombstoneSpans = retombstoneSpans
    }

    /// `reissueContentIDs` gives every node this operation inserts a fresh identity.
    ///
    /// A reverse operation that reverses a deletion by re-inserting a copy of the removed nodes
    /// carries their original ids, so executing it would put two nodes under one id — the ambiguity
    /// that makes a position anchored there resolve differently on different replicas. Undo already
    /// re-identifies a restored value elsewhere: ``ArraySetOperation`` and ``AddOperation`` both take
    /// the fresh ticket in ``Document/undo()``. This is the tree's counterpart, called from the same
    /// place so the ids come from the change the undo creates.
    ///
    /// A restore-mode reverse is left alone: it revives nodes under their original identity by
    /// design, which is what makes concurrent undos of one deletion converge rather than duplicate.
    ///
    /// - Parameter issueTimeTicket: Issues the next ticket of the change the undo creates.
    /// - Returns: The `(old, new)` pairs it minted, so the caller can re-point whatever else was
    ///   recorded against the old ids -- the same reconciliation a split's re-created elements need
    ///   (``getReplacedIDs()``).
    /// - Throws: ``YorkieError`` with code `errRefused` when this operation also splits.
    @discardableResult
    func reissueContentIDs(_ issueTimeTicket: @escaping () -> TimeTicket) throws -> [(CRDTTreeNodeID, CRDTTreeNodeID)] {
        var reissued: [(CRDTTreeNodeID, CRDTTreeNodeID)] = []
        guard let contents = self.contents, self.restoreMode == nil else {
            return reissued
        }

        // The tickets taken here start at `executedAt.delimiter + 1` and run one per node, while
        // `execute` simulates the tickets an element split consumes starting at
        // `executedAt.delimiter + contents.count + 1`. The two ranges overlap as soon as content has
        // descendants, so this only holds while no content-bearing reverse splits — which is every
        // reverse `toReverseOperation` builds, all of them `splitLevel: 0`.
        if self.splitLevel != 0 {
            throw YorkieError(code: .errRefused, message: "cannot reissue content ids on a splitting edit")
        }

        for content in contents {
            traverseAll(node: content) { node, _ in
                let prev = node.id
                node.id = CRDTTreeNodeID(createdAt: issueTimeTicket(), offset: 0)
                reissued.append((prev, node.id))
                // A fresh identity has to be fresh in every field that names a node. The copy came
                // from `deepcopy`, which carries the split chain and the merge lineage of the node it
                // copied: left in place they would splice this node into a chain it never belonged
                // to, and `purge` relinking that chain would unlink the real tombstone from it.
                node.insPrevID = nil
                node.insNextID = nil
                node.mergedFrom = nil
                node.mergedAt = nil
                node.mergedInto = nil
            }
        }

        return reissued
    }

    /// `makeSplitTicketIssuer` returns the closure ``CRDTTree/edit(_:_:_:_:_:_:)`` uses to issue
    /// tickets for the nodes an element split creates.
    ///
    /// The originating replica issued them and carries them in ``splitTickets``, so this hands them
    /// back in the same order. A change written before that field existed carries none and falls
    /// back to reconstructing them from `editedAt` and the number of top-level contents — a
    /// reconstruction that is wrong as soon as content has descendants, since each of those consumed
    /// a ticket too.
    ///
    /// TODO(sejongk): When splitting element nodes, a new nodeID is assigned with a different
    /// timeTicket. In the same change context, the timeTickets share the same lamport and actorID
    /// but have different delimiters, incremented by one for each. This logic might be unclear;
    /// consider refactoring for multi-level concurrent editing in the Tree implementation.
    ///
    /// - Parameter editedAt: The ticket this operation executes at.
    /// - Returns: A closure returning the next split ticket on each call.
    private func makeSplitTicketIssuer(_ editedAt: TimeTicket) -> () -> TimeTicket {
        // The base is captured once and advanced one delimiter per issued ticket, so successive
        // tickets in a multi-level split are consecutive. Reading the base back off the last issued
        // ticket instead would re-add the content count on every call.
        var delimiter = editedAt.delimiter + UInt32(self.contents?.count ?? 0)
        self.consumedSplitTickets = 0
        return {
            if self.consumedSplitTickets < self.splitTickets.count {
                let index = self.consumedSplitTickets
                self.consumedSplitTickets += 1
                // Reported as the ticket leaves, not after the split returns: the caller re-points
                // the rest of the change at the element this ticket identifies, and that has to be
                // in place before those operations run. `split` always inserts the node it clones
                // under the ticket it took, so a consumed ticket is an element that exists.
                self.splitTicketConsumedHandler?(index)
                return self.splitTickets[index]
            }
            delimiter += 1
            return TimeTicket(lamport: editedAt.lamport, delimiter: delimiter, actorID: editedAt.actorID)
        }
    }

    /// `getSplitTickets` returns the tickets issued for the nodes an element split created, in issue
    /// order.
    ///
    /// - Returns: The issued tickets, empty when this edit did not split an element.
    func getSplitTickets() -> [TimeTicket] {
        self.splitTickets
    }

    /// `setSplitTickets` records the tickets issued for the nodes an element split created.
    ///
    /// The originating replica calls this after executing the edit, so every other replica can use
    /// them instead of reconstructing them.
    ///
    /// - Parameter tickets: The tickets in issue order.
    func setSplitTickets(_ tickets: [TimeTicket]) {
        self.splitTickets = tickets
    }

    /// `getReplacedIDs` returns the ids of the elements this split re-creates, innermost first.
    /// Empty unless this operation is the redo of a split or the undo of a merge.
    func getReplacedIDs() -> [CRDTTreeNodeID] {
        self.replacedIDs
    }

    /// `reconcileNodeID` points this operation at `curr` wherever it named `prev`: its range, and
    /// the restore spans an identity-preserving undo carries. See
    /// ``TreeStyleOperation/reconcileNodeID(prev:curr:)``.
    func reconcileNodeID(prev: CRDTTreeNodeID, curr: CRDTTreeNodeID) {
        self.fromPos = self.fromPos.replaceNodeID(prev: prev, curr: curr)
        self.toPos = self.toPos.replaceNodeID(prev: prev, curr: curr)

        // `span.id` too, not just the anchors: it is the identity `restore` and `retombstone` look
        // the node up by, and the one they RECREATE the node under when garbage collection has
        // purged it (``CRDTTree/restore(_:_:)``). Left naming the element the split has just
        // re-minted under a new ticket, an identity restore would revive nothing and recreate a
        // duplicate under the stale id.
        func reconcileSpans(_ spans: [TreeRestoreSpan]?) -> [TreeRestoreSpan]? {
            spans?.map { span in
                TreeRestoreSpan(
                    id: replaceTreeNodeID(span.id, prev: prev, curr: curr),
                    nodeType: span.nodeType,
                    isText: span.isText,
                    length: span.length,
                    value: span.value,
                    attrs: span.attrs,
                    parentID: span.parentID.map { replaceTreeNodeID($0, prev: prev, curr: curr) },
                    leftSiblingID: span.leftSiblingID.map { replaceTreeNodeID($0, prev: prev, curr: curr) },
                    rightSiblingID: span.rightSiblingID.map { replaceTreeNodeID($0, prev: prev, curr: curr) }
                )
            }
        }

        self.restoreSpans = reconcileSpans(self.restoreSpans)
        self.retombstoneSpans = reconcileSpans(self.retombstoneSpans)
        self.replacedIDs = self.replacedIDs.map { replaceTreeNodeID($0, prev: prev, curr: curr) }
    }

    /// `onSplitTicketConsumed` registers `handler`, called with the index of each recorded split
    /// ticket as the split takes it -- i.e. once per element the split really mints, and never for
    /// a level it stopped short of. The operation is executed twice per undo/redo (clone, then
    /// root), so the handler is called twice for the same index and has to be idempotent. Pass
    /// `nil` to clear it once both executions are done: the handler closes over the undo/redo
    /// entry, which the operation must not keep alive -- and must never re-point again from a later
    /// execution. See ``splitTicketConsumedHandler``.
    func onSplitTicketConsumed(_ handler: ((Int) -> Void)? = nil) {
        self.splitTicketConsumedHandler = handler
    }

    /// `getSplitRecreatedIDs` returns the `(removed element, its replacement)` pairs the LAST
    /// execution's split produced -- the elements a merge had taken away and that this split
    /// re-created under new ids. Reset at every execution, so after a change has been applied it
    /// describes the root pass.
    ///
    /// Unlike ``getReplacedIDs()`` this is derived from the tree the split ran on, not from the
    /// reverse op this replica recorded, so it is available for a PEER's split too: the operation
    /// on the wire says which tickets the split minted, never what they replace.
    func getSplitRecreatedIDs() -> [(CRDTTreeNodeID, CRDTTreeNodeID)] {
        self.splitRecreatedIDs
    }

    /// `getConsumedSplitTicketCount` returns how many of the recorded split tickets the LAST
    /// execution handed to the tree -- how many elements that execution really minted. Fewer than
    /// `splitLevel` when the split loop ran out of ancestors, and zero when this operation never
    /// ran.
    ///
    /// The count is reset at the start of every execution, so after an undo/redo has applied the
    /// change it describes the root pass, not the clone pass that ran first. The two can disagree:
    /// the clone and the root are separate trees, and a remote change applied between the clone's
    /// last sync and now can leave the split with a different number of ancestors to cross. The
    /// handler above fires per execution and cannot tell which; anything that must reflect what the
    /// ROOT tree actually minted has to check this after the fact.
    func getConsumedSplitTicketCount() -> Int {
        self.consumedSplitTickets
    }

    /// `setActor` sets the given actor to this operation and to the tickets its split issued.
    ///
    /// A document edited before `Client.attach` runs under the initial actor, and
    /// `Document.setActor` re-stamps every pending local change once the real actor
    /// arrives, by calling this through an `Operation` existential. The default
    /// implementation rewrites `executedAt` alone, which would leave the split
    /// tickets recorded at edit time naming the old actor: they are issued from the
    /// change's own context, so every reader — the converter's split-ticket decode,
    /// and any replica reasoning about which change minted a node — expects them to
    /// carry the change's actor. Re-stamp them here. The lamport and the delimiters
    /// are untouched, so their order (and the identities the split mints) is
    /// unchanged.
    ///
    /// - Parameter actorID: The actor to stamp onto ``executedAt`` and every split ticket.
    func setActor(_ actorID: ActorID) {
        self.executedAt.setActor(actorID)
        self.splitTickets = self.splitTickets.map {
            var ticket = $0
            ticket.setActor(actorID)
            return ticket
        }
    }

    /**
     * `execute` executes this operation on the given `CRDTRoot`.
     */
    @discardableResult
    func execute(
        root: CRDTRoot,
        versionVector: VersionVector? = nil,
        source: OpSource = .local
    ) throws -> ExecutionResult? {
        guard let parentObject = root.find(createdAt: self.parentCreatedAt) else {
            let log = "fail to find \(self.parentCreatedAt)"
            Logger.critical(log)
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        let editedAt = self.executedAt
        guard let tree = parentObject as? CRDTTree else {
            throw YorkieError(code: .errInvalidArgument, message: "fail to execute, only Tree can execute edit")
        }

        // Identity-preserving restore/retombstone path (mirrors ``EditOperation``).
        // `restoreMode` selects direction; an undo (`.restore`) revives
        // `restoreSpans` and re-removes `retombstoneSpans`, the redo
        // (`.retombstone`) does the opposite. Nodes move by identity, never
        // copy-reinsert.
        if self.restoreSpans != nil || self.retombstoneSpans != nil {
            return try self.executeIdentityPreservingEdit(tree: tree, root: root, editedAt: editedAt)
        }

        // For undo ops the stored integer indices may have been reconciled against remote edits;
        // convert them back to positions on the current tree before editing.
        if self.isUndoOp, let fromIdx = self.fromIdx, let toIdx = self.toIdx {
            self.fromPos = try tree.findPos(fromIdx)
            self.toPos = try fromIdx == toIdx ? self.fromPos : (tree.findPos(toIdx))
        }

        // The tree drops content that reuses an ID it already holds, and reports the size of what it
        // accepted. The reverse operation and the undo stack both read that size rather than the
        // content this operation carried: a range covering content the tree refused would delete a
        // neighbour on redo.
        let (changes, pairs, diff, removedNodes, preEditFromIdx, mergeLevel, preTombstoned, removedSpans, insertedSpans, insertedContentSize, splitSize, mergedNodes, splitRecreatedIDs) = try tree.edit(
            (self.fromPos, self.toPos),
            self.contents?.compactMap { $0.deepcopy() },
            self.splitLevel,
            editedAt,
            self.makeSplitTicketIssuer(editedAt),
            versionVector
        )

        // Capture the pre-edit range so a remote/local edit can reconcile parked undo ops. `toIdx`
        // is `fromIdx` plus the total visible tokens of the nodes this edit removed.
        self.lastFromIdx = preEditFromIdx
        let removedSize = removedNodes.reduce(0) { $0 + $1.paddedSize }
        self.lastToIdx = preEditFromIdx + removedSize
        self.insertedContentSize = insertedContentSize
        self.splitSize = splitSize
        // What this execution's split re-created -- see `getSplitRecreatedIDs`. Reset on every
        // execution, so after undo/redo has applied the change this describes the root pass.
        self.splitRecreatedIDs = splitRecreatedIDs

        // Build the reverse op for undo.
        // A pure split (splitLevel > 0, no content inserted, no nodes removed) gets a
        // boundary-deletion reverse so that undo merges the split elements back. This
        // covers both level-1 and level-2+ splits, enabling undo/redo of splitLevel>=2.
        let isPureSplit = self.splitLevel > 0
            && (self.contents?.isEmpty ?? true)
            && removedNodes.isEmpty
        let reverseOp: Operation?
        if self.splitLevel == 0 {
            reverseOp = try self.toReverseOperation(tree, removedNodes, preEditFromIdx, preTombstoned: preTombstoned, mergeLevel: mergeLevel, removedSpans: removedSpans, insertedSpans: insertedSpans, mergedNodes: mergedNodes)
        } else if isPureSplit {
            reverseOp = try self.toSplitReverseOperation(tree, preEditFromIdx, splitSize)
        } else {
            reverseOp = nil
        }

        root.acc(diff)

        for pair in pairs {
            root.registerGCPair(pair)
        }

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        let opInfos: [any OperationInfo] = changes.compactMap { change in
            let value: [CRDTTreeNode] = {
                if case .nodes(let nodes) = change.value {
                    return nodes
                } else {
                    return []
                }
            }()

            return TreeEditOpInfo(
                path: path,
                from: change.from,
                to: change.to,
                value: value.compactMap { $0.toJSONTreeNode },
                splitLevel: change.splitLevel,
                fromPath: change.fromPath,
                toPath: change.toPath
            )
        }

        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
    }

    /// `executeIdentityPreservingEdit` runs the identity-preserving restore/retombstone path
    /// (mirrors ``EditOperation``) that ``execute(root:versionVector:source:)`` delegates to when
    /// this operation carries `restoreSpans`/`retombstoneSpans`: an undo (`.restore`) revives
    /// `restoreSpans` and re-removes `retombstoneSpans`, the redo (`.retombstone`) does the
    /// opposite. Nodes move by identity, never copy-reinsert.
    ///
    /// One opInfo is produced per node that left or came back, in the order it did, so an editor
    /// can apply them one after another like any other edit. The list is empty when nothing visible
    /// changed (e.g. everything stays under a removed ancestor); the change still propagates, since
    /// `Document.executeUndoRedo` gates on executed operations, not opInfos. ``executedRanges`` is
    /// set from the same per-node measurements, for the undo stack: the stored `fromIdx`/`toIdx`
    /// describe the forward edit this op reverses and never move (the nodes are addressed by
    /// identity), so they would shift the pending entries by a range this op never touched.
    private func executeIdentityPreservingEdit(tree: CRDTTree, root: CRDTRoot, editedAt: TimeTicket) throws -> ExecutionResult {
        var isRetombstone = false
        if case .retombstone = self.restoreMode {
            isRetombstone = true
        }
        let toRestore = (isRetombstone ? self.retombstoneSpans : self.restoreSpans) ?? []
        let toRetombstone = (isRetombstone ? self.restoreSpans : self.retombstoneSpans) ?? []

        var diff = DataSize(data: 0, meta: 0)
        // 1. Re-remove (retombstone) by identity. Isolating a straddling piece
        // splits it (live-split overhead accounted to `diff`).
        let (retombstonePairs, retombstoneDiff, retombstoneChanges) = try tree.retombstone(toRetombstone, editedAt)
        diff.addDataSizes(others: retombstoneDiff)
        for pair in retombstonePairs {
            root.registerGCPair(pair)
        }
        // 2. Revive (restore) by identity. Isolating a range out of a straddling
        // piece can split off born-removed remainders as pending GC pairs;
        // register them FIRST so a split-born un-tombstoned target is walked
        // gc->live correctly by the unregister below (mirrors the Text path).
        // Un-tombstoned nodes move gc->live via `unregisterGCPair` (must be
        // after `removedAt` is cleared, which `restore` does); recreated nodes
        // are brand new, so add their size to live, plus any live-split
        // overhead.
        let (untombstoned, recreated, restorePairs, restoreDiff, restoreChanges) = try tree.restore(toRestore, editedAt)
        for pair in restorePairs {
            root.registerGCPair(pair)
        }
        for node in untombstoned {
            root.unregisterGCPair(GCPair(parent: tree, child: node))
        }
        diff.addDataSizes(others: restoreDiff)
        for node in recreated {
            diff.addDataSizes(others: node.getDataSize())
        }
        root.acc(diff)

        let path = try root.createPath(createdAt: self.parentCreatedAt)
        let edits = retombstoneChanges + restoreChanges
        let opInfos: [any OperationInfo] = edits.map { edit in
            let value: [CRDTTreeNode] = {
                if case .nodes(let nodes) = edit.change.value {
                    return nodes
                }
                return []
            }()
            return TreeEditOpInfo(path: path,
                                  from: edit.change.from,
                                  to: edit.change.to,
                                  value: value.compactMap { $0.toJSONTreeNode },
                                  splitLevel: 0,
                                  fromPath: edit.change.fromPath,
                                  toPath: edit.change.toPath)
        }
        self.executedRanges = edits.map { ($0.change.from, $0.change.to, $0.insertedSize) }

        // Reverse keeps the same span sets and flips the direction.
        let reverseOp = TreeEditOperation(parentCreatedAt: self.parentCreatedAt,
                                          fromPos: self.fromPos,
                                          toPos: self.toPos,
                                          contents: nil,
                                          splitLevel: 0,
                                          executedAt: TimeTicket.initial, // reassigned at (re)undo time
                                          isUndoOp: true,
                                          fromIdx: self.fromIdx,
                                          toIdx: self.toIdx,
                                          restoreSpans: self.restoreSpans,
                                          restoreMode: isRetombstone ? .restore : .retombstone,
                                          retombstoneSpans: self.retombstoneSpans)

        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
    }

    /// `toReverseOperation` creates the reverse operation for undo.
    ///
    /// The reverse op stores both ``CRDTTreePos`` (for initial use) and integer indices (for
    /// reconciliation when remote edits arrive). At undo time the integer indices take precedence
    /// and are converted to positions via `tree.findPos`.
    ///
    /// When `mergeLevel > 0`, the edit was a cross-boundary merge (it moved children by
    /// deleting element boundaries). The reverse of a merge is a split — not content
    /// re-insertion — so a split op with `splitLevel = mergeLevel` is returned instead of
    /// the normal content-reinsertion reverse.
    ///
    /// Nodes whose IDs appear in `preTombstoned` were already tombstoned before this edit ran.
    /// They represent the user's earlier delete intent and must not be resurrected when undoing
    /// this edit. They are excluded from `topLevelRemoved` and from the cloned content.
    ///
    /// - Parameters:
    ///   - tree: The tree after this edit has been applied.
    ///   - removedNodes: The nodes removed by this edit, to be re-inserted on undo.
    ///   - preEditFromIdx: The start index captured before the edit deletions.
    ///   - preTombstoned: IDs of nodes already tombstoned before this edit ran.
    ///   - mergeLevel: The number of element boundaries merged by this edit. When greater than
    ///     zero the reverse op is a split rather than a content reinsertion.
    /// - Returns: The reverse ``TreeEditOperation``, or `nil` when the edit was a no-op.
    private func toReverseOperation(_ tree: CRDTTree, _ removedNodes: [CRDTTreeNode], _ preEditFromIdx: Int, preTombstoned: Set<String> = [], mergeLevel: Int = 0, removedSpans: [TreeRestoreSpan] = [], insertedSpans: [TreeRestoreSpan] = [], mergedNodes: [CRDTTreeNode] = []) throws -> Operation? {
        // Identity-preserving reverse: reverse an edit by reviving the nodes it
        // removed (`restoreSpans`) AND re-removing the nodes it inserted
        // (`retombstoneSpans`), both by ORIGINAL identity instead of
        // copy-reinsert. `edit` only fills these spans when the edit was
        // merge/split-free (spansComplete), so this never fires for the
        // merge/split cases below; the `redoSplitLevel` guard keeps a split's own
        // boundary-deletion undo on the re-split path (its deletion would
        // otherwise fill `removedSpans` here).
        if self.redoSplitLevel == nil, !removedSpans.isEmpty || !insertedSpans.isEmpty {
            return TreeEditOperation(parentCreatedAt: self.parentCreatedAt,
                                     fromPos: self.fromPos,
                                     toPos: self.toPos,
                                     contents: nil,
                                     splitLevel: 0,
                                     executedAt: TimeTicket.initial, // assigned at undo time
                                     isUndoOp: true,
                                     fromIdx: preEditFromIdx,
                                     toIdx: preEditFromIdx,
                                     restoreSpans: removedSpans,
                                     restoreMode: .restore,
                                     retombstoneSpans: insertedSpans)
        }

        // Special case: this op is a boundary-deletion that was generated to reverse a split.
        // Its redo (i.e. the reverse of this reverse) should re-split at the merged position,
        // not re-insert the tombstoned boundary nodes as raw content.
        if let redoSplitLevel, redoSplitLevel > 0 {
            let splitRedoFromPos = try tree.findPos(preEditFromIdx)
            let splitRedoOp = TreeEditOperation(
                parentCreatedAt: self.parentCreatedAt,
                fromPos: splitRedoFromPos,
                toPos: splitRedoFromPos,
                contents: nil,
                splitLevel: redoSplitLevel,
                executedAt: TimeTicket.initial,
                isUndoOp: true,
                fromIdx: preEditFromIdx,
                toIdx: preEditFromIdx
            )
            splitRedoOp.replacedIDs = mergedAwayIDs(mergedNodes)
            return splitRedoOp
        }

        // Cross-boundary merge: the reverse is a split, not content re-insertion.
        // A merge deletes element boundaries (e.g., </p><p>), moving children
        // into the target. The undo re-creates those boundaries via split.
        if mergeLevel > 0 {
            let splitFromPos = try tree.findPos(preEditFromIdx)
            let splitUndoOp = TreeEditOperation(
                parentCreatedAt: self.parentCreatedAt,
                fromPos: splitFromPos,
                toPos: splitFromPos,
                contents: nil,
                splitLevel: Int32(mergeLevel),
                executedAt: TimeTicket.initial,
                isUndoOp: true,
                fromIdx: preEditFromIdx,
                toIdx: preEditFromIdx
            )
            splitUndoOp.replacedIDs = mergedAwayIDs(mergedNodes)
            return splitUndoOp
        }

        // Inserted content size in tree index tokens, measured before the edit: these nodes are now
        // in the tree, and one inserted under a concurrently removed parent is tombstoned on the way
        // in, which shrinks the size read back here. The guard below relies on that pre-edit size to
        // recognize an edit that had no effect. What it counts is the content the tree accepted, not
        // the content this operation carried — a reverse range covering a dropped copy would delete a
        // neighbour on redo.
        let insertedContentSize = self.insertedContentSize ?? 0

        // Guard: if the positions exceed the post-edit tree size, the edit was a no-op (e.g. a
        // concurrent parent deletion tombstoned the inserted content). Skip the reverse op.
        let maxNeededIdx = preEditFromIdx + insertedContentSize
        if maxNeededIdx > tree.size {
            return nil
        }

        // Filter to top-level removed nodes (whose parent is NOT also removed).
        // Also exclude nodes that were already tombstoned before this edit ran:
        // those represent the user's earlier delete intent and must not be
        // resurrected by a parent-level undo, even at the root of topLevelRemoved.
        let topLevelRemoved = removedNodes.filter { node in
            if preTombstoned.contains(node.toIDString) {
                return false
            }
            guard let parent = node.parent else {
                return true
            }
            return removedNodes.contains { $0 === parent } == false
        }

        // Deep copy for re-insertion on undo, but drop descendants that were
        // already tombstoned before this edit. Without this filter, undoing a
        // parent delete would resurrect the user's earlier independent deletes —
        // causing accumulation across undo/redo cycles in nested-edit scenarios.
        let reverseContents: [CRDTTreeNode]? = topLevelRemoved.isEmpty
            ? nil
            : topLevelRemoved.compactMap { node in
                cloneAndDropPreTombstoned(node, preTombstoned)
            }

        // Positions for the reverse range, computed on the post-edit tree from the pre-edit index.
        let reverseFromPos = try tree.findPos(preEditFromIdx)
        let reverseToPos = try insertedContentSize > 0
            ? (tree.findPos(preEditFromIdx + insertedContentSize))
            : reverseFromPos

        // executedAt is reassigned just before execution when Document.undo() is called.
        return TreeEditOperation(
            parentCreatedAt: self.parentCreatedAt,
            fromPos: reverseFromPos,
            toPos: reverseToPos,
            contents: reverseContents,
            splitLevel: 0,
            executedAt: TimeTicket.initial,
            isUndoOp: true,
            fromIdx: preEditFromIdx,
            toIdx: preEditFromIdx + insertedContentSize
        )
    }

    /// `toSplitReverseOperation` creates the reverse operation for a pure split edit (splitLevel > 0).
    ///
    /// A split creates element boundaries (one close token + one open token per level). The reverse
    /// is a boundary-deletion: a `splitLevel=0` edit that removes those tokens, merging the split
    /// elements back together.
    ///
    /// `boundarySize` is how many tokens the split actually opened, not `2 * splitLevel`, which is
    /// only how many it asked for: the split loop stops when it runs out of ancestors to split, and
    /// a level the tree has no room for would size this range over tokens the split never opened.
    /// The undo then deletes live content past its own boundary and merges elements the split never
    /// separated.
    ///
    /// The boundary-deletion op carries ``redoSplitLevel`` so that *its* reverse regenerates a
    /// proper split (redo) rather than re-inserting the tombstoned boundary nodes as content.
    ///
    /// - Parameters:
    ///   - tree: The tree after the split has been applied.
    ///   - preEditFromIdx: The from index captured before the split.
    ///   - boundarySize: The visible-index size the split opened.
    /// - Returns: The boundary-deletion ``TreeEditOperation``, or `nil` when the split was a no-op.
    private func toSplitReverseOperation(_ tree: CRDTTree, _ preEditFromIdx: Int, _ boundarySize: Int) throws -> Operation? {
        // The split had no visible effect — a concurrent deletion tombstoned the element it
        // split, so its boundary occupies no visible index, or there was no ancestor left to
        // split at all. Nothing for an undo to merge.
        if boundarySize == 0 {
            return nil
        }

        let reverseFromIdx = preEditFromIdx
        let reverseToIdx = preEditFromIdx + boundarySize

        // Belt and braces against a range that runs off the end of the tree: deleting it would
        // take out live content to the right of the boundary.
        if reverseToIdx > tree.size {
            return nil
        }

        let reverseFromPos = try tree.findPos(reverseFromIdx)
        let reverseToPos = try tree.findPos(reverseToIdx)

        let boundaryDeletionOp = TreeEditOperation(
            parentCreatedAt: self.parentCreatedAt,
            fromPos: reverseFromPos,
            toPos: reverseToPos,
            contents: nil,
            splitLevel: 0,
            executedAt: TimeTicket.initial,
            isUndoOp: true,
            fromIdx: reverseFromIdx,
            toIdx: reverseToIdx
        )
        // Tag the op so its own reverse (redo) regenerates a split rather than raw content.
        boundaryDeletionOp.redoSplitLevel = self.splitLevel
        return boundaryDeletionOp
    }

    /// `normalizePos` returns the visible-index `(from, to)` range of this operation.
    ///
    /// For undo ops it returns the stored (possibly reconciled) indices; for forward ops it returns
    /// the pre-edit indices captured during `execute`.
    func normalizePos() -> (Int, Int) {
        if self.isUndoOp, let fromIdx = self.fromIdx, let toIdx = self.toIdx {
            return (fromIdx, toIdx)
        }

        if let lastFromIdx = self.lastFromIdx, let lastToIdx = self.lastToIdx {
            return (lastFromIdx, lastToIdx)
        }

        return (0, 0)
    }

    /// `reconcileOperation` shifts this (undo) op's integer indices when a remote edit changes the
    /// tree while the operation is parked on the undo/redo stack, so a later undo lands in the right
    /// spot. Uses the same 6-case overlap logic as ``EditOperation/reconcileOperation(_:_:_:)``.
    func reconcileOperation(_ remoteFrom: Int, _ remoteTo: Int, _ contentLen: Int) {
        // Identity-addressed restore/retombstone ops locate their nodes by
        // `CRDTTreeNodeID`, not by index, so index reconciliation must not touch
        // them (mirrors ``EditOperation`` for Text).
        if self.restoreSpans != nil || self.retombstoneSpans != nil {
            return
        }
        guard self.isUndoOp, let localFrom = self.fromIdx, let localTo = self.toIdx, remoteFrom <= remoteTo else {
            return
        }

        let remoteRangeLen = remoteTo - remoteFrom

        func apply(_ na: Int, _ nb: Int) {
            self.fromIdx = max(0, na)
            self.toIdx = max(0, nb)
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

    /// `getExecutedRanges` returns the visible ranges this execution replaced, each with the size it
    /// inserted there, in the order they applied -- what the undo stack has to be reconciled against.
    ///
    /// An identity-preserving restore/retombstone reports one entry per node that came back or left,
    /// measured as it happened; every other edit reports its single normalized range.
    func getExecutedRanges() -> [(Int, Int, Int)] {
        if let executedRanges = self.executedRanges {
            return executedRanges
        }

        let (from, to) = self.normalizePos()
        return [(from, to, self.getContentSize())]
    }

    /// `getContentSize` returns the total visible size of this operation's content.
    ///
    /// Once the operation has run, this is the size the tree accepted: content whose ID was already
    /// in the tree is dropped, and the undo stack shifts its stored indices by this size, so counting
    /// the dropped copy would move every index in the stack past content that was never inserted.
    func getContentSize() -> Int {
        if let insertedContentSize = self.insertedContentSize {
            return insertedContentSize + (self.splitSize ?? 0)
        }
        return self.contents?.reduce(0) { $0 + $1.paddedSize } ?? 0
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
        let fromPos = "\(self.fromPos.leftSiblingID):\(self.fromPos.leftSiblingID.offset)"
        let toPos = "\(self.toPos.leftSiblingID):\(self.toPos.leftSiblingID.offset)"

        return "\(parent).EDIT(\(fromPos),\(toPos),\(self.contents?.map { "\($0)" }.joined(separator: ",") ?? ""))"
    }
}
