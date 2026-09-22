/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

/**
 * `SetOperation` represents an operation that stores the value corresponding to the
 * given key in the Object.
 */
struct SetOperation: Operation {
    let parentCreatedAt: TimeTicket
    var executedAt: TimeTicket
    /// The key of this operation.
    let key: String
    /// The value of this operation.
    let value: CRDTElement

    init(key: String, value: CRDTElement, parentCreatedAt: TimeTicket, executedAt: TimeTicket) {
        self.parentCreatedAt = parentCreatedAt
        self.executedAt = executedAt
        self.key = key
        self.value = value
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
        // NOTE: handle cases where the operation cannot be executed during undo/redo
        // (e.g. the parent object or one of its ancestors was already removed).
        if source == .undoRedo, self.isAncestorRemoved(root) {
            return nil
        }
        let previousValue = (root.find(createdAt: self.parentCreatedAt) as? CRDTObject)?.get(key: self.key)
        let reverseOp = self.toReverseOperation(previousValue)
        let opInfos = try self.executeOpInfos(root: root, versionVector: versionVector, source: source)
        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
    }

    /// Returns whether the parent object or any of its ancestors was already removed.
    private func isAncestorRemoved(_ root: CRDTRoot) -> Bool {
        var currentCreatedAt: TimeTicket? = self.parentCreatedAt
        while let createdAt = currentCreatedAt, let pair = root.findElementPairByCreatedAt(createdAt) {
            if pair.element.isRemoved {
                return true
            }
            currentCreatedAt = pair.parent?.createdAt
        }
        return false
    }

    /// Returns the reverse operation (restoring the previous value, or removing it) for undo/redo.
    private func toReverseOperation(_ previousValue: CRDTElement?) -> Operation {
        if let previousValue, !previousValue.isRemoved {
            return SetOperation(key: self.key, value: previousValue.deepcopy(),
                                parentCreatedAt: self.parentCreatedAt, executedAt: TimeTicket.initial)
        }
        // executedAt is reassigned just before execution when Document.undo() is called.
        return RemoveOperation(parentCreatedAt: self.parentCreatedAt,
                               createdAt: self.value.createdAt, executedAt: TimeTicket.initial)
    }

    private func executeOpInfos(
        root: CRDTRoot,
        versionVector: VersionVector? = nil,
        source: OpSource = .local
    ) throws -> [any OperationInfo] {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let parent = parent as? CRDTObject else {
            let log: String
            if parent == nil {
                log = "failed to find \(self.parentCreatedAt)"
            } else {
                log = "fail to execute, only object can execute set"
            }
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        let value = self.value.deepcopy()
        let removed = parent.set(key: self.key, value: value, executedAt: self.executedAt)
        // NOTE(hackerwins): A set can restore an element under a createdAt that a
        // tombstone already answers to -- undoing a remove re-inserts the removed
        // element under its original identity, and `parent.set` above has just
        // handed that identity to the restored copy in the object's
        // `nodeMapByCreatedAt`.
        //
        // The entry that has to follow is the one in `gcElementSetByCreatedAt`.
        // Collection resolves it through the index that was just re-pointed, so
        // leaving it makes the next pass reach live data.
        //
        // Retiring that entry is the whole job, so retire only that entry. The
        // tombstone's other registrations are deliberately left alone: its
        // descendant set can be a strict superset of the restored copy's, since a
        // peer may have added a child into the container after the undoing replica
        // took its copy, and tearing the subtree out of `elementPairMapByCreatedAt`
        // would take those extra descendants with it, with nothing to put them back
        // -- so a later change addressed at one of them throws inside
        // `applyChangePack`. See ``CRDTRoot/unregisterRemovedElementPair(_:)``.
        //
        // This is a condition on the state of the tree, not on who is applying:
        // peers apply the undo with `OpSource.remote`, and the Go server replays it
        // to build a snapshot, and every one of them has the same stale entry.
        // Gating it on `.undoRedo` spared only the replica that performed the undo;
        // the Go SDK gates the same call and loses the member outright there, which
        // is the data loss yorkie#1978 fixes alongside this.
        //
        // An ordinary set carries a freshly issued createdAt, so the lookup
        // normally misses and costs one map read.
        root.unregisterRemovedElementPair(value.createdAt)
        // `registerElement` adopts every tombstone in the subtree it books, so the
        // members `RemoveOperation.toReverseOperation` captured as already-removed
        // inside `value.deepcopy()` are charged to gc and made collectable without
        // a walk here.
        root.registerElement(value, parent: parent)
        if let removed {
            root.registerRemovedElement(removed)
        }
        // NOTE(hackerwins): A value that lost the set is marked removed by
        // `parent.set` above, before it was registered. `registerElement` is what
        // books it into gc, and registering it as removed a second time here would
        // refund a ticket live is holding on the one path where `registerElement`
        // leaves it in live.

        guard let path = try? root.createPath(createdAt: parentCreatedAt) else {
            throw YorkieError(code: .errUnexpected, message: "fail to get path")
        }

        return [SetOpInfo(path: path, key: self.key)]
    }

    /**
     * `effectedCreatedAt` returns the creation time of the effected element.
     */
    var effectedCreatedAt: TimeTicket {
        return self.value.createdAt
    }

    /**
     * `toTestString` returns a String containing the meta data.
     */
    var toTestString: String {
        return "\(self.parentCreatedAt.toTestString).SET"
    }
}
