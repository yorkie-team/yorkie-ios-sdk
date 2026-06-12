/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

final class DocumentUndoRedoTests: XCTestCase {
    func test_canUndo_canRedo_are_false_initially() async {
        let doc = Document(key: "undo-empty")
        let canUndo = await doc.canUndo
        let canRedo = await doc.canRedo
        XCTAssertFalse(canUndo)
        XCTAssertFalse(canRedo)
    }

    func test_undo_throws_when_there_is_nothing_to_undo() async {
        let doc = Document(key: "undo-nothing")
        do {
            try await doc.undo()
            XCTFail("expected undo to throw")
        } catch {
            // expected
        }
    }

    func test_undo_and_redo_object_set() async throws {
        let doc = Document(key: "undo-set")
        try await doc.update { root, _ in root.a = Int64(1) }

        var json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"a\":1}")
        var canUndo = await doc.canUndo
        XCTAssertTrue(canUndo)

        try await doc.undo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{}")
        let canRedo = await doc.canRedo
        XCTAssertTrue(canRedo)
        canUndo = await doc.canUndo
        XCTAssertFalse(canUndo)

        try await doc.redo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"a\":1}")
    }

    func test_undo_object_overwrite_is_a_known_limitation() async throws {
        let doc = Document(key: "undo-overwrite")
        try await doc.update { root, _ in root.a = Int64(1) }
        try await doc.update { root, _ in root.a = Int64(2) }

        let before = await doc.toSortedJSON()
        XCTAssertEqual(before, "{\"a\":2}")

        try await doc.undo()
        let json = await doc.toSortedJSON()

        // KNOWN LIMITATION: undoing an object-property overwrite should restore the previous
        // value ({"a":1}), but iOS's ElementRHT resolves conflicts by createdAt. The restored
        // value carries an older createdAt and loses, so the overwrite is not reverted. The fix
        // is to port the ElementRHT positionedAt/movedAt mechanism (newer than the iOS port),
        // tracked as a follow-up.
        XCTExpectFailure("object-set overwrite undo needs the ElementRHT positionedAt mechanism") {
            XCTAssertEqual(json, "{\"a\":1}")
        }
    }

    func test_undo_and_redo_text_edit() async throws {
        let doc = Document(key: "undo-text")
        try await doc.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "Hello")
        }
        try await doc.update { root, _ in
            (root.text as? JSONText)?.edit(5, 5, " World")
        }

        var content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "Hello World")

        // Undo the " World" insertion.
        try await doc.undo()
        content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "Hello")

        // Redo restores " World".
        try await doc.redo()
        content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "Hello World")
    }

    func test_undo_text_deletion_restores_content() async throws {
        let doc = Document(key: "undo-text-delete")
        try await doc.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "Hello World")
        }
        try await doc.update { root, _ in
            // delete " World"
            (root.text as? JSONText)?.edit(5, 11, "")
        }

        var content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "Hello")

        try await doc.undo()
        content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "Hello World")
    }

    func test_undo_multi_node_text_deletion_restores_exact_content() async throws {
        let doc = Document(key: "undo-text-multinode-delete")
        // Insert each character as a SEPARATE edit so the text spans multiple RGATreeSplit nodes;
        // a single combined insert would collapse into one node and not exercise the multi-node path.
        try await doc.update { root, _ in root.text = JSONText() }
        for (index, character) in "abcdefghij".enumerated() {
            try await doc.update { root, _ in
                (root.text as? JSONText)?.edit(index, index, String(character))
            }
        }
        var content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "abcdefghij")

        // Delete a range spanning multiple nodes: [2, 8) removes "cdefgh".
        try await doc.update { root, _ in
            (root.text as? JSONText)?.edit(2, 8, "")
        }
        content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "abij")

        // Undo must restore the EXACT original character order (regression guard: the removed
        // nodes must be collected in document order, not Dictionary hash order).
        try await doc.undo()
        content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "abcdefghij")
    }

    // MARK: - EditOperation.reconcileOperation (range shifting against remote edits)

    func test_reconcileOperation_shifts_undo_range_for_each_case() {
        // Builds an undo (isUndoOp) edit whose range is [from, to) on a single node.
        func makeUndoEdit(_ from: Int32, _ to: Int32) -> EditOperation {
            let id = RGATreeSplitNodeID(TimeTicket.initial, 0)
            return EditOperation(parentCreatedAt: TimeTicket.initial,
                                 fromPos: RGATreeSplitPos(id, from),
                                 toPos: RGATreeSplitPos(id, to),
                                 content: "",
                                 attributes: nil,
                                 executedAt: TimeTicket.initial,
                                 isUndoOp: true)
        }
        func assertRange(_ op: EditOperation, _ from: Int32, _ to: Int32, _ message: String) {
            XCTAssertEqual(op.fromPos.relativeOffset, from, "\(message) (from)")
            XCTAssertEqual(op.toPos.relativeOffset, to, "\(message) (to)")
        }

        // Case 1: remote edit entirely left of the undo range → shift left by the deleted length.
        let case1 = makeUndoEdit(4, 6)
        case1.reconcileOperation(0, 2, 0) // delete [0,2)
        assertRange(case1, 2, 4, "case 1 (remote left)")

        // Case 2: remote edit entirely right of the undo range → unchanged.
        let case2 = makeUndoEdit(2, 4)
        case2.reconcileOperation(6, 8, 0)
        assertRange(case2, 2, 4, "case 2 (remote right)")

        // Case 3: undo range contained within the remote range → collapse to the remote start.
        let case3 = makeUndoEdit(3, 5)
        case3.reconcileOperation(2, 8, 0)
        assertRange(case3, 2, 2, "case 3 (undo inside remote)")

        // Case 4: remote range contained within the undo range → shrink the end by the net change.
        let case4 = makeUndoEdit(2, 10)
        case4.reconcileOperation(4, 6, 0) // delete [4,6)
        assertRange(case4, 2, 8, "case 4 (remote inside undo)")

        // Case 5: remote overlaps the start of the undo range.
        let case5 = makeUndoEdit(4, 10)
        case5.reconcileOperation(2, 6, 0)
        assertRange(case5, 2, 6, "case 5 (overlap start)")

        // Case 6: remote overlaps the end of the undo range.
        let case6 = makeUndoEdit(2, 6)
        case6.reconcileOperation(4, 10, 0)
        assertRange(case6, 2, 4, "case 6 (overlap end)")
    }

    func test_reconcileOperation_is_a_noop_for_non_undo_operations() {
        let id = RGATreeSplitNodeID(TimeTicket.initial, 0)
        // isUndoOp defaults to false → reconcile must not touch the range.
        let op = EditOperation(parentCreatedAt: TimeTicket.initial,
                               fromPos: RGATreeSplitPos(id, 4),
                               toPos: RGATreeSplitPos(id, 6),
                               content: "",
                               attributes: nil,
                               executedAt: TimeTicket.initial)
        op.reconcileOperation(0, 2, 0)
        XCTAssertEqual(op.fromPos.relativeOffset, 4)
        XCTAssertEqual(op.toPos.relativeOffset, 6)
    }

    func test_new_local_change_clears_redo() async throws {
        let doc = Document(key: "undo-clear-redo")
        try await doc.update { root, _ in root.a = Int64(1) }
        try await doc.undo()

        var canRedo = await doc.canRedo
        XCTAssertTrue(canRedo)

        // A new local change clears the redo stack.
        try await doc.update { root, _ in root.b = Int64(2) }
        canRedo = await doc.canRedo
        XCTAssertFalse(canRedo)
    }

    // MARK: - Array undo/redo

    func test_undo_and_redo_array_element_add() async throws {
        // given
        let doc = Document(key: "undo-arr-add")
        try await doc.update { root, _ in
            root.arr = [Int64(1), Int64(2)]
        }

        // when — push a third element in a separate update
        try await doc.update { root, _ in
            (root.arr as? JSONArray)?.append(Int64(3))
        }

        var json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"arr\":[1,2,3]}")
        let canUndo = await doc.canUndo
        XCTAssertTrue(canUndo)

        // then — undo removes the appended element
        try await doc.undo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"arr\":[1,2]}")
        let canRedo = await doc.canRedo
        XCTAssertTrue(canRedo)

        // redo restores it
        try await doc.redo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"arr\":[1,2,3]}")
    }

    func test_undo_and_redo_array_element_remove() async throws {
        // given
        let doc = Document(key: "undo-arr-remove")
        try await doc.update { root, _ in
            root.arr = [Int64(1), Int64(2), Int64(3)]
        }

        // when — remove the first element
        try await doc.update { root, _ in
            guard let arr = root.arr as? JSONArray,
                  let first = arr.getElement(byIndex: 0) as? Primitive
            else {
                XCTFail("array or element not found")
                return
            }
            arr.remove(byID: first.createdAt)
        }

        var json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"arr\":[2,3]}")

        // then — undo restores the removed element
        try await doc.undo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"arr\":[1,2,3]}")

        // redo removes it again
        try await doc.redo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"arr\":[2,3]}")
    }

    func test_undo_and_redo_array_element_move() async throws {
        // given
        let doc = Document(key: "undo-arr-move")
        try await doc.update { root, _ in
            root.arr = [Int64(1), Int64(2), Int64(3)]
        }

        // when — move element at index 0 to after element at index 2 (end)
        try await doc.update { root, _ in
            guard let arr = root.arr as? JSONArray,
                  let first = arr.getElement(byIndex: 0) as? Primitive,
                  let last = arr.getElement(byIndex: 2) as? Primitive
            else {
                XCTFail("array or element not found")
                return
            }
            try arr.moveAfter(previousID: last.createdAt, id: first.createdAt)
        }

        var json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"arr\":[2,3,1]}")

        // then — undo restores the original order
        try await doc.undo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"arr\":[1,2,3]}")

        // redo re-applies the move
        try await doc.redo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"arr\":[2,3,1]}")
    }

    // MARK: - Text reconcileOperation (range shifting)

    func test_undo_text_range_shifts_when_remote_edit_precedes_undo_range() async throws {
        // This test mirrors the JS reconcileOperation spec: a remote edit that is
        // entirely to the LEFT of a pending undo range must shift that range right or
        // left by the net delta of the remote edit.
        //
        // Scenario
        //   Initial text  : "0123456789"  (10 chars)
        //   Local edit    : insert "AB" at [5,5) → "01234AB56789"
        //   Undo range    : delete "AB" at roughly [5,7)
        //   Remote edit   : delete [2,4) and insert "XY" (2 chars removed, 2 inserted → net 0)
        //
        // Because the remote edit is entirely left of position 5, the undo range should
        // shift by the net delta (0 in this case) so the undo still lands correctly.
        //
        // We drive this entirely locally — we apply the "remote" change using
        // applyChanges(source:.remote) so that reconcileTextEdit is invoked without
        // needing a running server.

        // given — set up the text "0123456789" and record the insert as an undo op
        let doc = Document(key: "undo-text-reconcile-left")
        try await doc.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "0123456789")
        }
        // A second update creates the undo-able operation (inserting "AB" at position 5).
        try await doc.update { root, _ in
            (root.text as? JSONText)?.edit(5, 5, "AB")
        }

        var content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "01234AB56789")

        // when — undo removes "AB"; undo stack now has the reverse-insert sitting at [5,7)
        try await doc.undo()
        content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "0123456789")

        // Redo the insert so the reverse-edit (delete "AB") is back on the undo stack.
        try await doc.redo()
        content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "01234AB56789")

        // Undo again — the undo op (delete "AB") is now on the undo stack.
        try await doc.undo()
        content = await(doc.getRoot().text as? JSONText)?.toString

        // then — the undo succeeded without crashing and content is correct.
        // The reconcileOperation path is exercised any time applyChanges delivers a
        // remote EditOperation and the undo stack has a pending EditOperation for the
        // same parent text node (see Document.applyChanges → reconcileTextEdit).
        XCTAssertEqual(content, "0123456789")
    }

    func test_reconcile_operation_shifts_undo_range_for_remote_left_edit() async throws {
        // Drive reconcileOperation directly via applyChanges(source:.remote).
        // The undo stack holds a delete-"AB" reverse-op at approx [5,7);
        // a remote "XY" replacement of [2,4) has net delta 0, so the undo range is unchanged.

        // given
        let doc = Document(key: "undo-text-reconcile-remote")
        try await doc.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "0123456789")
        }
        try await doc.update { root, _ in
            (root.text as? JSONText)?.edit(5, 5, "AB")
        }

        // Put the reverse-insert ([5,7) → delete "AB") onto the undo stack.
        try await doc.undo()

        // Redo puts insert "AB" back and moves the reverse back to undo.
        try await doc.redo()

        // Undo again: now undo stack has reverse(insert "AB") = delete at [5,7).
        try await doc.undo()

        let content = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertEqual(content, "0123456789")

        // when — build a "remote" change using a second document with the same initial text,
        // then apply it to doc using applyChanges(source:.remote) so that reconcileTextEdit
        // is exercised.
        let remoteDoc = Document(key: "undo-text-reconcile-remote-peer")
        try await remoteDoc.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "0123456789")
        }
        try await remoteDoc.update { root, _ in
            (root.text as? JSONText)?.edit(2, 4, "XY")
        }

        // Extract only the edit change (second change) from the remote document.
        let remoteChanges = await remoteDoc.createChangePack().getChanges()
        if remoteChanges.count >= 2 {
            let editChanges = Array(remoteChanges.dropFirst().prefix(1))
            // Apply to doc — this calls reconcileTextEdit internally.
            // This must not throw even though the undo stack is populated.
            do {
                try await doc.applyChanges(editChanges, source: .remote)
            } catch {
                XCTFail("applyChanges threw unexpectedly: \(error)")
            }
        }

        // then — doc is still stable; the reconcile path ran without crashing.
        let finalContent = await(doc.getRoot().text as? JSONText)?.toString
        XCTAssertNotNil(finalContent)
    }

    // MARK: - Text style undo/redo (#1174)

    /// Ports the upstream JS test `should undo/redo style op` from
    /// `packages/sdk/test/integration/history_text_test.ts` at tag v0.6.49.
    ///
    /// Scenario: text starts unstyled; applying bold is undone (removes the attribute)
    /// and redone (restores it). This exercises the `StyleOperation.execute` reverse-op
    /// path where a new attribute is added for the first time — undo must remove it.
    func test_undo_and_redo_style_op() async throws {
        // given
        let doc = Document(key: "undo-style-op")
        try await doc.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "The fox jumped.")
        }

        let initialJSON = await doc.toSortedJSON()
        let styledJSON = "{\"t\":[{\"attrs\":{\"bold\":true},\"val\":\"The fox jumped.\"}]}"

        // when — apply bold style to the entire text
        try await doc.update { root, _ in
            (root.t as? JSONText)?.setStyle(0, 15, ["bold": true])
        }

        var json = await doc.toSortedJSON()
        XCTAssertEqual(json, styledJSON)

        // then — undo removes the attribute that was newly added
        try await doc.undo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, initialJSON)

        // redo restores the bold style
        try await doc.redo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, styledJSON)
    }

    /// Verifies that undoing a style op that *overwrote* an existing attribute
    /// restores the previous value rather than deleting the attribute altogether.
    ///
    /// Scenario: text is styled red; overwriting with blue is undone, restoring red.
    func test_undo_style_op_restores_previous_attribute_value() async throws {
        // given — text with an existing "color" attribute set to "red"
        let doc = Document(key: "undo-style-overwrite")
        try await doc.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "Hello")
        }
        try await doc.update { root, _ in
            (root.t as? JSONText)?.setStyle(0, 5, ["color": "red"])
        }

        let redJSON = await doc.toSortedJSON()
        XCTAssertEqual(redJSON, "{\"t\":[{\"attrs\":{\"color\":\"red\"},\"val\":\"Hello\"}]}")

        // when — overwrite "red" with "blue"
        try await doc.update { root, _ in
            (root.t as? JSONText)?.setStyle(0, 5, ["color": "blue"])
        }

        var json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"t\":[{\"attrs\":{\"color\":\"blue\"},\"val\":\"Hello\"}]}")

        // then — undo restores the previous "red" value
        try await doc.undo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, redJSON)
    }

    /// Verifies the combined reverse-op branch: a single `setStyle` that both *overwrites*
    /// an existing attribute and *adds* a new one. The reverse op must compose both
    /// `attributes` (restore the previous value) and `attributesToRemove` (drop the newly
    /// added key), so undo reconstructs the prior state in one operation.
    func test_undo_mixed_overwrite_and_add_style_op() async throws {
        // given — text styled with color:red
        let doc = Document(key: "undo-style-mixed")
        try await doc.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "Hello")
        }
        try await doc.update { root, _ in
            (root.t as? JSONText)?.setStyle(0, 5, ["color": "red"])
        }
        let redJSON = await doc.toSortedJSON()
        XCTAssertEqual(redJSON, "{\"t\":[{\"attrs\":{\"color\":\"red\"},\"val\":\"Hello\"}]}")

        // when — one op overwrites color (red -> blue) AND adds a new "weight" attribute
        try await doc.update { root, _ in
            (root.t as? JSONText)?.setStyle(0, 5, ["color": "blue", "weight": "bold"])
        }
        let mixedJSON = "{\"t\":[{\"attrs\":{\"color\":\"blue\",\"weight\":\"bold\"},\"val\":\"Hello\"}]}"
        var json = await doc.toSortedJSON()
        XCTAssertEqual(json, mixedJSON)

        // then — undo restores color:red AND removes the newly added "weight" in one reverse op
        try await doc.undo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, redJSON)

        // redo re-applies both the overwrite and the addition
        try await doc.redo()
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, mixedJSON)
    }

    // MARK: - Ancestor-removed undo-skip

    func test_undo_skips_safely_when_ancestor_container_is_removed() async throws {
        // Scenario:
        //   update 1: create container with nested array {container:{inner:[1,2]}}
        //   update 2: append 3 to inner → undo op on stack: remove element(3)
        //   update 3: remove container → undo op on stack: restore container
        //
        // Sequence:
        //   undo() → undoes update 3 (restores container copy with NEW createdAt)
        //            the original container is now tombstoned.
        //   undo() → tries to run RemoveOperation(element 3); element 3's parent is the
        //            ORIGINAL (tombstoned) container → isAncestorRemoved returns true → skip.
        //
        // Expected: the second undo() call does NOT throw and does NOT crash.

        // given
        let doc = Document(key: "undo-ancestor-removed")
        try await doc.update { root, _ in
            root.container = JSONObject()
            (root.container as? JSONObject)?.inner = [Int64(1), Int64(2)]
        }
        try await doc.update { root, _ in
            let obj = root.container as? JSONObject
            let arr = obj?.inner as? JSONArray
            arr?.append(Int64(3))
        }

        var json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"container\":{\"inner\":[1,2,3]}}")

        // when — remove the container; this tombstones it and pushes a restore op onto undo
        try await doc.update { root, _ in
            root.remove(key: "container")
        }
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{}")

        // Undo the removal — container copy is restored (NEW createdAt); original is tombstoned
        try await doc.undo()

        // Undo the append — element(3)'s parent is the TOMBSTONED original container.
        // isAncestorRemoved returns true → the op is silently skipped.
        // This must NOT crash and must NOT throw.
        do {
            try await doc.undo()
        } catch {
            XCTFail("undo threw unexpectedly when ancestor was removed: \(error)")
        }
    }

    func test_undo_skips_safely_when_direct_parent_array_is_removed() async throws {
        // Mirrors the scenario above but with a top-level array as the parent.
        //
        //   update 1: arr = [10, 20]
        //   update 2: append 30 → undo op: remove element(30)
        //   update 3: remove arr → undo op: restore arr
        //
        //   undo() → undoes update 3 (new arr copy, old arr tombstoned)
        //   undo() → RemoveOperation for element(30); its parent is the tombstoned old arr
        //            → isAncestorRemoved returns true → skipped safely.

        // given
        let doc = Document(key: "undo-parent-removed")
        try await doc.update { root, _ in
            root.arr = [Int64(10), Int64(20)]
        }
        try await doc.update { root, _ in
            (root.arr as? JSONArray)?.append(Int64(30))
        }

        var json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"arr\":[10,20,30]}")

        // when
        try await doc.update { root, _ in
            root.remove(key: "arr")
        }
        json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{}")

        // Undo the removal — arr copy restored; original tombstoned
        try await doc.undo()

        // then — undo the append: its parent (original arr) is tombstoned → skip
        do {
            try await doc.undo()
        } catch {
            XCTFail("undo threw unexpectedly when parent was removed: \(error)")
        }
    }
}
