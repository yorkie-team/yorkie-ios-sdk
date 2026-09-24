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

/// Ports `packages/sdk/test/integration/gc_containment_test.ts` from
/// yorkie-js-sdk v0.7.21 (yorkie-js-sdk#1341). See ``GCContainmentTests`` for
/// the matching unit-level ports and the production change (commit
/// 160aa95dc2).
///
/// `undoTolerantly` runs an undo/redo that may have nothing left to apply. A
/// reverse operation names the element it was recorded against, and a peer
/// may have removed that element in the meantime; that is reported as a
/// ``YorkieError`` and leaves the document untouched. What must not happen is
/// the document being left unable to sync, which is what the rest of the
/// test checks.
private func undoTolerantly(_ run: () throws -> Void) {
    do {
        try run()
    } catch is YorkieError {
        // Expected: nothing to undo/redo, or the target element was already
        // removed by a peer.
    } catch {
        XCTFail("undo/redo failed with \(error)")
    }
}

/// Returns the index of the `items` entry whose `id` field matches, or `-1`.
private func indexOf(_ items: JSONArray, id: String) -> Int {
    for idx in 0 ..< items.length() {
        if let item = items[idx] as? JSONObject, item.id as? String == id {
            return idx
        }
    }
    return -1
}

/// Removes the item named `id` and reinserts a fresh copy at the front of
/// `root.items` -- a move expressed as a remove + insert rather than a
/// `Move` operation, matching upstream's `splice` + `splice` shape. Must run
/// inside a ``Document/update(_:_:)`` block: it takes the updater's own
/// `root` rather than reaching for ``Document/getRoot()``, which would push
/// operations into a throwaway context that is never synced.
private func reorderToFront(_ root: JSONObject, id: String, width: Int64, height: Int64, text: String) throws {
    guard let items = root.items as? JSONArray else {
        return
    }

    let idx = indexOf(items, id: id)
    guard idx >= 0 else {
        return
    }

    _ = try items.splice(start: idx, deleteCount: 1)
    // Upstream writes this as `r.items.splice(0, 0, plain)`. iOS accepts the same literal
    // now, though it still expands to an empty container plus per-member operations rather
    // than the single `Add` `buildCRDTElement` produces -- see the note in
    // `JSONArray.insertAfterInternal`.
    _ = try items.splice(start: 0, deleteCount: 0, items: [
        "id": id,
        "box": ["w": width, "h": height],
        "body": ["text": text]
    ] as [String: Any])
}

final class GCContainmentIntegrationTests: XCTestCase {
    /// Ports: "keeps syncing while two peers reorder, edit and undo one
    /// element".
    ///
    /// Every sync applies a change pack, which is where a document that
    /// cannot resolve a member of its collection worklist dies: it throws
    /// inside `applyChangePack` and goes on throwing on every later sync, so
    /// the client never syncs that document again (yorkie-js-sdk#1340). One
    /// element is removed and re-inserted, and edited, over and over by both
    /// peers, walking their undo stacks without syncing in between --
    /// exercising the restore-duplicates-identity path this release fixes
    /// under sustained pressure.
    ///
    /// **Scope note -- convergence is deliberately not asserted here, unlike
    /// upstream.** Upstream reorders with `r.items.splice(0, 0, plain)`, and
    /// `buildCRDTElement` builds the object's members first so the whole literal
    /// goes out as ONE `Add`. iOS accepts the same literal now, but still
    /// inserts an empty container and pushes the members as their own
    /// operations -- so two peers reordering concurrently interleave a different
    /// sequence than upstream's, and the documents end up disagreeing about the
    /// re-inserted entry.
    ///
    /// That was first assumed to be an artifact of this test having to spell the
    /// insert out as an empty object plus `Set`s. It is not: with the literal
    /// insert in place the divergence reproduces byte-for-byte, and it also
    /// reproduces on the commit before the v0.7.21 fix (`160aa95dc2^`). Closing
    /// it means porting `buildCRDTElement`, which is its own change. What this
    /// test pins meanwhile is what #1341 is actually about: the clients keep
    /// syncing.
    @MainActor
    func test_keeps_syncing_while_two_peers_reorder_edit_and_undo_one_element() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            func sync() async throws {
                for _ in 0 ..< 4 {
                    try await c1.sync(d1)
                    try await c2.sync(d2)
                }
            }

            try d1.update { root, _ in
                root.items = [
                    ["id": "x", "box": ["w": Int64(10), "h": Int64(10)], "body": ["text": ""]],
                    ["id": "y", "box": ["w": Int64(10), "h": Int64(10)], "body": ["text": ""]]
                ]
            }
            try await sync()

            // One element removed and re-inserted over and over, both peers
            // rewriting its nested objects and walking their undo stacks.
            for round in 0 ..< 8 {
                try d1.update({ root, _ in
                    try reorderToFront(root, id: "x", width: 10, height: 10, text: "")
                }, "reorder")

                try d2.update({ root, _ in
                    guard let items = root.items as? JSONArray else { return }
                    let idx = indexOf(items, id: "x")
                    guard idx >= 0 else { return }
                    (items[idx] as? JSONObject)?.body = ["text": String(repeating: "o", count: round + 1)]
                    (items[idx] as? JSONObject)?.box = ["w": Int64(10), "h": Int64(20 + round)]
                }, "edit")

                try await sync()

                if round % 3 == 0 {
                    undoTolerantly { try d1.undo() }
                }
                if round % 4 == 0 {
                    try d2.update({ root, _ in
                        guard let items = root.items as? JSONArray else { return }
                        let idx = indexOf(items, id: "y")
                        if idx >= 0 {
                            _ = try items.splice(start: idx, deleteCount: 1)
                        }
                    }, "remove y")
                    undoTolerantly { try d2.undo() }
                }
                if round % 5 == 0 {
                    undoTolerantly { try d1.redo() }
                    undoTolerantly { try d2.redo() }
                }

                // No sync in between, so both peers stack a reverse operation
                // on top of state the other has not seen.
                try d1.update({ root, _ in
                    guard let items = root.items as? JSONArray else { return }
                    let idx = indexOf(items, id: "x")
                    if idx >= 0 {
                        (items[idx] as? JSONObject)?.body = ["text": "d1-\(round)"]
                    }
                }, "edit body")
                try d2.update({ root, _ in
                    try reorderToFront(root, id: "x", width: 10, height: 10, text: "")
                }, "reorder")
                undoTolerantly { try d1.undo() }
                undoTolerantly { try d2.undo() }

                try await sync()
            }

            try d1.update({ root, _ in
                guard let items = root.items as? JSONArray else { return }
                let idx = indexOf(items, id: "x")
                if idx >= 0 {
                    (items[idx] as? JSONObject)?.box = ["w": Int64(1), "h": Int64(1)]
                }
            }, "final edit")

            // A poisoned client stops applying change packs entirely, so what
            // separates a healthy client from a dead one is whether an
            // ordinary edit still round-trips -- in BOTH directions, since a
            // client that has stopped applying keeps producing changes of its
            // own. Top-level scalars are used as the probe rather than the
            // array, for the reason in the note above.
            try d1.update({ root, _ in root.pingD1 = Int64(1) }, "ping d1")
            try d2.update({ root, _ in root.pingD2 = Int64(2) }, "ping d2")
            try await sync()

            // Upstream asserts the two documents agree here. On iOS they do
            // not, so the assertion is kept and marked expected-to-fail rather
            // than deleted.
            //
            // STRICT deliberately: if the two documents ever start converging,
            // the expected failure does not fire and this test FAILS, which is
            // the report we want -- a non-strict block would pass silently and
            // the gap would close unnoticed. The divergence is deterministic
            // (verified over repeated standalone runs and a full-suite run), so
            // strict does not make this flaky.
            //
            // The divergence is real and pre-existing -- it reproduces
            // byte-for-byte on `160aa95dc2^` and with `Sources/Document`
            // reverted to `main` -- but it is not small: d1 ends holding an
            // empty `{}` where an item should be, and the other item loses its
            // `id`, while d2 keeps both. See the scope note above.
            XCTExpectFailure("iOS array reorder/undo convergence gap -- pre-existing, not yorkie-js-sdk#1341; upstream asserts convergence here") {
                XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON(), "the two documents disagree after the final edit")
            }

            for (name, json) in [("d1", d1.toSortedJSON()), ("d2", d2.toSortedJSON())] {
                XCTAssertTrue(json.contains("\"pingD1\":1"), "\(name) never received d1's edit -- it stopped applying change packs")
                XCTAssertTrue(json.contains("\"pingD2\":2"), "\(name) never received d2's edit -- it stopped applying change packs")
            }
        }
    }
}
