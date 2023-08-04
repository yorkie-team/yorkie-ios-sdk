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

    init(parentCreatedAt: TimeTicket, fromPos: CRDTTreePos, toPos: CRDTTreePos, attributes: [String: String], executedAt: TimeTicket) {
        self.parentCreatedAt = parentCreatedAt
        self.fromPos = fromPos
        self.toPos = toPos
        self.attributes = attributes
        self.executedAt = executedAt
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

        let changes = try tree.style((self.fromPos, self.toPos), self.attributes, self.executedAt)

        guard let path = try? root.createPath(createdAt: parentCreatedAt) else {
            throw YorkieError.unexpected(message: "fail to get path")
        }

        return changes.compactMap { change in
            guard case .attributes(let attributes) = change.value else {
                return nil
            }

            return TreeStyleOpInfo(
                path: path,
                from: change.from,
                to: change.to,
                fromPath: change.fromPath,
                value: attributes.anyValueTypeDictionary
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
        let fromPos = "\(self.fromPos.createdAt.toTestString):\(self.fromPos.offset)"
        let toPos = "\(self.toPos.createdAt.toTestString):\(self.toPos.offset)"

        let attrString = self.attributes.compactMap { key, value in
            "\(key):\"\(value)\""
        }.joined(separator: " ")

        return "\(parent).STYLE(\(fromPos),\(toPos),\(attrString))"
    }
}
