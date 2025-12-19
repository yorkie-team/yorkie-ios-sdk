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
    let splitLevel: Int32

    init(parentCreatedAt: TimeTicket,
         fromPos: CRDTTreePos,
         toPos: CRDTTreePos,
         contents: [CRDTTreeNode]?,
         splitLevel: Int32,
         executedAt: TimeTicket)
    {
        self.parentCreatedAt = parentCreatedAt
        self.fromPos = fromPos
        self.toPos = toPos
        self.contents = contents
        self.splitLevel = splitLevel
        self.executedAt = executedAt
    }

    /**
     * `execute` executes this operation on the given `CRDTRoot`.
     */
    @discardableResult
    func execute(
        root: CRDTRoot,
        versionVector: VersionVector?
    ) throws -> [any OperationInfo] {
        guard let parentObject = root.find(createdAt: self.parentCreatedAt) else {
            let log = "fail to find \(self.parentCreatedAt)"
            Logger.critical(log)
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        var editedAt = self.executedAt
        guard let tree = parentObject as? CRDTTree else {
            throw YorkieError(code: .errInvalidArgument, message: "fail to execute, only Tree can execute edit")
        }

        /**
         * TODO(sejongk): When splitting element nodes, a new nodeID is assigned with a different timeTicket.
         * In the same change context, the timeTickets share the same lamport and actorID but have different delimiters,
         * incremented by one for each.
         * Therefore, it is possible to simulate later timeTickets using `editedAt` and the length of `contents`.
         * This logic might be unclear; consider refactoring for multi-level concurrent editing in the Tree implementation.
         */
        let (changes, pairs, diff) = try tree.edit((self.fromPos, self.toPos), self.contents?.compactMap { $0.deepcopy() }, self.splitLevel, editedAt, {
            var delimiter = editedAt.delimiter
            if let contents {
                delimiter += UInt32(contents.count)
            }

            delimiter += 1
            editedAt = TimeTicket(lamport: editedAt.lamport, delimiter: delimiter, actorID: editedAt.actorID)

            return editedAt
        }, versionVector)
        root.acc(diff)

        for pair in pairs {
            root.registerGCPair(pair)
        }

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        return changes.compactMap { change in
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
