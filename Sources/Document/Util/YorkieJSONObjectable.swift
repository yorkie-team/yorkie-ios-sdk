/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
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

/// ``YorkieJSONObjectable`` provide a way to make a dictionary including members of a type confirming ``YorkieJSONObjectable``.
public protocol YorkieJSONObjectable: Codable {
    /// The members of ``excludedLabels`` is not included in a dictionary made by ``toYorkieObject``.
    var excludedMembers: [String] { get }
}

public extension YorkieJSONObjectable {
    /// ``toJsonObject`` make a dictionary including members of a type confirming ``YorkieObjectable``.
    internal var toJsonObject: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let dictionary = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            return [:]
        }

        var result = [String: Any]()
        for (key, value) in dictionary {
            guard self.excludedMembers.contains(key) == false else { continue }
            if let value = value as? YorkieJSONObjectable {
                result[key] = value.toJsonObject
            } else if let value = value as? [Any] {
                result[key] = value.toJsonArray
            } else {
                result[key] = value
            }
        }

        return result
    }

    var excludedMembers: [String] {
        []
    }
}

/// ``toJsonArray`` provide a way to make a array including types confiming``YorkieJSONObjectable``, arrys, and values.
internal extension Array {
    var toJsonArray: [Any] {
        self.map {
            if let value = $0 as? YorkieJSONObjectable {
                return value.toJsonObject
            } else if let value = $0 as? Array {
                return value.toJsonArray
            } else {
                return $0
            }
        }
    }
}
