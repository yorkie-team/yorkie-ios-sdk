/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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

/// `JSONNode` is one node of a parsed document tree, suitable for rendering with
/// SwiftUI's `OutlineGroup`.
///
/// A node is built from the JSON produced by `Document.toSortedJSON()`. Containers
/// (objects / arrays) carry their `children`; scalars have `children == nil` so the
/// outline shows no disclosure control.
public struct JSONNode: Identifiable {
    /// Stable identity derived from the node's path, so `OutlineGroup` preserves
    /// expansion state across live refreshes (a fresh `UUID()` per build would
    /// collapse the tree on every poll).
    public let id: String

    /// The object key or array index label for this node.
    public let key: String

    /// A short rendering of the node's value: the scalar itself, or a
    /// container summary such as `{3}` / `[2]`.
    public let valuePreview: String

    /// The node's children, or `nil` for scalars and empty containers.
    public let children: [JSONNode]?

    /// Builds a node tree rooted at `value`, labelled `key`.
    public static func build(key: String, value: Any) -> JSONNode {
        self.build(key: key, value: value, path: key)
    }

    private static func build(key: String, value: Any, path: String) -> JSONNode {
        switch value {
        case let dictionary as [String: Any]:
            let children = dictionary.keys.sorted().map { childKey in
                self.build(key: childKey, value: dictionary[childKey] as Any, path: "\(path)/\(childKey)")
            }
            return JSONNode(id: path, key: key, valuePreview: "{\(children.count)}", children: children.isEmpty ? nil : children)

        case let array as [Any]:
            let children = array.enumerated().map { index, element in
                self.build(key: "[\(index)]", value: element, path: "\(path)/\(index)")
            }
            return JSONNode(id: path, key: key, valuePreview: "[\(children.count)]", children: children.isEmpty ? nil : children)

        case is NSNull:
            return JSONNode(id: path, key: key, valuePreview: "null", children: nil)

        case let number as NSNumber:
            // JSON booleans and integers both bridge to NSNumber; only a real
            // `CFBoolean` (e.g. JSON `true`/`false`) should render as a bool.
            // Otherwise integer `0`/`1` would be shown as `false`/`true`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return JSONNode(id: path, key: key, valuePreview: number.boolValue ? "true" : "false", children: nil)
            }
            return JSONNode(id: path, key: key, valuePreview: number.stringValue, children: nil)

        case let string as String:
            return JSONNode(id: path, key: key, valuePreview: "\"\(string)\"", children: nil)

        default:
            return JSONNode(id: path, key: key, valuePreview: String(describing: value), children: nil)
        }
    }

    /// Parses a `toSortedJSON()` string into top-level nodes.
    static func parse(sortedJSON: String) -> [JSONNode] {
        guard let data = sortedJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return []
        }

        if let dictionary = object as? [String: Any] {
            return dictionary.keys.sorted().map { self.build(key: $0, value: dictionary[$0] as Any) }
        }
        return [self.build(key: "root", value: object)]
    }
}
