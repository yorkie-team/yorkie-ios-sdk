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

// Ports the range-based styleByPath / removeStyleByPath test cases from
// yorkie-js-sdk 0.7.3 (#1198):
//   .doc/js-0.7.3/tests/tree_test_styleByPath_additions.ts
//
// All tests run locally without a server because they use a single Document
// whose changes stay in-process (no client attach / sync needed).

import XCTest
@testable import Yorkie

final class TreeStyleByPathTests: XCTestCase {
    // MARK: - styleByPath range

    /// Mirrors JS: "Can style a range by path"
    ///
    /// styleByPath([0], [2], { color: "red" }) styles both paragraph elements.
    @MainActor
    func test_can_style_a_range_by_path() throws {
        // given
        let doc = Document(key: "tree-style-range-1")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "a")],
                                        attributes: ["weight": "bold"]),
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "b")])
                ])
            )
        }

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.styleByPath([0], [2], ["color": "red"])
        }

        // then
        let xml = (doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(xml, "<doc><p color=\"red\" weight=\"bold\">a</p><p color=\"red\">b</p></doc>")
    }

    /// Mirrors JS: "Can style multiple elements across a range by path"
    ///
    /// styleByPath([0], [2], { bold: "true" }) applies to both paragraphs.
    @MainActor
    func test_can_style_multiple_elements_across_a_range_by_path() throws {
        // given
        let doc = Document(key: "tree-style-range-2")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "cd")])
                ])
            )
        }

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.styleByPath([0], [2], ["bold": "true"])
        }

        // then
        let xml = (doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(xml, "<doc><p bold=\"true\">ab</p><p bold=\"true\">cd</p></doc>")
    }

    /// Mirrors JS: "Can style single element by path (backward compat)"
    ///
    /// The single-path overload styleByPath([0], { bold: "true" }) still works.
    @MainActor
    func test_can_style_single_element_by_path_backward_compat() throws {
        // given
        let doc = Document(key: "tree-style-single-compat")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "hello")])
                ])
            )
        }

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.styleByPath([0], ["bold": "true"])
        }

        // then
        let xml = (doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(xml, "<doc><p bold=\"true\">hello</p></doc>")
    }

    // MARK: - removeStyleByPath range

    /// Mirrors JS: "Can remove style by path"
    ///
    /// removeStyleByPath([0], [2], ["italic"]) removes italic from both paragraphs.
    @MainActor
    func test_can_remove_style_by_path() throws {
        // given
        let doc = Document(key: "tree-remove-style-range-1")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "a")],
                                        attributes: ["bold": "true", "italic": "true"]),
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "b")],
                                        attributes: ["bold": "true", "italic": "true"])
                ])
            )
        }

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.removeStyleByPath([0], [2], ["italic"])
        }

        // then
        let xml = (doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(xml, "<doc><p bold=\"true\">a</p><p bold=\"true\">b</p></doc>")
    }

    /// Mirrors JS: "Can remove style from multiple elements across a range by path"
    ///
    /// removeStyleByPath([0], [2], ["bold"]) strips bold from both paragraphs.
    @MainActor
    func test_can_remove_style_from_multiple_elements_across_a_range_by_path() throws {
        // given
        let doc = Document(key: "tree-remove-style-range-2")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "ab")],
                                        attributes: ["bold": "true"]),
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "cd")],
                                        attributes: ["bold": "true"])
                ])
            )
        }

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.removeStyleByPath([0], [2], ["bold"])
        }

        // then
        let xml = (doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(xml, "<doc><p>ab</p><p>cd</p></doc>")
    }

    // MARK: - Validation errors — styleByPath

    /// Mirrors JS: "Should throw on mismatched path lengths for range styleByPath"
    ///
    /// styleByPath([0], [0, 0], ...) must throw because the path lengths differ (1 vs 2).
    @MainActor
    func test_should_throw_on_mismatched_path_lengths_for_range_style_by_path() throws {
        // given
        let doc = Document(key: "tree-style-path-length-mismatch")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "a")])
                ])
            )
        }

        // when / then
        XCTAssertThrowsError(
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.styleByPath([0], [0, 0], ["bold": "true"])
            }
        ) { error in
            let yorkieError = error as? YorkieError
            XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
        }
    }

    /// Mirrors JS: "Should throw on empty paths for styleByPath"
    ///
    /// styleByPath([], [], ...) must throw because paths are empty.
    @MainActor
    func test_should_throw_on_empty_paths_for_style_by_path() throws {
        // given
        let doc = Document(key: "tree-style-empty-paths")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "a")])
                ])
            )
        }

        // when / then
        XCTAssertThrowsError(
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.styleByPath([], [], ["bold": "true"])
            }
        ) { error in
            let yorkieError = error as? YorkieError
            XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
        }
    }

    // MARK: - Validation errors — removeStyleByPath

    /// Mirrors JS: "Should throw on mismatched path lengths for removeStyleByPath"
    ///
    /// removeStyleByPath([0], [0, 0], ...) must throw because the path lengths differ.
    @MainActor
    func test_should_throw_on_mismatched_path_lengths_for_remove_style_by_path() throws {
        // given
        let doc = Document(key: "tree-remove-style-path-length-mismatch")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "a")],
                                        attributes: ["bold": "true"])
                ])
            )
        }

        // when / then
        XCTAssertThrowsError(
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.removeStyleByPath([0], [0, 0], ["bold"])
            }
        ) { error in
            let yorkieError = error as? YorkieError
            XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
        }
    }

    /// Mirrors JS: "Should throw on empty paths for removeStyleByPath"
    ///
    /// removeStyleByPath([], [], ...) must throw because paths are empty.
    @MainActor
    func test_should_throw_on_empty_paths_for_remove_style_by_path() throws {
        // given
        let doc = Document(key: "tree-remove-style-empty-paths")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [JSONTreeTextNode(value: "a")],
                                        attributes: ["bold": "true"])
                ])
            )
        }

        // when / then
        XCTAssertThrowsError(
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.removeStyleByPath([], [], ["bold"])
            }
        ) { error in
            let yorkieError = error as? YorkieError
            XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
        }
    }

    /// Exercises the `[String: Any]` range overload (the dictionary-literal tests above resolve to
    /// the `Codable` overload). An explicitly-typed `[String: Any]` routes through
    /// `styleByPathRangeInternal` via `stringValueTypeDictionary`.
    @MainActor
    func test_can_style_a_range_by_path_with_string_any_attributes() throws {
        // given
        let doc = Document(key: "tree-style-range-stringany")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "a")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "b")])
                ])
            )
        }

        // when
        let attributes: [String: Any] = ["color": "red"]
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.styleByPath([0], [2], attributes)
        }

        // then
        let xml = (doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(xml, "<doc><p color=\"red\">a</p><p color=\"red\">b</p></doc>")
    }
}
