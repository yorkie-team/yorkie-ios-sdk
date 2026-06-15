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

/// Initial tree: <doc><p>The fox jumped.</p></doc>
///
/// Mirrors `initTree` from the JS test file.
@MainActor
private func initTreeFox(_ doc: Document) throws {
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeTextNode(value: "The fox jumped.")
                ])
            ])
        )
    }
}

/// Returns the XML of the `t` field in the document root.
///
/// Mirrors `xmlOf` from the JS test file.
@MainActor
private func xmlOf(_ doc: Document) -> String {
    (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
}

/// Applies tree operations from the perspective of client 1 (operates at middle / end).
///
/// Mirrors `applyTreeOp1` in the JS source.
@MainActor
private func applyTreeOp1(_ doc: Document, _ op: String) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        switch op {
        case "insert-text":
            // Append "X" at end of <p> text (before closing tag). Index 16 is before </p>.
            try tree.edit(16, 16, JSONTreeTextNode(value: "X"))
        case "delete-text":
            // Delete char at middle: "fox" → "fx" (delete 'o' at index 6).
            try tree.edit(6, 7)
        case "insert-element":
            // Add <p>New</p> after first <p>.
            try tree.edit(17, 17, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "New")]))
        case "delete-element":
            // Delete first <p> entirely: indices [0, 17).
            try tree.edit(0, 17)
        case "replace-text":
            // Replace 'fox' with 'cat': indices [5, 8).
            try tree.edit(5, 8, JSONTreeTextNode(value: "cat"))
        case "replace-element":
            // Replace first <p> with <p>Replaced</p>.
            try tree.edit(0, 17, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "Replaced")]))
        default:
            break
        }
    }
}

/// Applies tree operations from the perspective of client 2 (operates at different positions).
///
/// Mirrors `applyTreeOp2` in the JS source.
@MainActor
private func applyTreeOp2(_ doc: Document, _ op: String) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        switch op {
        case "insert-text":
            // Insert "Q" at start of <p> text.
            try tree.edit(1, 1, JSONTreeTextNode(value: "Q"))
        case "delete-text":
            // Delete last char '.' at end of text.
            try tree.edit(15, 16)
        case "insert-element":
            // Insert <p>Front</p> before first <p>.
            try tree.edit(0, 0, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "Front")]))
        default:
            break
        }
    }
}

// MARK: - 1. Single Client - Basic Undo/Redo

final class TreeHistorySingleClientBasicTests: XCTestCase {
    // Ports: "should undo/redo insert-text"
    @MainActor
    func test_can_undo_redo_insert_text() async throws {
        // given
        let doc = Document(key: "tree-history-basic-insert-text")
        try initTreeFox(doc)

        let before = xmlOf(doc)

        // when
        try applyTreeOp1(doc, "insert-text")
        let after = xmlOf(doc)

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before, "undo insert-text failed")

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after, "redo insert-text failed")
    }

    // Ports: "should undo/redo delete-text"
    @MainActor
    func test_can_undo_redo_delete_text() async throws {
        // given
        let doc = Document(key: "tree-history-basic-delete-text")
        try initTreeFox(doc)

        let before = xmlOf(doc)

        // when
        try applyTreeOp1(doc, "delete-text")
        let after = xmlOf(doc)

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before, "undo delete-text failed")

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after, "redo delete-text failed")
    }

    // Ports: "should undo/redo insert-element"
    @MainActor
    func test_can_undo_redo_insert_element() async throws {
        // given
        let doc = Document(key: "tree-history-basic-insert-elem")
        try initTreeFox(doc)

        let before = xmlOf(doc)

        // when
        try applyTreeOp1(doc, "insert-element")
        let after = xmlOf(doc)

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before, "undo insert-element failed")

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after, "redo insert-element failed")
    }

    // Ports: "should undo/redo delete-element"
    @MainActor
    func test_can_undo_redo_delete_element() async throws {
        // given
        let doc = Document(key: "tree-history-basic-delete-elem")
        try initTreeFox(doc)

        let before = xmlOf(doc)

        // when
        try applyTreeOp1(doc, "delete-element")
        let after = xmlOf(doc)

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before, "undo delete-element failed")

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after, "redo delete-element failed")
    }

    // Ports: "should undo/redo replace-text"
    @MainActor
    func test_can_undo_redo_replace_text() async throws {
        // given
        let doc = Document(key: "tree-history-basic-replace-text")
        try initTreeFox(doc)

        let before = xmlOf(doc)

        // when
        try applyTreeOp1(doc, "replace-text")
        let after = xmlOf(doc)

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before, "undo replace-text failed")

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after, "redo replace-text failed")
    }

    // Ports: "should undo/redo replace-element"
    @MainActor
    func test_can_undo_redo_replace_element() async throws {
        // given
        let doc = Document(key: "tree-history-basic-replace-elem")
        try initTreeFox(doc)

        let before = xmlOf(doc)

        // when
        try applyTreeOp1(doc, "replace-element")
        let after = xmlOf(doc)

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before, "undo replace-element failed")

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after, "redo replace-element failed")
    }

    // Ports: "should handle undo-redo round trip multiple times"
    @MainActor
    func test_can_handle_undo_redo_round_trip_multiple_times() async throws {
        // given
        let doc = Document(key: "tree-history-round-trip")
        try initTreeFox(doc)

        let initial = xmlOf(doc)

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "Hello "))
        }
        let modified = xmlOf(doc)

        // when/then — three consecutive undo/redo cycles must restore the same states
        for round in 0 ..< 3 {
            try doc.undo()
            XCTAssertEqual(xmlOf(doc), initial, "round \(round) undo failed")
            try doc.redo()
            XCTAssertEqual(xmlOf(doc), modified, "round \(round) redo failed")
        }
    }

    // Ports: "should clear redo stack when new edit is made after undo"
    @MainActor
    func test_clears_redo_stack_when_new_edit_is_made_after_undo() async throws {
        // given
        let doc = Document(key: "tree-history-clear-redo")
        try initTreeFox(doc)

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(16, 16, JSONTreeTextNode(value: "X"))
        }

        // when — undo then make a new edit
        try doc.undo()
        XCTAssertTrue(doc.canRedo)

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "Z"))
        }

        // then — redo stack is cleared
        XCTAssertFalse(doc.canRedo)
    }
}

// MARK: - 2. Single Client - Chained Ops

final class TreeHistorySingleClientChainedOpsTests: XCTestCase {
    // Applies one chained operation using safe, position-stable operations.
    //
    // Mirrors `applyChainOp` inside the JS chained ops loop.
    @MainActor
    private func applyChainOp(_ doc: Document, _ op: String) throws {
        try doc.update { root, _ in
            guard let tree = root.t as? JSONTree else { return }
            switch op {
            case "insert-text":
                // Insert at end of content in first <p> using editByPath.
                try tree.editByPath([0, 1], [0, 1], JSONTreeTextNode(value: "X"))
            case "delete-text":
                // Delete first char in first <p>.
                try tree.edit(1, 2)
            case "insert-element":
                // Insert new <p> at end using editByPath.
                try tree.editByPath([1], [1], JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "N")]))
            default:
                break
            }
        }
    }

    // Shared implementation for all chained-op tests.
    @MainActor
    private func runChainTest(_ op1: String, _ op2: String, _ op3: String) throws {
        let key = "tree-chain-\(op1)-\(op2)-\(op3)".toDocKey
        let doc = Document(key: key)

        // given — initial tree with <doc><p>ABCD</p></doc>
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeTextNode(value: "ABCD")
                    ])
                ])
            )
        }

        var snapshots: [String] = [xmlOf(doc)]

        // when — apply three operations sequentially, recording snapshots
        try applyChainOp(doc, op1)
        snapshots.append(xmlOf(doc))
        try self.applyChainOp(doc, op2)
        snapshots.append(xmlOf(doc))
        try self.applyChainOp(doc, op3)
        snapshots.append(xmlOf(doc))

        // then — undo: S3 → S2 → S1 → S0
        for step in stride(from: 3, through: 1, by: -1) {
            try doc.undo()
            XCTAssertEqual(xmlOf(doc), snapshots[step - 1], "undo to S\(step - 1) (\(op1)-\(op2)-\(op3))")
        }

        // then — redo: S0 → S1 → S2 → S3
        for step in 0 ..< 3 {
            try doc.redo()
            XCTAssertEqual(xmlOf(doc), snapshots[step + 1], "redo to S\(step + 1) (\(op1)-\(op2)-\(op3))")
        }
    }

    // Ports: "should undo chain correctly: insert-text-insert-text-insert-text"
    @MainActor
    func test_can_undo_chain_insert_text_insert_text_insert_text() async throws {
        try self.runChainTest("insert-text", "insert-text", "insert-text")
    }

    // Ports: "should undo chain correctly: insert-text-insert-text-delete-text"
    @MainActor
    func test_can_undo_chain_insert_text_insert_text_delete_text() async throws {
        try self.runChainTest("insert-text", "insert-text", "delete-text")
    }

    // Ports: "should undo chain correctly: insert-text-insert-text-insert-element"
    @MainActor
    func test_can_undo_chain_insert_text_insert_text_insert_element() async throws {
        try self.runChainTest("insert-text", "insert-text", "insert-element")
    }

    // Ports: "should undo chain correctly: insert-text-delete-text-insert-text"
    @MainActor
    func test_can_undo_chain_insert_text_delete_text_insert_text() async throws {
        try self.runChainTest("insert-text", "delete-text", "insert-text")
    }

    // Ports: "should undo chain correctly: insert-text-delete-text-delete-text"
    @MainActor
    func test_can_undo_chain_insert_text_delete_text_delete_text() async throws {
        try self.runChainTest("insert-text", "delete-text", "delete-text")
    }

    // Ports: "should undo chain correctly: insert-text-delete-text-insert-element"
    @MainActor
    func test_can_undo_chain_insert_text_delete_text_insert_element() async throws {
        try self.runChainTest("insert-text", "delete-text", "insert-element")
    }

    // Ports: "should undo chain correctly: insert-text-insert-element-insert-text"
    @MainActor
    func test_can_undo_chain_insert_text_insert_element_insert_text() async throws {
        try self.runChainTest("insert-text", "insert-element", "insert-text")
    }

    // Ports: "should undo chain correctly: insert-text-insert-element-delete-text"
    @MainActor
    func test_can_undo_chain_insert_text_insert_element_delete_text() async throws {
        try self.runChainTest("insert-text", "insert-element", "delete-text")
    }

    // Ports: "should undo chain correctly: insert-text-insert-element-insert-element"
    @MainActor
    func test_can_undo_chain_insert_text_insert_element_insert_element() async throws {
        try self.runChainTest("insert-text", "insert-element", "insert-element")
    }

    // Ports: "should undo chain correctly: delete-text-insert-text-insert-text"
    @MainActor
    func test_can_undo_chain_delete_text_insert_text_insert_text() async throws {
        try self.runChainTest("delete-text", "insert-text", "insert-text")
    }

    // Ports: "should undo chain correctly: delete-text-insert-text-delete-text"
    @MainActor
    func test_can_undo_chain_delete_text_insert_text_delete_text() async throws {
        try self.runChainTest("delete-text", "insert-text", "delete-text")
    }

    // Ports: "should undo chain correctly: delete-text-insert-text-insert-element"
    @MainActor
    func test_can_undo_chain_delete_text_insert_text_insert_element() async throws {
        try self.runChainTest("delete-text", "insert-text", "insert-element")
    }

    // Ports: "should undo chain correctly: delete-text-delete-text-insert-text"
    @MainActor
    func test_can_undo_chain_delete_text_delete_text_insert_text() async throws {
        try self.runChainTest("delete-text", "delete-text", "insert-text")
    }

    // Ports: "should undo chain correctly: delete-text-delete-text-delete-text"
    @MainActor
    func test_can_undo_chain_delete_text_delete_text_delete_text() async throws {
        try self.runChainTest("delete-text", "delete-text", "delete-text")
    }

    // Ports: "should undo chain correctly: delete-text-delete-text-insert-element"
    @MainActor
    func test_can_undo_chain_delete_text_delete_text_insert_element() async throws {
        try self.runChainTest("delete-text", "delete-text", "insert-element")
    }

    // Ports: "should undo chain correctly: delete-text-insert-element-insert-text"
    @MainActor
    func test_can_undo_chain_delete_text_insert_element_insert_text() async throws {
        try self.runChainTest("delete-text", "insert-element", "insert-text")
    }

    // Ports: "should undo chain correctly: delete-text-insert-element-delete-text"
    @MainActor
    func test_can_undo_chain_delete_text_insert_element_delete_text() async throws {
        try self.runChainTest("delete-text", "insert-element", "delete-text")
    }

    // Ports: "should undo chain correctly: delete-text-insert-element-insert-element"
    @MainActor
    func test_can_undo_chain_delete_text_insert_element_insert_element() async throws {
        try self.runChainTest("delete-text", "insert-element", "insert-element")
    }

    // Ports: "should undo chain correctly: insert-element-insert-text-insert-text"
    @MainActor
    func test_can_undo_chain_insert_element_insert_text_insert_text() async throws {
        try self.runChainTest("insert-element", "insert-text", "insert-text")
    }

    // Ports: "should undo chain correctly: insert-element-insert-text-delete-text"
    @MainActor
    func test_can_undo_chain_insert_element_insert_text_delete_text() async throws {
        try self.runChainTest("insert-element", "insert-text", "delete-text")
    }

    // Ports: "should undo chain correctly: insert-element-insert-text-insert-element"
    @MainActor
    func test_can_undo_chain_insert_element_insert_text_insert_element() async throws {
        try self.runChainTest("insert-element", "insert-text", "insert-element")
    }

    // Ports: "should undo chain correctly: insert-element-delete-text-insert-text"
    @MainActor
    func test_can_undo_chain_insert_element_delete_text_insert_text() async throws {
        try self.runChainTest("insert-element", "delete-text", "insert-text")
    }

    // Ports: "should undo chain correctly: insert-element-delete-text-delete-text"
    @MainActor
    func test_can_undo_chain_insert_element_delete_text_delete_text() async throws {
        try self.runChainTest("insert-element", "delete-text", "delete-text")
    }

    // Ports: "should undo chain correctly: insert-element-delete-text-insert-element"
    @MainActor
    func test_can_undo_chain_insert_element_delete_text_insert_element() async throws {
        try self.runChainTest("insert-element", "delete-text", "insert-element")
    }

    // Ports: "should undo chain correctly: insert-element-insert-element-insert-text"
    @MainActor
    func test_can_undo_chain_insert_element_insert_element_insert_text() async throws {
        try self.runChainTest("insert-element", "insert-element", "insert-text")
    }

    // Ports: "should undo chain correctly: insert-element-insert-element-delete-text"
    @MainActor
    func test_can_undo_chain_insert_element_insert_element_delete_text() async throws {
        try self.runChainTest("insert-element", "insert-element", "delete-text")
    }

    // Ports: "should undo chain correctly: insert-element-insert-element-insert-element"
    @MainActor
    func test_can_undo_chain_insert_element_insert_element_insert_element() async throws {
        try self.runChainTest("insert-element", "insert-element", "insert-element")
    }
}

// MARK: - 3. Single Client - Edge Cases

final class TreeHistorySingleClientEdgeCasesTests: XCTestCase {
    // Ports: "should handle edit at start position"
    @MainActor
    func test_can_handle_edit_at_start_position() async throws {
        // given
        let doc = Document(key: "tree-history-edge-start")
        try initTreeFox(doc)

        let before = xmlOf(doc)

        // when — replace "The" (indices 1–4) with "A"
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 4, JSONTreeTextNode(value: "A"))
        }
        let after = xmlOf(doc)

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after)
    }

    // Ports: "should handle edit at middle position"
    @MainActor
    func test_can_handle_edit_at_middle_position() async throws {
        // given
        let doc = Document(key: "tree-history-edge-middle")
        try initTreeFox(doc)

        let before = xmlOf(doc)

        // when — replace 'fox' (indices 5–8) with 'cat'
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(5, 8, JSONTreeTextNode(value: "cat"))
        }
        let after = xmlOf(doc)

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after)
    }

    // Ports: "should handle edit at end position"
    @MainActor
    func test_can_handle_edit_at_end_position() async throws {
        // given
        let doc = Document(key: "tree-history-edge-end")
        try initTreeFox(doc)

        let before = xmlOf(doc)

        // when — append '!' at end of text (index 16)
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(16, 16, JSONTreeTextNode(value: "!"))
        }
        let after = xmlOf(doc)

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after)
    }

    // Ports: "should handle full tree deletion + undo"
    @MainActor
    func test_can_handle_full_tree_deletion_and_undo() async throws {
        // given
        let doc = Document(key: "tree-history-edge-delete-all")
        try initTreeFox(doc)

        let before = xmlOf(doc)

        // when — delete entire <p> contents
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(0, 17)
        }
        XCTAssertEqual(xmlOf(doc), "<doc></doc>")

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), "<doc></doc>")
    }

    // Ports: "should handle empty undo/redo stacks"
    @MainActor
    func test_can_handle_empty_undo_redo_stacks() async throws {
        // given
        let doc = Document(key: "tree-history-edge-empty-stack")
        try initTreeFox(doc)

        // The init update itself is undoable.
        XCTAssertTrue(doc.canUndo)

        // when — undo the init
        try doc.undo()

        // then — nothing more to undo
        XCTAssertFalse(doc.canUndo)
    }

    // Ports: "should handle rapid consecutive edits"
    @MainActor
    func test_can_handle_rapid_consecutive_edits() async throws {
        // given — empty <p> node
        let doc = Document(key: "tree-history-edge-rapid")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [])
                ])
            )
        }

        var states: [String] = [xmlOf(doc)]

        // when — insert digits 0–9 one at a time at position 1 (inside <p>)
        for digit in 0 ..< 10 {
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: String(digit)))
            }
            states.append(xmlOf(doc))
        }

        // then — undo all in reverse order
        for index in stride(from: 9, through: 0, by: -1) {
            try doc.undo()
            XCTAssertEqual(xmlOf(doc), states[index])
        }

        // then — redo all in forward order
        for index in 1 ... 10 {
            try doc.redo()
            XCTAssertEqual(xmlOf(doc), states[index])
        }
    }
}

// MARK: - 4. Single Client - Split/Merge

final class TreeHistorySingleClientSplitMergeTests: XCTestCase {
    // Ports: "should undo splitByPath"
    //
    // splitByPath/mergeByPath decompose into several `editInternal` calls (each splitLevel == 0)
    // inside a single `doc.update { }`. All of those land in one change, so their reverse ops are
    // pushed as a single undo-stack entry — one `doc.undo()` reverts the whole split, matching the
    // JS spec.
    @MainActor
    func test_can_undo_splitByPath() async throws {
        // given
        let doc = Document(key: "tree-history-split-undo")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeTextNode(value: "ABCD")
                    ])
                ])
            )
        }

        let before = xmlOf(doc)
        XCTAssertEqual(before, "<doc><p>ABCD</p></doc>")

        // when — split at offset 2 inside the text (between "AB" and "CD")
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.splitByPath([0, 2])
        }
        let after = xmlOf(doc)
        XCTAssertEqual(after, "<doc><p>AB</p><p>CD</p></doc>")

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)
    }

    // Ports: "should redo splitByPath"
    @MainActor
    func test_can_redo_splitByPath() async throws {
        // given
        let doc = Document(key: "tree-history-split-redo")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeTextNode(value: "ABCD")
                    ])
                ])
            )
        }

        let before = xmlOf(doc)

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.splitByPath([0, 2])
        }
        let after = xmlOf(doc)
        XCTAssertEqual(after, "<doc><p>AB</p><p>CD</p></doc>")

        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after)
    }

    // Ports: "should undo mergeByPath"
    @MainActor
    func test_can_undo_mergeByPath() async throws {
        // given
        let doc = Document(key: "tree-history-merge-undo")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "AB")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "CD")])
                ])
            )
        }

        let before = xmlOf(doc)
        XCTAssertEqual(before, "<doc><p>AB</p><p>CD</p></doc>")

        // when — merge second <p> into first
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.mergeByPath([1])
        }
        let after = xmlOf(doc)
        XCTAssertEqual(after, "<doc><p>ABCD</p></doc>")

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)
    }

    // Ports: "should redo mergeByPath"
    @MainActor
    func test_can_redo_mergeByPath() async throws {
        // given
        let doc = Document(key: "tree-history-merge-redo")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "AB")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "CD")])
                ])
            )
        }

        let before = xmlOf(doc)

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.mergeByPath([1])
        }
        let after = xmlOf(doc)
        XCTAssertEqual(after, "<doc><p>ABCD</p></doc>")

        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)

        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after)
    }
}

// MARK: - 5. Multi Client - Basic

final class TreeHistoryMultiClientBasicTests: XCTestCase {
    // MARK: undo convergence

    // Ports: "should converge after undo: insert-text-insert-text"
    @MainActor
    func test_can_converge_after_undo_insert_text_insert_text() async throws {
        try await self.runUndoConvergenceTest(op1: "insert-text", op2: "insert-text")
    }

    // Ports: "should converge after undo: insert-text-delete-text"
    @MainActor
    func test_can_converge_after_undo_insert_text_delete_text() async throws {
        try await self.runUndoConvergenceTest(op1: "insert-text", op2: "delete-text")
    }

    // Ports: "should converge after undo: insert-text-insert-element"
    @MainActor
    func test_can_converge_after_undo_insert_text_insert_element() async throws {
        try await self.runUndoConvergenceTest(op1: "insert-text", op2: "insert-element")
    }

    // Ports: "should converge after undo: delete-text-insert-text"
    @MainActor
    func test_can_converge_after_undo_delete_text_insert_text() async throws {
        try await self.runUndoConvergenceTest(op1: "delete-text", op2: "insert-text")
    }

    // Ports: "should converge after undo: delete-text-delete-text"
    @MainActor
    func test_can_converge_after_undo_delete_text_delete_text() async throws {
        try await self.runUndoConvergenceTest(op1: "delete-text", op2: "delete-text")
    }

    // Ports: "should converge after undo: delete-text-insert-element"
    @MainActor
    func test_can_converge_after_undo_delete_text_insert_element() async throws {
        try await self.runUndoConvergenceTest(op1: "delete-text", op2: "insert-element")
    }

    // Ports: "should converge after undo: insert-element-insert-text"
    @MainActor
    func test_can_converge_after_undo_insert_element_insert_text() async throws {
        try await self.runUndoConvergenceTest(op1: "insert-element", op2: "insert-text")
    }

    // Ports: "should converge after undo: insert-element-delete-text"
    @MainActor
    func test_can_converge_after_undo_insert_element_delete_text() async throws {
        try await self.runUndoConvergenceTest(op1: "insert-element", op2: "delete-text")
    }

    // Ports: "should converge after undo: insert-element-insert-element"
    @MainActor
    func test_can_converge_after_undo_insert_element_insert_element() async throws {
        try await self.runUndoConvergenceTest(op1: "insert-element", op2: "insert-element")
    }

    // MARK: redo convergence

    // Ports: "should converge after redo: insert-text-insert-text"
    @MainActor
    func test_can_converge_after_redo_insert_text_insert_text() async throws {
        try await self.runRedoConvergenceTest(op1: "insert-text", op2: "insert-text")
    }

    // Ports: "should converge after redo: insert-text-delete-text" — skipped in JS (TODO Phase 2).
    func test_can_converge_after_redo_insert_text_delete_text() throws {
        throw XCTSkip("Phase 2: redo insert-text × delete-text diverges — mirrors JS it.skip")
    }

    // Ports: "should converge after redo: insert-text-insert-element"
    @MainActor
    func test_can_converge_after_redo_insert_text_insert_element() async throws {
        try await self.runRedoConvergenceTest(op1: "insert-text", op2: "insert-element")
    }

    // Ports: "should converge after redo: delete-text-insert-text"
    @MainActor
    func test_can_converge_after_redo_delete_text_insert_text() async throws {
        try await self.runRedoConvergenceTest(op1: "delete-text", op2: "insert-text")
    }

    // Ports: "should converge after redo: delete-text-delete-text"
    @MainActor
    func test_can_converge_after_redo_delete_text_delete_text() async throws {
        try await self.runRedoConvergenceTest(op1: "delete-text", op2: "delete-text")
    }

    // Ports: "should converge after redo: delete-text-insert-element"
    @MainActor
    func test_can_converge_after_redo_delete_text_insert_element() async throws {
        try await self.runRedoConvergenceTest(op1: "delete-text", op2: "insert-element")
    }

    // Ports: "should converge after redo: insert-element-insert-text"
    @MainActor
    func test_can_converge_after_redo_insert_element_insert_text() async throws {
        try await self.runRedoConvergenceTest(op1: "insert-element", op2: "insert-text")
    }

    // Ports: "should converge after redo: insert-element-delete-text"
    @MainActor
    func test_can_converge_after_redo_insert_element_delete_text() async throws {
        try await self.runRedoConvergenceTest(op1: "insert-element", op2: "delete-text")
    }

    // Ports: "should converge after redo: insert-element-insert-element"
    @MainActor
    func test_can_converge_after_redo_insert_element_insert_element() async throws {
        try await self.runRedoConvergenceTest(op1: "insert-element", op2: "insert-element")
    }

    // MARK: - Shared implementations

    @MainActor
    private func runUndoConvergenceTest(op1: String, op2: String) async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — init tree on d1 and sync to d2
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [
                            JSONTreeTextNode(value: "The fox jumped.")
                        ])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — both clients apply concurrent ops
            try applyTreeOp1(d1, op1)
            try applyTreeOp2(d2, op2)

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON(), "after ops (\(op1) × \(op2))")

            // when — both clients undo
            try d1.undo()
            try d2.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — documents converge after undo
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON(), "after undo (\(op1) × \(op2))")
        }
    }

    @MainActor
    private func runRedoConvergenceTest(op1: String, op2: String) async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — init tree on d1 and sync to d2
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [
                            JSONTreeTextNode(value: "The fox jumped.")
                        ])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — both clients apply concurrent ops
            try applyTreeOp1(d1, op1)
            try applyTreeOp2(d2, op2)

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // undo
            try d1.undo()
            try d2.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // redo
            try d1.redo()
            try d2.redo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — documents converge after redo
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON(), "after redo (\(op1) × \(op2))")
        }
    }
}

// MARK: - 6. Multi Client - Reconcile Cases

final class TreeHistoryReconcileCasesTests: XCTestCase {
    // Ports: "Case 1 (left): remote edit LEFT of undo should shift position"
    @MainActor
    func test_case1_remote_edit_left_of_undo_shifts_position() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — <doc><p>0123456789</p></doc>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [
                            JSONTreeTextNode(value: "0123456789")
                        ])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 deletes [7,9) = "67"; d2 inserts "XX" at 3 (left of d1's range)
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(7, 9) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "XX")) }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            try d1.undo()
            try d2.undo()
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            try d1.redo()
            try d2.redo()
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    // Ports: "Case 2 (right): remote edit RIGHT of undo should not affect"
    @MainActor
    func test_case2_remote_edit_right_of_undo_is_unaffected() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — <doc><p>0123456789</p></doc>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [
                            JSONTreeTextNode(value: "0123456789")
                        ])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 deletes [3,5) = "23"; d2 inserts "YY" at 9 (right of d1's range)
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(3, 5) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(9, 9, JSONTreeTextNode(value: "YY")) }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            try d1.undo()
            try d2.undo()
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            try d1.redo()
            try d2.redo()
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    // Ports: "Case 3 (contained_by): undo range contained by remote should collapse"
    // JS marks this .skip (TODO Phase 2).
    @MainActor
    func test_case3_undo_range_contained_by_remote_collapses() async throws {
        throw XCTSkip("Phase 2: overlapping reconciliation (Case 3 contained_by) not yet supported — mirrors JS it.skip")
    }

    // Ports: "Case 4 (contains): remote range contained by undo should adjust"
    // JS marks this .skip (TODO Phase 2).
    @MainActor
    func test_case4_remote_range_contained_by_undo_adjusts() async throws {
        throw XCTSkip("Phase 2: overlapping reconciliation (Case 4 contains) not yet supported — mirrors JS it.skip")
    }

    // Ports: "Case 5 (overlap_start): remote overlaps start of undo range"
    // JS marks this .skip (TODO Phase 2).
    @MainActor
    func test_case5_remote_overlaps_start_of_undo_range() async throws {
        throw XCTSkip("Phase 2: overlapping reconciliation (Case 5 overlap_start) not yet supported — mirrors JS it.skip")
    }

    // Ports: "Case 6 (overlap_end): remote overlaps end of undo range"
    // JS marks this .skip (TODO Phase 2).
    @MainActor
    func test_case6_remote_overlaps_end_of_undo_range() async throws {
        throw XCTSkip("Phase 2: overlapping reconciliation (Case 6 overlap_end) not yet supported — mirrors JS it.skip")
    }

    // Ports: "Case 7 (adjacent): adjacent edits at boundary"
    @MainActor
    func test_case7_adjacent_edits_at_boundary() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — <doc><p>0123456789</p></doc>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [
                            JSONTreeTextNode(value: "0123456789")
                        ])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 deletes [5,7) = "56"; d2 inserts "AA" at 7 (adjacent to d1's range end)
            try d1.update { root, _ in try (root.t as? JSONTree)?.edit(5, 7) }
            try d2.update { root, _ in try (root.t as? JSONTree)?.edit(7, 7, JSONTreeTextNode(value: "AA")) }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            try d1.undo()
            try d2.undo()
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            try d1.redo()
            try d2.redo()
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }
}

// MARK: - 7. Multi Client - Edge Cases

final class TreeHistoryMultiClientEdgeCasesTests: XCTestCase {
    // Ports: "should converge with concurrent element + text edits"
    @MainActor
    func test_can_converge_with_concurrent_element_and_text_edits() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — <doc><p>ABCD</p></doc>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [
                            JSONTreeTextNode(value: "ABCD")
                        ])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 inserts a new element, d2 inserts text
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(5, 5, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "New")]))
            }
            try d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "X"))
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            // when — both clients undo
            try d1.undo()
            try d2.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — documents converge after concurrent undo
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    // Ports: "should converge with concurrent text edits in same paragraph"
    @MainActor
    func test_can_converge_with_concurrent_text_edits_in_same_paragraph() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — <doc><p>ABCDEFGH</p></doc>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [
                            JSONTreeTextNode(value: "ABCDEFGH")
                        ])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — both clients edit different non-overlapping ranges in the same paragraph
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 5, JSONTreeTextNode(value: "XX"))
            }
            try d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(7, 9, JSONTreeTextNode(value: "YY"))
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            // when — d1 undoes then redoes; d2 just undoes
            try d1.undo()
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            try d1.redo()
            try d2.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — documents converge
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    // Ports: "should converge with nested structure concurrent edits"
    @MainActor
    func test_can_converge_with_nested_structure_concurrent_edits() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — <doc><p>AB</p><p>CD</p></doc>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "AB")]),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "CD")])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1 edits in first <p>, d2 edits in second <p>
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "X"))
            }
            try d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(5, 5, JSONTreeTextNode(value: "Y"))
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            // when — both undo
            try d1.undo()
            try d2.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            // when — both redo
            try d1.redo()
            try d2.redo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — documents converge after redo
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }
}
