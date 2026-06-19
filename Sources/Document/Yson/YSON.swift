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

/// YSON (Yorkie Serialized Object Notation) utilities.
///
/// YSON is an extended JSON format that supports Yorkie CRDT types. ``RevisionSummary/snapshot``
/// is serialized in this format; use ``parse(_:)`` to turn it into a typed ``YSONValue``.
public enum YSON {
    /// Parses a YSON string into a typed ``YSONValue``.
    ///
    /// YSON extends JSON to support Yorkie CRDT types such as `Text([...])`, `Tree(...)`,
    /// `Counter(Int(10))`, `Int(42)`, `Long(64)`, `Date("...")` and `BinData("...")`.
    ///
    /// - Parameter yson: The YSON formatted string.
    /// - Returns: The parsed ``YSONValue``.
    /// - Throws: ``YorkieError`` with ``YorkieError/code`` `errInvalidArgument` when parsing fails.
    public static func parse(_ yson: String) throws -> YSONValue {
        let processed = self.preprocessYSON(yson)

        guard let data = processed.data(using: .utf8) else {
            throw YorkieError(code: .errInvalidArgument, message: "Failed to parse YSON: invalid encoding")
        }

        do {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return try self.postprocessValue(parsed)
        } catch let error as YorkieError {
            throw error
        } catch {
            throw YorkieError(code: .errInvalidArgument, message: "Failed to parse YSON: \(error.localizedDescription)")
        }
    }

    /// Extracts the plain text content from a ``YSONText``.
    public static func textToString(_ text: YSONText) -> String {
        text.nodes.map { $0.val }.joined()
    }

    /// Converts a ``YSONTree`` to its XML string representation.
    public static func treeToXML(_ tree: YSONTree) -> String {
        self.treeNodeToXML(tree.root)
    }

    // MARK: - Type guards

    /// Returns whether the value is a ``YSONText``.
    public static func isText(_ value: YSONValue) -> Bool {
        if case .text = value { return true }
        return false
    }

    /// Returns whether the value is a ``YSONTree``.
    public static func isTree(_ value: YSONValue) -> Bool {
        if case .tree = value { return true }
        return false
    }

    /// Returns whether the value is a 32-bit integer.
    public static func isInt(_ value: YSONValue) -> Bool {
        if case .int = value { return true }
        return false
    }

    /// Returns whether the value is a 64-bit integer.
    public static func isLong(_ value: YSONValue) -> Bool {
        if case .long = value { return true }
        return false
    }

    /// Returns whether the value is a date.
    public static func isDate(_ value: YSONValue) -> Bool {
        if case .date = value { return true }
        return false
    }

    /// Returns whether the value is binary data.
    public static func isBinData(_ value: YSONValue) -> Bool {
        if case .binData = value { return true }
        return false
    }

    /// Returns whether the value is a Counter CRDT.
    public static func isCounter(_ value: YSONValue) -> Bool {
        if case .counter = value { return true }
        return false
    }

    /// Returns whether the value is a DedupCounter CRDT.
    public static func isDedupCounter(_ value: YSONValue) -> Bool {
        if case .dedupCounter = value { return true }
        return false
    }

    /// Returns whether the value is a plain object (not a special type).
    ///
    /// Returns `false` for special CRDT types such as ``YSONValue/counter(_:)`` and
    /// ``YSONValue/dedupCounter(value:registers:)`` even if they could otherwise appear
    /// as object-shaped values in other representations.
    public static func isObject(_ value: YSONValue) -> Bool {
        if case .object = value { return true }
        return false
    }

    // MARK: - Preprocessing

    /// Converts YSON special syntax to a JSON-compatible representation using `__yson_type` markers.
    ///
    /// DedupCounter is handled first because its compound literal `DedupCounter(Int(n),"b64")`
    /// would be partially matched by the Counter or Int patterns if those ran first.
    private static func preprocessYSON(_ yson: String) -> String {
        var result = yson

        // DedupCounter must be replaced before Counter and Int, as its literal contains
        // an Int(…) sub-expression and a quoted registers string.
        // DedupCounter(Int(15),"b64") →
        //   {"__yson_type":"DedupCounter","__yson_data":{"__yson_type":"Int","__yson_data":15},"__yson_registers":"b64"}
        let dedupPattern = "DedupCounter\\(Int\\((-?\\d+)\\),\"([^\"]+)\"\\)"
        if let regex = try? NSRegularExpression(pattern: dedupPattern) {
            var output = ""
            var lastEnd = result.startIndex
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches {
                let matchRange = Range(match.range, in: result)!
                output += result[lastEnd ..< matchRange.lowerBound]
                let valueRange = Range(match.range(at: 1), in: result)!
                let regsRange = Range(match.range(at: 2), in: result)!
                let value = String(result[valueRange])
                let regs = String(result[regsRange])
                output += "{\"__yson_type\":\"DedupCounter\",\"__yson_data\":{\"__yson_type\":\"Int\",\"__yson_data\":\(value)},\"__yson_registers\":\"\(regs)\"}"
                lastEnd = matchRange.upperBound
            }
            output += result[lastEnd...]
            result = output
        }

        // Counter and the remaining types are handled in order.
        let replacements: [(pattern: String, template: String)] = [
            ("Counter\\((Int|Long)\\((-?\\d+)\\)\\)",
             "{\"__yson_type\":\"Counter\",\"__yson_data\":{\"__yson_type\":\"$1\",\"__yson_data\":$2}}"),
            ("Int\\((-?\\d+)\\)", "{\"__yson_type\":\"Int\",\"__yson_data\":$1}"),
            ("Long\\((-?\\d+)\\)", "{\"__yson_type\":\"Long\",\"__yson_data\":$1}"),
            ("Date\\(\"([^\"]*)\"\\)", "{\"__yson_type\":\"Date\",\"__yson_data\":\"$1\"}"),
            ("BinData\\(\"([^\"]*)\"\\)", "{\"__yson_type\":\"BinData\",\"__yson_data\":\"$1\"}"),
            ("Text\\((\\[(?:[^\\[\\]]|\\[(?:[^\\[\\]]|\\[[^\\[\\]]*\\])*\\])*\\])\\)",
             "{\"__yson_type\":\"Text\",\"__yson_data\":$1}"),
            ("Tree\\((\\{[^{}]*(?:\\{[^{}]*(?:\\{[^{}]*\\})*[^{}]*\\})*[^{}]*\\})\\)",
             "{\"__yson_type\":\"Tree\",\"__yson_data\":$1}")
        ]

        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }

        return result
    }

    // MARK: - Postprocessing

    private static let typeKey = "__yson_type"
    private static let dataKey = "__yson_data"

    /// Recursively restores YSON types from the parsed JSON object graph.
    private static func postprocessValue(_ value: Any) throws -> YSONValue {
        if value is NSNull {
            return .null
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }

        if let string = value as? String {
            return .string(string)
        }

        if let array = value as? [Any] {
            return try .array(array.map { try self.postprocessValue($0) })
        }

        if let dict = value as? [String: Any] {
            if let marker = dict[typeKey] as? String {
                // DedupCounter requires both __yson_data and __yson_registers from the same dict.
                if marker == "DedupCounter" {
                    return try self.postprocessDedupCounter(dict)
                }
                return try self.postprocessMarked(marker, data: dict[self.dataKey] as Any)
            }

            var object = [String: YSONValue]()
            for (key, val) in dict {
                object[key] = try self.postprocessValue(val)
            }
            return .object(object)
        }

        throw YorkieError(code: .errInvalidArgument, message: "invalid YSON value")
    }

    /// Restores a value tagged with a `__yson_type` marker.
    private static func postprocessMarked(_ marker: String, data: Any) throws -> YSONValue {
        switch marker {
        case "Int":
            guard let number = data as? NSNumber else { break }
            return .int(number.int32Value)
        case "Long":
            guard let number = data as? NSNumber else { break }
            return .long(number.int64Value)
        case "Date":
            guard let string = data as? String else { break }
            return .date(string)
        case "BinData":
            guard let string = data as? String else { break }
            return .binData(string)
        case "Counter":
            let counterValue = try postprocessValue(data)
            guard YSON.isInt(counterValue) || YSON.isLong(counterValue) else {
                throw YorkieError(code: .errInvalidArgument, message: "Counter must contain Int or Long")
            }
            return .counter(counterValue)
        case "Text":
            guard let nodes = data as? [Any] else { break }
            return try .text(YSONText(nodes: nodes.map { try self.postprocessTextNode($0) }))
        case "Tree":
            return try .tree(YSONTree(root: self.postprocessTreeNode(data)))
        default:
            break
        }

        throw YorkieError(code: .errInvalidArgument, message: "invalid YSON \(marker) format")
    }

    /// Restores a DedupCounter value from a dict that contains both `__yson_data` and `__yson_registers`.
    ///
    /// - Throws: ``YorkieError`` with code `errInvalidArgument` when the inner value is not an Int.
    private static func postprocessDedupCounter(_ dict: [String: Any]) throws -> YSONValue {
        guard let registers = dict["__yson_registers"] as? String else {
            throw YorkieError(code: .errInvalidArgument, message: "invalid YSON DedupCounter format")
        }
        let innerValue = try postprocessValue(dict[dataKey] as Any)
        guard YSON.isInt(innerValue) else {
            throw YorkieError(code: .errInvalidArgument, message: "DedupCounter must contain Int")
        }
        return .dedupCounter(value: innerValue, registers: registers)
    }

    private static func postprocessTextNode(_ node: Any) throws -> YSONTextNode {
        guard let dict = node as? [String: Any], let val = dict["val"] as? String else {
            throw YorkieError(code: .errInvalidArgument, message: "invalid text node format")
        }

        var attrs: [String: YSONValue]?
        if let rawAttrs = dict["attrs"] as? [String: Any] {
            var mapped = [String: YSONValue]()
            for (key, value) in rawAttrs {
                mapped[key] = try self.postprocessValue(value)
            }
            attrs = mapped
        }

        return YSONTextNode(val: val, attrs: attrs)
    }

    private static func postprocessTreeNode(_ node: Any) throws -> YSONTreeNode {
        guard let dict = node as? [String: Any], let type = dict["type"] as? String else {
            throw YorkieError(code: .errInvalidArgument, message: "invalid tree node format")
        }

        // Text node.
        if type == "text", let value = dict["value"] as? String {
            return YSONTreeNode(type: type, value: value)
        }

        // Element node.
        let attrs = dict["attrs"] as? [String: String]

        var children: [YSONTreeNode]?
        if let rawChildren = dict["children"] as? [Any] {
            children = try rawChildren.map { try self.postprocessTreeNode($0) }
        }

        return YSONTreeNode(type: type, attrs: attrs, children: children)
    }

    // MARK: - XML

    private static func treeNodeToXML(_ node: YSONTreeNode) -> String {
        let attrs = node.attrs?.map { " \($0.key)=\"\(self.escapeXML($0.value))\"" }.joined() ?? ""

        // Text node with value.
        if node.type == "text", let value = node.value {
            return "<\(node.type)\(attrs)>\(self.escapeXML(value))</\(node.type)>"
        }

        // Empty element node.
        guard let children = node.children, !children.isEmpty else {
            return "<\(node.type)\(attrs) />"
        }

        // Element node with children.
        let inner = children.map { self.treeNodeToXML($0) }.joined()
        return "<\(node.type)\(attrs)>\(inner)</\(node.type)>"
    }

    private static func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
