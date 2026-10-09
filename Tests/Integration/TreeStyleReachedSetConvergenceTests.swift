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

// Ported (as convergence scenarios, via the two-client live-server harness
// this file's siblings already use) from a representative slice of
// yorkie-js-sdk v0.7.24: `packages/sdk/test/unit/document/tree_style_reached_set_test.ts`
// "Tree style reached set" (yorkie-js-sdk#1404, yorkie#2038, design doc
// section 9 "Port specification").
//
// The full JS file replays both delivery orders of a hand-built change batch
// against a fresh in-memory replica; this port instead lets two real clients
// race the structural and style changes and sync through the server, which
// exercises the same `CRDTTree.styleTargets` resolution end to end and is
// the pattern already established by `TreeMergeConvergenceTests.swift`. Only
// the base tree, the two concurrent edits, and the expected converged XML are
// taken from the JS source; the index numbers are the same CRDT tree index
// space JS and iOS have shared throughout this port.
//
// Before this commit, a style's reached set was resolved in the RECEIVING
// replica's current (post-structural-change) index space, so which change a
// replica applied first changed what the style covered -- on live nodes,
// with no way back, since a style cannot be retracted and GC never touches a
// live node. These tests assert both replicas converge to the one XML the
// change's OWN declared positions describe, regardless of sync order.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

final class TreeStyleReachedSetConvergenceTests: XCTestCase {
    /// `<r><p>ab</p><p>cd</p><p>ef</p></r>`, 12 wide inside the root.
    /// Index layout: r(0) p1(1) a(2) b(3) /p1(4) p2(5) c(6) d(7) /p2(8) p3(9) e(10) f(11) /p3(12)
    @MainActor
    private func seedStyleScanBase(_ d1: Document, _ c1: Client, _ c2: Client) async throws {
        try d1.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")]),
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ef")])
            ]))
        }
        try await c1.sync()
        try await c2.sync()
    }

    // A concurrent split of the paragraph a style covers. The style range ran
    // past the paragraph's end before the split existed, so it styles the
    // paragraph; the split then has to carry that onto both halves,
    // whichever change a replica applies first.
    @MainActor
    func test_styles_both_halves_of_a_concurrently_split_paragraph() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try await self.seedStyleScanBase(d1, c1, c2)

            // when — d1 splits p2 ("cd") between 'c' and 'd'; d2 bolds all of
            // p2. Neither has seen the other's change.
            try d1.update { root, _ in _ = try (root.t as? JSONTree)?.edit(6, 6, nil, 1) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.style(5, 8, ["b": "x"]) }

            // then — the style carries onto BOTH halves of the split.
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            let expected = "<r><p>ab</p><p b=\"x\">c</p><p b=\"x\">d</p><p>ef</p></r>"
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), expected)
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), expected)
        }
    }

    // A concurrent merge of the two paragraphs a style spans. The style
    // covered the first paragraph's End token and the second's Start token,
    // so both carry it -- the second as a tombstone, which only the fused
    // survivor's content shows.
    @MainActor
    func test_styles_both_paragraphs_a_concurrent_merge_joins() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try await self.seedStyleScanBase(d1, c1, c2)

            // when — d1 merges p1+p2 (p1 survives, absorbing p2's "cd"; p1's
            // own "ab" is deleted by the same edit); d2 bolds from inside p1
            // through just past p2's open tag -- p1's End token and p2's
            // Start token, so the (pre-merge) traversal styles both whole.
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(1, 5) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.style(1, 6, ["b": "x"]) }

            // then — the merge survivor (now holding "cd") is bold on both
            // replicas, whichever change arrives first.
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            let expected = "<r><p b=\"x\">cd</p><p>ef</p></r>"
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), expected)
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), expected)
        }
    }

    // The mirror of the previous case (§9.6): the merge removes the opening
    // tag of the paragraph the style range STARTS inside, moving its
    // children into the paragraph before it. The style named only the
    // paragraph it started in (p2), never the merge target (p1) that
    // paragraph's content ends up inside -- so the merge target is not
    // styled, even on a replica whose resolved traversal reaches it only
    // through an End token once the merge has run.
    @MainActor
    func test_does_not_style_the_merge_target_a_range_start_moved_into() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try await self.seedStyleScanBase(d1, c1, c2)

            // when — d1 merges p1+p2 as before; d2 bolds from between 'c' and
            // 'd' (inside p2 only) through just past p2's close tag -- a
            // range that never names p1.
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(1, 5) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.style(6, 8, ["b": "x"]) }

            // then — neither replica styles the merge target.
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            let expected = "<r><p>cd</p><p>ef</p></r>"
            XCTAssertEqual((d1.getRoot().t as? JSONTree)?.toXML(), expected)
            XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), expected)
        }
    }
}
