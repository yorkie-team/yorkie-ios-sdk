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

/// Ported from yorkie-js-sdk#1424 "Let a document choose its undo/redo depth":
/// `packages/sdk/test/unit/document/undo_depth_test.ts`.
///
/// Builds a document that typed `count` characters, one `Document.update` each, after an
/// initial `JSONText` whose own setup update is dropped via `clearHistory()`.
@MainActor
private func typed(_ count: Int, actor: String, maxUndoDepth: Int? = nil) throws -> Document {
    let opts = maxUndoDepth.map { DocumentOptions(disableGC: false, maxUndoDepth: $0) } ?? DocumentOptions(disableGC: false)
    let doc = Document(key: "undo-depth", opts: opts)
    doc.setActor(actor)
    try doc.update { root, _ in
        root.t = JSONText()
    }
    doc.clearHistory()
    for index in 0 ..< count {
        try doc.update { root, _ in
            _ = (root.t as? JSONText)?.edit(index, index, "a")
        }
    }
    return doc
}

/// Undoes `doc` until `canUndo` is false and returns how many steps it took.
@MainActor
private func undoAll(_ doc: Document) throws -> Int {
    var steps = 0
    while doc.canUndo {
        try doc.undo()
        steps += 1
    }
    return steps
}

/// `packages/sdk/test/unit/document/undo_depth_test.ts` describe('Document maxUndoDepth').
final class DocumentMaxUndoDepthTests: XCTestCase {
    private let actor = "000000000000000000000001"

    @MainActor
    func test_keeps_the_default_depth_when_the_option_is_not_given() throws {
        // given
        let doc = try typed(maxUndoRedoStackDepth + 10, actor: self.actor)

        // when / then
        let steps = try undoAll(doc)
        XCTAssertEqual(steps, maxUndoRedoStackDepth)
        let text = ((doc.getRoot().t as? JSONText)?.toString) ?? ""
        XCTAssertEqual(text, String(repeating: "a", count: 10))
    }

    @MainActor
    func test_keeps_as_many_undo_entries_as_the_option_allows() throws {
        // given
        let doc = try typed(120, actor: self.actor, maxUndoDepth: 100)

        // when / then
        let steps = try undoAll(doc)
        XCTAssertEqual(steps, 100)
        let text = ((doc.getRoot().t as? JSONText)?.toString) ?? ""
        XCTAssertEqual(text, String(repeating: "a", count: 20))
    }

    @MainActor
    func test_drops_the_oldest_entries_first_when_the_depth_is_small() throws {
        // given
        let doc = try typed(5, actor: self.actor, maxUndoDepth: 2)

        // when / then
        let steps = try undoAll(doc)
        XCTAssertEqual(steps, 2)
        let text = ((doc.getRoot().t as? JSONText)?.toString) ?? ""
        XCTAssertEqual(text, "aaa")
    }

    // The depth is deliberately above `maxUndoRedoStackDepth`: undoing all 60 changes pushes 60
    // redo entries, so a redo stack still bounded by the hard-coded default would have dropped
    // the 10 oldest of them.
    @MainActor
    func test_bounds_the_redo_stack_by_the_same_depth_not_the_default_one() throws {
        // given
        let doc = try typed(60, actor: self.actor, maxUndoDepth: 60)

        // when
        let undone = try undoAll(doc)
        XCTAssertEqual(undone, 60)
        let emptied = ((doc.getRoot().t as? JSONText)?.toString) ?? ""
        XCTAssertEqual(emptied, "")

        var redone = 0
        while doc.canRedo {
            try doc.redo()
            redone += 1
        }

        // then
        XCTAssertEqual(redone, 60)
        let text = ((doc.getRoot().t as? JSONText)?.toString) ?? ""
        XCTAssertEqual(text, String(repeating: "a", count: 60))
    }

    // JS also asserts a `maxUndoDepth` of 0, -1, 1.5, NaN and +Infinity all throw
    // `ErrInvalidArgument` from the `Document` constructor. Only 0 and -1 are ported: `Int`
    // cannot represent 1.5, NaN or +Infinity in the first place, so those three cases do not
    // apply to Swift's type system. Swift's `Document.init(key:opts:)` also stays non-throwing
    // by design -- see `DocumentOptions.maxUndoDepth`'s doc comment -- so a value below 1 is
    // asserted to fall back to the default depth instead of throwing.
    @MainActor
    func test_falls_back_to_the_default_depth_for_a_maxUndoDepth_of_zero() throws {
        let doc = try typed(maxUndoRedoStackDepth + 5, actor: self.actor, maxUndoDepth: 0)
        XCTAssertEqual(try undoAll(doc), maxUndoRedoStackDepth)
    }

    @MainActor
    func test_falls_back_to_the_default_depth_for_a_negative_maxUndoDepth() throws {
        let doc = try typed(maxUndoRedoStackDepth + 5, actor: self.actor, maxUndoDepth: -1)
        XCTAssertEqual(try undoAll(doc), maxUndoRedoStackDepth)
    }
}

/// `packages/sdk/test/unit/document/undo_depth_test.ts` describe('History depth').
///
/// JS reaches `History` through a cast on the `Document` instance and patches nothing; Swift's
/// `History` is `internal`, so these construct it directly (available to the test target via
/// `@testable import`).
final class HistoryDepthTests: XCTestCase {
    /// Builds a history entry that carries `n` so eviction order is observable. Mirrors JS's
    /// `entry(n)`, which uses a presence-change HistoryOperation as an inert marker.
    private func entry(_ mark: Int) -> [HistoryOperation] {
        [.presence(StringValueTypeDictionary.stringifyAttributes(["n": mark]))]
    }

    /// Reads back the `n` of each entry on a stack.
    private func marks(_ stack: [[HistoryOperation]]) -> [Int] {
        stack.compactMap { ops in
            guard case .presence(let dict) = ops.first, let raw = dict["n"] else { return nil }
            return Int(raw)
        }
    }

    func test_falls_back_to_the_default_depth_when_constructed_without_one() {
        XCTAssertEqual(History().getMaxDepth(), maxUndoRedoStackDepth)
    }

    func test_reports_the_depth_it_was_constructed_with() {
        XCTAssertEqual(History(maxDepth: 7).getMaxDepth(), 7)
    }

    func test_drops_the_oldest_redo_entry_once_the_depth_is_exceeded() {
        // given
        let history = History(maxDepth: 3)

        // when
        for mark in 0 ..< 5 {
            history.pushRedo(self.entry(mark))
        }

        // then
        XCTAssertEqual(self.marks(history.getRedoStackForTest()), [2, 3, 4])
    }

    func test_drops_the_oldest_undo_entry_once_the_depth_is_exceeded() {
        // given
        let history = History(maxDepth: 3)

        // when
        for mark in 0 ..< 5 {
            history.pushUndo(self.entry(mark))
        }

        // then
        XCTAssertEqual(self.marks(history.getUndoStackForTest()), [2, 3, 4])
    }

    func test_bounds_the_redo_stack_independently_of_the_default_depth() {
        // given
        let history = History(maxDepth: maxUndoRedoStackDepth + 5)

        // when
        for mark in 0 ..< (maxUndoRedoStackDepth + 5) {
            history.pushRedo(self.entry(mark))
        }

        // then
        XCTAssertEqual(history.getRedoStackForTest().count, maxUndoRedoStackDepth + 5)
        XCTAssertEqual(self.marks(history.getRedoStackForTest()).first, 0)
    }
}
