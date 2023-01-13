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

struct SelectOperation: Operation {
    internal var parentCreatedAt: TimeTicket
    internal var executedAt: TimeTicket

    /**
     * `fromPos` returns the start point of the editing range.
     */
    private(set) var fromPos: RGATreeSplitNodePos
    /**
     * `toPos` returns the end point of the editing range.
     */
    private(set) var toPos: RGATreeSplitNodePos

    init(parentCreatedAt: TimeTicket, fromPos: RGATreeSplitNodePos, toPos: RGATreeSplitNodePos, executedAt: TimeTicket) {
        self.parentCreatedAt = parentCreatedAt
        self.fromPos = fromPos
        self.toPos = toPos
        self.executedAt = executedAt
    }

    /**
     * `execute` executes this operation on the given document(`root`).
     */
    func execute(root: CRDTRoot) throws {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let text = parent as? CRDTText else {
            let log: String
            if let parent {
                log = "fail to execute, only Text can execute select: \(parent)"
            } else {
                log = "fail to find \(self.parentCreatedAt)"
            }

            Logger.critical(log)
            throw YorkieError.unexpected(message: log)
        }

        try text.select((self.fromPos, self.toPos), self.executedAt)
    }

    /**
     * `effectedCreatedAt` returns the creation time of the effected element.
     */
    internal var effectedCreatedAt: TimeTicket {
        self.parentCreatedAt
    }

    /**
     * `getStructureAsString` returns a string containing the meta data.
     */
    internal var structureAsString: String {
        let parent = self.parentCreatedAt.structureAsString
        let fromPos = self.fromPos.structureAsString
        let toPos = self.toPos.structureAsString
        return "\(parent).SELECT(\(fromPos),\(toPos)"
    }
}
