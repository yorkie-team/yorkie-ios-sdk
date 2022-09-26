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

enum Converter {
    
    /**
     * `valueFromBytes` parses the given bytes into value.
     */
    static func valueFrom(valueType: ValueType, data: Data) throws -> PrimitiveValue {
        switch valueType {
        case .null:
            return .null
        case .boolean:
            return .boolean(data[0] == 1)
        case .integer:
            let result = data.withUnsafeBytes { $0.load(as: Int32.self) }
            return .integer(result)
        case .double:
            let result = data.withUnsafeBytes { $0.load(as: Double.self) }
            return .double(result)
        case .string:
            return .string(String(decoding: data, as: UTF8.self))
        case .long:
            let result = data.withUnsafeBytes { $0.load(as: Int64.self) }
            return .long(result)
        case .bytes:
            return .bytes(data)
        case .date:
            let milliseconds = data.withUnsafeBytes { $0.load(as: Double.self) }
            return .date(Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
        default:
            throw YorkieError.unimplemented(message: String(describing: valueType))
        }
    }
    
}
