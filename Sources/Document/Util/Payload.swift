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
 * `JsonPrimitive`
 *
 * A protocol representing primitive data types allowed in JSON.
 * Only types conforming to this protocol can be serialized into JSON.
 */
public protocol JsonPrimitive: Codable {}

extension String: JsonPrimitive {}
extension Int: JsonPrimitive {}
extension Int64: JsonPrimitive {}
extension Double: JsonPrimitive {}
extension Bool: JsonPrimitive {}
extension Array: JsonPrimitive where Element: JsonPrimitive {}
extension Dictionary: JsonPrimitive where Key == String, Value: JsonPrimitive {}

/**
 * `Payload` is a container structure that stores values of type `Codable` using `AnyCodable`.
 * It provides convenient access and serialization to JSON format.
 */
public struct Payload: Equatable, CustomStringConvertible {
    let dictionary: [String: Any]

    public init(_ dictionary: [String: JsonPrimitive]) {
        self.dictionary = dictionary
    }

    public init(jsonData: Data) {
        self.dictionary = (try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]) ?? [:]
    }

    public subscript<T: Codable>(key: String) -> T? {
        return self.dictionary[key] as? T
    }

    public func toJSONData() throws -> Data {
        guard JSONSerialization.isValidJSONObject(self.dictionary) else {
            throw EncodingError.invalidValue(self.dictionary, EncodingError.Context(
                codingPath: [],
                debugDescription: "Invalid JSON object: \(self.dictionary)"
            ))
        }
        return try JSONSerialization.data(withJSONObject: self.dictionary, options: [.sortedKeys])
    }

    public var description: String {
        guard let jsonData = try? self.toJSONData(), let jsonString = String(data: jsonData, encoding: .utf8) else {
            return ""
        }
        return jsonString
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        return NSDictionary(dictionary: lhs.dictionary).isEqual(to: rhs.dictionary)
    }
}
