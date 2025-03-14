//
//  Payload.swift
//  Yorkie
//
//  Created by hiddenviewer on 3/11/25.
//

import Foundation

/**
 * `Payload` is a container structure that stores values of type `Codable` using `AnyCodable`.
 * It provides convenient access and serialization to JSON format.
 */
public struct Payload: Equatable, CustomStringConvertible {
    let dictionary: [String: Any]

    public init(_ dictionary: [String: Any]) {
        self.dictionary = dictionary
    }

    public init(data: Data) {
        self.dictionary = (try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) ?? [:]
    }

    public subscript(key: String) -> Any? {
        return self.dictionary[key]
    }

    public func toJSONData() throws -> Data {
        guard JSONSerialization.isValidJSONObject(self.dictionary) else {
            throw EncodingError.invalidValue(self.dictionary, EncodingError.Context(
                codingPath: [],
                debugDescription: "Invalid JSON object: \(self.dictionary)"
            ))
        }
        return try JSONSerialization.data(withJSONObject: self.dictionary, options: .sortedKeys)
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
