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
public protocol YorkieJSONObjectable {
    /// The members of ``excludedLabels`` is not included in a dictionary made by ``toYorkieObject``.
    var excludedLabels: [String] { get }
}

public extension YorkieJSONObjectable {
    /// ``toJsonObject`` make a dictionary including members of a type confirming ``YorkieObjectable``.
    internal var toJsonObject: [String: Any] {
        var result = [String: Any]()
        Mirror(reflecting: self).children.forEach { child in
            guard let label = child.label,
                  excludedLabels.contains(label) == false
            else {
                return
            }

            if let value = child.value as? YorkieJSONObjectable {
                result[label] = value.toJsonObject
            } else if let value = child.value as? [Any] {
                result[label] = value.toJsonArray
            } else {
                result[label] = child.value
            }
        }

        return result
    }

    var excludedLabels: [String] {
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
