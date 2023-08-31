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
 * `TreeEditOperation` is an operation representing Tree editing.
 */
struct TreeEditOperation: Operation {
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
     * `content` returns the content of Edit.
     */
    let contents: [CRDTTreeNode]?
    let maxCreatedAtMapByActor: [String: TimeTicket]

    init(parentCreatedAt: TimeTicket, fromPos: CRDTTreePos, toPos: CRDTTreePos, contents: [CRDTTreeNode]?, executedAt: TimeTicket, maxCreatedAtMapByActor: [String: TimeTicket]) {
        self.parentCreatedAt = parentCreatedAt
        self.fromPos = fromPos
        self.toPos = toPos
        self.contents = contents
        self.executedAt = executedAt
        self.maxCreatedAtMapByActor = maxCreatedAtMapByActor
    }

    /**
     * `execute` executes this operation on the given `CRDTRoot`.
     */
    @discardableResult
    public func execute(root: CRDTRoot) throws -> [any OperationInfo] {
        guard let parentObject = root.find(createdAt: self.parentCreatedAt) else {
            let log = "fail to find \(self.parentCreatedAt)"
            Logger.critical(log)
            throw YorkieError.unexpected(message: log)
        }

        guard let tree = parentObject as? CRDTTree else {
            fatalError("fail to execute, only Tree can execute edit")
        }

        let (changes, _) = try tree.edit((self.fromPos, self.toPos), self.contents?.compactMap { $0.deepcopy() }, self.executedAt, self.maxCreatedAtMapByActor)

        if self.fromPos != self.toPos {
            root.registerElementHasRemovedNodes(tree)
        }

        guard let path = try? root.createPath(createdAt: parentCreatedAt) else {
            throw YorkieError.unexpected(message: "fail to get path")
        }

        return changes.compactMap { change in
            guard case .nodes(let nodes) = change.value else {
                return nil
            }

            return TreeEditOpInfo(
                path: path,
                from: change.from,
                to: change.to,
                fromPath: change.fromPath,
                toPath: change.toPath,
                value: nodes
            )
        }
    }

    /**
     * `effectedCreatedAt` returns the creation time of the effected element.
     */
    public var effectedCreatedAt: TimeTicket {
        self.parentCreatedAt
    }

    /**
     * `toTestString` returns a string containing the meta data.
     */
    public var toTestString: String {
        let parent = self.parentCreatedAt.toTestString
        let fromPos = "\(self.fromPos.leftSiblingID):\(self.fromPos.leftSiblingID.offset)"
        let toPos = "\(self.toPos.leftSiblingID):\(self.toPos.leftSiblingID.offset)"

        return "\(parent).EDIT(\(fromPos),\(toPos),\(self.contents?.map { "\($0)" }.joined(separator: ",") ?? ""))"
    }
}
