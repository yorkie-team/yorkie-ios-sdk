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

/// `clearRemovedAt` clears the `removedAt` tombstone markers from a node and all its descendants,
/// so they can be re-inserted as live nodes on undo.
///
/// iOS tracks a single visible `size` per node (unlike the JS SDK's separate `visibleSize` /
/// `totalSize`), so removal only decreases an element's `size`. The traversal is postorder, so by
/// the time an element node is visited its descendants are already live again — recomputing the
/// element's `size` from its (now all-live) `children` restores the full visible size. Text nodes
/// keep their `size`, which removal never decreased.
private func clearRemovedAt(_ node: CRDTTreeNode) {
    traverseAll(node: node) { node, _ in
        node.removedAt = nil
        if node.isText == false {
            node.size = node.children.reduce(0) { $0 + $1.paddedSize }
        }
    }
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

    init(parentCreatedAt: TimeTicket,
         fromPos: CRDTTreePos,
         toPos: CRDTTreePos,
         contents: [CRDTTreeNode]?,
         splitLevel: Int32,
         executedAt: TimeTicket,
         isUndoOp: Bool = false,
         fromIdx: Int? = nil,
         toIdx: Int? = nil)
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

        var editedAt = self.executedAt
        guard let tree = parentObject as? CRDTTree else {
            throw YorkieError(code: .errInvalidArgument, message: "fail to execute, only Tree can execute edit")
        }

        // For undo ops the stored integer indices may have been reconciled against remote edits;
        // convert them back to positions on the current tree before editing.
        if self.isUndoOp, let fromIdx = self.fromIdx, let toIdx = self.toIdx {
            self.fromPos = try tree.findPos(fromIdx)
            self.toPos = try fromIdx == toIdx ? self.fromPos : (tree.findPos(toIdx))
        }

        /**
         * TODO(sejongk): When splitting element nodes, a new nodeID is assigned with a different timeTicket.
         * In the same change context, the timeTickets share the same lamport and actorID but have different delimiters,
         * incremented by one for each.
         * Therefore, it is possible to simulate later timeTickets using `editedAt` and the length of `contents`.
         * This logic might be unclear; consider refactoring for multi-level concurrent editing in the Tree implementation.
         */
        let (changes, pairs, diff, removedNodes, preEditFromIdx) = try tree.edit((self.fromPos, self.toPos), self.contents?.compactMap { $0.deepcopy() }, self.splitLevel, editedAt, {
            var delimiter = editedAt.delimiter
            if let contents {
                delimiter += UInt32(contents.count)
            }

            delimiter += 1
            editedAt = TimeTicket(lamport: editedAt.lamport, delimiter: delimiter, actorID: editedAt.actorID)

            return editedAt
        }, versionVector)

        // Capture the pre-edit range so a remote/local edit can reconcile parked undo ops. `toIdx`
        // is `fromIdx` plus the total visible tokens of the nodes this edit removed.
        self.lastFromIdx = preEditFromIdx
        let removedSize = removedNodes.reduce(0) { $0 + $1.paddedSize }
        self.lastToIdx = preEditFromIdx + removedSize

        // Build the reverse op for undo. Phase 1 skips split edits (splitLevel > 0).
        let reverseOp = self.splitLevel == 0
            ? try self.toReverseOperation(tree, removedNodes, preEditFromIdx)
            : nil

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

    /// `toReverseOperation` creates the reverse operation for undo.
    ///
    /// The reverse op stores both ``CRDTTreePos`` (for initial use) and integer indices (for
    /// reconciliation when remote edits arrive). At undo time the integer indices take precedence
    /// and are converted to positions via `tree.findPos`.
    ///
    /// - Parameters:
    ///   - tree: The tree after this edit has been applied.
    ///   - removedNodes: The nodes removed by this edit, to be re-inserted on undo.
    ///   - preEditFromIdx: The start index captured before the edit deletions.
    /// - Returns: The reverse ``TreeEditOperation``, or `nil` when the edit was a no-op.
    private func toReverseOperation(_ tree: CRDTTree, _ removedNodes: [CRDTTreeNode], _ preEditFromIdx: Int) throws -> Operation? {
        // Total tree-index tokens inserted by this edit.
        let insertedContentSize = self.contents?.reduce(0) { $0 + $1.paddedSize } ?? 0

        // Guard: if the positions exceed the post-edit tree size, the edit was a no-op (e.g. a
        // concurrent parent deletion tombstoned the inserted content). Skip the reverse op.
        let maxNeededIdx = preEditFromIdx + insertedContentSize
        if maxNeededIdx > tree.size {
            return nil
        }

        // Keep only top-level removed nodes (whose parent is not also removed).
        let topLevelRemoved = removedNodes.filter { node in
            guard let parent = node.parent else {
                return true
            }
            return removedNodes.contains { $0 === parent } == false
        }

        // Deep copy for re-insertion on undo, clearing tombstone markers.
        let reverseContents: [CRDTTreeNode]? = topLevelRemoved.isEmpty
            ? nil
            : topLevelRemoved.compactMap { node in
                guard let clone = node.deepcopy() else {
                    return nil
                }
                clearRemovedAt(clone)
                return clone
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

    /// `getContentSize` returns the total visible size of this operation's content.
    func getContentSize() -> Int {
        self.contents?.reduce(0) { $0 + $1.paddedSize } ?? 0
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
