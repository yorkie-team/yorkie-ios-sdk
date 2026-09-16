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

    func test_should_throw_on_dedupcounter_missing_registers() {
        // Manually crafted JSON that bypasses preprocessing — __yson_registers is absent.
        let malformed = "{\"v\":{\"__yson_type\":\"DedupCounter\",\"__yson_data\":{\"__yson_type\":\"Int\",\"__yson_data\":5}}}"
        XCTAssertThrowsError(try YSON.parse(malformed))
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
            XCTAssertEqual(yorkieError.message, "Failed to parse YSON: unterminated string literal")
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
            XCTAssertEqual(yorkieError.message, "Failed to parse YSON: unbalanced parentheses in YSON")
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
            XCTAssertEqual(yorkieError.message, "Failed to parse YSON: DedupCounter expects a value and a registers argument")
        }
    }
}
