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
 * `AddOperation` is an operation representing adding an element to an Array.
 */
struct AddOperation: Operation {
    let parentCreatedAt: TimeTicket
    var executedAt: TimeTicket
    let previousCreatedAt: TimeTicket
    let value: CRDTElement

    init(parentCreatedAt: TimeTicket, previousCreatedAt: TimeTicket, value: CRDTElement, executedAt: TimeTicket) {
        self.parentCreatedAt = parentCreatedAt
        self.executedAt = executedAt
        self.previousCreatedAt = previousCreatedAt
        self.value = value
    }

    /**
     * `execute` executes this operation on the given document(`root`).
     */
    func execute(root: CRDTRoot) throws {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let array = parent as? CRDTArray else {
            let log: String
            if parent == nil {
                log = "fail to find \(self.parentCreatedAt)"
            } else {
                log = "fail to execute, only array can execute add"
            }
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        let value = self.value.deepcopy()
        try array.insert(value: value, afterCreatedAt: self.previousCreatedAt)
        root.registerElement(value, parent: array)
    }

    /**
     * `effectedCreatedAt` returns the time of the effected element.
     */
    var effectedCreatedAt: TimeTicket {
        return self.value.createdAt
    }

    /**
     * `structureAsString` returns a string containing the meta data.
     */
    var structureAsString: String {
        return "\(self.parentCreatedAt.structureAsString).ADD"
    }
}
