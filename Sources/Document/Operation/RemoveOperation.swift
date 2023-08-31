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
 * `RemoveOperation` is an operation representing removes an element from Container.
 */
struct RemoveOperation: Operation {
    let parentCreatedAt: TimeTicket
    var executedAt: TimeTicket
    /// The creation time of the target element.
    let createdAt: TimeTicket

    init(parentCreatedAt: TimeTicket, createdAt: TimeTicket, executedAt: TimeTicket) {
        self.parentCreatedAt = parentCreatedAt
        self.createdAt = createdAt
        self.executedAt = executedAt
    }

    /**
     * `execute` executes this operation on the given document(`root`).
     */
    @discardableResult
    func execute(root: CRDTRoot) throws -> [any OperationInfo] {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let object = parent as? CRDTContainer else {
            let log: String
            if let parent {
                log = "only object and array can execute remove: \(parent)"
            } else {
                log = "fail to find \(self.parentCreatedAt)"
            }

            Logger.critical(log)
            throw YorkieError.unexpected(message: log)
        }

        let element = try object.delete(createdAt: self.createdAt, executedAt: self.executedAt)
        root.registerRemovedElement(element)

        guard let path = try? root.createPath(createdAt: parentCreatedAt) else {
            throw YorkieError.unexpected(message: "fail to get path")
        }

        let key = try? object.subPath(createdAt: self.createdAt)

        return [parent is CRDTArray ? RemoveOpInfo(path: path, key: nil, index: Int(key ?? "")) : RemoveOpInfo(path: path, key: key, index: nil)]
    }

    /**
     * `effectedCreatedAt` returns the creation time of the effected element.
     */
    var effectedCreatedAt: TimeTicket {
        return self.parentCreatedAt
    }

    /**
     * `toTestString` returns a string containing the meta data.
     */
    var toTestString: String {
        return "\(self.parentCreatedAt.toTestString).REMOVE"
    }
}
