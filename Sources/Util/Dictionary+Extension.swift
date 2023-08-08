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

typealias AnyValueTypeDictionary = [String: Any]

extension AnyValueTypeDictionary {
    var stringValueTypeDictionary: [String: String] {
        self.convertToDictionaryStringValues(self)
    }

    func convertToDictionaryStringValues(_ dictionary: [String: Any]) -> [String: String] {
        var convertedDictionary: [String: String] = [:]

        for (key, value) in dictionary {
            if let stringValue = value as? String {
                let jsonString = "\"\(stringValue)\""
                convertedDictionary[key] = jsonString
            } else if let convertibleToString = value as? CustomStringConvertible {
                let jsonString = "\(convertibleToString.description)"
                convertedDictionary[key] = jsonString
            } else if let nestedDictionary = value as? [String: Any] {
                // If the value is a nested dictionary, recursively convert it
                let nestedConverted = self.convertToDictionaryStringValues(nestedDictionary)
                // Convert the nested dictionary to its JSON representation
                if let jsonString = try? JSONSerialization.data(withJSONObject: nestedConverted) {
                    convertedDictionary[key] = String(data: jsonString, encoding: .utf8)
                } else {
                    convertedDictionary[key] = "null"
                }
            } else {
                print("Warning: Skipping non-convertible value for key '\(key)': \(value)")
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

        self.forEach {
            if let value = Int($0.value) {
                result[$0.key] = value
            } else if let value = Double($0.value) {
                result[$0.key] = value
            } else if $0.value.lowercased() == "true" {
                result[$0.key] = true
            } else if $0.value.lowercased() == "false" {
                result[$0.key] = false
            } else if let data = $0.value.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            {
                result[$0.key] = object
            } else {
                result[$0.key] = $0.value
            }
        }

        return result
    }
}
