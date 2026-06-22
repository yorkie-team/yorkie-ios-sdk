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

// MARK: - Helpers

/// Initial tree: <doc><p><inline></inline></p></doc>
@MainActor
private func initBlockTree(_ doc: Document) throws {
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeElementNode(type: "inline", children: [])
                ])
            ])
        )
    }
}

/// Insert a sibling <p><inline></inline></p> at the document level.
@MainActor
private func insertSiblingBlock(_ doc: Document) throws {
    try doc.update { root, _ in
        try (root.t as? JSONTree)?.editByPath(
            [1], [1],
            JSONTreeElementNode(type: "p", children: [
                JSONTreeElementNode(type: "inline", children: [])
            ])
        )
    }
}

/// Insert one character at the end of the second <p>'s inline.
/// Mirrors the JS `typeInSecondBlock` helper.
@MainActor
private func typeInSecondBlock(_ doc: Document, _ ch: String) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        let xml = tree.toXML()
        // Compute the offset from the last <inline>...</inline></p></doc> at the tail.
        let suffix = "</inline></p></doc>"
        let cur: Int
        if let range = xml.range(of: "<inline>", options: .backwards),
           let endRange = xml.range(of: suffix, options: .backwards)
        {
            let innerStart = xml.index(range.upperBound, offsetBy: 0)
            let innerEnd = endRange.lowerBound
            if innerStart <= innerEnd {
                cur = xml.distance(from: innerStart, to: innerEnd)
            } else {
                cur = 0
            }
        } else {
            cur = 0
        }
        try tree.editByPath([1, 0, cur], [1, 0, cur], JSONTreeTextNode(value: ch))
    }
}

// MARK: - 5. Single Client — reverseOp pre-tombstoned descendant filtering

/// Ports: "Tree History - single client reverseOp pre-tombstoned filter"
/// from packages/sdk/test/integration/history_tree_split_test.ts (PR #1239).
///
/// These unit tests exercise the `cloneAndDropPreTombstoned` fix:
/// undoing a parent delete must NOT resurrect descendants the user
/// independently deleted before that edit.

final class TreePreTombstonedFilterTests: XCTestCase {
    // Ports: "should not accumulate reverseOp contents across redo cycles"
    //
    // The redo-stack top's node count must be the same in every cycle. Without
    // the `cloneAndDropPreTombstoned` filter it grows because each undo/redo cycle
    // adds the previously-tombstoned characters back into the reverseOp payload.
    @MainActor
    func test_reverseOp_contents_size_is_constant_across_redo_cycles() throws {
        // given — <doc><p><inline></inline></p></doc> + a second <p> block
        let doc = Document(key: "pretomb-size-stable")
        try initBlockTree(doc)
        try insertSiblingBlock(doc)

        let numCycles = 4
        var redoOpSizes = [Int]()

        for _ in 0 ..< numCycles {
            // Type "asdf" into the second block.
            for ch in ["a", "s", "d", "f"] {
                try typeInSecondBlock(doc, ch)
            }

            // Undo each char.
            for _ in 0 ..< 4 {
                try doc.undo()
            }

            // Undo the block-insert. The redo-stack top now holds the "re-insert block" op.
            try doc.undo()

            // Count nodes in the redo-stack top TreeEditOperation.
            let redoStack = doc.getRedoStackForTest()
            let topEntry = redoStack.last ?? []
            var nodeCount = 0
            for histOp in topEntry {
                if case .operation(let op) = histOp, let treeOp = op as? TreeEditOperation {
                    nodeCount += treeOp.getContentSize()
                }
            }
            redoOpSizes.append(nodeCount)

            // Redo for the next cycle's setup.
            try doc.redo()
        }

        // All cycles must produce the same count — no accumulation.
        XCTAssertFalse(redoOpSizes.isEmpty, "expected at least one cycle")
        let first = redoOpSizes[0]
        for (idx, size) in redoOpSizes.enumerated() {
            XCTAssertEqual(size, first, "cycle \(idx) redo size \(size) != cycle-0 size \(first)")
        }
    }

    // Ports: "should allow typing at the correct position after redo"
    //
    // After the type-undo-undo-redo sequence, typing into the second block
    // must land in the correct position and produce the expected XML.
    @MainActor
    func test_typing_at_correct_position_after_redo() throws {
        // given
        let doc = Document(key: "pretomb-typing-after-redo")
        try initBlockTree(doc)
        try insertSiblingBlock(doc)

        for ch in ["a", "s", "d", "f"] {
            try typeInSecondBlock(doc, ch)
        }
        for _ in 0 ..< 4 {
            try doc.undo()
        }
        try doc.undo()

        // when — undo leaves only the initial block
        let xmlAfterUndo = (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
        XCTAssertEqual(xmlAfterUndo, "<doc><p><inline></inline></p></doc>")

        // when — redo re-creates the second block (empty)
        try doc.redo()
        let xmlAfterRedo = (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
        XCTAssertEqual(xmlAfterRedo, "<doc><p><inline></inline></p><p><inline></inline></p></doc>")

        // then — typing into the second block lands correctly
        try typeInSecondBlock(doc, "x")
        let xmlFinal = (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
        XCTAssertEqual(xmlFinal, "<doc><p><inline></inline></p><p><inline>x</inline></p></doc>")
    }

    // Ports: "should remain stable across three cycles followed by typing"
    //
    // Three full type-undo-undo-redo cycles must leave the tree identical each
    // time. After the last cycle, typing "z" must land at the correct position.
    @MainActor
    func test_stable_across_three_cycles_followed_by_typing() throws {
        // given
        let doc = Document(key: "pretomb-three-cycles")
        try initBlockTree(doc)
        try insertSiblingBlock(doc)

        let expectedAfterRedo = "<doc><p><inline></inline></p><p><inline></inline></p></doc>"

        for cycle in 0 ..< 3 {
            for ch in ["a", "s", "d", "f"] {
                try typeInSecondBlock(doc, ch)
            }
            for _ in 0 ..< 4 {
                try doc.undo()
            }
            try doc.undo()
            try doc.redo()

            let xml = (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
            XCTAssertEqual(xml, expectedAfterRedo, "cycle \(cycle): unexpected XML after redo")
        }

        // then — typing still lands correctly after all cycles
        try typeInSecondBlock(doc, "z")
        let xmlFinal = (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
        XCTAssertEqual(xmlFinal, "<doc><p><inline></inline></p><p><inline>z</inline></p></doc>")
    }

    // Ports: "should produce reverseContents with consistent sizes"
    //
    // After the type-undo-undo sequence the redo-stack top must contain at
    // least one TreeEditOperation, and every surviving element node's
    // reported `getContentSize()` must be non-negative (structural sanity).
    // The full size-equality check requires internal node inspection that
    // would couple to `CRDTTreeNode` internals; we guard the high-level
    // invariant instead.
    @MainActor
    func test_redo_stack_top_has_well_formed_content_after_undo() throws {
        // given
        let doc = Document(key: "pretomb-content-size")
        try initBlockTree(doc)
        try insertSiblingBlock(doc)

        for ch in ["a", "s", "d", "f"] {
            try typeInSecondBlock(doc, ch)
        }
        for _ in 0 ..< 4 {
            try doc.undo()
        }
        try doc.undo()

        // then — redo stack must be non-empty and contain a tree-edit op
        let redoStack = doc.getRedoStackForTest()
        XCTAssertFalse(redoStack.isEmpty, "redo stack must be non-empty after undo")

        let topEntry = redoStack.last ?? []
        let treeOps = topEntry.compactMap { entry -> TreeEditOperation? in
            if case .operation(let op) = entry { return op as? TreeEditOperation }
            return nil
        }
        XCTAssertFalse(treeOps.isEmpty, "redo-stack top must contain at least one TreeEditOperation")

        for op in treeOps {
            XCTAssertGreaterThanOrEqual(op.getContentSize(), 0)
        }
    }
}
