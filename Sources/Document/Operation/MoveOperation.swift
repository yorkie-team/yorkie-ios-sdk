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
 * `MoveOperation` is an operation representing moving an element to an Array.
 */
struct MoveOperation: Operation {
    let parentCreatedAt: TimeTicket
    var executedAt: TimeTicket
    /// The creation time of previous element.
    private(set) var previousCreatedAt: TimeTicket
    private(set) var createdAt: TimeTicket

    /**
     * `setCreatedAt` sets the creation time of the target element.
     */
    mutating func setCreatedAt(_ createdAt: TimeTicket) {
        self.createdAt = createdAt
    }

    /**
     * `setPrevCreatedAt` sets the creation time of the previous element.
     */
    mutating func setPrevCreatedAt(_ createdAt: TimeTicket) {
        self.previousCreatedAt = createdAt
    }

    init(parentCreatedAt: TimeTicket, previousCreatedAt: TimeTicket, createdAt: TimeTicket, executedAt: TimeTicket) {
        self.parentCreatedAt = parentCreatedAt
        self.executedAt = executedAt
        self.previousCreatedAt = previousCreatedAt
        self.createdAt = createdAt
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
        // Compute the reverse before mutating, capturing the current previous element.
        let reverseOp = self.toReverseOperation(root)
        let opInfos = try self.executeOpInfos(root: root, versionVector: versionVector)
        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
    }

    /// Returns the reverse operation (moving the element back to its previous position) for undo/redo.
    private func toReverseOperation(_ root: CRDTRoot) -> Operation? {
        guard let array = root.find(createdAt: self.parentCreatedAt) as? CRDTArray,
              let prevCreatedAt = try? array.getPreviousCreatedAt(createdAt: self.createdAt)
        else {
            return nil
        }
        // executedAt is reassigned just before execution when Document.undo() is called.
        return MoveOperation(parentCreatedAt: self.parentCreatedAt,
                             previousCreatedAt: prevCreatedAt,
                             createdAt: self.createdAt,
                             executedAt: TimeTicket.initial)
    }

    private func executeOpInfos(
        root: CRDTRoot,
        versionVector: VersionVector? = nil
    ) throws -> [any OperationInfo] {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let array = parent as? CRDTArray else {
            let log: String
            if parent == nil {
                log = "fail to find \(self.parentCreatedAt)"
            } else {
                log = "fail to execute, only array can execute move"
            }
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        guard let previousIndex = try Int(array.subPath(createdAt: self.createdAt)) else {
            throw YorkieError(code: .errUnexpected, message: "fail to get previousIndex")
        }

        try array.move(createdAt: self.createdAt, afterCreatedAt: self.previousCreatedAt, executedAt: self.executedAt)

        guard let index = try Int(array.subPath(createdAt: self.createdAt)) else {
            throw YorkieError(code: .errUnexpected, message: "fail to get index")
        }

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        return [MoveOpInfo(path: path, previousIndex: previousIndex, index: index)]
    }

    /**
     * `effectedCreatedAt` returns the creation time of the effected element.
     */
    var effectedCreatedAt: TimeTicket {
        return self.createdAt
    }

    /**
     * `toTestString` returns a string containing the meta data.
     */
    var toTestString: String {
        return "\(self.parentCreatedAt.toTestString).MOVE"
    }
}
