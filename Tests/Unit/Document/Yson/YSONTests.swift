/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

import XCTest
@testable import Yorkie

/// Ports: `packages/sdk/test/unit/document/yson_test.ts` from yorkie-js-sdk v0.7.19
/// (yorkie-js-sdk#1335 "Replace YSON regex preprocessor with a string-aware scanner").
///
/// The old `preprocessYSON` rewrote `Tree(...)`/`Text([...])` literals with a chain of
/// fixed-depth regular expressions: nesting past three levels was left untransformed, and
/// brackets inside string values were counted as structure. `preprocessYSON` is now a
/// string-aware scanner without either limitation.
///
/// The `Reserved Marker Keys` section ports yorkie-js-sdk v0.7.28 (yorkie-js-sdk#1545
/// "Escape user keys in YSON's reserved marker namespace").
final class YSONTests: XCTestCase {
    // MARK: - parse

    func test_should_parse_primitives() throws {
        XCTAssertEqual(try YSON.parse("\"hello\""), .string("hello"))
        XCTAssertEqual(try YSON.parse("42"), .number(42))
        XCTAssertEqual(try YSON.parse("true"), .bool(true))
        XCTAssertEqual(try YSON.parse("null"), .null)
    }

    func test_should_parse_arrays() throws {
        XCTAssertEqual(try YSON.parse("[1, 2, 3]"), .array([.number(1), .number(2), .number(3)]))
    }

    func test_should_parse_plain_objects() throws {
        let result = try YSON.parse("{\"name\":\"Alice\",\"age\":30}")
        XCTAssertEqual(result, .object(["name": .string("Alice"), "age": .number(30)]))
    }

    func test_should_parse_text_crdt() throws {
        let result = try YSON.parse("{\"content\":Text([{\"val\":\"H\"},{\"val\":\"i\"}])}")
        guard case .object(let obj) = result, let content = obj["content"] else {
            return XCTFail("expected object with content")
        }
        XCTAssertTrue(YSON.isText(content))
        XCTAssertEqual(content, .text(YSONText(nodes: [YSONTextNode(val: "H"), YSONTextNode(val: "i")])))
    }

    func test_should_parse_text_crdt_with_attributes() throws {
        let result = try YSON.parse("{\"content\":Text([{\"val\":\"H\",\"attrs\":{\"bold\":true}}])}")
        guard case .object(let obj) = result, case .text(let text)? = obj["content"] else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(text.nodes[0].attrs, ["bold": .bool(true)])
    }

    func test_should_parse_tree_crdt() throws {
        let yson = "{\"content\":Tree({\"type\":\"doc\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"text\",\"value\":\"Hello\"}]}]})}"
        let result = try YSON.parse(yson)
        guard case .object(let obj) = result, case .tree(let tree)? = obj["content"] else {
            return XCTFail("expected tree content")
        }
        XCTAssertEqual(tree.root.type, "doc")
        XCTAssertEqual(tree.root.children?.count, 1)
        XCTAssertEqual(tree.root.children?[0].type, "p")
    }

    func test_should_parse_nested_structures() throws {
        let result = try YSON.parse("{\"users\":[{\"name\":\"Alice\",\"content\":Text([{\"val\":\"A\"}])}]}")
        guard case .object(let obj) = result, case .array(let users)? = obj["users"],
              case .object(let user) = users[0], let content = user["content"]
        else {
            return XCTFail("expected nested users array")
        }
        XCTAssertTrue(YSON.isText(content))
    }

    // MARK: - Type guards

    func test_isText_should_identify_text_objects() {
        let text = YSONValue.text(YSONText(nodes: [YSONTextNode(val: "H")]))
        XCTAssertTrue(YSON.isText(text))
        XCTAssertFalse(YSON.isText(.object(["type": .string("NotText")])))
        XCTAssertFalse(YSON.isText(.string("string")))
    }

    func test_isTree_should_identify_tree_objects() {
        let tree = YSONValue.tree(YSONTree(root: YSONTreeNode(type: "doc", children: [])))
        XCTAssertTrue(YSON.isTree(tree))
        XCTAssertFalse(YSON.isTree(.object(["type": .string("NotTree")])))
    }

    func test_isObject_should_identify_plain_objects() {
        XCTAssertTrue(YSON.isObject(.object(["name": .string("Alice")])))
        XCTAssertFalse(YSON.isObject(.text(YSONText(nodes: []))))
        XCTAssertFalse(YSON.isObject(.array([.number(1), .number(2)])))
    }

    // MARK: - Utility functions

    func test_textToString_should_extract_text() {
        let text = YSONText(nodes: [
            YSONTextNode(val: "H"), YSONTextNode(val: "e"), YSONTextNode(val: "l"),
            YSONTextNode(val: "l"), YSONTextNode(val: "o")
        ])
        XCTAssertEqual(YSON.textToString(text), "Hello")
    }

    func test_textToString_should_handle_empty_text() {
        XCTAssertEqual(YSON.textToString(YSONText(nodes: [])), "")
    }

    func test_treeToXML_should_convert_tree_to_xml() {
        let tree = YSONTree(root: YSONTreeNode(type: "doc", children: [
            YSONTreeNode(type: "p", attrs: ["class": "paragraph"], children: [
                YSONTreeNode(type: "text", value: "Hello")
            ])
        ]))
        let xml = YSON.treeToXML(tree)
        XCTAssertTrue(xml.contains("<doc>"))
        XCTAssertTrue(xml.contains("<p class=\"paragraph\">"))
        XCTAssertTrue(xml.contains("<text>Hello</text>"))
    }

    // MARK: - Special scalar types

    func test_should_parse_int_type() throws {
        guard case .object(let obj) = try YSON.parse("{\"value\":Int(42)}") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["value"], .int(42))
    }

    func test_should_parse_negative_int() throws {
        guard case .object(let obj) = try YSON.parse("{\"value\":Int(-42)}") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["value"], .int(-42))
    }

    func test_should_parse_long_type() throws {
        guard case .object(let obj) = try YSON.parse("{\"value\":Long(64)}") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["value"], .long(64))
    }

    func test_should_parse_date_type() throws {
        let dateStr = "2025-01-02T15:04:05.058Z"
        guard case .object(let obj) = try YSON.parse("{\"value\":Date(\"\(dateStr)\")}") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["value"], .date(dateStr))
    }

    func test_should_parse_bindata_type() throws {
        guard case .object(let obj) = try YSON.parse("{\"value\":BinData(\"AQID\")}") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["value"], .binData("AQID"))
    }

    func test_should_parse_counter_with_int() throws {
        guard case .object(let obj) = try YSON.parse("{\"value\":Counter(Int(10))}") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["value"], .counter(.int(10)))
    }

    func test_should_parse_counter_with_long() throws {
        guard case .object(let obj) = try YSON.parse("{\"value\":Counter(Long(100))}") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["value"], .counter(.long(100)))
    }

    func test_should_parse_dedupcounter_with_int() throws {
        guard case .object(let obj) = try YSON.parse("{\"value\":DedupCounter(Int(15),\"AQID\")}") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["value"], .dedupCounter(value: .int(15), registers: "AQID"))
    }

    func test_should_parse_dedupcounter_with_negative_int() throws {
        guard case .object(let obj) = try YSON.parse("{\"value\":DedupCounter(Int(-7),\"base64data\")}") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["value"], .dedupCounter(value: .int(-7), registers: "base64data"))
    }

    func test_isDedupCounter_should_identify_dedupcounter_values() {
        let dc = YSONValue.dedupCounter(value: .int(5), registers: "AQID")
        XCTAssertTrue(YSON.isDedupCounter(dc))
        XCTAssertFalse(YSON.isDedupCounter(.counter(.int(5))))
        XCTAssertFalse(YSON.isDedupCounter(.int(5)))
        XCTAssertFalse(YSON.isDedupCounter(.object(["x": .int(1)])))
    }

    func test_isObject_should_exclude_dedupcounter() {
        let dc = YSONValue.dedupCounter(value: .int(5), registers: "AQID")
        XCTAssertFalse(YSON.isObject(dc))
        XCTAssertTrue(YSON.isObject(.object(["x": .string("y")])))
    }

    func test_should_not_confuse_dedupcounter_with_counter_during_parse() throws {
        // Ensures DedupCounter is handled before Counter in preprocessing so that
        // Counter(Int(10)) inside a DedupCounter literal is not incorrectly consumed.
        let yson = "{\"dc\":DedupCounter(Int(15),\"AQID\"),\"c\":Counter(Int(10))}"
        guard case .object(let obj) = try YSON.parse(yson) else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["dc"], .dedupCounter(value: .int(15), registers: "AQID"))
        XCTAssertEqual(obj["c"], .counter(.int(10)))
    }

    // MARK: - Complex document

    func test_should_parse_document_with_all_types() throws {
        let yson = """
        {
            "str": "value1",
            "num": 42,
            "int": Int(42),
            "long": Long(64),
            "null": null,
            "bool": true,
            "bytes": BinData("AQID"),
            "date": Date("2025-01-02T15:04:05.058Z"),
            "counter": Counter(Int(10)),
            "dedupCounter": DedupCounter(Int(5),"AQID"),
            "text": Text([{"val":"Hello"}]),
            "tree": Tree({"type":"p","children":[{"type":"text","value":"Hello World"}]})
        }
        """
        guard case .object(let obj) = try YSON.parse(yson) else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["str"], .string("value1"))
        XCTAssertEqual(obj["num"], .number(42))
        XCTAssertTrue(YSON.isInt(obj["int"]!))
        XCTAssertTrue(YSON.isLong(obj["long"]!))
        XCTAssertEqual(obj["null"], .null)
        XCTAssertEqual(obj["bool"], .bool(true))
        XCTAssertTrue(YSON.isBinData(obj["bytes"]!))
        XCTAssertTrue(YSON.isDate(obj["date"]!))
        XCTAssertTrue(YSON.isCounter(obj["counter"]!))
        XCTAssertTrue(YSON.isText(obj["text"]!))
        XCTAssertTrue(YSON.isTree(obj["tree"]!))
        XCTAssertTrue(YSON.isDedupCounter(obj["dedupCounter"]!))
    }

    // MARK: - Error handling

    func test_should_throw_on_invalid_json() {
        XCTAssertThrowsError(try YSON.parse("invalid json"))
    }

    func test_should_throw_on_invalid_text_format() {
        XCTAssertThrowsError(try YSON.parse("{\"content\":Text([{\"invalid\":\"node\"}])}"))
    }

    func test_should_throw_on_invalid_tree_format() {
        XCTAssertThrowsError(try YSON.parse("{\"content\":Tree({\"invalid\":\"tree\"})}"))
    }

    func test_should_treat_hand_written_marker_json_as_plain_data() throws {
        // Hand-written JSON in the marker shape never went through the constructor syntax,
        // so since yorkie-js-sdk v0.7.28 (#1545) its `__yson_*` keys are user data, not a
        // DedupCounter, and are not validated as one (a missing `__yson_registers` no longer throws).
        let handWritten = "{\"v\":{\"__yson_type\":\"DedupCounter\",\"__yson_data\":{\"__yson_type\":\"Int\",\"__yson_data\":5}}}"
        XCTAssertEqual(try YSON.parse(handWritten), .object(["v": .object([
            "__yson_type": .string("DedupCounter"),
            "__yson_data": .object(["__yson_type": .string("Int"), "__yson_data": .number(5)])
        ])]))
    }

    // MARK: - Deep nesting (regression: regex depth ceiling)

    func test_should_parse_a_tree_nested_deeper_than_three_levels() throws {
        // given: doc > block > inline > text is already depth four.
        let yson = #"{"c":Tree({"type":"doc","children":[{"type":"block","children":[{"type":"inline","children":[{"type":"text","value":"a"}]}]}]})}"#

        // when
        let result = try YSON.parse(yson)

        // then
        guard case .object(let obj) = result, case .tree(let tree)? = obj["c"] else {
            return XCTFail("expected tree content")
        }
        XCTAssertEqual(YSON.treeToXML(tree), "<doc><block><inline><text>a</text></inline></block></doc>")
    }

    func test_should_parse_a_tree_nested_far_past_four_levels() throws {
        // given: doc > l0 > l1 > ... > l7 > text.
        var node = #"{"type":"text","value":"deep"}"#
        for level in stride(from: 7, through: 0, by: -1) {
            node = "{\"type\":\"l\(level)\",\"children\":[\(node)]}"
        }
        let yson = "{\"c\":Tree({\"type\":\"doc\",\"children\":[\(node)]})}"

        // when
        let result = try YSON.parse(yson)

        // then
        guard case .object(let obj) = result, case .tree(let tree)? = obj["c"] else {
            return XCTFail("expected tree content")
        }
        let xml = YSON.treeToXML(tree)
        XCTAssertTrue(xml.contains("<l0>"))
        XCTAssertTrue(xml.contains("<l7>"))
        XCTAssertTrue(xml.contains("<text>deep</text>"))
    }

    // MARK: - Bracket characters in string values (regression: not string-aware)

    func test_should_parse_a_text_value_with_an_unmatched_closing_bracket() throws {
        // given / when
        let result = try YSON.parse(#"{"c":Text([{"val":"a]b"}])}"#)

        // then
        guard case .object(let obj) = result, case .text(let text)? = obj["c"] else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(text.nodes[0].val, "a]b")
    }

    func test_should_parse_a_text_value_with_an_unmatched_opening_bracket() throws {
        // given / when
        let result = try YSON.parse(#"{"c":Text([{"val":"a[b"}])}"#)

        // then
        guard case .object(let obj) = result, case .text(let text)? = obj["c"] else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(text.nodes[0].val, "a[b")
    }

    func test_should_parse_a_tree_value_with_an_unmatched_closing_brace() throws {
        // given / when
        let result = try YSON.parse(#"{"c":Tree({"type":"doc","children":[{"type":"text","value":"a}b"}]})}"#)

        // then
        guard case .object(let obj) = result, case .tree(let tree)? = obj["c"] else {
            return XCTFail("expected tree content")
        }
        XCTAssertTrue(YSON.treeToXML(tree).contains("a}b"))
    }

    func test_should_parse_a_text_value_containing_a_closing_paren() throws {
        // given / when
        let result = try YSON.parse(#"{"c":Text([{"val":"see f(x))"}])}"#)

        // then
        guard case .object(let obj) = result, case .text(let text)? = obj["c"] else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(text.nodes[0].val, "see f(x))")
    }

    func test_should_parse_a_value_with_an_escaped_quote_adjacent_to_a_bracket() throws {
        // given / when
        let result = try YSON.parse(#"{"c":Text([{"val":"a\"]b"}])}"#)

        // then
        guard case .object(let obj) = result, case .text(let text)? = obj["c"] else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(text.nodes[0].val, "a\"]b")
    }

    func test_should_not_treat_a_constructor_like_substring_inside_a_string_as_a_type() throws {
        // given / when
        let result = try YSON.parse(#"{"c":Text([{"val":"Int(42) and Tree(x)"}])}"#)

        // then
        guard case .object(let obj) = result, case .text(let text)? = obj["c"] else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(text.nodes[0].val, "Int(42) and Tree(x)")
    }

    func test_should_parse_a_dedupcounter_whose_registers_contain_a_comma_and_paren() throws {
        // given / when — the registers string holds both a comma and a closing paren, so a
        // naive split on "," or a paren scan that ignored strings would mis-split the args
        let parsed = try YSON.parse(#"{"v":DedupCounter(Int(15),"a,b)c")}"#)

        // then
        guard case .object(let obj) = parsed else {
            return XCTFail("expected an object but got \(parsed)")
        }
        XCTAssertEqual(obj["v"], .dedupCounter(value: .int(15), registers: "a,b)c"))
    }

    // MARK: - Text and Tree in the same root

    func test_should_parse_a_document_holding_both_text_and_tree_each_with_bracket_content() throws {
        // given
        let yson = #"{"t":Text([{"val":"x]y"}]),"tr":Tree({"type":"doc","children":[{"type":"text","value":"p}q"}]})}"#

        // when
        let result = try YSON.parse(yson)

        // then
        guard case .object(let obj) = result,
              case .text(let text)? = obj["t"],
              case .tree(let tree)? = obj["tr"]
        else {
            return XCTFail("expected text and tree content")
        }
        XCTAssertEqual(text.nodes[0].val, "x]y")
        XCTAssertTrue(YSON.treeToXML(tree).contains("p}q"))
    }

    // MARK: - Error handling (string-aware scanner)

    func test_should_throw_on_constructor_nesting_beyond_the_depth_limit() {
        // given — a syntactically balanced but pathologically deep nest. Each level
        // costs a stack frame in preprocessYSON, and without the bound this crashes
        // the process with SIGSEGV somewhere below 4000 rather than throwing.
        let deep = "{\"v\":" + String(repeating: "Int(", count: 5000) + "5"
            + String(repeating: ")", count: 5000) + "}"

        // when / then
        XCTAssertThrowsError(try YSON.parse(deep)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected YorkieError but got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
            XCTAssertEqual(yorkieError.message, "Failed to parse YSON: YSON constructor nesting deeper than 64")
        }
    }

    func test_should_still_accept_nesting_at_the_depth_limit() throws {
        // given — depth 2 is the deepest shape a real document uses
        // (DedupCounter(Int(n),"…")); confirm the bound does not reject it
        let parsed = try YSON.parse(#"{"v":Counter(Int(10))}"#)

        // then
        guard case .object(let obj) = parsed else {
            return XCTFail("expected an object but got \(parsed)")
        }
        XCTAssertEqual(obj["v"], .counter(.int(10)))
    }

    func test_should_parse_a_string_value_starting_with_a_combining_mark() throws {
        // given — the mark is the FIRST scalar in the literal, so with grapheme-cluster
        // scanning it fuses with the opening quote and the literal is never recognised.
        // Per-keystroke Thai, Hindi and decomposed Vietnamese editing produce exactly this,
        // and the server emits such values raw, so these are real snapshots.
        let cases: [(String, String)] = [
            ("Thai SARA AM", "{\"c\":Text([{\"val\":\"\u{0E33}\"}])}"),
            ("combining acute", "{\"a\":\"\u{0301}x\"}"),
            ("variation selector", "{\"c\":Text([{\"val\":\"\u{FE0F}\"}])}"),
            ("emoji skin tone", "{\"c\":Text([{\"val\":\"\u{1F3FB}\"}])}"),
            ("prepend before the closing quote", "{\"a\":\"x\u{0600}\",\"c\":Int(1)}")
        ]

        // when / then
        for (name, input) in cases {
            XCTAssertNoThrow(try YSON.parse(input), name)
        }
    }

    func test_should_accept_the_integer_boundaries_and_reject_one_past_them() throws {
        // given / when / then — a Double cannot represent Int64.max (it rounds up to
        // 2^63), so a double-based range check rejects the legitimate maximum and
        // compares equal to the first out-of-range value. The bounds use Decimal.
        let accepted: [(String, YSONValue)] = [
            ("{\"v\":Long(9223372036854775807)}", .long(Int64.max)),
            ("{\"v\":Long(-9223372036854775808)}", .long(Int64.min)),
            ("{\"v\":Int(2147483647)}", .int(Int32.max)),
            ("{\"v\":Int(-2147483648)}", .int(Int32.min))
        ]
        for (input, expected) in accepted {
            guard case .object(let obj) = try YSON.parse(input) else {
                return XCTFail("expected an object for \(input)")
            }
            XCTAssertEqual(obj["v"], expected, input)
        }

        for input in ["{\"v\":Long(9223372036854775808)}", "{\"v\":Int(2147483648)}"] {
            XCTAssertThrowsError(try YSON.parse(input), input) { error in
                XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument, input)
            }
        }
    }

    func test_should_reject_a_boolean_constructor_argument() {
        // given / when / then — `as? NSNumber` also matches __NSCFBoolean, so without an
        // explicit check Int(true) would read as 1
        for input in ["{\"v\":Int(true)}", "{\"v\":Long(false)}", "{\"v\":Counter(Int(true))}"] {
            XCTAssertThrowsError(try YSON.parse(input), input) { error in
                XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument, input)
            }
        }
    }

    func test_should_reject_a_non_integral_constructor_argument() {
        // given / when / then — these would otherwise truncate (1.5 -> 1) or wrap
        // (1e10 -> 1410065408) rather than being refused
        for input in ["{\"v\":Int(1.5)}", "{\"v\":Long(2.9)}", "{\"v\":Int(1e10)}"] {
            XCTAssertThrowsError(try YSON.parse(input), input) { error in
                XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument, input)
            }
        }
    }

    func test_should_throw_on_an_unterminated_string_literal() {
        // given / when / then
        XCTAssertThrowsError(try YSON.parse(#"{"c":Text([{"val":"a}])}"#)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected YorkieError but got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
            // The message matters: asserting only the code would also pass against
            // the old regex implementation, where JSONSerialization rejected the
            // untransformed literal with the same code from a different origin.
            XCTAssertEqual(yorkieError.message, "Failed to parse YSON: Text has an unterminated string")
        }
    }

    func test_should_throw_on_unbalanced_parentheses() {
        // given / when / then
        XCTAssertThrowsError(try YSON.parse(#"{"c":Tree({"type":"doc"}"#)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected YorkieError but got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
            // The message matters: asserting only the code would also pass against
            // the old regex implementation, where JSONSerialization rejected the
            // untransformed literal with the same code from a different origin.
            XCTAssertEqual(yorkieError.message, "Failed to parse YSON: Tree has unbalanced parentheses")
        }
    }

    func test_should_throw_on_a_dedupcounter_with_the_wrong_argument_count() {
        // given / when / then
        XCTAssertThrowsError(try YSON.parse(#"{"c":DedupCounter(Int(15))}"#)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected YorkieError but got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
            // The message matters: asserting only the code would also pass against
            // the old regex implementation, where JSONSerialization rejected the
            // untransformed literal with the same code from a different origin.
            XCTAssertEqual(yorkieError.message, "Failed to parse YSON: DedupCounter expects two arguments, got 1")
        }
    }

    // MARK: - Reserved Marker Keys

    // Ports `describe('Reserved Marker Keys')` from yorkie-js-sdk v0.7.28
    // (yorkie-js-sdk#1545): a user key in the `__yson_` namespace must stay plain data
    // rather than be read as a type marker.

    private func parseObject(_ input: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: YSONValue] {
        guard case .object(let object) = try YSON.parse(input) else {
            XCTFail("expected object", file: file, line: line)
            return [:]
        }
        return object
    }

    private var reservedIntObject: YSONValue {
        .object(["x": .object(["__yson_type": .string("Int"), "__yson_data": .number(7)])])
    }

    func test_should_not_read_a_user_key_as_a_type_marker() throws {
        // given / when
        let result = try YSON.parse(#"{"x":{"__yson_type":"Int","__yson_data":7}}"#)

        // then
        XCTAssertEqual(result, self.reservedIntObject)
    }

    func test_should_not_read_a_user_key_as_a_dedupcounter_marker() throws {
        // given / when
        let result = try YSON.parse(
            #"{"x":{"__yson_type":"DedupCounter","__yson_data":{"__yson_type":"Int","__yson_data":1},"__yson_registers":"aGk="}}"#
        )

        // then
        XCTAssertEqual(result, .object(["x": .object([
            "__yson_type": .string("DedupCounter"),
            "__yson_data": .object(["__yson_type": .string("Int"), "__yson_data": .number(1)]),
            "__yson_registers": .string("aGk=")
        ])]))
    }

    func test_should_recognize_a_marker_key_however_it_is_spelled() throws {
        // given / when / then: JSON escapes decode to the reserved keys before any decision is made
        XCTAssertEqual(
            try YSON.parse(#"{"x":{"\u005f_yson_type":"Int","__yson_\u0064ata":7}}"#),
            self.reservedIntObject
        )
        // uppercase hex digits and an escaped trailing character
        XCTAssertEqual(
            try YSON.parse(#"{"x":{"\u005F_yson_typ\u0065":"Int","__yson_dat\u0061":7}}"#),
            self.reservedIntObject
        )
    }

    func test_should_recognize_a_reserved_key_spelled_with_a_backslash_first() throws {
        // given / when: the literal starts with an escape, not with a literal underscore
        let result = try YSON.parse(#"{"x":{"\u005f\u005fyson_type":"Int","__yson_data":7}}"#)

        // then
        XCTAssertEqual(result, self.reservedIntObject)
    }

    func test_should_keep_an_escaped_backslash_key_unchanged() throws {
        // given / when: the literal decodes to the 9-character key `\__yson_a`, which is not reserved
        let result = try YSON.parse(#"{"x":{"\\__yson_a":1}}"#)

        // then
        XCTAssertEqual(result, .object(["x": .object(["\\__yson_a": .number(1)])]))
    }

    func test_should_keep_a_reserved_key_nested_in_an_array_valued_text_attribute() throws {
        // given / when
        let result = try YSON.parse(#"{"t":Text([{"val":"a","attrs":{"k":[{"__yson_type":"b"}]}}])}"#)

        // then: the nested key is user data and survives unescaped
        XCTAssertEqual(result, .object(["t": .text(YSONText(nodes: [
            YSONTextNode(val: "a", attrs: ["k": .array([.object(["__yson_type": .string("b")])])])
        ]))]))
    }

    func test_should_round_trip_a_key_that_collides_with_the_escape_prefix() throws {
        // given / when
        let result = try YSON.parse(#"{"__yson_esc_x":1,"__yson_esc___yson_type":2}"#)

        // then
        XCTAssertEqual(result, .object(["__yson_esc_x": .number(1), "__yson_esc___yson_type": .number(2)]))
    }

    func test_should_keep_a_reserved_key_that_holds_a_constructor() throws {
        // given / when
        let result = try YSON.parse(#"{"__yson_data":Int(3)}"#)

        // then
        XCTAssertEqual(result, .object(["__yson_data": .int(3)]))
    }

    func test_should_leave_a_reserved_name_used_as_a_string_value_alone() throws {
        // given / when
        let result = try YSON.parse(#"{"v":"__yson_type","w":"__yson_esc_a"}"#)

        // then
        XCTAssertEqual(result, .object(["v": .string("__yson_type"), "w": .string("__yson_esc_a")]))
    }

    func test_should_keep_a_reserved_key_in_text_node_attributes() throws {
        // given / when
        let result = try YSON.parse(#"{"t":Text([{"val":"a","attrs":{"__yson_type":"b"}}])}"#)

        // then
        XCTAssertEqual(result, .object(["t": .text(YSONText(nodes: [
            YSONTextNode(val: "a", attrs: ["__yson_type": .string("b")])
        ]))]))
    }

    func test_should_keep_a_reserved_key_in_tree_node_attributes() throws {
        // given / when
        let result = try YSON.parse(#"{"t":Tree({"type":"doc","attrs":{"__yson_type":"b"},"children":[]})}"#)

        // then
        XCTAssertEqual(result, .object(["t": .tree(YSONTree(root: YSONTreeNode(
            type: "doc", attrs: ["__yson_type": "b"], children: []
        )))]))
    }

    func test_should_keep_a_reserved_key_nested_in_a_text_attribute_value() throws {
        // given / when
        let result = try YSON.parse(#"{"t":Text([{"val":"a","attrs":{"k":{"__yson_type":"b"}}}])}"#)

        // then
        XCTAssertEqual(result, .object(["t": .text(YSONText(nodes: [
            YSONTextNode(val: "a", attrs: ["k": .object(["__yson_type": .string("b")])])
        ]))]))
    }

    func test_should_keep_a_reserved_key_nested_in_a_tree_attribute_value() throws {
        // given / when
        let result = try YSON.parse(#"{"t":Tree({"type":"doc","attrs":{"k":[{"__yson_type":"b"}]},"children":[]})}"#)

        // then: the whole attrs are kept, as JS does; the string-valued view is empty
        let root = YSONTreeNode(
            type: "doc",
            rawAttrs: .object(["k": .array([.object(["__yson_type": .string("b")])])]),
            children: []
        )
        XCTAssertEqual(result, .object(["t": .tree(YSONTree(root: root))]))
        XCTAssertEqual(root.attrs, [:])
    }

    func test_should_keep_an_array_valued_attrs_an_array() throws {
        // given / when
        let result = try YSON.parse(#"{"t":Text([{"val":"a","attrs":[{"__yson_type":"b"}]}])}"#)

        // then: the array is kept in rawAttrs, as JS does; the object view is nil
        let node = YSONTextNode(val: "a", rawAttrs: .array([.object(["__yson_type": .string("b")])]))
        XCTAssertEqual(result, .object(["t": .text(YSONText(nodes: [node]))]))
        XCTAssertNil(node.attrs)
    }

    func test_should_keep_a_proto_key_an_own_property_of_an_object() throws {
        // given / when
        let result = try YSON.parse(#"{"x":{"__proto__":{"polluted":true}}}"#)

        // then: a Swift dictionary has no prototype, so this is an ordinary key
        XCTAssertEqual(result, .object(["x": .object(["__proto__": .object(["polluted": .bool(true)])])]))
    }

    func test_should_keep_a_proto_attribute_an_own_property() throws {
        // given / when
        let result = try YSON.parse(#"{"t":Tree({"type":"doc","attrs":{"__proto__":{"polluted":true}},"children":[]})}"#)

        // then
        XCTAssertEqual(result, .object(["t": .tree(YSONTree(root: YSONTreeNode(
            type: "doc",
            rawAttrs: .object(["__proto__": .object(["polluted": .bool(true)])]),
            children: []
        )))]))
    }

    func test_should_keep_a_proto_attribute_with_a_string_value() throws {
        // given / when
        let result = try YSON.parse(#"{"t":Tree({"type":"doc","attrs":{"__proto__":"x"},"children":[]})}"#)

        // then
        XCTAssertEqual(result, .object(["t": .tree(YSONTree(root: YSONTreeNode(
            type: "doc", attrs: ["__proto__": "x"], children: []
        )))]))
    }

    // MARK: Reserved Marker Keys (iOS-specific)

    func test_should_recognize_a_reserved_key_followed_by_whitespace_before_the_colon() throws {
        // given / when
        let result = try YSON.parse("{\"x\":{\"__yson_type\" \n\t\r :\"Int\",\"__yson_data\" :7}}")

        // then
        XCTAssertEqual(result, self.reservedIntObject)
    }

    func test_should_not_escape_a_reserved_name_in_a_constructor_argument() throws {
        // given / when: the string argument is a value, never a key
        let result = try YSON.parse(#"{"d":Date("__yson_type"),"b":BinData("__yson_data")}"#)

        // then
        XCTAssertEqual(result, .object(["d": .date("__yson_type"), "b": .binData("__yson_data")]))
    }

    func test_should_escape_a_reserved_key_inside_a_constructor_argument() throws {
        // given / when
        let result = try YSON.parse(#"{"c":Counter(Int(1)),"t":Text([{"val":"a","attrs":{"__yson_data":1}}])}"#)

        // then
        XCTAssertEqual(result, .object([
            "c": .counter(.int(1)),
            "t": .text(YSONText(nodes: [YSONTextNode(val: "a", attrs: ["__yson_data": .number(1)])]))
        ]))
    }

    func test_should_pass_an_undecodable_reserved_key_through_to_the_parse_error() {
        // given / when / then: a lone surrogate cannot be decoded, so it is left for the JSON parser to reject
        XCTAssertThrowsError(try YSON.parse(#"{"__yson_\ud800":1}"#)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected YorkieError but got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
            XCTAssertTrue(yorkieError.message.hasPrefix("Failed to parse YSON:"), yorkieError.message)
        }
    }

    func test_should_keep_the_last_value_of_a_duplicated_reserved_key_like_any_duplicated_key() throws {
        // given / when
        let reserved = try YSON.parse(#"{"x":{"__yson_type":1,"__yson_type":2}}"#)
        let plain = try YSON.parse(#"{"x":{"k":1,"k":2}}"#)

        // then: escaping must not change duplicate-key handling, and the last value wins as in JS
        XCTAssertEqual(reserved, .object(["x": .object(["__yson_type": .number(2)])]))
        XCTAssertEqual(plain, .object(["x": .object(["k": .number(2)])]))
    }

    func test_should_round_trip_a_reserved_key_with_a_combining_mark() throws {
        // given: "__yson_" followed by U+0301, which merges with the underscore into one grapheme
        let key = "__yson_\u{0301}"

        // when
        let result = try YSON.parse("{\"x\":{\"\(key)\":1}}")

        // then
        XCTAssertEqual(result, .object(["x": .object([key: .number(1)])]))
    }

    func test_should_round_trip_a_document_with_many_reserved_and_plain_keys() throws {
        // given
        let input = #"{"a":1,"__yson_type":"Int","b":2,"__yson_data":7,"c":3,"__yson_registers":"r","d":4,"__yson_esc_x":5,"e":6,"__yson_other":8}"#

        // when
        let result = try self.parseObject(input)

        // then
        XCTAssertEqual(result, [
            "a": .number(1), "b": .number(2), "c": .number(3), "d": .number(4), "e": .number(6),
            "__yson_type": .string("Int"), "__yson_data": .number(7), "__yson_registers": .string("r"),
            "__yson_esc_x": .number(5), "__yson_other": .number(8)
        ])
    }

    // MARK: Attrs of any shape (rawAttrs)

    private func treeRoot(_ input: String, file: StaticString = #filePath, line: UInt = #line) throws -> YSONTreeNode {
        let object = try self.parseObject(input, file: file, line: line)
        guard case .tree(let tree)? = object["t"] else {
            XCTFail("expected a tree", file: file, line: line)
            return YSONTreeNode(type: "")
        }
        return tree.root
    }

    private func textNode(_ input: String, file: StaticString = #filePath, line: UInt = #line) throws -> YSONTextNode {
        let object = try self.parseObject(input, file: file, line: line)
        guard case .text(let text)? = object["t"], let node = text.nodes.first else {
            XCTFail("expected a text node", file: file, line: line)
            return YSONTextNode(val: "")
        }
        return node
    }

    func test_should_keep_every_attribute_of_a_tree_node_with_mixed_value_types() throws {
        // given / when
        let root = try self.treeRoot(#"{"t":Tree({"type":"doc","attrs":{"class":"p","n":1,"on":true,"z":null},"children":[]})}"#)

        // then: rawAttrs is lossless, attrs is the string-valued subset
        XCTAssertEqual(root.rawAttrs, .object([
            "class": .string("p"), "n": .number(1), "on": .bool(true), "z": .null
        ]))
        XCTAssertEqual(root.attrs, ["class": "p"])
    }

    func test_should_parse_all_string_tree_attrs_equal_to_a_node_built_with_the_legacy_init() throws {
        // given / when
        let root = try self.treeRoot(#"{"t":Tree({"type":"p","attrs":{"a":"1","b":"2"},"children":[]})}"#)

        // then: nothing changes for string-only attrs
        XCTAssertEqual(root, YSONTreeNode(type: "p", attrs: ["a": "1", "b": "2"], children: []))
        XCTAssertEqual(root.attrs, ["a": "1", "b": "2"])
        XCTAssertEqual(root.rawAttrs, .object(["a": .string("1"), "b": .string("2")]))
    }

    func test_should_parse_text_attrs_equal_to_a_node_built_with_the_legacy_init() throws {
        // given / when
        let node = try self.textNode(#"{"t":Text([{"val":"a","attrs":{"bold":true}}])}"#)

        // then
        XCTAssertEqual(node, YSONTextNode(val: "a", attrs: ["bold": .bool(true)]))
        XCTAssertEqual(node.attrs, ["bold": .bool(true)])
    }

    func test_should_keep_an_array_valued_attrs_of_a_tree_node() throws {
        // given / when
        let root = try self.treeRoot(#"{"t":Tree({"type":"doc","attrs":[1,"a"],"children":[]})}"#)

        // then
        XCTAssertEqual(root.rawAttrs, .array([.number(1), .string("a")]))
        XCTAssertNil(root.attrs)
    }

    func test_should_drop_attrs_that_are_neither_an_object_nor_an_array() throws {
        // given / when / then: JS keeps only object-typed attrs, so every other shape is dropped
        for attrs in [#""x""#, "5", "true", "null"] {
            let node = try self.textNode(#"{"t":Text([{"val":"a","attrs":\#(attrs)}])}"#)
            XCTAssertNil(node.rawAttrs, "text attrs \(attrs)")
            XCTAssertNil(node.attrs, "text attrs \(attrs)")

            let root = try self.treeRoot(#"{"t":Tree({"type":"doc","attrs":\#(attrs),"children":[]})}"#)
            XCTAssertNil(root.rawAttrs, "tree attrs \(attrs)")
            XCTAssertNil(root.attrs, "tree attrs \(attrs)")
        }
        XCTAssertNil(try self.textNode(#"{"t":Text([{"val":"a"}])}"#).rawAttrs)
        XCTAssertNil(try self.treeRoot(#"{"t":Tree({"type":"doc","children":[]})}"#).rawAttrs)
    }

    func test_should_keep_empty_attrs_objects_and_arrays() throws {
        // given / when / then
        XCTAssertEqual(try self.textNode(#"{"t":Text([{"val":"a","attrs":{}}])}"#).rawAttrs, .object([:]))
        XCTAssertEqual(try self.textNode(#"{"t":Text([{"val":"a","attrs":[]}])}"#).rawAttrs, .array([]))
        XCTAssertEqual(try self.treeRoot(#"{"t":Tree({"type":"doc","attrs":{},"children":[]})}"#).attrs, [:])
        XCTAssertEqual(try self.treeRoot(#"{"t":Tree({"type":"doc","attrs":[],"children":[]})}"#).rawAttrs, .array([]))
    }

    func test_should_unescape_a_reserved_key_of_a_tree_attribute_with_a_non_string_value() throws {
        // given / when
        let root = try self.treeRoot(#"{"t":Tree({"type":"doc","attrs":{"__yson_type":1,"c":"s"},"children":[]})}"#)

        // then
        XCTAssertEqual(root.rawAttrs, .object(["__yson_type": .number(1), "c": .string("s")]))
        XCTAssertEqual(root.attrs, ["c": "s"])
    }

    func test_should_keep_a_reserved_key_nested_in_an_array_valued_attrs_element() throws {
        // given / when
        let node = try self.textNode(#"{"t":Text([{"val":"a","attrs":[{"__yson_type":"b"},[{"__yson_data":1}]]}])}"#)

        // then
        XCTAssertEqual(node.rawAttrs, .array([
            .object(["__yson_type": .string("b")]),
            .array([.object(["__yson_data": .number(1)])])
        ]))
    }

    func test_should_read_a_constructor_in_attrs_position_as_a_plain_object() throws {
        // given / when: JS reads attrs by walking keys only, so the marker is not interpreted
        let node = try self.textNode(#"{"t":Text([{"val":"a","attrs":Int(3)}])}"#)

        // then
        XCTAssertEqual(node.rawAttrs, .object(["__yson_type": .string("Int"), "__yson_data": .number(3)]))
    }

    func test_should_type_a_constructor_inside_an_attrs_object_value() throws {
        // given / when: pre-existing iOS behaviour, kept
        let node = try self.textNode(#"{"t":Text([{"val":"a","attrs":{"k":Int(3)}}])}"#)

        // then
        XCTAssertEqual(node.attrs, ["k": .int(3)])
    }

    func test_should_parse_an_invalid_constructor_in_tree_attrs_keeping_its_raw_value() throws {
        // given / when: the old code parsed this (attrs nil) and JS parses it; it must not throw
        let root = try self.treeRoot(#"{"t":Tree({"type":"p","attrs":{"k":Int(1.5)},"children":[]})}"#)

        // then: the raw marker object is kept, not typed and not dropped
        XCTAssertEqual(root.rawAttrs, .object(["k": .object(["__yson_type": .string("Int"), "__yson_data": .number(1.5)])]))
        XCTAssertEqual(root.attrs, [:])
    }

    func test_should_still_type_a_valid_constructor_in_tree_attrs() throws {
        // given / when
        let root = try self.treeRoot(#"{"t":Tree({"type":"p","attrs":{"k":Int(3),"bad":Long(true),"s":"x"},"children":[]})}"#)

        // then
        guard case .object(let attrs)? = root.rawAttrs else {
            return XCTFail("expected object attrs")
        }
        XCTAssertEqual(attrs["k"], .int(3))
        XCTAssertEqual(attrs["s"], .string("x"))
        XCTAssertNotNil(attrs["bad"])
    }

    func test_should_still_reject_an_invalid_constructor_in_text_attrs() {
        // given / when / then: Text attrs behaviour is unchanged
        XCTAssertThrowsError(try YSON.parse(#"{"t":Text([{"val":"a","attrs":{"k":Int(1.5)}}])}"#))
    }

    func test_should_expose_raw_attrs_of_nodes_built_with_the_legacy_inits() {
        // given / when
        let text = YSONTextNode(val: "a", attrs: ["b": .bool(true)])
        let tree = YSONTreeNode(type: "p", attrs: ["a": "1"])

        // then
        XCTAssertEqual(text.rawAttrs, .object(["b": .bool(true)]))
        XCTAssertEqual(tree.rawAttrs, .object(["a": .string("1")]))
        XCTAssertNil(YSONTextNode(val: "a").rawAttrs)
        XCTAssertNil(YSONTreeNode(type: "p").rawAttrs)
    }

    func test_should_skip_non_string_tree_attrs_when_rendering_xml() throws {
        // given
        let root = try self.treeRoot(#"{"t":Tree({"type":"p","attrs":{"class":"x","n":1,"on":true},"children":[]})}"#)

        // when / then: attributes with no string form are left out of the XML, string ones stay
        XCTAssertEqual(YSON.treeToXML(YSONTree(root: root)), #"<p class="x" />"#)
        XCTAssertEqual(
            YSON.treeToXML(YSONTree(root: YSONTreeNode(type: "p", rawAttrs: .array([.number(1)]), children: []))),
            "<p />"
        )
    }

    // MARK: Duplicated keys (last value wins)

    func test_should_keep_the_last_value_of_a_key_repeated_three_times() throws {
        XCTAssertEqual(try self.parseObject(#"{"k":1,"k":2,"k":3}"#), ["k": .number(3)])
    }

    func test_should_keep_the_last_value_of_a_duplicated_nested_key() throws {
        XCTAssertEqual(try YSON.parse(#"{"a":{"k":1,"k":2}}"#), .object(["a": .object(["k": .number(2)])]))
    }

    func test_should_keep_the_last_value_when_a_duplicate_is_spelled_with_an_escape() throws {
        // given / when
        let result = try self.parseObject(#"{"k":1,"\u006b":2}"#)
        let reversed = try self.parseObject(#"{"\u006b":1,"k":2,"k":3}"#)

        // then
        XCTAssertEqual(result, ["k": .number(2)])
        XCTAssertEqual(reversed, ["k": .number(3)])
    }

    func test_should_not_merge_the_same_key_of_sibling_objects() throws {
        XCTAssertEqual(
            try YSON.parse(#"[{"k":1},{"k":2},{"k":3,"k":4}]"#),
            .array([.object(["k": .number(1)]), .object(["k": .number(2)]), .object(["k": .number(4)])])
        )
    }

    func test_should_keep_the_last_value_of_a_key_repeated_at_different_depths() throws {
        // given / when
        let result = try self.parseObject(#"{"k":{"k":1},"k":{"k":2}}"#)

        // then
        XCTAssertEqual(result, ["k": .object(["k": .number(2)])])
    }

    func test_should_keep_the_last_value_of_a_key_that_reappears_after_a_nested_scope_closed() throws {
        XCTAssertEqual(
            try self.parseObject(#"{"a":1,"o":{"a":9},"a":2}"#),
            ["a": .number(2), "o": .object(["a": .number(9)])]
        )
    }

    func test_should_keep_the_last_value_of_a_duplicated_attrs_key() throws {
        // given / when
        let node = try self.textNode(#"{"t":Text([{"val":"a","attrs":{"b":1,"b":2}}])}"#)
        let root = try self.treeRoot(#"{"t":Tree({"type":"doc","attrs":{"c":"x","c":"y"},"children":[]})}"#)

        // then
        XCTAssertEqual(node.attrs, ["b": .number(2)])
        XCTAssertEqual(root.attrs, ["c": "y"])
    }

    func test_should_keep_the_last_value_of_a_duplicated_node_field() throws {
        // given / when
        let node = try self.textNode(#"{"t":Text([{"val":"a","val":"b"}])}"#)
        let root = try self.treeRoot(#"{"t":Tree({"type":"x","type":"doc","children":[{"type":"a"}],"children":[]})}"#)

        // then
        XCTAssertEqual(node.val, "b")
        XCTAssertEqual(root, YSONTreeNode(type: "doc", children: []))
    }

    func test_should_keep_the_last_value_of_a_duplicated_key_next_to_constructors() throws {
        // given / when / then
        XCTAssertEqual(try self.parseObject(#"{"a":Int(1),"a":Int(2)}"#), ["a": .int(2)])
        XCTAssertEqual(try self.parseObject(#"{"a":Int(1),"a":"s"}"#), ["a": .string("s")])
        XCTAssertEqual(try self.parseObject(#"{"a":"s","a":Int(1)}"#), ["a": .int(1)])
        XCTAssertEqual(try self.parseObject(#"{"a":Counter(Int(1)),"a":Counter(Long(2))}"#), ["a": .counter(.long(2))])
    }

    func test_should_not_validate_a_value_that_a_later_duplicate_overwrote() throws {
        // given / when: JS never looks at the overwritten value either
        let result = try self.parseObject(#"{"a":Int(1.5),"a":2}"#)

        // then
        XCTAssertEqual(result, ["a": .number(2)])
    }

    func test_should_keep_the_last_value_of_a_duplicated_key_inside_a_constructor_argument() throws {
        // given / when
        let object = try self.parseObject(#"{"t":Tree({"type":"doc","children":[{"type":"p","attrs":{"k":"1","k":"2"}}]})}"#)

        // then
        guard case .tree(let tree)? = object["t"] else {
            return XCTFail("expected a tree")
        }
        XCTAssertEqual(tree.root.children?.first?.attrs, ["k": "2"])
    }

    func test_should_keep_a_user_key_in_the_junk_namespace_next_to_a_duplicate() throws {
        // given / when: a key spelled like the internal rename must neither vanish nor be read as junk
        let result = try self.parseObject(#"{"k":1,"__yson_dup_k":7,"k":2,"__yson_dup_k":8}"#)

        // then
        XCTAssertEqual(result, ["k": .number(2), "__yson_dup_k": .number(8)])
    }

    func test_should_keep_the_last_value_of_an_escaped_duplicate_key_in_index_mode() throws {
        // given / when: more than 16 keys, then an escaped spelling of an earlier plain `k`
        let result = try self.parseObject(#"{"f0":0,"f1":0,"f2":0,"f3":0,"f4":0,"f5":0,"f6":0,"f7":0,"f8":0,"f9":0,"f10":0,"f11":0,"f12":0,"f13":0,"f14":0,"f15":0,"f16":0,"f17":0,"f18":0,"f19":0,"k":1,"\u006b":2}"#)

        // then
        XCTAssertEqual(result["k"], .number(2))
        XCTAssertEqual(result.count, 21)
    }

    func test_should_keep_an_escaped_literal_of_the_junk_namespace_as_a_user_key() throws {
        // given / when: `__yson_dup_k` spelled with an escape must survive next to a real duplicate
        let result = try self.parseObject(#"{"k":1,"\u005f_yson_dup_k":7,"k":2}"#)

        // then
        XCTAssertEqual(result, ["k": .number(2), "__yson_dup_k": .number(7)])
    }

    func test_should_keep_the_last_value_of_an_escaped_reserved_key_repeated_three_times() throws {
        // given / when
        let result = try self.parseObject(#"{"x":{"__yson_type":1,"\u005f_yson_type":2,"__yson_type":3}}"#)

        // then
        XCTAssertEqual(result, ["x": .object(["__yson_type": .number(3)])])
    }

    func test_should_keep_a_document_without_duplicates_unchanged() throws {
        // given
        let input = #"{"a":1,"b":{"c":[1,2,{"d":3}],"e":"x"},"f":[{"a":1},{"a":2}],"g":Text([{"val":"v","attrs":{"k":1}}])}"#

        // when / then
        XCTAssertEqual(try self.parseObject(input), [
            "a": .number(1),
            "b": .object(["c": .array([.number(1), .number(2), .object(["d": .number(3)])]), "e": .string("x")]),
            "f": .array([.object(["a": .number(1)]), .object(["a": .number(2)])]),
            "g": .text(YSONText(nodes: [YSONTextNode(val: "v", attrs: ["k": .number(1)])]))
        ])
    }

    func test_should_reject_unbalanced_closers_without_trapping() {
        // given / when / then: the dedup scope stack must tolerate a stray closer
        for input in [#"}{"a":1,"a":2}"#, #"{"a":1}}"#, #"]"#, #"{"a":1,"a":2}]}"#, #"{"a":1,"a":2"#] {
            XCTAssertThrowsError(try YSON.parse(input), input)
        }
    }

    func test_should_pass_an_undecodable_duplicate_key_through_to_the_parse_error() {
        // given / when / then: a lone surrogate cannot be decoded, so dedup is skipped and parsing fails
        XCTAssertThrowsError(try YSON.parse(#"{"\ud800":1,"\ud800":2}"#)) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument)
        }
    }

    func test_should_not_trap_on_very_deep_array_nesting() {
        // given
        let input = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)

        // when / then: parsing or rejecting are both fine, crashing is not
        _ = try? YSON.parse(input)
    }

    func test_should_keep_the_last_value_of_one_key_repeated_a_hundred_thousand_times() throws {
        // given: the shape that made a per-duplicate insert quadratic
        let members = (0 ..< 100_000).map { #""k":\#($0)"# }.joined(separator: ",")

        // when
        let result = try self.parseObject("{\(members)}")

        // then
        XCTAssertEqual(result, ["k": .number(99999)])
    }

    func test_should_keep_the_last_value_of_many_duplicated_keys_in_a_large_document() throws {
        // given: ~5 MB, 50k distinct keys each present twice with different values
        let pad = String(repeating: "x", count: 30)
        let first = (0 ..< 50000).map { #""key_\#($0)":"first_\#(pad)""# }
        let second = (0 ..< 50000).map { #""key_\#($0)":"last_\#($0)_\#(pad)""# }
        let input = "{" + (first + second).joined(separator: ",") + "}"
        XCTAssertGreaterThan(input.utf8.count, 4_500_000)

        // when
        let result = try self.parseObject(input)

        // then
        XCTAssertEqual(result.count, 50000)
        XCTAssertEqual(result["key_0"], .string("last_0_\(pad)"))
        XCTAssertEqual(result["key_49999"], .string("last_49999_\(pad)"))
        XCTAssertEqual(result["key_1234"], .string("last_1234_\(pad)"))
    }
}
