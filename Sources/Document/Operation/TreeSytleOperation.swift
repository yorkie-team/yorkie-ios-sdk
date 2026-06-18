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

/**
 * `TreeStyleOperation` represents an operation that modifies the style of the
 * node in the Tree.
 */
class TreeStyleOperation: Operation {
    var parentCreatedAt: TimeTicket
    var executedAt: TimeTicket

    /**
     * `fromPos` returns the start point of the editing range.
     */
    let fromPos: CRDTTreePos
    /**
     * `toPos` returns the end point of the editing range.
     */
    let toPos: CRDTTreePos
    /**
     * `attributes` returns the content of Edit.
     */
    let attributes: [String: String]
    let attributesToRemove: [String]

    init(
        parentCreatedAt: TimeTicket,
        fromPos: CRDTTreePos,
        toPos: CRDTTreePos,
        attributes: [String: String],
        attributesToRemove: [String],
        executedAt: TimeTicket
    ) {
        self.parentCreatedAt = parentCreatedAt
        self.fromPos = fromPos
        self.toPos = toPos
        self.attributes = attributes
        self.attributesToRemove = attributesToRemove
        self.executedAt = executedAt
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

        guard let tree = parentObject as? CRDTTree else {
            throw YorkieError(code: .errInvalidArgument, message: "fail to execute, only Tree can execute edit")
        }

        let changes: [TreeChange]
        let pairs: [GCPair]
        var diff: DataSize
        // Attribute state captured from the first styled node, used to build the reverse op.
        var reversePrevAttributes = [String: String]()
        var reverseAttrsToRemove = [String]()

        if self.attributes.isEmpty == false {
            let prevAttributes: [String: String]
            let newAttrKeys: [String]
            (pairs, changes, diff, prevAttributes, newAttrKeys) = try tree.style(
                (self.fromPos, self.toPos),
                self.attributes,
                self.executedAt,
                versionVector
            )
            reversePrevAttributes = prevAttributes
            reverseAttrsToRemove = newAttrKeys
        } else {
            let prevAttributes: [String: String]
            (pairs, changes, diff, prevAttributes) = try tree.removeStyle(
                (self.fromPos, self.toPos),
                self.attributesToRemove,
                self.executedAt,
                versionVector
            )
            reversePrevAttributes = prevAttributes
        }

        root.acc(diff)

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        for pair in pairs {
            root.registerGCPair(pair)
        }

        // Build the reverse operation for undo.
        let reverseOp: Operation?
        if !reversePrevAttributes.isEmpty, !reverseAttrsToRemove.isEmpty {
            // Both existing attrs to restore and new attrs to remove — combined style op.
            reverseOp = TreeStyleOperation(
                parentCreatedAt: self.parentCreatedAt,
                fromPos: self.fromPos,
                toPos: self.toPos,
                attributes: reversePrevAttributes,
                attributesToRemove: reverseAttrsToRemove,
                executedAt: TimeTicket.initial
            )
        } else if !reverseAttrsToRemove.isEmpty {
            // Only new attrs to remove — reverse is a removeStyle.
            reverseOp = TreeStyleOperation(
                parentCreatedAt: self.parentCreatedAt,
                fromPos: self.fromPos,
                toPos: self.toPos,
                attributes: [:],
                attributesToRemove: reverseAttrsToRemove,
                executedAt: TimeTicket.initial
            )
        } else if !reversePrevAttributes.isEmpty {
            // Only existing attrs to restore — reverse is a style.
            reverseOp = TreeStyleOperation(
                parentCreatedAt: self.parentCreatedAt,
                fromPos: self.fromPos,
                toPos: self.toPos,
                attributes: reversePrevAttributes,
                attributesToRemove: [],
                executedAt: TimeTicket.initial
            )
        } else {
            reverseOp = nil
        }

        let opInfos: [any OperationInfo] = changes.compactMap { change in
            let values: TreeStyleOpValue? = {
                switch change.value {
                case .attributes(let attributes):
                    return .attributes(attributes.toJSONObejct)
                case .attributesToRemove(let keys):
                    return .attributesToRemove(keys)
                default:
                    return nil
                }
            }()

            return TreeStyleOpInfo(
                path: path,
                from: change.from,
                to: change.to,
                fromPath: change.fromPath,
                toPath: change.toPath,
                value: values
            )
        }

        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
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

        let attrString = self.attributes.compactMap { key, value in
            "\(key):\"\(value)\""
        }.joined(separator: " ")

        return "\(parent).STYLE(\(fromPos),\(toPos),\(attrString))"
    }
}
