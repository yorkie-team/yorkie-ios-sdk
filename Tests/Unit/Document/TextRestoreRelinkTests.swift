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

/// Ports `packages/sdk/test/unit/document/text_restore_relink_test.ts` from
/// yorkie-js-sdk v0.7.18 (yorkie-js-sdk#1327 "Relink insertion chain when
/// restore recreates a purged fragment").
///
/// `restore()`'s gap-recreate branch inserts a recreated node with
/// `insertAfter`, which only maintains the physical prev/next chain — it does
/// NOT relink the separate insertion chain (`insPrev`/`insNext`). So after a
/// purged interior fragment is recreated on undo, the surviving neighbours of
/// the same insertion still point their insertion pointers past the
/// recreated node (their pre-recreate links).
///
/// A LATER edit whose boundary lands on that recreated node resolves its
/// absolute offset via the floor-node walk that follows `insPrev`. Because the
/// recreated node was skipped in the insertion chain, the walk lands on the
/// wrong node and the offset resolution miscomputes the relative offset —
/// dropping the edit silently or, as here, throwing because the offset
/// exceeds the resolved node's length.
final class TextRestoreRelinkTests: XCTestCase {
    private let actor = "000000000000000000000001"

    @MainActor
    func test_keeps_a_later_boundary_edit_correct_after_a_purged_interior_fragment_is_recreated() throws {
        // given — single insertion "0123456789": one node, id (t1:0)
        let doc = Document(key: "text-restore-relink-1327")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.t = JSONText()
        }

        try doc.update { root, _ in
            _ = (root.t as? JSONText)?.edit(0, 0, "0123456789")
        }
        XCTAssertEqual((doc.getRoot().t as? JSONText)?.toString, "0123456789")

        // when — delete the interior "45" (indices [4,6)). The node splits into
        // (t1:0)"0123" - {t1:4 "45"} - (t1:6)"6789"; the middle is tombstoned.
        try doc.update { root, _ in
            _ = (root.t as? JSONText)?.edit(4, 6, "")
        }
        XCTAssertEqual((doc.getRoot().t as? JSONText)?.toString, "01236789")

        // purge the tombstone so undo cannot un-tombstone in place and must
        // recreate the "45" fragment through restore()'s gap branch
        let purged = doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [self.actor]))
        XCTAssertGreaterThan(purged, 0, "the deleted \"45\" fragment should be purged")
        XCTAssertEqual(doc.getGarbageLength(), 0, "nothing should remain pending GC")

        // undo recreates (t1:4)"45" via insertAfter — physical chain is repaired
        // ("0123456789") but the insertion chain around it stays stale
        try doc.undo()
        XCTAssertEqual(
            (doc.getRoot().t as? JSONText)?.toString,
            "0123456789",
            "restore itself must rebuild the visible text"
        )

        // then — the bug bites here: an edit whose boundary (index 6) sits
        // exactly at the recreated node's right edge resolves through the
        // stale insertion chain
        try doc.update { root, _ in
            _ = (root.t as? JSONText)?.edit(6, 6, "X")
        }
        XCTAssertEqual(
            (doc.getRoot().t as? JSONText)?.toString,
            "012345X6789",
            "an edit at the recreated boundary must land at the right offset"
        )
    }
}
