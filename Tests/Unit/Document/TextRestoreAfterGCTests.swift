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

/// Ports `packages/sdk/test/unit/document/text_restore_after_gc_test.ts` from
/// yorkie-js-sdk v0.7.14 (yorkie-js-sdk#1310 "Recreate purged text runs in order
/// on restore, not reversed").
///
/// Regression for the reversed-text undo. Typing character by character makes
/// each character its own single-char insertion. Deleting a contiguous run and
/// then undoing AFTER the tombstones were GC-purged forces every character down
/// restore's recreate path. Because no character shares an insertion with any
/// other, none of the same-insertion anchor rungs fire; each recreated fragment
/// must chain after the one placed just before it, or the run comes back
/// reversed ("my name" -> "eman ym"). Un-tombstoning (no GC) already preserved
/// order, which is why this only reproduced once the run was purged.
final class TextRestoreAfterGCTests: XCTestCase {
    private let actor = "000000000000000000000001"

    @MainActor
    func test_recreates_a_purged_multi_insertion_run_in_document_order_on_undo() throws {
        // given — each character typed separately, so each is its own insertion
        let doc = Document(key: "text-restore-after-gc")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.t = JSONText()
        }

        let text = "hello my name is"
        for (index, character) in text.enumerated() {
            try doc.update { root, _ in
                (root.t as? JSONText)?.edit(index, index, String(character))
            }
        }
        XCTAssertEqual((doc.getRoot().t as? JSONText)?.toString, text)

        // when — delete "my name", then purge the tombstones so undo cannot
        // un-tombstone in place and must recreate from the spans
        try doc.update { root, _ in
            (root.t as? JSONText)?.edit(6, 13, "")
        }
        XCTAssertEqual((doc.getRoot().t as? JSONText)?.toString, "hello  is")

        let purged = doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [self.actor]))
        XCTAssertGreaterThan(purged, 0, "the deleted run should be purged")

        try doc.undo()

        // then — the run comes back forward, not reversed
        XCTAssertEqual((doc.getRoot().t as? JSONText)?.toString, text)
    }
}
