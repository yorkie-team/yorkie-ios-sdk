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

// Ports yorkie-js-sdk 0.7.27 (#1524):
//   packages/sdk/test/unit/document/tree_style_path_bounds_test.ts
//
// Runs locally without a server: a single Document whose changes stay in-process.

import XCTest
@testable import Yorkie

final class TreeStylePathBoundsTests: XCTestCase {
    private let initialXML = "<root><p><t>ab</t></p><p></p></root>"
    private let initialTextXML = "<root><p>ab</p><p>cd</p></root>"

    /// Builds `<root><p><t>ab</t></p><p></p></root>`.
    @MainActor
    private func setup() throws -> Document {
        let doc = Document(key: "tree-style-path-bounds")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "root", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "t", children: [JSONTreeTextNode(value: "ab")])
                    ]),
                    JSONTreeElementNode(type: "p", children: [])
                ])
            )
        }
        return doc
    }

    /// Builds `<root><p>ab</p><p>cd</p></root>`.
    @MainActor
    private func setupText() throws -> Document {
        let doc = Document(key: "tree-style-path-bounds-text")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "root", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                ])
            )
        }
        return doc
    }

    @MainActor
    private func xml(_ doc: Document) -> String? {
        (doc.getRoot().t as? JSONTree)?.toXML()
    }

    @MainActor
    private func assertInvalidArgument(_ doc: Document,
                                       file: StaticString = #filePath,
                                       line: UInt = #line,
                                       _ body: @escaping (JSONTree) throws -> Void)
    {
        XCTAssertThrowsError(try doc.update { root, _ in
            try body(root.t as! JSONTree)
        }, file: file, line: line) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument, file: file, line: line)
        }
    }

    // MARK: - styleByPath with a path that names no node

    @MainActor
    func test_styles_the_node_at_an_existing_path() throws {
        let doc = try setup()
        try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([0, 0], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), "<root><p><t bold=\"true\">ab</t></p><p></p></root>")
    }

    @MainActor
    func test_styles_the_element_at_a_top_level_path() throws {
        let doc = try setup()
        try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([1], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), "<root><p><t>ab</t></p><p bold=\"true\"></p></root>")
    }

    @MainActor
    func test_rejects_the_first_child_path_of_an_empty_element() throws {
        let doc = try setup()
        self.assertInvalidArgument(doc) { try $0.styleByPath([1, 0], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialXML)
    }

    @MainActor
    func test_rejects_the_path_one_past_the_last_child() throws {
        let doc = try setup()
        self.assertInvalidArgument(doc) { try $0.styleByPath([0, 1], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialXML)
    }

    @MainActor
    func test_rejects_the_top_level_path_one_past_the_last_element() throws {
        let doc = try setup()
        self.assertInvalidArgument(doc) { try $0.styleByPath([2], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialXML)
    }

    @MainActor
    func test_keeps_rejecting_paths_further_out_of_range() throws {
        let doc = try setup()
        self.assertInvalidArgument(doc) { try $0.styleByPath([1, 5], ["bold": true]) }
        self.assertInvalidArgument(doc) { try $0.styleByPath([0, 3], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialXML)
    }

    @MainActor
    func test_rejects_a_negative_path_element() throws {
        let doc = try setup()
        self.assertInvalidArgument(doc) { try $0.styleByPath([-1], ["bold": true]) }
        self.assertInvalidArgument(doc) { try $0.styleByPath([0, -1], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialXML)
    }

    @MainActor
    func test_leaves_the_range_form_alone() throws {
        let doc = try setup()
        try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([0], [1], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), "<root><p bold=\"true\"><t bold=\"true\">ab</t></p><p></p></root>")
    }

    // MARK: - text-only parent

    @MainActor
    func test_rejects_the_offset_one_past_the_last_character() throws {
        let doc = try setupText()
        self.assertInvalidArgument(doc) { try $0.styleByPath([0, 2], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialTextXML)
    }

    @MainActor
    func test_rejects_an_offset_further_past_the_last_character() throws {
        let doc = try setupText()
        self.assertInvalidArgument(doc) { try $0.styleByPath([0, 3], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialTextXML)
    }

    @MainActor
    func test_rejects_a_negative_character_offset() throws {
        let doc = try setupText()
        self.assertInvalidArgument(doc) { try $0.styleByPath([0, -1], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialTextXML)
    }

    @MainActor
    func test_accepts_an_offset_that_names_a_character() throws {
        let doc = try setupText()
        try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([0, 0], ["bold": true]) }
        try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([0, 1], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialTextXML)
    }

    @MainActor
    func test_still_styles_the_elements_themselves() throws {
        let doc = try setupText()
        try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([1], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), "<root><p>ab</p><p bold=\"true\">cd</p></root>")
    }

    // MARK: - negative element in every path API

    @MainActor
    func test_rejects_a_negative_element_in_the_single_path_style_form() throws {
        let doc = try setup()
        self.assertInvalidArgument(doc) { try $0.styleByPath([0, -1], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialXML)
    }

    @MainActor
    func test_rejects_a_negative_element_in_the_range_style_form() throws {
        let doc = try setup()
        self.assertInvalidArgument(doc) { try $0.styleByPath([-1], [1], ["bold": true]) }
        self.assertInvalidArgument(doc) { try $0.styleByPath([0, -1], [0, 0], ["bold": true]) }
        XCTAssertEqual(self.xml(doc), self.initialXML)
    }

    @MainActor
    func test_rejects_a_negative_element_in_removeStyleByPath() throws {
        let doc = try setup()
        try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([0, 0], ["bold": true]) }
        let styled = "<root><p><t bold=\"true\">ab</t></p><p></p></root>"
        self.assertInvalidArgument(doc) { try $0.removeStyleByPath([0, -1], [0, 0], ["bold"]) }
        XCTAssertEqual(self.xml(doc), styled)
    }

    @MainActor
    func test_rejects_a_negative_element_in_splitByPath() throws {
        let doc = try setupText()
        self.assertInvalidArgument(doc) { try $0.splitByPath([0, -1]) }
        XCTAssertEqual(self.xml(doc), self.initialTextXML)
    }

    @MainActor
    func test_rejects_a_negative_element_in_mergeByPath() throws {
        let doc = try setup()
        self.assertInvalidArgument(doc) { try $0.mergeByPath([-1]) }
        XCTAssertEqual(self.xml(doc), self.initialXML)
    }

    @MainActor
    func test_rejects_a_negative_element_in_editByPath() throws {
        let doc = try setupText()
        self.assertInvalidArgument(doc) { _ = try $0.editByPath([0, -1], [0, 1]) }
        XCTAssertEqual(self.xml(doc), self.initialTextXML)
    }

    @MainActor
    func test_rejects_a_negative_element_in_editBulkByPath() throws {
        let doc = try setupText()
        self.assertInvalidArgument(doc) { _ = try $0.editBulkByPath([0, -1], [0, 1], []) }
        XCTAssertEqual(self.xml(doc), self.initialTextXML)
    }

    @MainActor
    func test_rejects_a_negative_element_in_pathToIndex() throws {
        let doc = try setup()
        let tree = try XCTUnwrap(doc.getRoot().t as? JSONTree)
        for path in [[0, -1], [-1]] {
            XCTAssertThrowsError(try tree.pathToIndex(path)) { error in
                XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument)
            }
        }
    }
}
