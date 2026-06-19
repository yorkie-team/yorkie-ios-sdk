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

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

// MARK: - Helpers

/// Returns the XML of the `t` field in the document root.
@MainActor
private func l2treeXML(_ doc: Document) -> String {
    (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
}

/// Builds the initial <doc><div><p>ABCD</p></div></doc> tree used by L2 tests.
/// Index layout: doc(0) div(1) p(2) A(3) B(4) C(5) D(6) /p(7) /div(8)
@MainActor
private func initL2Tree(_ doc: Document) throws {
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "div", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeTextNode(value: "ABCD")
                    ])
                ])
            ])
        )
    }
}

// MARK: - Structs

private struct SplitL2Case {
    let pos: String
    let splitIdx: Int
    let afterXML: String
}

/// splitLevel=2 table from JS history_tree_test.ts §4f.
///
/// Index layout for <doc><div><p>ABCD</p></div></doc>:
///   doc(0)  div(1)  p(2)  A(3)  B(4)  C(5)  D(6)  /p(7)  /div(8)
///
/// - front: split at 2 → <doc><div><p></p></div><div><p>ABCD</p></div></doc>
/// - middle: split at 4 → <doc><div><p>AB</p></div><div><p>CD</p></div></doc>
/// - back: split at 6 → <doc><div><p>ABCD</p></div><div><p></p></div></doc>
private let splitL2Cases: [SplitL2Case] = [
    SplitL2Case(
        pos: "front",
        splitIdx: 2,
        afterXML: "<doc><div><p></p></div><div><p>ABCD</p></div></doc>"
    ),
    SplitL2Case(
        pos: "middle",
        splitIdx: 4,
        afterXML: "<doc><div><p>AB</p></div><div><p>CD</p></div></doc>"
    ),
    SplitL2Case(
        pos: "back",
        splitIdx: 6,
        afterXML: "<doc><div><p>ABCD</p></div><div><p></p></div></doc>"
    )
]

private let splitL2BeforeXML = "<doc><div><p>ABCD</p></div></doc>"

// MARK: - 4f. Single Client — Split L2 undo/redo (table-driven)

//
// Ports: "Tree History - single client split L2 undo/redo"
// from packages/sdk/test/integration/history_tree_test.ts v0.7.7 §4f.
//
// These tests run with a local offline Document — no server required.
// Each test is annotated @MainActor because Document.update and undo/redo
// run on the main actor.

final class TreeHistorySplitL2UndoTests: XCTestCase {
    // MARK: - should undo split

    // Ports: "should undo split at front"
    @MainActor
    func test_can_undo_l2_split_at_front() throws {
        let tc = splitL2Cases.first(where: { $0.pos == "front" })!
        try self.runUndoTest(tc)
    }

    // Ports: "should undo split at middle"
    @MainActor
    func test_can_undo_l2_split_at_middle() throws {
        let tc = splitL2Cases.first(where: { $0.pos == "middle" })!
        try self.runUndoTest(tc)
    }

    // Ports: "should undo split at back"
    @MainActor
    func test_can_undo_l2_split_at_back() throws {
        let tc = splitL2Cases.first(where: { $0.pos == "back" })!
        try self.runUndoTest(tc)
    }

    // MARK: - should undo-redo split

    // Ports: "should undo-redo split at front"
    @MainActor
    func test_can_undo_redo_l2_split_at_front() throws {
        let tc = splitL2Cases.first(where: { $0.pos == "front" })!
        try self.runUndoRedoTest(tc)
    }

    // Ports: "should undo-redo split at middle"
    @MainActor
    func test_can_undo_redo_l2_split_at_middle() throws {
        let tc = splitL2Cases.first(where: { $0.pos == "middle" })!
        try self.runUndoRedoTest(tc)
    }

    // Ports: "should undo-redo split at back"
    @MainActor
    func test_can_undo_redo_l2_split_at_back() throws {
        let tc = splitL2Cases.first(where: { $0.pos == "back" })!
        try self.runUndoRedoTest(tc)
    }

    // MARK: - should undo-redo-undo split

    // Ports: "should undo-redo-undo split at front"
    @MainActor
    func test_can_undo_redo_undo_l2_split_at_front() throws {
        let tc = splitL2Cases.first(where: { $0.pos == "front" })!
        try self.runUndoRedoUndoTest(tc)
    }

    // Ports: "should undo-redo-undo split at middle"
    @MainActor
    func test_can_undo_redo_undo_l2_split_at_middle() throws {
        let tc = splitL2Cases.first(where: { $0.pos == "middle" })!
        try self.runUndoRedoUndoTest(tc)
    }

    // Ports: "should undo-redo-undo split at back"
    @MainActor
    func test_can_undo_redo_undo_l2_split_at_back() throws {
        let tc = splitL2Cases.first(where: { $0.pos == "back" })!
        try self.runUndoRedoUndoTest(tc)
    }

    // MARK: - shared helpers

    @MainActor
    private func runUndoTest(_ tc: SplitL2Case) throws {
        // given
        let doc = Document(key: "split-l2-undo-\(tc.pos)".toDocKey)
        try initL2Tree(doc)
        XCTAssertEqual(l2treeXML(doc), splitL2BeforeXML)

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(tc.splitIdx, tc.splitIdx, nil, 2)
        }
        XCTAssertEqual(l2treeXML(doc), tc.afterXML, "split at \(tc.pos) produced wrong XML")

        // then
        try doc.undo()
        XCTAssertEqual(l2treeXML(doc), splitL2BeforeXML, "undo split at \(tc.pos) failed")
    }

    @MainActor
    private func runUndoRedoTest(_ tc: SplitL2Case) throws {
        // given
        let doc = Document(key: "split-l2-undo-redo-\(tc.pos)".toDocKey)
        try initL2Tree(doc)

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(tc.splitIdx, tc.splitIdx, nil, 2)
        }

        try doc.undo()
        XCTAssertEqual(l2treeXML(doc), splitL2BeforeXML, "undo split at \(tc.pos) failed")

        // then
        try doc.redo()
        XCTAssertEqual(l2treeXML(doc), tc.afterXML, "redo split at \(tc.pos) failed")
    }

    @MainActor
    private func runUndoRedoUndoTest(_ tc: SplitL2Case) throws {
        // given
        let doc = Document(key: "split-l2-uru-\(tc.pos)".toDocKey)
        try initL2Tree(doc)

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(tc.splitIdx, tc.splitIdx, nil, 2)
        }

        try doc.undo()
        try doc.redo()
        try doc.undo()

        // then
        XCTAssertEqual(l2treeXML(doc), splitL2BeforeXML, "undo-redo-undo split at \(tc.pos) failed")
    }
}

// MARK: - 4g. Single Client — Split L2 chained with other ops (table-driven)

//
// Ports: "Tree History - single client split L2 chained ops"
// from packages/sdk/test/integration/history_tree_test.ts v0.7.7 §4g.
//
// NOTE: the JS skips the `split-l2 → split-l2` case (known undo bug for
// consecutive L2 splits). That case is omitted here rather than skipped to
// keep the test count accurate. See JS comment #1235 for the upstream ticket.

private enum SplitL2ChainOp: String {
    case splitL2 = "split-l2"
    case insertText = "insert-text"
    case deleteText = "delete-text"
}

/// Applies one operation from the §4g chain using editByPath on the <div><p>ABCD</p></div> tree.
@MainActor
private func applyL2ChainOp(_ doc: Document, _ op: SplitL2ChainOp) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        switch op {
        case .splitL2:
            // Split first <div><p> at offset 2 (between B and C) with splitLevel=2.
            try tree.editByPath([0, 0, 2], [0, 0, 2], nil, 2)
        case .insertText:
            // Insert 'X' at start of first <div><p>.
            try tree.editByPath([0, 0, 0], [0, 0, 0], JSONTreeTextNode(value: "X"))
        case .deleteText:
            // Delete the first char of <div><p>ABCD</p></div>.
            try tree.editByPath([0, 0, 0], [0, 0, 1])
        }
    }
}

final class TreeHistorySplitL2ChainedOpsTests: XCTestCase {
    // Pairs from the 3-element set, excluding split-l2 → split-l2 (known bug #1235).

    // Ports: "should undo chain: split-l2 → insert-text"
    @MainActor
    func test_can_undo_l2_chain_splitL2_insertText() throws {
        try self.runChain(.splitL2, .insertText)
    }

    // Ports: "should undo chain: split-l2 → delete-text"
    @MainActor
    func test_can_undo_l2_chain_splitL2_deleteText() throws {
        try self.runChain(.splitL2, .deleteText)
    }

    // Ports: "should undo chain: insert-text → split-l2"
    @MainActor
    func test_can_undo_l2_chain_insertText_splitL2() throws {
        try self.runChain(.insertText, .splitL2)
    }

    // Ports: "should undo chain: insert-text → insert-text"
    @MainActor
    func test_can_undo_l2_chain_insertText_insertText() throws {
        try self.runChain(.insertText, .insertText)
    }

    // Ports: "should undo chain: insert-text → delete-text"
    @MainActor
    func test_can_undo_l2_chain_insertText_deleteText() throws {
        try self.runChain(.insertText, .deleteText)
    }

    // Ports: "should undo chain: delete-text → split-l2"
    @MainActor
    func test_can_undo_l2_chain_deleteText_splitL2() throws {
        try self.runChain(.deleteText, .splitL2)
    }

    // Ports: "should undo chain: delete-text → insert-text"
    @MainActor
    func test_can_undo_l2_chain_deleteText_insertText() throws {
        try self.runChain(.deleteText, .insertText)
    }

    // Ports: "should undo chain: delete-text → delete-text"
    @MainActor
    func test_can_undo_l2_chain_deleteText_deleteText() throws {
        try self.runChain(.deleteText, .deleteText)
    }

    // MARK: - shared helper

    @MainActor
    private func runChain(_ op1: SplitL2ChainOp, _ op2: SplitL2ChainOp) throws {
        // given — <doc><div><p>ABCD</p></div></doc>
        let key = "split-l2-chain-\(op1.rawValue)-\(op2.rawValue)".toDocKey
        let doc = Document(key: key)
        try initL2Tree(doc)

        let s0 = l2treeXML(doc)
        try applyL2ChainOp(doc, op1)
        let s1 = l2treeXML(doc)
        try applyL2ChainOp(doc, op2)
        let s2 = l2treeXML(doc)

        // when — undo twice: s2 → s1 → s0
        try doc.undo()
        XCTAssertEqual(l2treeXML(doc), s1, "undo \(op2.rawValue) failed")
        try doc.undo()
        XCTAssertEqual(l2treeXML(doc), s0, "undo \(op1.rawValue) failed")

        // then — redo twice: s0 → s1 → s2
        try doc.redo()
        XCTAssertEqual(l2treeXML(doc), s1, "redo \(op1.rawValue) failed")
        try doc.redo()
        XCTAssertEqual(l2treeXML(doc), s2, "redo \(op2.rawValue) failed")
    }
}

// MARK: - 4h. Multi Client — Split L2 convergence after undo/redo (table-driven)

//
// Ports: "Tree History - multi client split L2 convergence"
// from packages/sdk/test/integration/history_tree_test.ts v0.7.7 §4h.
// Requires a live yorkie server.
//
// Initial tree: <doc><div><p>ABCD</p></div><div><p>EFGH</p></div></doc>
// Index layout:
//   doc(0) div(1) p(2) A(3) B(4) C(5) D(6) /p(7) /div(8)
//          div(9) p(10) E(11) F(12) G(13) H(14) /p(15) /div(16)
//
// d1: split first <div><p> at middle (after B, idx=4) with splitLevel=2
// d2: concurrent remote op at various positions
// Then d1 undoes (and in the redo suite, also redoes) the split.

private enum L2RemoteOp: String, CaseIterable {
    case insertText = "insert-text"
    case deleteText = "delete-text"
    case insertElement = "insert-element"
}

private enum L2RemotePos: String, CaseIterable {
    case beforeSplit = "before-split"
    case afterSplit = "after-split"
    case differentElement = "different-element"
}

@MainActor
private func applyL2RemoteOp(_ doc: Document, op: L2RemoteOp, pos: L2RemotePos) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        switch (op, pos) {
        // insert-text variants
        case (.insertText, .beforeSplit):
            // insert X before B (idx 3 is A, idx 4 is B)
            try tree.edit(3, 3, JSONTreeTextNode(value: "X"))
        case (.insertText, .afterSplit):
            // insert X after C (idx 6 is D — after split point idx=4 the 'after' side starts)
            try tree.edit(6, 6, JSONTreeTextNode(value: "X"))
        case (.insertText, .differentElement):
            // insert X into the second <div><p>EFGH</p></div> at idx 11
            try tree.edit(11, 11, JSONTreeTextNode(value: "X"))
        // delete-text variants
        case (.deleteText, .beforeSplit):
            // delete A (idx 2..3 would be inside p boundary; use p(2)+1=3 for text start)
            try tree.edit(2, 3)
        case (.deleteText, .afterSplit):
            // delete one char on the 'after' side
            try tree.edit(5, 6)
        case (.deleteText, .differentElement):
            // delete E from second <div><p>EFGH</p></div>
            try tree.edit(10, 11)
        // insert-element variants
        case (.insertElement, .beforeSplit):
            // insert a new <div><p>NEW</p></div> before the first <div>
            try tree.edit(0, 0, JSONTreeElementNode(type: "div", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "NEW")])
            ]))
        case (.insertElement, .afterSplit):
            // insert after the first </div> closing boundary (idx 8)
            try tree.edit(8, 8, JSONTreeElementNode(type: "div", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "NEW")])
            ]))
        case (.insertElement, .differentElement):
            // insert after the second </div> (idx 16)
            try tree.edit(16, 16, JSONTreeElementNode(type: "div", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "NEW")])
            ]))
        }
    }
}

final class TreeHistorySplitL2ConvergenceTests: XCTestCase {
    // MARK: - undo convergence (9 cases: 3 ops × 3 positions)

    // Ports: "should converge: split L2 + remote insert-text at before-split"
    @MainActor
    func test_can_converge_l2_split_plus_remote_insertText_at_beforeSplit() async throws {
        try await self.runUndoConvergenceTest(op: .insertText, pos: .beforeSplit)
    }

    // Ports: "should converge: split L2 + remote insert-text at after-split"
    @MainActor
    func test_can_converge_l2_split_plus_remote_insertText_at_afterSplit() async throws {
        try await self.runUndoConvergenceTest(op: .insertText, pos: .afterSplit)
    }

    // Ports: "should converge: split L2 + remote insert-text at different-element"
    @MainActor
    func test_can_converge_l2_split_plus_remote_insertText_at_differentElement() async throws {
        try await self.runUndoConvergenceTest(op: .insertText, pos: .differentElement)
    }

    // Ports: "should converge: split L2 + remote delete-text at before-split"
    @MainActor
    func test_can_converge_l2_split_plus_remote_deleteText_at_beforeSplit() async throws {
        try await self.runUndoConvergenceTest(op: .deleteText, pos: .beforeSplit)
    }

    // Ports: "should converge: split L2 + remote delete-text at after-split"
    @MainActor
    func test_can_converge_l2_split_plus_remote_deleteText_at_afterSplit() async throws {
        try await self.runUndoConvergenceTest(op: .deleteText, pos: .afterSplit)
    }

    // Ports: "should converge: split L2 + remote delete-text at different-element"
    @MainActor
    func test_can_converge_l2_split_plus_remote_deleteText_at_differentElement() async throws {
        try await self.runUndoConvergenceTest(op: .deleteText, pos: .differentElement)
    }

    // Ports: "should converge: split L2 + remote insert-element at before-split"
    @MainActor
    func test_can_converge_l2_split_plus_remote_insertElement_at_beforeSplit() async throws {
        try await self.runUndoConvergenceTest(op: .insertElement, pos: .beforeSplit)
    }

    // Ports: "should converge: split L2 + remote insert-element at after-split"
    @MainActor
    func test_can_converge_l2_split_plus_remote_insertElement_at_afterSplit() async throws {
        try await self.runUndoConvergenceTest(op: .insertElement, pos: .afterSplit)
    }

    // Ports: "should converge: split L2 + remote insert-element at different-element"
    @MainActor
    func test_can_converge_l2_split_plus_remote_insertElement_at_differentElement() async throws {
        try await self.runUndoConvergenceTest(op: .insertElement, pos: .differentElement)
    }

    // MARK: - redo convergence (9 cases: 3 ops × 3 positions)

    // Ports: "should converge after redo: split L2 + remote insert-text at before-split"
    @MainActor
    func test_can_converge_l2_split_redo_plus_remote_insertText_at_beforeSplit() async throws {
        try await self.runRedoConvergenceTest(op: .insertText, pos: .beforeSplit)
    }

    // Ports: "should converge after redo: split L2 + remote insert-text at after-split"
    @MainActor
    func test_can_converge_l2_split_redo_plus_remote_insertText_at_afterSplit() async throws {
        try await self.runRedoConvergenceTest(op: .insertText, pos: .afterSplit)
    }

    // Ports: "should converge after redo: split L2 + remote insert-text at different-element"
    @MainActor
    func test_can_converge_l2_split_redo_plus_remote_insertText_at_differentElement() async throws {
        try await self.runRedoConvergenceTest(op: .insertText, pos: .differentElement)
    }

    // Ports: "should converge after redo: split L2 + remote delete-text at before-split"
    @MainActor
    func test_can_converge_l2_split_redo_plus_remote_deleteText_at_beforeSplit() async throws {
        try await self.runRedoConvergenceTest(op: .deleteText, pos: .beforeSplit)
    }

    // Ports: "should converge after redo: split L2 + remote delete-text at after-split"
    @MainActor
    func test_can_converge_l2_split_redo_plus_remote_deleteText_at_afterSplit() async throws {
        try await self.runRedoConvergenceTest(op: .deleteText, pos: .afterSplit)
    }

    // Ports: "should converge after redo: split L2 + remote delete-text at different-element"
    @MainActor
    func test_can_converge_l2_split_redo_plus_remote_deleteText_at_differentElement() async throws {
        try await self.runRedoConvergenceTest(op: .deleteText, pos: .differentElement)
    }

    // Ports: "should converge after redo: split L2 + remote insert-element at before-split"
    @MainActor
    func test_can_converge_l2_split_redo_plus_remote_insertElement_at_beforeSplit() async throws {
        try await self.runRedoConvergenceTest(op: .insertElement, pos: .beforeSplit)
    }

    // Ports: "should converge after redo: split L2 + remote insert-element at after-split"
    @MainActor
    func test_can_converge_l2_split_redo_plus_remote_insertElement_at_afterSplit() async throws {
        try await self.runRedoConvergenceTest(op: .insertElement, pos: .afterSplit)
    }

    // Ports: "should converge after redo: split L2 + remote insert-element at different-element"
    @MainActor
    func test_can_converge_l2_split_redo_plus_remote_insertElement_at_differentElement() async throws {
        try await self.runRedoConvergenceTest(op: .insertElement, pos: .differentElement)
    }

    // MARK: - shared helpers

    @MainActor
    private func makeInitialL2TwoDocTree(_ d1: Document) throws {
        try d1.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "div", children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ABCD")])
                    ]),
                    JSONTreeElementNode(type: "div", children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "EFGH")])
                    ])
                ])
            )
        }
    }

    @MainActor
    private func runUndoConvergenceTest(op: L2RemoteOp, pos: L2RemotePos) async throws {
        let title = "\(self.description)-l2-split-undo-\(op.rawValue)-\(pos.rawValue)"
        try await withTwoClientsAndDocuments(title) { c1, d1, c2, d2 in
            // given — initial two-div tree
            try self.makeInitialL2TwoDocTree(d1)
            try await c1.sync()
            try await c2.sync()

            // when — d1 splits first <div><p> at middle (after B) with splitLevel=2
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(4, 4, nil, 2)
            }

            // d2 applies a concurrent remote operation
            try applyL2RemoteOp(d2, op: op, pos: pos)

            // sync both directions
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // d1 undoes the split
            try d1.undo()

            // sync again
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both must converge
            XCTAssertEqual(
                l2treeXML(d1),
                l2treeXML(d2),
                "divergence: split L2 + \(op.rawValue) at \(pos.rawValue)"
            )
        }
    }

    @MainActor
    private func runRedoConvergenceTest(op: L2RemoteOp, pos: L2RemotePos) async throws {
        let title = "\(self.description)-l2-split-redo-\(op.rawValue)-\(pos.rawValue)"
        try await withTwoClientsAndDocuments(title) { c1, d1, c2, d2 in
            // given — initial two-div tree
            try self.makeInitialL2TwoDocTree(d1)
            try await c1.sync()
            try await c2.sync()

            // when — d1 splits first <div><p> at middle (after B) with splitLevel=2
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(4, 4, nil, 2)
            }

            // d2 applies a concurrent remote operation
            try applyL2RemoteOp(d2, op: op, pos: pos)

            // sync both directions
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // d1 undoes then redoes the split
            try d1.undo()
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            try d1.redo()
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both must converge after redo
            XCTAssertEqual(
                l2treeXML(d1),
                l2treeXML(d2),
                "redo divergence: split L2 + \(op.rawValue) at \(pos.rawValue)"
            )
        }
    }
}

// MARK: - 4i. Multi Client — Split L2 edge cases

//
// Ports: "Tree History - multi client split L2 edge cases"
// from packages/sdk/test/integration/history_tree_test.ts v0.7.7 §4i.
// Requires a live yorkie server.

final class TreeHistorySplitL2EdgeCasesTests: XCTestCase {
    // Ports: "should converge: undo L2 front split with remote insert"
    //
    // d1: front split → <doc><div><p></p></div><div><p>AB</p></div></doc>
    // d2: concurrent insert X into the same element
    @MainActor
    func test_can_converge_undo_l2_front_split_with_remote_insert() async throws {
        let title = "\(self.description)-l2-front-split-remote-insert"
        try await withTwoClientsAndDocuments(title) { c1, d1, c2, d2 in
            // given — <doc><div><p>AB</p></div></doc>
            // Index layout: doc(0) div(1) p(2) A(3) B(4) /p(5) /div(6)
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "div", children: [
                            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "AB")])
                        ])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1: front split at idx=2 with splitLevel=2
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, nil, 2)
            }

            // d2: insert X inside the same <p> (at idx 3, which is 'A' in original)
            try d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "X"))
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // d1 undoes the front split
            try d1.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both must converge
            XCTAssertEqual(
                l2treeXML(d1),
                l2treeXML(d2),
                "divergence: undo front L2 split with remote insert"
            )
        }
    }

    // Ports: "should converge: undo L2 back split with remote insert"
    //
    // d1: back split → <doc><div><p>AB</p></div><div><p></p></div></doc>
    // d2: concurrent insert X into the element before the split
    @MainActor
    func test_can_converge_undo_l2_back_split_with_remote_insert() async throws {
        let title = "\(self.description)-l2-back-split-remote-insert"
        try await withTwoClientsAndDocuments(title) { c1, d1, c2, d2 in
            // given — <doc><div><p>AB</p></div></doc>
            // Index layout: doc(0) div(1) p(2) A(3) B(4) /p(5) /div(6)
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "div", children: [
                            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "AB")])
                        ])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1: back split at idx=4 (after 'B') with splitLevel=2
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(4, 4, nil, 2)
            }

            // d2: insert X at idx 2 (inside <p>, before 'A')
            try d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "X"))
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // d1 undoes the back split
            try d1.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both must converge
            XCTAssertEqual(
                l2treeXML(d1),
                l2treeXML(d2),
                "divergence: undo back L2 split with remote insert"
            )
        }
    }

    // Ports: "should handle undo after concurrent parent deletion (L2)"
    //
    // d1: splits first <div><p> at middle with splitLevel=2
    // d2: deletes the first <div> entirely
    // Then d1 undoes the split — the parent is deleted so it should be a no-op.
    @MainActor
    func test_can_handle_undo_after_concurrent_parent_deletion_l2() async throws {
        let title = "\(self.description)-l2-undo-after-parent-deletion"
        try await withTwoClientsAndDocuments(title) { c1, d1, c2, d2 in
            // given — <doc><div><p>ABCD</p></div><div><p>EFGH</p></div></doc>
            // Index layout:
            //   doc(0) div(1) p(2) A(3) B(4) C(5) D(6) /p(7) /div(8)
            //          div(9) p(10) E(11) F(12) G(13) H(14) /p(15) /div(16)
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "div", children: [
                            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ABCD")])
                        ]),
                        JSONTreeElementNode(type: "div", children: [
                            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "EFGH")])
                        ])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 splits the first <div><p> at middle (after B, idx=4) with splitLevel=2
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(4, 4, nil, 2)
            }

            // d2 deletes the first <div> entirely — spans idx 0 to 8 (exclusive)
            try d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 8)
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // d1 undoes the split — parent is deleted, should be a no-op
            try d1.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both must converge
            XCTAssertEqual(
                l2treeXML(d1),
                l2treeXML(d2),
                "divergence after undo with concurrent parent deletion (L2)"
            )
        }
    }
}

// MARK: - 4e-extra. Multi Client — Split L1 concurrent parent deletion

//
// Ports: "should handle undo after concurrent parent deletion (L1)"
// from packages/sdk/test/integration/history_tree_test.ts v0.7.7 §4e (end).
// Requires a live yorkie server.
//
// d1: split first <p> at middle with splitLevel=1
// d2: delete the first <p> entirely
// Then d1 undoes the split — the parent node is deleted, should be a no-op.

final class TreeHistorySplitL1ConcurrentDeleteTests: XCTestCase {
    // Ports: "should handle undo after concurrent parent deletion (L1)"
    @MainActor
    func test_can_handle_undo_after_concurrent_parent_deletion_l1() async throws {
        let title = "\(self.description)-l1-undo-after-parent-deletion"
        try await withTwoClientsAndDocuments(title) { c1, d1, c2, d2 in
            // given — <doc><p>ABCD</p><p>EFGH</p></doc>
            // Index layout:
            //   doc(0) p(1) A(2) B(3) C(4) D(5) /p(6)
            //          p(7) E(8) F(9) G(10) H(11) /p(12)
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ABCD")]),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "EFGH")])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 splits first <p> at middle (after B, idx=3) with splitLevel=1
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, nil, 1)
            }

            // d2 deletes the first <p> entirely — spans idx 0 to 6 (exclusive 6)
            try d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 6)
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // d1 undoes the split — parent is deleted, should be a no-op
            try d1.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both must converge
            XCTAssertEqual(
                l2treeXML(d1),
                l2treeXML(d2),
                "divergence after undo with concurrent parent deletion (L1)"
            )
        }
    }
}
