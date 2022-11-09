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

enum PrimitiveValue: Equatable {
    case null
    case boolean(Bool)
    case integer(Int32)
    case long(Int64)
    case double(Double)
    case string(String)
    case bytes(Data)
    case date(Date)
}

/**
 * `Primitive` represents primitive data type including logical clock.
 * It has a type and a value.
 */
class Primitive: CRDTElement {
    let createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    let value: PrimitiveValue

    init(value: PrimitiveValue, createdAt: TimeTicket) {
        self.createdAt = createdAt

        switch value {
        case .date(let dateValue):
            // Trim the less than a millisecond
            self.value = .date(Date(timeIntervalSince1970: Double(dateValue.millisecondTimeIntervalSince1970) / 1000))
        default:
            self.value = value
        }
    }

    /**
     * `type` returns the primitive type of the value.
     */
    static func type(of value: Any?) -> PrimitiveValue? {
        guard let value else {
            return .null
        }

        switch value {
        case let casted as Bool:
            return .boolean(casted)
        case let casted as Int32:
            return .integer(casted)
        case let casted as Int64:
            return .long(casted)
        case let casted as Double:
            return .double(casted)
        case let casted as String:
            return .string(casted)
        case let casted as Data:
            return .bytes(casted)
        case let casted as Date:
            return .date(casted)
        default:
            return nil
        }
    }

    /**
     * `isSupport` check if the given value is supported type.
     */
    static func isSupport(value: Any) -> Bool {
        return Primitive.type(of: value) != nil
    }

    /**
     * `isNumericType` checks numeric type by JSONPrimitive
     */
    var isNumericType: Bool {
        switch self.value {
        case .integer, .long, .double:
            return true
        default:
            return false
        }
    }

    /**
     * `toBytes` creates an array representing the value.
     */
    func toBytes() -> Data {
        switch self.value {
        case .null:
            return Data()
        case .boolean(let value):
            var valueInInt = Int(exactly: NSNumber(value: value))
            return Data(bytes: &valueInInt, count: MemoryLayout.size(ofValue: valueInInt))
        case .integer(let value):
            return withUnsafeBytes(of: value.bigEndian) { Data($0) }
        case .double(let value):
            return withUnsafeBytes(of: value.bitPattern.bigEndian) { Data($0) }
        case .string(let value):
            return value.data(using: .utf8) ?? Data()
        case .long(let value):
            return withUnsafeBytes(of: value.bigEndian) { Data($0) }
        case .bytes(let value):
            return value
        case .date(let value):
            let milliseconds = value.millisecondTimeIntervalSince1970
            return withUnsafeBytes(of: milliseconds.bigEndian) { Data($0) }
        }
    }
}

extension Primitive {
    /**
     * `toJSON` returns the JSON encoding of the value.
     *
     * TODOs: We need to consider the case where the value is
     * a byte array and a date.
     */
    func toJSON() -> String {
        switch self.value {
        case .null:
            return "null"
        case .boolean(let value):
            return "\"\(value)\""
        case .integer(let value):
            return "\(value)"
        case .double(let value):
            return "\(value)"
        case .string(let value):
            return "\"\(value.escaped())\""
        case .long(let value):
            return "\(value)"
        case .bytes(let value):
            return "\(value)"
        case .date(let value):
            return "\(value.millisecondTimeIntervalSince1970)"
        }
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of the value.
     */
    func toSortedJSON() -> String {
        return self.toJSON()
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> CRDTElement {
        let primitive = Primitive(value: self.value, createdAt: self.createdAt)
        primitive.setMovedAt(self.movedAt)
        return primitive
    }
}

private extension Date {
    /**
     * `millisecondTimeIntervalSince1970` returns the number representing the milliseconds elapsed between 1 January 1970 00:00:00 UTC and the given date.
     *  It's simmilar getTime() in javascript
     */
    var millisecondTimeIntervalSince1970: Int {
        Int(floor(self.timeIntervalSince1970 * 1000))
    }
}
