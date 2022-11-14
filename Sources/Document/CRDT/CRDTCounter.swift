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

enum CounterValue: Equatable {
    case integer(Int32)
    case long(Int64)
    case double(Double)
}

/**
 * `CounterInternal` represents changeable number data type.
 *
 * @internal
 */
class CRDTCounter: CRDTElement {
    var createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    var value: CounterValue

    init(value: CounterValue, createdAt: TimeTicket) {
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
        switch self.value {
        case .integer(let int32Value):
            return withUnsafeBytes(of: int32Value.littleEndian) { Data($0) }
        case .long(let int64Value):
            return withUnsafeBytes(of: int64Value.littleEndian) { Data($0) }
        case .double(let doubleValue):
            return withUnsafeBytes(of: doubleValue.bitPattern.littleEndian) { Data($0) }
        }
    }

    /**
     * `increase` increases numeric data.
     */
    @discardableResult
    public func increase(_ by: Primitive) throws -> CRDTCounter {
        guard by.isNumericType else {
            throw YorkieError.type(message: "Unsupported type of value: \(type(of: by.value))")
        }

        let byValue: Double

        switch by.value {
        case .integer(let int32Value):
            byValue = Double(int32Value)
        case .long(let int64Value):
            byValue = Double(int64Value)
        case .double(let doubleValue):
            byValue = doubleValue
        default:
            throw YorkieError.type(message: "Unsupported type of value: \(type(of: by.value))")
        }

        switch self.value {
        case .integer(let int32Value):
            self.value = .integer(int32Value + Int32(byValue))
        case .long(let int64Value):
            self.value = .long(int64Value + Int64(byValue))
        case .double(let doubleValue):
            self.value = .double(doubleValue + byValue)
        }

        return self
    }
}
