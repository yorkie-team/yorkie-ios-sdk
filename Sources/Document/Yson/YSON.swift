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
        do {
            // Inside the do so the scanner's own errors carry the same
            // "Failed to parse YSON: " prefix as a JSONSerialization failure, matching
            // upstream, which wraps every stage in one try.
            let processed = try self.preprocessYSON(Array(yson.utf8))
            let parsed = try JSONSerialization.jsonObject(with: Data(processed), options: [.fragmentsAllowed])
            return try self.postprocessValue(parsed)
        } catch let error as YorkieError {
            throw YorkieError(code: error.code, message: "Failed to parse YSON: \(error.message)")
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

    /// The YSON type constructor names the scanner recognizes, as UTF-8 bytes.
    ///
    /// Order is irrelevant: the token-boundary check and the required `(` mean at most
    /// one name can match at any index, so a maintainer adding a constructor need not
    /// place it anywhere in particular.
    private static let ysonConstructors: [(name: String, bytes: [UInt8])] = [
        "DedupCounter", "Counter", "BinData", "Date", "Long", "Int", "Text", "Tree"
    ].map { ($0, Array($0.utf8)) }

    /// The deepest constructor nesting `preprocessYSON` will recurse through.
    ///
    /// Each nested constructor costs a stack frame, and a syntactically balanced but
    /// pathologically deep input would otherwise exhaust the stack and terminate the
    /// process rather than throwing. Upstream recurses unbounded, which is survivable
    /// in JS because exceeding the call stack raises a catchable `RangeError`; in Swift
    /// it is a hard crash, so the limit is deliberately stricter here.
    ///
    /// Real documents nest constructors shallowly — `DedupCounter(Int(n),"…")` is two,
    /// and depth in a `Tree`/`Text` payload is JSON nesting rather than constructors —
    /// so this leaves a wide margin.
    private static let maxConstructorDepth = 64

    private enum Byte {
        static let quote: UInt8 = 0x22
        static let backslash: UInt8 = 0x5C
        static let lparen: UInt8 = 0x28
        static let rparen: UInt8 = 0x29
        static let lbracket: UInt8 = 0x5B
        static let rbracket: UInt8 = 0x5D
        static let lbrace: UInt8 = 0x7B
        static let rbrace: UInt8 = 0x7D
        static let comma: UInt8 = 0x2C
        static let underscore: UInt8 = 0x5F
    }

    /// Reports whether `byte` can appear inside an identifier.
    ///
    /// ASCII-only, matching upstream's `/[A-Za-z0-9_]/`, so a constructor keyword is
    /// matched at a token boundary rather than as the tail of a longer word.
    private static func isIdentByte(_ byte: UInt8?) -> Bool {
        guard let byte else {
            return false
        }
        return (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x30 && byte <= 0x39) || byte == Byte.underscore
    }

    /// Reports whether `byte` is JSON-legal whitespace, matching what JS `trim()` strips
    /// between tokens.
    private static func isSpaceByte(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
    }

    /// Returns the index just past the JSON string literal starting at `start`.
    ///
    /// - Parameters:
    ///   - bytes: The scanned UTF-8 bytes.
    ///   - start: The index of the opening quote.
    /// - Returns: The index just past the closing quote.
    /// - Throws: ``YorkieError`` with `errInvalidArgument` when the literal is unterminated.
    private static func skipString(_ bytes: [UInt8], _ start: Int) throws -> Int {
        var idx = start + 1
        while idx < bytes.count {
            if bytes[idx] == Byte.backslash {
                idx += 2
                continue
            }
            if bytes[idx] == Byte.quote {
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
    private static func findMatchingParen(_ bytes: [UInt8], _ start: Int) throws -> Int {
        var depth = 1
        var idx = start
        while idx < bytes.count {
            let byte = bytes[idx]
            if byte == Byte.quote {
                idx = try self.skipString(bytes, idx)
                continue
            }
            if byte == Byte.lparen {
                depth += 1
            } else if byte == Byte.rparen {
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
    private static func splitTopLevelArgs(_ bytes: [UInt8]) throws -> [[UInt8]] {
        func trimmed(_ slice: ArraySlice<UInt8>) -> [UInt8] {
            var lower = slice.startIndex
            var upper = slice.endIndex
            while lower < upper, self.isSpaceByte(slice[lower]) {
                lower += 1
            }
            while upper > lower, self.isSpaceByte(slice[upper - 1]) {
                upper -= 1
            }
            return Array(slice[lower ..< upper])
        }

        var args: [[UInt8]] = []
        var depth = 0
        var start = 0
        var idx = 0
        while idx < bytes.count {
            let byte = bytes[idx]
            if byte == Byte.quote {
                idx = try self.skipString(bytes, idx)
                continue
            }
            if byte == Byte.lparen || byte == Byte.lbracket || byte == Byte.lbrace {
                depth += 1
            } else if byte == Byte.rparen || byte == Byte.rbracket || byte == Byte.rbrace {
                depth -= 1
            } else if byte == Byte.comma, depth == 0 {
                args.append(trimmed(bytes[start ..< idx]))
                start = idx + 1
            }
            idx += 1
        }
        args.append(trimmed(bytes[start...]))
        return args
    }

    /// Returns the constructor name beginning at `idx`, when it starts on a token boundary
    /// and is immediately followed by `(`.
    private static func matchConstructorAt(_ bytes: [UInt8], _ idx: Int) -> (name: String, count: Int)? {
        if idx > 0, self.isIdentByte(bytes[idx - 1]) {
            return nil
        }
        for (name, nameBytes) in self.ysonConstructors {
            let count = nameBytes.count
            guard idx + count < bytes.count, bytes[idx + count] == Byte.lparen else {
                continue
            }
            var matched = true
            for offset in 0 ..< count where bytes[idx + offset] != nameBytes[offset] {
                matched = false
                break
            }
            if matched {
                return (name, count)
            }
        }
        return nil
    }

    /// Converts YSON special syntax to a JSON-compatible representation using `__yson_type` markers.
    ///
    /// A single left-to-right pass rewrites constructor literals into their marker objects.
    /// The scanner copies string literals verbatim, so brackets and parentheses inside string
    /// values are never counted as structure, and matches constructor arguments by paren
    /// depth rather than by a fixed-arity pattern, so there is no ceiling on the nesting a
    /// single constructor argument may contain. Nested constructors such as `Counter(Int(10))`
    /// are handled by recursing into the argument content, and that recursion is capped at
    /// ``maxConstructorDepth`` levels.
    ///
    /// Scanning is done over UTF-8 **bytes** rather than `Character`s. Swift `Character`s are
    /// extended grapheme clusters, so a quote immediately followed by a combining mark —
    /// which is exactly what per-keystroke Thai, Hindi or decomposed Vietnamese text produces
    /// at the start of a value — fuses into one cluster that never compares equal to `"`, and
    /// the scanner would report an unterminated literal on perfectly valid input. Every
    /// structural token and constructor name is ASCII and UTF-8 continuation bytes are all
    /// `>= 0x80`, so byte comparison cannot collide with multi-byte content.
    ///
    /// - Throws: ``YorkieError`` with `errInvalidArgument` when a string literal is
    ///   unterminated, the parentheses are unbalanced, the nesting exceeds
    ///   ``maxConstructorDepth``, or `DedupCounter` has the wrong arity.
    private static func preprocessYSON(_ bytes: [UInt8], depth: Int = 0) throws -> [UInt8] {
        guard depth <= self.maxConstructorDepth else {
            throw YorkieError(code: .errInvalidArgument,
                              message: "YSON constructor nesting deeper than \(self.maxConstructorDepth)")
        }

        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var idx = 0

        while idx < bytes.count {
            let byte = bytes[idx]

            // Copy string literals verbatim so their contents are never interpreted
            // as structure.
            if byte == Byte.quote {
                let end = try self.skipString(bytes, idx)
                result.append(contentsOf: bytes[idx ..< end])
                idx = end
                continue
            }

            guard let match = self.matchConstructorAt(bytes, idx) else {
                result.append(byte)
                idx += 1
                continue
            }

            let argStart = idx + match.count + 1
            let argEnd = try self.findMatchingParen(bytes, argStart)
            let argContent = Array(bytes[argStart ..< argEnd])

            if match.name == "DedupCounter" {
                let args = try self.splitTopLevelArgs(argContent)
                guard args.count == 2 else {
                    throw YorkieError(code: .errInvalidArgument,
                                      message: "DedupCounter expects a value and a registers argument")
                }
                let value = try self.preprocessYSON(args[0], depth: depth + 1)
                result.append(contentsOf: Array("{\"\(self.typeKey)\":\"DedupCounter\",\"\(self.dataKey)\":".utf8))
                result.append(contentsOf: value)
                result.append(contentsOf: Array(",\"\(self.registersKey)\":".utf8))
                result.append(contentsOf: args[1])
                result.append(Byte.rbrace)
            } else {
                let data = try self.preprocessYSON(argContent, depth: depth + 1)
                result.append(contentsOf: Array("{\"\(self.typeKey)\":\"".utf8))
                result.append(contentsOf: Array(match.name.utf8))
                result.append(contentsOf: Array("\",\"\(self.dataKey)\":".utf8))
                result.append(contentsOf: data)
                result.append(Byte.rbrace)
            }

            idx = argEnd + 1
        }

        return result
    }

    // MARK: - Postprocessing

    private static let typeKey = "__yson_type"
    private static let dataKey = "__yson_data"
    private static let registersKey = "__yson_registers"

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

    /// Reports whether `number` is a whole number that is not a boolean.
    ///
    /// The constructor regexes this parser replaced were the only integer-literal guard:
    /// they matched `-?\d+` and nothing else. `as? NSNumber` alone is far looser — it also
    /// matches `__NSCFBoolean`, so `Int(true)` would read as `1`, and it happily truncates
    /// `Int(1.5)` to `1` or wraps `Int(1e10)` to its low 32 bits. Reject both here so the
    /// existing `invalid YSON Int format` throw is reached instead.
    private static func isIntegral(_ number: NSNumber) -> Bool {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return false
        }
        let value = number.doubleValue
        return value.isFinite && value == value.rounded()
    }

    /// Restores a value tagged with a `__yson_type` marker.
    private static func postprocessMarked(_ marker: String, data: Any) throws -> YSONValue {
        switch marker {
        case "Int":
            guard let number = data as? NSNumber, self.isIntegral(number),
                  number.decimalValue >= Decimal(Int32.min), number.decimalValue <= Decimal(Int32.max)
            else { break }
            return .int(number.int32Value)
        case "Long":
            // `decimalValue`, not `doubleValue`: a Double cannot represent `Int64.max`,
            // it rounds up to 2^63, so a double-based bound rejects the legitimate
            // maximum and compares equal to the first out-of-range value.
            guard let number = data as? NSNumber, self.isIntegral(number),
                  number.decimalValue >= Decimal(Int64.min), number.decimalValue <= Decimal(Int64.max)
            else { break }
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
        guard let registers = dict[self.registersKey] as? String else {
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
