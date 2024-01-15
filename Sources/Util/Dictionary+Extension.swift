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

typealias AnyValueTypeDictionary = [String: Any?]

extension AnyValueTypeDictionary {
    var stringValueTypeDictionary: [String: String] {
        self.convertToDictionaryStringValues(self)
    }

    func convertToDictionaryStringValues(_ dictionary: [String: Any?]) -> [String: String] {
        var convertedDictionary: [String: String] = [:]

        for (key, value) in dictionary {
            if let value = value as? Encodable,
               let jsonData = try? JSONEncoder().encode(value),
               let stringValue = String(data: jsonData, encoding: .utf8)
            {
                convertedDictionary[key] = stringValue
            } else if let value = value as? [String: Any],
                      let jsonData = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                      let stringValue = String(data: jsonData, encoding: .utf8)
            {
                convertedDictionary[key] = stringValue
            } else if let value = value as? [[String: Any]],
                      let jsonData = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                      let stringValue = String(data: jsonData, encoding: .utf8)
            {
                convertedDictionary[key] = stringValue
            } else if let value {
                if value is String {
                    convertedDictionary[key] = String("\"\(value)\"")
                } else {
                    convertedDictionary[key] = String("\(value)")
                }
                print("Warning: non-encodable value for key '\(key)': \(value)")
            } else {
                convertedDictionary[key] = "null"
            }
        }

        return convertedDictionary
    }

    static func == (lhs: AnyValueTypeDictionary, rhs: AnyValueTypeDictionary) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        for (key, value) in lhs {
            if let value = value as? Int, let otherValue = rhs[key] as? Int, value == otherValue {
                continue
            } else if let value = value as? Double, let otherValue = rhs[key] as? Double, value == otherValue {
                continue
            } else if let value = value as? Bool, let otherValue = rhs[key] as? Bool, value == otherValue {
                continue
            } else if let value = value as? String, let otherValue = rhs[key] as? String, value == otherValue {
                continue
            } else if let value = value as? AnyValueTypeDictionary, let otherValue = rhs[key] as? AnyValueTypeDictionary, value == otherValue {
                continue
            } else {
                return false
            }
        }

        return true
    }
}

typealias StringValueTypeDictionary = [String: String]

extension StringValueTypeDictionary {
    var anyValueTypeDictionary: AnyValueTypeDictionary {
        var result = AnyValueTypeDictionary()

        for item in self {
            if let value = Int(item.value) {
                result[item.key] = value
            } else if let value = Double(item.value) {
                result[item.key] = value
            } else if let value = Bool(item.value) {
                result[item.key] = value
            } else if let data = item.value.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            {
                result[item.key] = object
            } else {
                result[item.key] = item.value
            }
        }

        return result
    }

    var toJSONObejct: [String: Any] {
        self.compactMapValues { $0.toJSONObject }
    }
}
