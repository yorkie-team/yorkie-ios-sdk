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

// Ports: packages/sdk/test/integration/tree_test.ts, describe
// "Tree.splitByPath/mergeByPath" (yorkie-js-sdk#1358, commit 9c15ab29,
// "Stop splitByPath and mergeByPath from copying content").
//
// Both helpers used to lower a structural change into a delete plus an
// insert of a value copy, which a concurrent operation could never have
// seen. They now route through `edit`: `splitByPath` becomes an empty edit
// with split level 1, `mergeByPath` an empty edit across the boundary. Both
// reject the paths they cannot act on. These cases cover what they do, the
// paths each refuses, and the tombstones the old copy used to leave behind.
//
// All tests run locally without a server because they use a single Document
// whose changes stay in-process (no client attach / sync needed); the
// concurrency coverage from the companion
// `tree_concurrent_split_merge_test.ts` lives in
// `Tests/Integration/TreeIntegrationTests.swift` instead, since it needs two
// attached clients.

import XCTest
@testable import Yorkie

final class TreeSplitMergeByPathTests: XCTestCase {
    /// `docWithTwoSpans` returns a document holding
    /// `<doc><p><span>abc</span><span>de</span></p></doc>`.
    @MainActor
    private func docWithTwoSpans(key: String = "tree-split-merge-\(UUID().uuidString)") throws -> Document {
        let doc = Document(key: key)

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "span", children: [JSONTreeTextNode(value: "abc")]),
                        JSONTreeElementNode(type: "span", children: [JSONTreeTextNode(value: "de")])
                    ])
                ])
            )
        }

        return doc
    }

    /// Mirrors JS: "Can split a text position and a child position"
    @MainActor
    func test_can_split_a_text_position_and_a_child_position() throws {
        // given
        let doc = try self.docWithTwoSpans()

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.splitByPath([0, 0, 1])
        }

        // then
        XCTAssertEqual((doc.getRoot().t as? JSONTree)?.toXML(), "<doc><p><span>a</span><span>bc</span><span>de</span></p></doc>")

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.splitByPath([0, 1])
        }

        // then
        XCTAssertEqual((doc.getRoot().t as? JSONTree)?.toXML(), "<doc><p><span>a</span></p><p><span>bc</span><span>de</span></p></doc>")
    }

    /// Mirrors JS: "Can merge a boundary back together"
    @MainActor
    func test_can_merge_a_boundary_back_together() throws {
        // given
        let doc = try self.docWithTwoSpans()

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.mergeByPath([0, 1])
        }

        // then
        XCTAssertEqual((doc.getRoot().t as? JSONTree)?.toXML(), "<doc><p><span>abcde</span></p></doc>")
    }

    /// Mirrors JS: "Should not leave garbage content behind"
    ///
    /// Neither helper copies content any more, so neither leaves a tombstone
    /// holding a copy of it. A split removes nothing at all; a merge removes
    /// only the two boundary nodes, which carry no data of their own.
    @MainActor
    func test_should_not_leave_garbage_content_behind() throws {
        // given
        let doc = try self.docWithTwoSpans()

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.splitByPath([0, 0, 1])
        }

        // then
        var gc = doc.getDocSize().gc
        XCTAssertEqual(gc.data, 0)
        XCTAssertEqual(gc.meta, 0)

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.mergeByPath([0, 1])
        }

        // then
        gc = doc.getDocSize().gc
        XCTAssertEqual(gc.data, 0)
    }

    /// Mirrors JS: "Should throw on empty paths for splitByPath and mergeByPath"
    @MainActor
    func test_should_throw_on_empty_paths_for_split_by_path_and_merge_by_path() throws {
        // given
        let doc = try self.docWithTwoSpans()

        // when / then
        XCTAssertThrowsError(
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.splitByPath([])
            }
        ) { error in
            let yorkieError = error as? YorkieError
            XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
            XCTAssertEqual(yorkieError?.message, "path should not be empty")
        }

        XCTAssertThrowsError(
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.mergeByPath([])
            }
        ) { error in
            let yorkieError = error as? YorkieError
            XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
            XCTAssertEqual(yorkieError?.message, "path should not be empty")
        }
    }

    /// Mirrors JS: "Should throw when splitByPath targets the root"
    ///
    /// A split needs a parent to hold the two halves, and the root has none.
    /// Without the guard this pushes an operation that changes nothing.
    @MainActor
    func test_should_throw_when_split_by_path_targets_the_root() throws {
        // given
        let doc = try self.docWithTwoSpans()

        // when / then
        for path in [[0], [1]] {
            XCTAssertThrowsError(
                try doc.update { root, _ in
                    try (root.t as? JSONTree)?.splitByPath(path)
                }
            ) { error in
                let yorkieError = error as? YorkieError
                XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
                XCTAssertEqual(yorkieError?.message, "the root node cannot be split")
            }
        }

        XCTAssertEqual((doc.getRoot().t as? JSONTree)?.toXML(), "<doc><p><span>abc</span><span>de</span></p></doc>")
    }

    /// Mirrors JS: "Should throw when splitByPath targets text held by the root"
    ///
    /// The position resolves to a text node, so the node that would split is
    /// its parent — the root again.
    @MainActor
    func test_should_throw_when_split_by_path_targets_text_held_by_the_root() throws {
        // given
        let doc = Document(key: "tree-split-text-held-by-root-\(UUID().uuidString)")

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [JSONTreeTextNode(value: "abcde")])
            )
        }

        // when / then
        XCTAssertThrowsError(
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.splitByPath([2])
            }
        ) { error in
            let yorkieError = error as? YorkieError
            XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
            XCTAssertEqual(yorkieError?.message, "the root node cannot be split")
        }

        XCTAssertEqual((doc.getRoot().t as? JSONTree)?.toXML(), "<doc>abcde</doc>")
    }

    /// Mirrors JS: "Should throw when mergeByPath targets a first child"
    ///
    /// There is no left sibling to merge into. Reading one off the end of the
    /// children used to raise a TypeError instead.
    @MainActor
    func test_should_throw_when_merge_by_path_targets_a_first_child() throws {
        // given
        let doc = try self.docWithTwoSpans()

        // when / then
        for path in [[0, 0], [0]] {
            XCTAssertThrowsError(
                try doc.update { root, _ in
                    try (root.t as? JSONTree)?.mergeByPath(path)
                }
            ) { error in
                let yorkieError = error as? YorkieError
                XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
                XCTAssertEqual(yorkieError?.message, "the first child cannot be merged")
            }
        }
    }

    /// Mirrors JS: "Should throw when mergeByPath targets a text position"
    @MainActor
    func test_should_throw_when_merge_by_path_targets_a_text_position() throws {
        // given
        let doc = try self.docWithTwoSpans()

        // when / then
        XCTAssertThrowsError(
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.mergeByPath([0, 0, 1])
            }
        ) { error in
            let yorkieError = error as? YorkieError
            XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
            XCTAssertEqual(yorkieError?.message, "text node cannot be merged")
        }
    }
}
