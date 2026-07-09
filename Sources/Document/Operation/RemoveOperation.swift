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
 * `RemoveOperation` is an operation representing removes an element from Container.
 */
struct RemoveOperation: Operation {
    let parentCreatedAt: TimeTicket
    var executedAt: TimeTicket
    /// The creation time of the target element.
    private(set) var createdAt: TimeTicket

    /**
     * `setCreatedAt` sets the creation time of the target element.
     */
    mutating func setCreatedAt(_ createdAt: TimeTicket) {
        self.createdAt = createdAt
    }

    init(parentCreatedAt: TimeTicket, createdAt: TimeTicket, executedAt: TimeTicket) {
        self.parentCreatedAt = parentCreatedAt
        self.createdAt = createdAt
        self.executedAt = executedAt
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
        // (e.g. the target element or one of its ancestors was already removed).
        if source == .undoRedo, self.isAncestorRemoved(root) {
            return nil
        }
        // Compute the reverse before deleting, capturing the current element/value.
        let reverseOp = self.toReverseOperation(root)
        let opInfos = try self.executeOpInfos(root: root, versionVector: versionVector)
        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
    }

    /// Returns whether the target element or any of its ancestors was already removed.
    private func isAncestorRemoved(_ root: CRDTRoot) -> Bool {
        var currentCreatedAt: TimeTicket? = self.createdAt
        while let createdAt = currentCreatedAt, let pair = root.findElementPairByCreatedAt(createdAt) {
            if pair.element.isRemoved {
                return true
            }
            currentCreatedAt = pair.parent?.createdAt
        }
        return false
    }

    /// Returns the reverse operation (restoring the removed element) for undo/redo.
    private func toReverseOperation(_ root: CRDTRoot) -> Operation? {
        let parent = root.find(createdAt: self.parentCreatedAt)
        if let array = parent as? CRDTArray {
            guard let value = try? array.get(createdAt: self.createdAt),
                  let prevCreatedAt = try? array.getPreviousCreatedAt(createdAt: self.createdAt)
            else {
                return nil
            }
            // executedAt is reassigned just before execution when Document.undo() is called.
            return AddOperation(parentCreatedAt: self.parentCreatedAt,
                                previousCreatedAt: prevCreatedAt,
                                value: value.deepcopy(),
                                executedAt: TimeTicket.initial)
        }
        if let object = parent as? CRDTObject {
            guard let key = try? object.subPath(createdAt: self.createdAt),
                  let value = object.get(key: key)
            else {
                return nil
            }
            return SetOperation(key: key, value: value.deepcopy(),
                                parentCreatedAt: self.parentCreatedAt,
                                executedAt: TimeTicket.initial)
        }
        return nil
    }

    private func executeOpInfos(
        root: CRDTRoot,
        versionVector: VersionVector? = nil
    ) throws -> [any OperationInfo] {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let object = parent as? CRDTContainer else {
            let log: String
            if let parent {
                log = "only object and array can execute remove: \(parent)"
            } else {
                log = "fail to find \(self.parentCreatedAt)"
            }
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        // Compute the sub-path (the index, for arrays) BEFORE deleting: once the
        // element is tombstoned, `subPath` -> `TreeList.indexOf` returns -1 for the
        // now-removed node. Mirrors yorkie-js-sdk `RemoveOperation.execute`, which
        // reads `subPathOf` before `container.delete`.
        let key = try object.subPath(createdAt: self.createdAt)
        let index = Int(key)

        let element = try object.delete(createdAt: self.createdAt, executedAt: self.executedAt)
        root.registerRemovedElement(element)

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        return [parent is CRDTArray ? RemoveOpInfo(path: path, key: nil, index: index) : RemoveOpInfo(path: path, key: key, index: nil)]
    }

    /**
     * `effectedCreatedAt` returns the creation time of the effected element.
     */
    var effectedCreatedAt: TimeTicket {
        return self.parentCreatedAt
    }

    /**
     * `toTestString` returns a string containing the meta data.
     */
    var toTestString: String {
        return "\(self.parentCreatedAt.toTestString).REMOVE"
    }
}
