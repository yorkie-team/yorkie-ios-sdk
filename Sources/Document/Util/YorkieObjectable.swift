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

/// ``YorkieObjectable`` provide a way to make a dictionary including members of a type confirming ``YorkieObjectable``.
public protocol YorkieObjectable {
    /// Make a dictionary including members of a type confirming ``YorkieObjectable``.
    var toYorkieObject: [String: Any] { get }

    /// The members of ``excludedLabels`` is not included in a dictionary made by ``toYorkieObject``.
    var excludedLabels: [String] { get }
}

public extension YorkieObjectable {
    var toYorkieObject: [String: Any] {
        var result = [String: Any]()
        Mirror(reflecting: self).children.forEach { child in
            guard let label = child.label else { return } // self.excludedLabels.contains(label) == false

            if let value = child.value as? YorkieObjectable {
                result[label] = value.toYorkieObject
            } else if let value = child.value as? [Any] {
                result[label] = value.toYorkieArray
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

/// ``toYorkieArray`` provide a way to make a array including types confiming``YorkieObjectable``, arrys, and values.
public extension Array {
    var toYorkieArray: [Any] {
        self.map {
            if let value = $0 as? YorkieObjectable {
                return value.toYorkieObject
            } else if let value = $0 as? Array {
                return value.toYorkieArray
            } else {
                return $0
            }
        }
    }
}
