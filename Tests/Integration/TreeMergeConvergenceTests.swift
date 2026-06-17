/*
 * Copyright 2024 The Yorkie Authors. All rights reserved.
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

// Integration tests for Tree merge/split convergence fixes ported from
// yorkie-js-sdk v0.7.4 (PRs #1202-1206, #1210, #1211).
// These tests require a running yorkie server at http://localhost:8080.

import XCTest
@testable @preconcurrency import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

// MARK: - Overlapping range

final class TreeOverlappingMergeConvergenceTests: XCTestCase {
    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent overlapping range)
    // — overlapping-merge-and-merge (was skipped in v0.7.3).
    @MainActor
    func test_overlapping_merge_and_merge() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "a")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "b")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "c")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>c</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>c</p></r>")

            // when — d1 merges p1+p2, d2 merges p2+p3 concurrently
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 4) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(5, 7) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>c</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>bc</p></r>")

            // then — both converge
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>abc</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>abc</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent overlapping range)
    // — overlapping-merge-and-delete-element-node (was skipped in v0.7.3).
    @MainActor
    func test_overlapping_merge_and_delete_element_node() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "a")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "b")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p></r>")

            // when — d1 merges p1+p2, d2 deletes content of p2 and its closing tag
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 4) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(3, 6) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent overlapping range)
    // — overlapping-merge-and-delete-text-nodes (was skipped in v0.7.3).
    @MainActor
    func test_overlapping_merge_and_delete_text_nodes() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "a")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "bcde")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>bcde</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>bcde</p></r>")

            // when — d1 merges p1+p2, d2 deletes "bc" in p2
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 4) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(4, 6) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>abcde</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>de</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ade</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ade</p></r>")
        }
    }
}

// MARK: - Contained range

final class TreeContainedMergeConvergenceTests: XCTestCase {
    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, contained range)
    // — contained-split-and-split-at-different-levels (was skipped in v0.7.3).
    @MainActor
    func test_contained_split_and_split_at_different_levels() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — <r><p><p>ab</p><p>c</p></p></r>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "c")])
                    ])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p><p>ab</p><p>c</p></p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p><p>ab</p><p>c</p></p></r>")

            // when — d1 splits inner p at a|b (level 1), d2 splits outer p at level 1
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(3, 3, nil, 1) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(5, 5, nil, 1) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p><p>a</p><p>b</p><p>c</p></p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p><p>ab</p></p><p><p>c</p></p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), (d2.getRoot().t as? JSONTree)?.toXML())
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p><p>a</p><p>b</p></p><p><p>c</p></p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, contained range)
    // — contained-split-and-delete-contents-in-split-node (was skipped in v0.7.3).
    @MainActor
    func test_contained_split_and_delete_contents_in_split_node() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p></r>")

            // when — d1 splits at a|b, d2 deletes "b"
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 2, nil, 1) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(2, 3) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p></p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p></p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, contained range)
    // — contained-split-and-delete-the-whole-original-and-split-nodes (was skipped in v0.7.3).
    @MainActor
    func test_contained_split_and_delete_the_whole_original_and_split_nodes() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p></r>")

            // when — d1 splits at a|b, d2 deletes the whole tree content
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 2, nil, 1) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(0, 4) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, contained range)
    // — contained-merge-and-merge-at-the-same-level (was skipped in v0.7.3).
    @MainActor
    func test_contained_merge_and_merge_at_the_same_level() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "a")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "b")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "c")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>c</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>c</p></r>")

            // when — d1 merges all three paragraphs, d2 merges only p2+p3
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 7) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(5, 7) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ac</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>bc</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ac</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ac</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, contained range)
    // — contained-merge-and-insert (was skipped in v0.7.3).
    @MainActor
    func test_contained_merge_and_insert() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "a")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "b")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p></r>")

            // when — d1 merges p1+p2, d2 inserts "c" before "b" in p2
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 4) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(4, 4, JSONTreeTextNode(value: "c")) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>cb</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>acb</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>acb</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, contained range)
    // — contained-merge-and-delete-contents-in-merged-node (was skipped in v0.7.3).
    @MainActor
    func test_contained_merge_and_delete_contents_in_merged_node() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "a")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "bc")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>bc</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>bc</p></r>")

            // when — d1 merges p1+p2, d2 deletes "b" from p2
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 4) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(4, 5) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>abc</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>c</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ac</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ac</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, contained range)
    // — contained-split-and-merge-same-block (new in v0.7.4; regression for #1726).
    // When one client splits inside a block that the other client merges, replicas must converge.
    @MainActor
    func test_contained_split_and_merge_same_block() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>cd</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>cd</p></r>")

            // when — d1 splits first paragraph at a|b, d2 merges both paragraphs
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 2, nil, 1) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(3, 5) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>cd</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>abcd</p></r>")

            // then — both replicas converge
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), (d2.getRoot().t as? JSONTree)?.toXML())
        }
    }
}

// MARK: - Side by side range

final class TreeSideBySideMergeConvergenceTests: XCTestCase {
    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — side-by-side-split-and-insert (was skipped in v0.7.3).
    @MainActor
    func test_side_by_side_split_and_insert() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p></r>")

            // when — d1 splits at a|b, d2 inserts a new paragraph after the current one
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 2, nil, 1) }
            try d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(4, 4, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "c")]))
            }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>c</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>c</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>c</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — side-by-side-split-and-delete (was skipped in v0.7.3).
    @MainActor
    func test_side_by_side_split_and_delete() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "c")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>c</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>c</p></r>")

            // when — d1 splits at a|b, d2 deletes p2 entirely
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 2, nil, 1) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(4, 7) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>c</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — cascade-delete-across-parent-after-multi-level-split (new in v0.7.4).
    @MainActor
    func test_cascade_delete_across_parent_after_multi_level_split() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — nested structure <r><p><p>ab</p><p>cd</p></p></r>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                    ])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 splits at level 2, d2 deletes a wide range
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(3, 3, nil, 2) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(1, 6) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p><p>a</p></p><p><p>b</p><p>cd</p></p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>cd</p></r>")

            // then — both replicas converge
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), (d2.getRoot().t as? JSONTree)?.toXML())
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>cd</p><p></p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — sequential-merge-then-split (new in v0.7.4).
    @MainActor
    func test_sequential_merge_then_split() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 merges both paragraphs (sequential, no concurrency)
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(3, 5) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>abcd</p></r>")

            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>abcd</p></r>")

            // d2 splits the merged content at ab|cd (sequential, knows about merge)
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(3, 3, nil, 1) }
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>cd</p></r>")

            // then — both replicas converge
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), (d2.getRoot().t as? JSONTree)?.toXML())
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>cd</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — multi-level-split-with-concurrent-merge-and-text-split (new in v0.7.4).
    @MainActor
    func test_multi_level_split_with_concurrent_merge_and_text_split() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — nested structure
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                    ])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when — concurrent split at level 2 and wide delete
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(3, 3, nil, 2) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(1, 6) }

            // then — both replicas converge
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), (d2.getRoot().t as? JSONTree)?.toXML())
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — split-with-concurrent-delete-overlapping-content (new in v0.7.4).
    // Fixed by Fix 9: skip merge for concurrent elements in collectBetween.
    @MainActor
    func test_split_with_concurrent_delete_overlapping_content() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>abcd</p></r>")

            // when — d1 deletes "bc", d2 splits <p> at position 3 (b|c)
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 4) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(3, 3, nil, 1) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ad</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>cd</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), (d2.getRoot().t as? JSONTree)?.toXML())
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>d</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — merge-with-concurrent-content-delete (new in v0.7.4).
    @MainActor
    func test_merge_with_concurrent_content_delete() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 deletes "b" (boundary only), d2 merges both paragraphs
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 3) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(3, 5) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>cd</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>abcd</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), (d2.getRoot().t as? JSONTree)?.toXML())
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>acd</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — merge-with-concurrent-full-content-delete-in-source (new in v0.7.4).
    @MainActor
    func test_merge_with_concurrent_full_content_delete_in_source() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 deletes "cd" from p2, d2 merges both paragraphs
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(5, 7) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(3, 5) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p></p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>abcd</p></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), (d2.getRoot().t as? JSONTree)?.toXML())
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — side-by-side-merge-and-merge (second instance added in v0.7.4, with 4 paragraphs).
    @MainActor
    func test_side_by_side_merge_and_merge_four_paragraphs() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — 4 paragraphs
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "a")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "b")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "c")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "d")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>c</p><p>d</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>c</p><p>d</p></r>")

            // when — d1 merges p1+p2, d2 merges p3+p4 concurrently
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(2, 4) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(8, 10) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>c</p><p>d</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>a</p><p>b</p><p>cd</p></r>")

            // then — both converge
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>cd</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p>ab</p><p>cd</p></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — concurrent-delete-after-merge-with-nested-content (new in v0.7.4).
    @MainActor
    func test_concurrent_delete_after_merge_with_nested_content() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — <r><p><b>a</b></p><p><b>b</b></p></r>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "b", children: [JSONTreeTextNode(value: "a")])
                    ]),
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "b", children: [JSONTreeTextNode(value: "b")])
                    ])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p><b>a</b></p><p><b>b</b></p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p><b>a</b></p><p><b>b</b></p></r>")

            // when — d1 merges p1+p2, d2 deletes everything
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(4, 6) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(0, 10) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r><p><b>a</b><b>b</b></p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r></r>")

            // then
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), /* html */ "<r></r>")
        }
    }

    // Ported from yorkie-js-sdk v0.7.4: Tree.edit(concurrent, side by side range)
    // — delete-starting-inside-merge-target (new in v0.7.4).
    // After sync: merged children (text_c) should be deleted because C2's delete range covers them.
    @MainActor
    func test_delete_starting_inside_merge_target() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "c")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), "<r><p>ab</p><p>c</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), "<r><p>ab</p><p>c</p></r>")

            // when — d1 merges p1+p2, d2 deletes from after "b" through end of tree
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(3, 5) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(3, 7) }
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), "<r><p>abc</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), "<r><p>ab</p></r>")

            // then — merged children (text_c) are deleted because C2's range covers them
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), "<r><p>ab</p></r>")
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), "<r><p>ab</p></r>")
        }
    }
}
