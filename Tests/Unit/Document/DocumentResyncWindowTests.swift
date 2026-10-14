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

// The pure window semantics of Client.resync (yorkie-js-sdk#1463, test/unit/client/resync_test.ts):
// a discard suspends minting until a restore or a re-anchor lifts it.
@MainActor
final class DocumentResyncWindowTests: XCTestCase {
    private func makeDocWithEdit() throws -> Document {
        let doc = Document(key: "resync-window-unit")
        try doc.update { root, _ in
            root.text = "refused edit"
        }
        return doc
    }

    private func assertRefused(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errRefused, file: file, line: line)
        }
    }

    func test_discard_suspends_update_undo_and_redo() throws {
        // given: a document with one queued change and an undoable edit.
        let doc = try self.makeDocWithEdit()
        XCTAssertTrue(doc.canUndo)
        XCTAssertTrue(doc.isMintable)

        // when
        let discarded = doc.discardLocalChanges()

        // then: the queue is empty and every minting entry point refuses, loudly.
        XCTAssertEqual(discarded.count, 1)
        XCTAssertFalse(doc.isMintable)
        self.assertRefused { try doc.update { root, _ in root.text = "minted mid-resync" } }
        self.assertRefused { try doc.undo() }
        self.assertRefused { try doc.redo() }
        // The refusal is the message the JS SDK raises.
        XCTAssertThrowsError(try doc.update { _, _ in }) { error in
            let message = (error as? YorkieError)?.message ?? ""
            XCTAssertTrue(message.contains("Update is not allowed on \"resync-window-unit\" while it is being re-anchored"))
        }
    }

    // `canUndo` answers for `undo`, and `undo` refuses in the window: the check-then-call
    // pattern must not turn into a throw.
    func test_can_undo_and_can_redo_are_false_inside_the_window() throws {
        let doc = try self.makeDocWithEdit()
        XCTAssertTrue(doc.canUndo)

        _ = doc.discardLocalChanges()

        XCTAssertFalse(doc.canUndo)
        XCTAssertFalse(doc.canRedo)
    }

    func test_restore_local_changes_makes_the_document_writable_again() throws {
        // given
        let doc = try self.makeDocWithEdit()
        let pendingBefore = doc.getPendingChangeStructs()
        let discarded = doc.discardLocalChanges()
        XCTAssertTrue(doc.getPendingChangeStructs().isEmpty)

        // when
        doc.restoreLocalChanges(discarded)

        // then: the queue is as it was found, and minting is allowed again.
        XCTAssertTrue(doc.isMintable)
        XCTAssertEqual(doc.getPendingChangeStructs().map { $0.id.getClientSeq() },
                       pendingBefore.map { $0.id.getClientSeq() })
        try doc.update { root, _ in
            root.text = "edited after the rollback"
        }
        XCTAssertEqual(doc.getRoot().text as? String, "edited after the rollback")
        // The counter was never rewound, so the new change follows the restored one.
        XCTAssertEqual(doc.getPendingChangeStructs().map { $0.id.getClientSeq() }, [1, 2])
    }

    func test_reset_for_reanchor_lifts_the_suspension() throws {
        // given
        let doc = try self.makeDocWithEdit()
        _ = doc.discardLocalChanges()
        XCTAssertFalse(doc.isMintable)

        // when
        doc.resetForReanchor()

        // then
        XCTAssertTrue(doc.isMintable)
        try doc.update { root, _ in
            root.text = "edited after the re-anchor"
        }
        XCTAssertEqual(doc.getRoot().text as? String, "edited after the re-anchor")
    }

    // An empty discard leaves no hole, so it suspends nothing.
    func test_an_empty_discard_does_not_suspend_minting() throws {
        let doc = Document(key: "resync-window-empty")

        let discarded = doc.discardLocalChanges()

        XCTAssertTrue(discarded.isEmpty)
        XCTAssertTrue(doc.isMintable)
        try doc.update { root, _ in
            root.text = "still writable"
        }
    }

    func test_the_dropped_event_reason_raw_value_matches_upstream() {
        XCTAssertEqual(LocalChangesDroppedValue.Reason.writeDenied.rawValue, "write-denied")
    }
}
