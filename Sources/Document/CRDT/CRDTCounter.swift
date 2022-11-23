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
 * `CRDTCounter` represents changeable number data type.
 */
class CRDTCounter<T: YorkieCountable>: CRDTElement {
    let createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    private(set) var value: T

    init(value: T, createdAt: TimeTicket) {
        self.createdAt = createdAt
        self.value = value
    }

    func toJSON() -> String {
        "\(self.value)"
    }

    func toSortedJSON() -> String {
        self.toJSON()
    }

    func deepcopy() -> CRDTElement {
        let counter = CRDTCounter(value: self.value, createdAt: self.createdAt)
        counter.movedAt = self.movedAt

        return counter
    }

    /**
     * `toBytes` creates an array representing the value.
     */
    public func toBytes() -> Data {
        return withUnsafeBytes(of: self.value.littleEndian) { Data($0) }
    }

    /**
     * `increase` increases numeric data.
     */
    @discardableResult
    public func increase(_ primitive: Primitive) throws -> CRDTCounter {
        switch primitive.value {
        case .integer(let int32Value):
            guard let value = int32Value as? T else {
                throw YorkieError.type(message: "Value Type mismatch: \(type(of: primitive)), \(T.self)")
            }

            self.value = self.value.addingReportingOverflow(value).partialValue
        case .long(let int64Value):
            guard let value = int64Value as? T else {
                throw YorkieError.type(message: "Value Type mismatch: \(type(of: primitive.value))")
            }

            self.value = self.value.addingReportingOverflow(value).partialValue
        default:
            throw YorkieError.type(message: "Unsupported type of value: \(type(of: primitive.value))")
        }

        return self
    }
}
