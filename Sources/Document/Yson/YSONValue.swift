/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

/// A single character in a Text CRDT.
public struct YSONTextNode: Equatable {
    /// The character value.
    public let val: String

    /// Optional attributes (e.g. formatting).
    public let attrs: [String: YSONValue]?

    public init(val: String, attrs: [String: YSONValue]? = nil) {
        self.val = val
        self.attrs = attrs
    }
}

/// A Text CRDT structure.
public struct YSONText: Equatable {
    public let nodes: [YSONTextNode]

    public init(nodes: [YSONTextNode]) {
        self.nodes = nodes
    }
}

/// A node in a Tree CRDT.
///
/// Text nodes carry a `value`; element nodes carry `attrs` and `children`.
public struct YSONTreeNode: Equatable {
    /// Node type (e.g. `text`, `p`, `div`).
    public let type: String

    /// Text content (for text nodes).
    public let value: String?

    /// Attributes (for element nodes).
    public let attrs: [String: String]?

    /// Child nodes (for element nodes).
    public let children: [YSONTreeNode]?

    public init(type: String, value: String? = nil, attrs: [String: String]? = nil, children: [YSONTreeNode]? = nil) {
        self.type = type
        self.value = value
        self.attrs = attrs
        self.children = children
    }
}

/// A Tree CRDT structure.
public struct YSONTree: Equatable {
    public let root: YSONTreeNode

    public init(root: YSONTreeNode) {
        self.root = root
    }
}

/// Any valid YSON value.
///
/// Mirrors the YSON value union from yorkie-js-sdk: primitives, collections, the CRDT types
/// (``YSONText``, ``YSONTree``, Counter) and the special scalar types (Int, Long, Date, BinData).
public indirect enum YSONValue: Equatable {
    /// A JSON string.
    case string(String)
    /// A JSON number (floating point).
    case number(Double)
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON null.
    case null
    /// A 32-bit integer (`Int(42)`).
    case int(Int32)
    /// A 64-bit integer (`Long(64)`).
    case long(Int64)
    /// An ISO 8601 timestamp string (`Date("...")`).
    case date(String)
    /// Base64-encoded binary data (`BinData("...")`).
    case binData(String)
    /// A Counter CRDT wrapping an ``YSONValue/int(_:)`` or ``YSONValue/long(_:)`` value.
    case counter(YSONValue)
    /// A Text CRDT.
    case text(YSONText)
    /// A Tree CRDT.
    case tree(YSONTree)
    /// A plain object.
    case object([String: YSONValue])
    /// An array.
    case array([YSONValue])
}
