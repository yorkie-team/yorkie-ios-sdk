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

struct EditOperation: Operation {
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
     * `content` returns the content of RichEdit.
     */
    private(set) var content: String

    /**
     * `attributes` returns the attributes of this Edit.
     */
    private(set) var attributes: [String: String]?

    init(
        parentCreatedAt: TimeTicket,
        fromPos: RGATreeSplitPos,
        toPos: RGATreeSplitPos,
        content: String,
        attributes: [String: String]?,
        executedAt: TimeTicket
    ) {
        self.parentCreatedAt = parentCreatedAt
        self.fromPos = fromPos
        self.toPos = toPos
        self.content = content
        self.attributes = attributes
        self.executedAt = executedAt
    }

    /**
     * `execute` executes this operation on the given document(`root`).
     */
    @discardableResult
    func execute(
        root: CRDTRoot,
        versionVector: VersionVector?
    ) throws -> [any OperationInfo] {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let text = parent as? CRDTText else {
            let log: String
            if let parent {
                log = "fail to execute, only Text can execute edit: \(parent)"
            } else {
                log = "fail to find \(self.parentCreatedAt)"
            }
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        let (changes, pairs, _) = try text.edit(
            (self.fromPos, self.toPos),
            self.content,
            self.executedAt,
            self.attributes,
            versionVector
        )

        for pair in pairs {
            root.registerGCPair(pair)
        }

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        return changes.compactMap {
            EditOpInfo(path: path, from: $0.from, to: $0.to, attributes: $0.attributes?.createdDictionary, content: $0.content)
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
        let fromPos = self.fromPos.toTestString
        let toPos = self.toPos.toTestString
        let content = self.content
        return "\(parent).EDIT(\(fromPos),\(toPos),\(content)"
    }
}
