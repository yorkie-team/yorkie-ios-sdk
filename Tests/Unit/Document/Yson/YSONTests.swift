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
}
