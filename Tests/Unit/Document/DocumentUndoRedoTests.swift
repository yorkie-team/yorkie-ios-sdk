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
}
