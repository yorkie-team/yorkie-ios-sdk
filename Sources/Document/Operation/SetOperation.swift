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
 * `SetOperation` represents an operation that stores the value corresponding to the
 * given key in the Object.
 */
class SetOperation: Operation {
    let parentCreatedAt: TimeTicket
    var executedAt: TimeTicket
    private let key: String
    private let value: CRDTElement

    init(key: String, value: CRDTElement, parentCreatedAt: TimeTicket, executedAt: TimeTicket) {
        self.parentCreatedAt = parentCreatedAt
        self.executedAt = executedAt
        self.key = key
        self.value = value
    }

    /**
     * `execute` executes this operation on the given document(`root`).
     */
    func execute(root: CRDTRoot) throws {
        let parent = root.find(createdAt: self.getParentCreatedAt())
        guard let parent = parent as? CRDTObject else {
            let log: String
            if parent == nil {
                log = "failed to find \(self.getParentCreatedAt())"

            } else {
                log = "fail to execute, only object can execute set"
            }

            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        let value = self.value.deepcopy()
        parent.set(key: self.key, value: value)
        root.registerElement(value, parent: parent)
    }

    /**
     * `getEffectedCreatedAt` returns the time of the effected element.
     */
    func getEffectedCreatedAt() -> TimeTicket {
        return self.value.getCreatedAt()
    }

    /**
     * `getStructureAsString` returns a String containing the meta data.
     */
    func getStructureAsString() -> String {
        return "\(self.getParentCreatedAt().getStructureAsString()).SET"
    }

    /**
     * `getKey` returns the key of this operation.
     */
    func getKey() -> String {
        return self.key
    }

    /**
     * `getValue` returns the value of this operation.
     */
    func getValue() -> CRDTElement {
        return self.value
    }
}