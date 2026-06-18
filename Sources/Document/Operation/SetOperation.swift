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
        let removed = parent.set(key: self.key, value: value)
        // NOTE: when resetting an element with a pre-existing createdAt during undo/redo,
        // deregister the previously tombstoned element before re-registering.
        if source == .undoRedo, root.find(createdAt: value.createdAt) != nil {
            root.deregisterElement(value)
        }
        root.registerElement(value, parent: parent)
        if let removed {
            root.registerRemovedElement(removed)
        }
        // NOTE(#1226): When the new value already has a removedAt (e.g. it was the
        // LWW-losing side of a concurrent set), register it as removed so GC can
        // collect it once all peers have seen the winning value.
        if value.removedAt != nil {
            root.registerRemovedElement(value)
        }

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
