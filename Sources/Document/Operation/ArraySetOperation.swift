/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

/**
 * `ArraySetOperation` is an operation representing setting an element in Array.
 */
class ArraySetOperation: Operation {
    var effectedCreatedAt: TimeTicket { self.createdAt }

    var toTestString: String { return "\(self.parentCreatedAt.toTestString).ARRAY_SET" }

    var parentCreatedAt: TimeTicket

    var executedAt: TimeTicket
    private(set) var createdAt: TimeTicket
    private let value: CRDTElement

    /**
     * `setCreatedAt` sets the creation time of the target element.
     */
    func setCreatedAt(_ createdAt: TimeTicket) {
        self.createdAt = createdAt
    }

    init(
        parentCreatedAt: TimeTicket,
        createdAt: TimeTicket,
        value: CRDTElement,
        executedAt: TimeTicket
    ) {
        self.createdAt = createdAt
        self.value = value
        self.parentCreatedAt = parentCreatedAt
        self.executedAt = executedAt
    }

    /**
     * `create` creates a new instance of ArraySetOperation.
     */
    static func create(
        parentCreatedAt: TimeTicket,
        createdAt: TimeTicket,
        value: CRDTElement,
        executedAt: TimeTicket
    ) -> ArraySetOperation {
        return ArraySetOperation(
            parentCreatedAt: parentCreatedAt,
            createdAt: createdAt,
            value: value,
            executedAt: executedAt
        )
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
        // Compute the reverse before mutating, capturing the current element value.
        let reverseOp = self.toReverseOperation(root)
        let opInfos = try self.executeOpInfos(root: root, versionVector: versionVector)
        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
    }

    /// Returns the reverse operation (restoring the previous element value) for undo/redo.
    private func toReverseOperation(_ root: CRDTRoot) -> Operation? {
        guard let array = root.find(createdAt: self.parentCreatedAt) as? CRDTArray,
              let previousValue = try? array.get(createdAt: self.createdAt)
        else {
            return nil
        }
        // executedAt is reassigned just before execution when Document.undo() is called.
        return ArraySetOperation(parentCreatedAt: self.parentCreatedAt,
                                 createdAt: self.value.createdAt,
                                 value: previousValue.deepcopy(),
                                 executedAt: TimeTicket.initial)
    }

    private func executeOpInfos(
        root: CRDTRoot,
        versionVector: VersionVector? = nil
    ) throws -> [any OperationInfo] {
        guard let parentObject = root.find(createdAt: parentCreatedAt) else {
            throw YorkieError(
                code: .errInvalidArgument,
                message: "fail to find \(self.parentCreatedAt)"
            )
        }

        guard let arrayParent = parentObject as? CRDTArray else {
            throw YorkieError(
                code: .errInvalidArgument,
                message: "fail to execute, only array can execute set"
            )
        }

        let value = self.value.deepcopy()

        try arrayParent.insert(
            value: value,
            prevCreatedAt: self.createdAt,
            executedAt: self.executedAt
        )
        try arrayParent.delete(createdAt: self.createdAt, executedAt: self.executedAt)

        // TODO(junseo): GC logic is not implemented here
        // because there is no way to distinguish between old and new element with same `createdAt`.
        root.registerElement(value, parent: nil)

        // TODO(emplam27): The reverse operation is not implemented yet.
        // let reverseOp: Operation? = nil
        guard let path = try? root.createPath(createdAt: parentCreatedAt) else {
            throw YorkieError(code: .errUnexpected, message: "fail to get index")
        }

        return [
            ArraySetOpInfo(
                path: path
            )
        ]
    }

    /**
     * `getCreatedAt` returns the creation time of the target element.
     */
    func getCreatedAt() -> TimeTicket {
        return self.createdAt
    }

    /**
     * `getValue` returns the value of this operation.
     */
    func getValue() -> CRDTElement {
        return self.value
    }
}
