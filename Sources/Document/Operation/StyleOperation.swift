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

struct StyleOperation: Operation {
    var parentCreatedAt: TimeTicket
    var executedAt: TimeTicket

    /**
     * `fromPos` returns the start point of the editing range.
     */
    private(set) var fromPos: RGATreeSplitPos
    /**
     * `toPos` returns the end point of the editing range.
     */
    private(set) var toPos: RGATreeSplitPos

    /**
     * `attributes` returns the attributes of this Edit.
     */
    private(set) var attributes: [String: String]

    /**
     * `attributesToRemove` returns the style attributes to remove.
     */
    private(set) var attributesToRemove: [String]

    init(
        parentCreatedAt: TimeTicket,
        fromPos: RGATreeSplitPos,
        toPos: RGATreeSplitPos,
        attributes: [String: String],
        attributesToRemove: [String] = [],
        executedAt: TimeTicket = .initial
    ) {
        self.parentCreatedAt = parentCreatedAt
        self.fromPos = fromPos
        self.toPos = toPos
        self.attributes = attributes
        self.attributesToRemove = attributesToRemove
        self.executedAt = executedAt
    }

    /**
     * `create` creates a new instance of StyleOperation for setting style attributes.
     */
    static func create(
        parentCreatedAt: TimeTicket,
        fromPos: RGATreeSplitPos,
        toPos: RGATreeSplitPos,
        attributes: [String: String],
        executedAt: TimeTicket = .initial
    ) -> StyleOperation {
        StyleOperation(
            parentCreatedAt: parentCreatedAt,
            fromPos: fromPos,
            toPos: toPos,
            attributes: attributes,
            attributesToRemove: [],
            executedAt: executedAt
        )
    }

    /**
     * `createRemoveStyleOperation` creates a new instance of StyleOperation for style removal.
     */
    static func createRemoveStyleOperation(
        parentCreatedAt: TimeTicket,
        fromPos: RGATreeSplitPos,
        toPos: RGATreeSplitPos,
        attributesToRemove: [String],
        executedAt: TimeTicket = .initial
    ) -> StyleOperation {
        StyleOperation(
            parentCreatedAt: parentCreatedAt,
            fromPos: fromPos,
            toPos: toPos,
            attributes: [:],
            attributesToRemove: attributesToRemove,
            executedAt: executedAt
        )
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
        let (opInfos, reverseOp) = try self.executeOpInfos(root: root, versionVector: versionVector)
        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
    }

    private func executeOpInfos(
        root: CRDTRoot,
        versionVector: VersionVector? = nil
    ) throws -> ([any OperationInfo], Operation?) {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let text = parent as? CRDTText else {
            let log: String
            if let parent {
                log = "fail to execute, only Text can execute style: \(parent)"
            } else {
                log = "fail to find \(self.parentCreatedAt)"
            }
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        var allPairs = [GCPair]()
        var allChanges = [TextChange]()
        var allDiff = DataSize(data: 0, meta: 0)
        var reversePrevAttributes = [String: String]()
        var reverseAttrsToRemove = [String]()

        // 01. Handle attributesToRemove (remove style attributes).
        if self.attributesToRemove.isEmpty == false {
            let (pairs, diff, changes, prevAttributes) = try text.removeStyle(
                (self.fromPos, self.toPos),
                self.attributesToRemove,
                self.executedAt,
                versionVector
            )
            allDiff.addDataSizes(others: diff)
            allPairs.append(contentsOf: pairs)
            allChanges.append(contentsOf: changes)
            for (key, value) in prevAttributes {
                reversePrevAttributes[key] = value
            }
        }

        // 02. Handle attributes (set style attributes).
        if self.attributes.isEmpty == false {
            let (pairs, diff, changes, prevAttributes, attrsToRemove) = try text.setStyle(
                (self.fromPos, self.toPos),
                self.attributes,
                self.executedAt,
                versionVector
            )
            allDiff.addDataSizes(others: diff)
            allPairs.append(contentsOf: pairs)
            allChanges.append(contentsOf: changes)
            for (key, value) in prevAttributes {
                reversePrevAttributes[key] = value
            }
            reverseAttrsToRemove.append(contentsOf: attrsToRemove)
        }

        root.acc(allDiff)

        for pair in allPairs {
            root.registerGCPair(pair)
        }

        // Build the reverse operation for undo/redo.
        var reverseOp: Operation?
        if reversePrevAttributes.isEmpty == false || reverseAttrsToRemove.isEmpty == false {
            if reversePrevAttributes.isEmpty == false, reverseAttrsToRemove.isEmpty == false {
                reverseOp = StyleOperation(
                    parentCreatedAt: self.parentCreatedAt,
                    fromPos: self.fromPos,
                    toPos: self.toPos,
                    attributes: reversePrevAttributes,
                    attributesToRemove: reverseAttrsToRemove
                )
            } else if reverseAttrsToRemove.isEmpty == false {
                reverseOp = StyleOperation.createRemoveStyleOperation(
                    parentCreatedAt: self.parentCreatedAt,
                    fromPos: self.fromPos,
                    toPos: self.toPos,
                    attributesToRemove: reverseAttrsToRemove
                )
            } else {
                reverseOp = StyleOperation.create(
                    parentCreatedAt: self.parentCreatedAt,
                    fromPos: self.fromPos,
                    toPos: self.toPos,
                    attributes: reversePrevAttributes
                )
            }
        }

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        let opInfos: [any OperationInfo] = allChanges.compactMap {
            StyleOpInfo(path: path, from: $0.from, to: $0.to, attributes: $0.attributes?.createdDictionary)
        }

        return (opInfos, reverseOp)
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
        return "\(parent).STYLE(\(fromPos),\(toPos)"
    }
}
