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
 * `IncreaseOperation` represents an operation that increments a numeric value to Counter.
 * Among Primitives, numeric types Integer, Long, and Double are used as values.
 */
struct IncreaseOperation: Operation {
    var parentCreatedAt: TimeTicket
    var executedAt: TimeTicket

    let value: CRDTElement

    init(parentCreatedAt: TimeTicket, value: CRDTElement, executedAt: TimeTicket) {
        self.parentCreatedAt = parentCreatedAt
        self.executedAt = executedAt
        self.value = value
    }

    var effectedCreatedAt: TimeTicket {
        self.parentCreatedAt
    }

    var toTestString: String {
        "\(self.parentCreatedAt.toTestString).INCREASE"
    }

    /**
     * `execute` executes this operation on the given document(`root`).
     */
    @discardableResult
    func execute(
        root: CRDTRoot,
        versionVector: VersionVector?
    ) throws -> [any OperationInfo] {
        guard let parentObject = root.find(createdAt: self.parentCreatedAt) else {
            let log = "fail to find \(self.parentCreatedAt)"
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        if let counter = parentObject as? CRDTCounter<Int32> {
            if let value = self.value.deepcopy() as? Primitive {
                try counter.increase(value)
            }
        } else if let counter = parentObject as? CRDTCounter<Int64> {
            if let value = self.value.deepcopy() as? Primitive {
                try counter.increase(value)
            }
        } else {
            let log = "fail to execute, only Counter can execute increase"
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        guard let value = Int((value as? Primitive)?.toJSON() ?? "") else {
            throw YorkieError(code: .errUnexpected, message: "fail to get counter value")
        }

        return [IncreaseOpInfo(path: path, value: value)]
    }
}
