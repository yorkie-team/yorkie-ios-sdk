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

/// Initial tree used by the split L1 tests: <doc><p>ABCD</p></doc>
@MainActor
private func initSplitTree(_ doc: Document) throws {
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeTextNode(value: "ABCD")
                ])
            ])
        )
    }
}

/// Returns the XML of the `t` field in the document root.
@MainActor
private func treeXML(_ doc: Document) -> String {
    (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
}

// MARK: - 4b. Single Client — Split L1 undo/redo (table-driven)

//
// Ports: "Tree History - single client split L1 undo/redo"
// from packages/sdk/test/integration/history_tree_test.ts (v0.7.5 block
// added in #1219, lines 484–590).
//
// Tree: <doc><p>ABCD</p></doc>
// split index 1 → <doc><p></p><p>ABCD</p></doc>   (front)
// split index 3 → <doc><p>AB</p><p>CD</p></doc>   (middle)
// split index 5 → <doc><p>ABCD</p><p></p></doc>   (back)

/// Positions, indexes and expected XML for each split variant.
private struct SplitL1Case {
    let pos: String
    let splitIdx: Int
    let afterXML: String
}

private let splitL1Cases: [SplitL1Case] = [
    SplitL1Case(pos: "front", splitIdx: 1, afterXML: "<doc><p></p><p>ABCD</p></doc>"),
    SplitL1Case(pos: "middle", splitIdx: 3, afterXML: "<doc><p>AB</p><p>CD</p></doc>"),
    SplitL1Case(pos: "back", splitIdx: 5, afterXML: "<doc><p>ABCD</p><p></p></doc>")
]

final class TreeHistorySplitL1UndoTests: XCTestCase {
    // MARK: - should undo split

    // Ports: "should undo split at front"
    @MainActor
    func test_can_undo_split_at_front() throws {
        let tc = splitL1Cases.first(where: { $0.pos == "front" })!
        try self.runUndoSplitTest(tc)
    }

    // Ports: "should undo split at middle"
    @MainActor
    func test_can_undo_split_at_middle() throws {
        let tc = splitL1Cases.first(where: { $0.pos == "middle" })!
        try self.runUndoSplitTest(tc)
    }

    // Ports: "should undo split at back"
    @MainActor
    func test_can_undo_split_at_back() throws {
        let tc = splitL1Cases.first(where: { $0.pos == "back" })!
        try self.runUndoSplitTest(tc)
    }

    // MARK: - should undo-redo split

    // Ports: "should undo-redo split at front"
    @MainActor
    func test_can_undo_redo_split_at_front() throws {
        let tc = splitL1Cases.first(where: { $0.pos == "front" })!
        try self.runUndoRedoSplitTest(tc)
    }

    // Ports: "should undo-redo split at middle"
    @MainActor
    func test_can_undo_redo_split_at_middle() throws {
        let tc = splitL1Cases.first(where: { $0.pos == "middle" })!
        try self.runUndoRedoSplitTest(tc)
    }

    // Ports: "should undo-redo split at back"
    @MainActor
    func test_can_undo_redo_split_at_back() throws {
        let tc = splitL1Cases.first(where: { $0.pos == "back" })!
        try self.runUndoRedoSplitTest(tc)
    }

    // MARK: - should undo-redo-undo split

    // Ports: "should undo-redo-undo split at front"
    @MainActor
    func test_can_undo_redo_undo_split_at_front() throws {
        let tc = splitL1Cases.first(where: { $0.pos == "front" })!
        try self.runUndoRedoUndoSplitTest(tc)
    }

    // Ports: "should undo-redo-undo split at middle"
    @MainActor
    func test_can_undo_redo_undo_split_at_middle() throws {
        let tc = splitL1Cases.first(where: { $0.pos == "middle" })!
        try self.runUndoRedoUndoSplitTest(tc)
    }

    // Ports: "should undo-redo-undo split at back"
    @MainActor
    func test_can_undo_redo_undo_split_at_back() throws {
        let tc = splitL1Cases.first(where: { $0.pos == "back" })!
        try self.runUndoRedoUndoSplitTest(tc)
    }

    // MARK: - shared helpers

    @MainActor
    private func runUndoSplitTest(_ tc: SplitL1Case) throws {
        // given
        let doc = Document(key: "split-l1-undo-\(tc.pos)".toDocKey)
        try initSplitTree(doc)
        let beforeXML = treeXML(doc)

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(tc.splitIdx, tc.splitIdx, nil, 1)
        }
        XCTAssertEqual(treeXML(doc), tc.afterXML, "split at \(tc.pos) produced wrong XML")

        // then
        try doc.undo()
        XCTAssertEqual(treeXML(doc), beforeXML, "undo split at \(tc.pos) failed")
    }

    @MainActor
    private func runUndoRedoSplitTest(_ tc: SplitL1Case) throws {
        // given
        let doc = Document(key: "split-l1-undo-redo-\(tc.pos)".toDocKey)
        try initSplitTree(doc)
        let beforeXML = treeXML(doc)

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(tc.splitIdx, tc.splitIdx, nil, 1)
        }

        try doc.undo()
        XCTAssertEqual(treeXML(doc), beforeXML, "undo split at \(tc.pos) failed")

        // then
        try doc.redo()
        XCTAssertEqual(treeXML(doc), tc.afterXML, "redo split at \(tc.pos) failed")
    }

    @MainActor
    private func runUndoRedoUndoSplitTest(_ tc: SplitL1Case) throws {
        // given
        let doc = Document(key: "split-l1-uru-\(tc.pos)".toDocKey)
        try initSplitTree(doc)
        let beforeXML = treeXML(doc)

        // when
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(tc.splitIdx, tc.splitIdx, nil, 1)
        }

        try doc.undo()
        try doc.redo()
        try doc.undo()

        // then
        XCTAssertEqual(treeXML(doc), beforeXML, "undo-redo-undo split at \(tc.pos) failed")
    }
}

// MARK: - 4b-edge. Split L1 edge cases

//
// Ports: "Tree History - split L1 edge cases" (v0.7.5, lines 1375–1456).

final class TreeHistorySplitL1EdgeCasesTests: XCTestCase {
    // Ports: "should undo front split with empty paragraph"
    @MainActor
    func test_can_undo_front_split_with_empty_paragraph() throws {
        // given — <doc><p>AB</p></doc>
        let doc = Document(key: "split-l1-edge-front-empty".toDocKey)
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeTextNode(value: "AB")
                    ])
                ])
            )
        }
        let beforeXML = treeXML(doc)

        // when — split at front (idx 1) → <doc><p></p><p>AB</p></doc>
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, nil, 1)
        }
        XCTAssertEqual(treeXML(doc), "<doc><p></p><p>AB</p></doc>")

        // then
        try doc.undo()
        XCTAssertEqual(treeXML(doc), beforeXML, "undo front split with empty paragraph failed")
    }

    // Ports: "should undo back split with empty paragraph"
    @MainActor
    func test_can_undo_back_split_with_empty_paragraph() throws {
        // given — <doc><p>AB</p></doc>
        let doc = Document(key: "split-l1-edge-back-empty".toDocKey)
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeTextNode(value: "AB")
                    ])
                ])
            )
        }
        let beforeXML = treeXML(doc)

        // when — split at back (idx 3) → <doc><p>AB</p><p></p></doc>
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(3, 3, nil, 1)
        }
        XCTAssertEqual(treeXML(doc), "<doc><p>AB</p><p></p></doc>")

        // then
        try doc.undo()
        XCTAssertEqual(treeXML(doc), beforeXML, "undo back split with empty paragraph failed")
    }

    // Ports: "should clear redo stack when new edit is made after split undo"
    @MainActor
    func test_clears_redo_stack_when_new_edit_made_after_split_undo() throws {
        // given — <doc><p>ABCD</p></doc>
        let doc = Document(key: "split-l1-edge-clear-redo".toDocKey)
        try initSplitTree(doc)

        // when — split at middle, undo, then make a new edit
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(3, 3, nil, 1)
        }
        try doc.undo()
        XCTAssertTrue(doc.canRedo, "redo stack must be non-empty after undo")

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "Z"))
        }

        // then — redo stack must be cleared by the new edit
        XCTAssertFalse(doc.canRedo, "redo stack must be empty after new edit")
    }
}

// MARK: - 4c. Single Client — Split L1 chained with other ops (table-driven)

//
// Ports: "Tree History - single client split L1 chained ops" (v0.7.5, lines 1175–1236).
//
// Each test performs op1 then op2, captures snapshots s0, s1, s2, then
// verifies undo/redo cycles restore s1 and s0 / s1 and s2.

private enum SplitChainOp: String, CaseIterable {
    case split, insertText = "insert-text", deleteText = "delete-text"
}

@MainActor
private func applySplitChainOp(_ doc: Document, _ op: SplitChainOp) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        switch op {
        case .split:
            // Split first <p> at offset 2 (between 2nd and 3rd char).
            try tree.editByPath([0, 2], [0, 2], nil, 1)
        case .insertText:
            // Insert 'X' at start of first <p>.
            try tree.editByPath([0, 0], [0, 0], JSONTreeTextNode(value: "X"))
        case .deleteText:
            // Delete first char of first <p>.
            try tree.edit(1, 2)
        }
    }
}

final class TreeHistorySplitL1ChainedOpsTests: XCTestCase {
    // The JS test generates all 9 (op1, op2) pairs from the 3-element set.
    // Each pair is expanded into an individual test method below.

    // Ports: "should undo chain: split → split"
    @MainActor
    func test_can_undo_chain_split_split() throws {
        try self.runChain(.split, .split)
    }

    // Ports: "should undo chain: split → insert-text"
    @MainActor
    func test_can_undo_chain_split_insertText() throws {
        try self.runChain(.split, .insertText)
    }

    // Ports: "should undo chain: split → delete-text"
    @MainActor
    func test_can_undo_chain_split_deleteText() throws {
        try self.runChain(.split, .deleteText)
    }

    // Ports: "should undo chain: insert-text → split"
    @MainActor
    func test_can_undo_chain_insertText_split() throws {
        try self.runChain(.insertText, .split)
    }

    // Ports: "should undo chain: insert-text → insert-text"
    @MainActor
    func test_can_undo_chain_insertText_insertText() throws {
        try self.runChain(.insertText, .insertText)
    }

    // Ports: "should undo chain: insert-text → delete-text"
    @MainActor
    func test_can_undo_chain_insertText_deleteText() throws {
        try self.runChain(.insertText, .deleteText)
    }

    // Ports: "should undo chain: delete-text → split"
    @MainActor
    func test_can_undo_chain_deleteText_split() throws {
        try self.runChain(.deleteText, .split)
    }

    // Ports: "should undo chain: delete-text → insert-text"
    @MainActor
    func test_can_undo_chain_deleteText_insertText() throws {
        try self.runChain(.deleteText, .insertText)
    }

    // Ports: "should undo chain: delete-text → delete-text"
    @MainActor
    func test_can_undo_chain_deleteText_deleteText() throws {
        try self.runChain(.deleteText, .deleteText)
    }

    // MARK: - shared helper

    @MainActor
    private func runChain(_ op1: SplitChainOp, _ op2: SplitChainOp) throws {
        // given — <doc><p>ABCD</p></doc>
        let key = "split-chain-\(op1.rawValue)-\(op2.rawValue)".toDocKey
        let doc = Document(key: key)
        try initSplitTree(doc)

        let s0 = treeXML(doc)
        try applySplitChainOp(doc, op1)
        let s1 = treeXML(doc)
        try applySplitChainOp(doc, op2)
        let s2 = treeXML(doc)

        // when — undo twice: s2 → s1 → s0
        try doc.undo()
        XCTAssertEqual(treeXML(doc), s1, "undo \(op2) failed")
        try doc.undo()
        XCTAssertEqual(treeXML(doc), s0, "undo \(op1) failed")

        // then — redo twice: s0 → s1 → s2
        try doc.redo()
        XCTAssertEqual(treeXML(doc), s1, "redo \(op1) failed")
        try doc.redo()
        XCTAssertEqual(treeXML(doc), s2, "redo \(op2) failed")
    }
}

// MARK: - 4d. Multi Client — Split L1 convergence after undo (table-driven)

//
// Ports: "Tree History - multi client split L1 convergence" (v0.7.5, lines 1238–1374).
// Requires a live 0.7.5 yorkie server.
//
// Initial tree: <doc><p>ABCD</p><p>EFGH</p></doc>
// d1: split first <p> at middle (idx 3) with splitLevel=1
// d2: concurrent remote op at various positions
// Then d1 undoes the split — d1 and d2 must converge.

private enum SplitRemoteOp: String, CaseIterable {
    case insertText = "insert-text"
    case deleteText = "delete-text"
    case insertElement = "insert-element"
}

private enum SplitRemotePos: String, CaseIterable {
    case beforeSplit = "before-split"
    case afterSplit = "after-split"
    case differentElement = "different-element"
}

@MainActor
private func applyRemoteOpForSplitConvergence(
    _ doc: Document,
    op: SplitRemoteOp,
    pos: SplitRemotePos
) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        switch (op, pos) {
        case (.insertText, .beforeSplit):
            try tree.edit(1, 1, JSONTreeTextNode(value: "X"))
        case (.insertText, .afterSplit):
            try tree.edit(5, 5, JSONTreeTextNode(value: "X"))
        case (.insertText, .differentElement):
            try tree.edit(7, 7, JSONTreeTextNode(value: "X"))
        case (.deleteText, .beforeSplit):
            try tree.edit(1, 2)
        case (.deleteText, .afterSplit):
            try tree.edit(4, 5)
        case (.deleteText, .differentElement):
            try tree.edit(7, 8)
        case (.insertElement, .beforeSplit):
            try tree.edit(0, 0, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "NEW")]))
        case (.insertElement, .afterSplit):
            try tree.edit(6, 6, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "NEW")]))
        case (.insertElement, .differentElement):
            try tree.edit(12, 12, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "NEW")]))
        }
    }
}

final class TreeHistorySplitL1ConvergenceTests: XCTestCase {
    // Ports: "should converge: split + remote insert-text at before-split"
    @MainActor
    func test_can_converge_split_plus_remote_insertText_at_beforeSplit() async throws {
        try await self.runSplitConvergenceTest(op: .insertText, pos: .beforeSplit)
    }

    // Ports: "should converge: split + remote insert-text at after-split"
    @MainActor
    func test_can_converge_split_plus_remote_insertText_at_afterSplit() async throws {
        try await self.runSplitConvergenceTest(op: .insertText, pos: .afterSplit)
    }

    // Ports: "should converge: split + remote insert-text at different-element"
    @MainActor
    func test_can_converge_split_plus_remote_insertText_at_differentElement() async throws {
        try await self.runSplitConvergenceTest(op: .insertText, pos: .differentElement)
    }

    // Ports: "should converge: split + remote delete-text at before-split"
    @MainActor
    func test_can_converge_split_plus_remote_deleteText_at_beforeSplit() async throws {
        try await self.runSplitConvergenceTest(op: .deleteText, pos: .beforeSplit)
    }

    // Ports: "should converge: split + remote delete-text at after-split"
    @MainActor
    func test_can_converge_split_plus_remote_deleteText_at_afterSplit() async throws {
        try await self.runSplitConvergenceTest(op: .deleteText, pos: .afterSplit)
    }

    // Ports: "should converge: split + remote delete-text at different-element"
    @MainActor
    func test_can_converge_split_plus_remote_deleteText_at_differentElement() async throws {
        try await self.runSplitConvergenceTest(op: .deleteText, pos: .differentElement)
    }

    // Ports: "should converge: split + remote insert-element at before-split"
    @MainActor
    func test_can_converge_split_plus_remote_insertElement_at_beforeSplit() async throws {
        try await self.runSplitConvergenceTest(op: .insertElement, pos: .beforeSplit)
    }

    // Ports: "should converge: split + remote insert-element at after-split"
    @MainActor
    func test_can_converge_split_plus_remote_insertElement_at_afterSplit() async throws {
        try await self.runSplitConvergenceTest(op: .insertElement, pos: .afterSplit)
    }

    // Ports: "should converge: split + remote insert-element at different-element"
    @MainActor
    func test_can_converge_split_plus_remote_insertElement_at_differentElement() async throws {
        try await self.runSplitConvergenceTest(op: .insertElement, pos: .differentElement)
    }

    // MARK: - shared helper

    @MainActor
    private func runSplitConvergenceTest(op: SplitRemoteOp, pos: SplitRemotePos) async throws {
        let title = "\(self.description)-\(op.rawValue)-\(pos.rawValue)"
        try await withTwoClientsAndDocuments(title) { c1, d1, c2, d2 in
            // given — initial tree with two paragraphs
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

            // when — d1 splits first <p> at middle (idx 3, splitLevel=1)
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, nil, 1)
            }

            // d2 applies a concurrent remote op
            try applyRemoteOpForSplitConvergence(d2, op: op, pos: pos)

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
                treeXML(d1),
                treeXML(d2),
                "divergence: split + \(op.rawValue) at \(pos.rawValue)"
            )
        }
    }
}
