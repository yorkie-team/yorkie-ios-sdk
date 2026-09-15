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
        let processed = try self.preprocessYSON(yson)

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

    /// The YSON type constructor names the scanner recognizes.
    ///
    /// Longer names precede their suffixes (`DedupCounter` before `Counter`) so the
    /// scanner prefers the longest match.
    private static let ysonConstructors = [
        "DedupCounter", "Counter", "BinData", "Date", "Long", "Int", "Text", "Tree"
    ]

    /// Reports whether `ch` can appear inside an identifier.
    ///
    /// Used to ensure a constructor keyword is matched at a token boundary rather than
    /// as the tail of some longer word.
    private static func isIdentChar(_ ch: Character?) -> Bool {
        guard let ch else {
            return false
        }
        return ch.isLetter || ch.isNumber || ch == "_"
    }

    /// Returns the index just past the JSON string literal starting at `start`.
    ///
    /// - Parameters:
    ///   - chars: The scanned characters.
    ///   - start: The index of the opening quote.
    /// - Returns: The index just past the closing quote.
    /// - Throws: ``YorkieError`` with `errInvalidArgument` when the literal is unterminated.
    private static func skipString(_ chars: [Character], _ start: Int) throws -> Int {
        var idx = start + 1
        while idx < chars.count {
            if chars[idx] == "\\" {
                idx += 2
                continue
            }
            if chars[idx] == "\"" {
                return idx + 1
            }
            idx += 1
        }
        throw YorkieError(code: .errInvalidArgument, message: "unterminated string literal")
    }

    /// Returns the index of the `)` closing the `(` whose argument begins at `start`.
    ///
    /// Parentheses inside string literals are ignored, so the boundary is found by depth
    /// counting rather than a fixed-arity pattern.
    ///
    /// - Throws: ``YorkieError`` with `errInvalidArgument` when the parentheses are unbalanced.
    private static func findMatchingParen(_ chars: [Character], _ start: Int) throws -> Int {
        var depth = 1
        var idx = start
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "\"" {
                idx = try self.skipString(chars, idx)
                continue
            }
            if ch == "(" {
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0 {
                    return idx
                }
            }
            idx += 1
        }
        throw YorkieError(code: .errInvalidArgument, message: "unbalanced parentheses in YSON")
    }

    /// Splits a constructor argument list on top-level commas, ignoring commas inside
    /// nested brackets or string literals.
    private static func splitTopLevelArgs(_ chars: [Character]) throws -> [String] {
        var args: [String] = []
        var depth = 0
        var start = 0
        var idx = 0
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "\"" {
                idx = try self.skipString(chars, idx)
                continue
            }
            if ch == "(" || ch == "[" || ch == "{" {
                depth += 1
            } else if ch == ")" || ch == "]" || ch == "}" {
                depth -= 1
            } else if ch == ",", depth == 0 {
                args.append(String(chars[start ..< idx]).trimmingCharacters(in: .whitespaces))
                start = idx + 1
            }
            idx += 1
        }
        args.append(String(chars[start...]).trimmingCharacters(in: .whitespaces))
        return args
    }

    /// Returns the constructor name beginning at `idx`, when it starts on a token boundary
    /// and is immediately followed by `(`.
    private static func matchConstructorAt(_ chars: [Character], _ idx: Int) -> String? {
        if idx > 0, self.isIdentChar(chars[idx - 1]) {
            return nil
        }
        for name in self.ysonConstructors {
            let count = name.count
            guard idx + count < chars.count, chars[idx + count] == "(" else {
                continue
            }
            if String(chars[idx ..< (idx + count)]) == name {
                return name
            }
        }
        return nil
    }

    /// Converts YSON special syntax to a JSON-compatible representation using `__yson_type` markers.
    ///
    /// A single left-to-right pass rewrites constructor literals into their marker objects.
    /// The scanner tracks string literals, so brackets and parentheses inside string values
    /// are never counted as structure, and matches constructor arguments by paren depth, so
    /// there is no nesting-depth ceiling. Nested constructors such as `Counter(Int(10))` are
    /// handled by recursing into the argument content.
    ///
    /// - Throws: ``YorkieError`` with `errInvalidArgument` when a string literal is
    ///   unterminated, the parentheses are unbalanced, or `DedupCounter` has the wrong arity.
    private static func preprocessYSON(_ yson: String) throws -> String {
        let chars = Array(yson)
        var result = ""
        var idx = 0

        while idx < chars.count {
            let ch = chars[idx]

            // Copy string literals verbatim so their contents are never interpreted
            // as structure.
            if ch == "\"" {
                let end = try self.skipString(chars, idx)
                result += String(chars[idx ..< end])
                idx = end
                continue
            }

            guard let name = self.matchConstructorAt(chars, idx) else {
                result.append(ch)
                idx += 1
                continue
            }

            let argStart = idx + name.count + 1
            let argEnd = try self.findMatchingParen(chars, argStart)
            let argContent = Array(chars[argStart ..< argEnd])

            if name == "DedupCounter" {
                let args = try self.splitTopLevelArgs(argContent)
                guard args.count == 2 else {
                    throw YorkieError(code: .errInvalidArgument,
                                      message: "DedupCounter expects a value and a registers argument")
                }
                let value = try self.preprocessYSON(args[0])
                result += "{\"__yson_type\":\"DedupCounter\",\"__yson_data\":\(value),\"__yson_registers\":\(args[1])}"
            } else {
                let data = try self.preprocessYSON(String(argContent))
                result += "{\"__yson_type\":\"\(name)\",\"__yson_data\":\(data)}"
            }

            idx = argEnd + 1
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
