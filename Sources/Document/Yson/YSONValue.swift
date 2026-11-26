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

    /// The attributes exactly as parsed: an object, or an array when the document stored
    /// an array-valued `attrs`; `nil` when absent or of any other shape.
    ///
    /// This is the lossless view, matching the JS SDK, which keeps any object or array.
    public let rawAttrs: YSONValue?

    /// Optional attributes (e.g. formatting), when ``rawAttrs`` is an object.
    ///
    /// This is a convenience view: it is `nil` for an array-valued `attrs`. Use ``rawAttrs``
    /// to read every shape.
    public var attrs: [String: YSONValue]? {
        if case .object(let object) = self.rawAttrs {
            return object
        }
        return nil
    }

    public init(val: String, attrs: [String: YSONValue]? = nil) {
        self.val = val
        self.rawAttrs = attrs.map { .object($0) }
    }

    /// Creates a node from raw attributes, which may be an object or an array.
    public init(val: String, rawAttrs: YSONValue?) {
        self.val = val
        self.rawAttrs = rawAttrs
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

    /// The attributes exactly as parsed, with values of any type (for element nodes): an
    /// object, or an array when the document stored an array-valued `attrs`; `nil` when
    /// absent or of any other shape.
    ///
    /// This is the lossless view, matching the JS SDK, which keeps any object or array.
    public let rawAttrs: YSONValue?

    /// The string-valued entries of ``rawAttrs`` when it is an object (for element nodes).
    ///
    /// This is a lossy convenience view: entries whose value is not a string are left out,
    /// and an array-valued `attrs` gives `nil`. Use ``rawAttrs`` to read everything.
    public var attrs: [String: String]? {
        guard case .object(let object) = self.rawAttrs else {
            return nil
        }
        return object.compactMapValues { value in
            if case .string(let string) = value {
                return string
            }
            return nil
        }
    }

    /// Child nodes (for element nodes).
    public let children: [YSONTreeNode]?

    public init(type: String, value: String? = nil, attrs: [String: String]? = nil, children: [YSONTreeNode]? = nil) {
        self.type = type
        self.value = value
        self.rawAttrs = attrs.map { .object($0.mapValues { .string($0) }) }
        self.children = children
    }

    /// Creates a node from raw attributes, whose values may be of any type, or an array.
    public init(type: String, value: String? = nil, rawAttrs: YSONValue?, children: [YSONTreeNode]? = nil) {
        self.type = type
        self.value = value
        self.rawAttrs = rawAttrs
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
    /// A DedupCounter CRDT wrapping an ``YSONValue/int(_:)`` value and a base64-encoded HyperLogLog registers string.
    case dedupCounter(value: YSONValue, registers: String)
    /// A Text CRDT.
    case text(YSONText)
    /// A Tree CRDT.
    case tree(YSONTree)
    /// A plain object.
    case object([String: YSONValue])
    /// An array.
    case array([YSONValue])
}
