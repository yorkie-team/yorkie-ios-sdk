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

/// Ports "must not collect a tombstone a deferred remote change anchors on" (yorkie-js-sdk#1393,
/// `pushonly_gc_test.ts`), which guards the push-only response fix in ``Client/syncInternal``.
final class PushOnlyGCIntegrationTests: XCTestCase {
    // A push-only client pushes but does not pull, and every response still carries the
    // server's minimum version vector. Collecting with it would purge tombstones while the
    // remote changes anchored on them are exactly what the client has not pulled yet, leaving
    // it unable to apply them once it resumes pulling. An IME composition holds a document in
    // push-only for as long as the user types, so this is the regime the fix protects.
    @MainActor
    func test_must_not_collect_a_tombstone_a_deferred_remote_change_anchors_on() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — both documents converge on a single-paragraph tree. c1 stays manual
            // throughout so each of its syncs lands in a known order.
            try d1.update { root, _ in
                root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            var d1XML = (d1.getRoot().tree as? JSONTree)?.toXML()
            var d2XML = (d2.getRoot().tree as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, "<doc><p>ab</p></doc>")
            XCTAssertEqual(d2XML, "<doc><p>ab</p></doc>")

            // when — 01. c2 composes: it pushes while pulling nothing. `sync()` with no document
            // sends with the attachment's own mode, so this is a real push-only request, not an
            // explicit pull override.
            try c2.changeSyncMode(d2, .realtimePushOnly)
            try d2.update { root, _ in
                try (root.tree as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "X"))
            }
            try await c2.sync()
            try await c1.sync()
            d1XML = (d1.getRoot().tree as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, "<doc><p>aXb</p></doc>")

            // 02. c2 replaces its "X": the node becomes a tombstone on both sides.
            try d2.update { root, _ in
                try (root.tree as? JSONTree)?.edit(2, 3, JSONTreeTextNode(value: "x"))
            }
            try await c2.sync()

            // 03. c1 still sees "X" live, and inserts right after it — an edit anchored on the
            // node c2 just removed. Then two syncs: the first pushes the insert and pulls the
            // removal, the second reports a version vector that covers the removal, so the
            // server's minimum vector now does too.
            try d1.update { root, _ in
                try (root.tree as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "Y"))
            }
            try await c1.sync()
            try await c1.sync()
            d1XML = (d1.getRoot().tree as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, "<doc><p>axYb</p></doc>")

            // 04. c2 keeps composing. The reply to this push carries a minimum vector under
            // which "X" is collectable, while the insert anchored on it is still waiting on the
            // server for c2 to pull. Before the fix, this reply — carrying neither changes nor
            // a snapshot — fell through to `applyChangePack`, which ran GC with that vector and
            // purged the tombstone c1's "Y" is anchored on.
            try d2.update { root, _ in
                try (root.tree as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "z"))
            }
            try await c2.sync()

            // then — the composition ends: c2 resumes and pulls the deferred insert. Before the
            // fix this failed to apply ("cannot find node") because the anchor tombstone was
            // already collected, leaving the two documents diverged.
            try c2.changeSyncMode(d2, .realtime)
            try await c2.sync(d2)
            try await c1.sync()

            d2XML = (d2.getRoot().tree as? JSONTree)?.toXML()
            d1XML = (d1.getRoot().tree as? JSONTree)?.toXML()
            XCTAssertEqual(d2XML, "<doc><p>zaxYb</p></doc>")
            XCTAssertEqual(d1XML, d2XML)
        }
    }
}
