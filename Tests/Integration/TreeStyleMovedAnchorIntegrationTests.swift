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

// Integration tests for "Tree.Style range ending after a merge-moved child",
// ported from yorkie-js-sdk v0.7.16:
// `packages/sdk/test/integration/tree_style_moved_anchor_test.ts`
// (yorkie-js-sdk#1317 "Stamp merge-bound inserts and filter style-range
// interlopers"). These tests require a running yorkie server at
// http://localhost:8080.

import XCTest
@testable @preconcurrency import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

final class TreeStyleMovedAnchorIntegrationTests: XCTestCase {
    @MainActor
    func test_does_not_style_a_node_concurrently_inserted_at_the_merged_anchor() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 inserts an empty <p> after the second paragraph, then
            // styles a range ending after `c`, a non-leftmost position inside
            // the second paragraph. The inserted <p> is outside the styled
            // range on d1.
            try d1.update { root, _ in try (root.tree as? JSONTree)?.edit(8, 8, JSONTreeElementNode(type: "p", children: [])) }
            try d1.update { root, _ in try (root.tree as? JSONTree)?.style(0, 6, ["bold": "x"]) }
            // d2 concurrently removes the range, merging across the paragraphs.
            try d2.update { root, _ in try (root.tree as? JSONTree)?.edit(0, 5) }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then
            XCTAssertEqual((d1.getRoot().tree as? JSONTree)?.toXML(), "<r><p></p>cd</r>")
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    @MainActor
    func test_does_not_leave_attributes_from_removeStyle_on_a_concurrently_inserted_node() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when
            try d1.update { root, _ in try (root.tree as? JSONTree)?.edit(8, 8, JSONTreeElementNode(type: "p", children: [])) }
            try d1.update { root, _ in try (root.tree as? JSONTree)?.removeStyle(0, 6, ["bold"]) }
            try d2.update { root, _ in try (root.tree as? JSONTree)?.edit(0, 5) }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then
            XCTAssertEqual((d1.getRoot().tree as? JSONTree)?.toXML(), "<r><p></p>cd</r>")
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    @MainActor
    func test_still_styles_an_own_insert_that_was_inside_the_styled_range() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 inserts <b> inside the second paragraph, before `c`,
            // and styles a range that covers it. The insert resolves into the
            // merge target on d2, and must stay styled on both replicas.
            try d1.update { root, _ in try (root.tree as? JSONTree)?.edit(5, 5, JSONTreeElementNode(type: "b", children: [])) }
            try d1.update { root, _ in try (root.tree as? JSONTree)?.style(0, 8, ["bold": "x"]) }
            try d2.update { root, _ in try (root.tree as? JSONTree)?.edit(0, 5) }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then
            XCTAssertEqual((d1.getRoot().tree as? JSONTree)?.toXML(), "<r><b bold=\"x\"></b>cd</r>")
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    @MainActor
    func test_skips_descendants_of_a_node_inserted_at_the_merged_anchor() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when — the inserted <p> carries a nested <b>; both are outside
            // the styled range on d1, so neither may be styled on the merging
            // replica.
            try d1.update { root, _ in try (root.tree as? JSONTree)?.edit(8, 8, JSONTreeElementNode(type: "p", children: [])) }
            try d1.update { root, _ in try (root.tree as? JSONTree)?.edit(9, 9, JSONTreeElementNode(type: "b", children: [])) }
            try d1.update { root, _ in try (root.tree as? JSONTree)?.style(0, 6, ["bold": "x"]) }
            try d2.update { root, _ in try (root.tree as? JSONTree)?.edit(0, 5) }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then
            XCTAssertEqual((d1.getRoot().tree as? JSONTree)?.toXML(), "<r><p><b></b></p>cd</r>")
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    @MainActor
    func test_still_styles_a_sibling_before_the_merge_source_tombstone() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "b", children: []),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when — the leading <b> is inside the styled range on both
            // replicas and sits before the merge-source tombstone after the
            // merge.
            try d1.update { root, _ in try (root.tree as? JSONTree)?.style(0, 8, ["bold": "x"]) }
            try d2.update { root, _ in try (root.tree as? JSONTree)?.edit(2, 7) }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then
            XCTAssertEqual((d1.getRoot().tree as? JSONTree)?.toXML(), "<r><b bold=\"x\"></b>cd</r>")
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    @MainActor
    func test_still_styles_a_child_that_arrived_via_an_earlier_synced_merge() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                    JSONTreeElementNode(type: "s", children: [JSONTreeElementNode(type: "i", children: [])])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when — fully synced merge: <s> into <p> — <i> moves into <p>
            // and keeps mergedFrom=s forever (stamped only on the first move).
            try d1.update { root, _ in try (root.tree as? JSONTree)?.edit(3, 5) }
            try await c1.sync()
            try await c2.sync()
            XCTAssertEqual((d1.getRoot().tree as? JSONTree)?.toXML(), "<r><p>ab<i></i></p></r>")
            XCTAssertEqual((d2.getRoot().tree as? JSONTree)?.toXML(), "<r><p>ab<i></i></p></r>")

            // d1 styles a range ending after <i>, a non-leftmost position
            // inside <p>, covering <i>. d2 concurrently merges <p> into <r>.
            try d1.update { root, _ in try (root.tree as? JSONTree)?.style(0, 5, ["bold": "x"]) }
            try d2.update { root, _ in try (root.tree as? JSONTree)?.edit(0, 1) }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then
            XCTAssertEqual((d1.getRoot().tree as? JSONTree)?.toXML(), "<r>ab<i bold=\"x\"></i></r>")
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    @MainActor
    func test_converges_when_a_third_client_inserts_at_the_merged_anchor() async throws {
        let rpcAddress = "http://localhost:8080"
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        let c3 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        try await c3.activate()

        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)
        let d3 = Document(key: docKey)
        try await c1.attach(d1, [:], .manual)
        try await c2.attach(d2, [:], .manual)
        try await c3.attach(d3, [:], .manual)

        try d1.update { root, _ in
            root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
            ]))
        }
        try await c1.sync()
        try await c2.sync()
        try await c3.sync()

        // d3's insert is unknown to d1's style, so the version-vector check
        // keeps it unstyled on every replica.
        try d1.update { root, _ in try (root.tree as? JSONTree)?.style(0, 6, ["bold": "x"]) }
        try d2.update { root, _ in try (root.tree as? JSONTree)?.edit(0, 5) }
        try d3.update { root, _ in try (root.tree as? JSONTree)?.edit(8, 8, JSONTreeElementNode(type: "p", children: [])) }

        for client in [c1, c2, c3] {
            try await client.sync()
        }
        try await c1.sync()
        try await c2.sync()

        XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        XCTAssertEqual(d2.toSortedJSON(), d3.toSortedJSON())

        try await c1.detach(d1)
        try await c2.detach(d2)
        try await c3.detach(d3)
        try await c1.deactivate()
        try await c2.deactivate()
        try await c3.deactivate()
    }
}
