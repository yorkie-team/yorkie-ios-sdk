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

/// Ports the identity-preserving-restore additions to
/// `packages/sdk/test/unit/document/document_test.ts` from yorkie-js-sdk
/// v0.7.13 (yorkie-js-sdk#1293 "Identity-preserving restore for Text
/// undo/redo").

/// `idOfNode` extracts the node id (`createdAt:offset`) of the piece whose
/// value is `value` from `RGATreeSplit.toTestString()`. Live nodes render as
/// `[<id> <value>]`, tombstoned nodes as `{<id> <value>}`. Identity-preserving
/// restore must reuse the SAME id; a copy-based undo would mint a new id from
/// the undo op's timestamp.
private func idOfNode(_ structure: String, value: String, removed: Bool) -> String? {
    let open = removed ? "\\{" : "\\["
    let close = removed ? "\\}" : "\\]"
    let pattern = "\(open)([^ \\}\\]]+) \(NSRegularExpression.escapedPattern(for: value))\(close)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    let range = NSRange(structure.startIndex..., in: structure)
    guard let match = regex.firstMatch(in: structure, range: range),
          let matchRange = Range(match.range(at: 1), in: structure)
    else {
        return nil
    }
    return String(structure[matchRange])
}

final class TextIdentityPreservingRestoreTests: XCTestCase {
    @MainActor
    func test_undo_redo_deletion_via_identity_preserving_restore() throws {
        // given
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.text = JSONText()
            _ = (root.text as? JSONText)?.edit(0, 0, "0123456789")
        }
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, "0123456789")

        // Delete "45" — the reverse op should carry restore spans, not a copy.
        try doc.update { root, _ in _ = (root.text as? JSONText)?.edit(4, 6, "") }
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, "01236789")

        // Capture the tombstoned "45" node's identity before undo.
        let structureBeforeUndo = (doc.getRoot().text as? JSONText)?.toTestString ?? ""
        let deletedId = try XCTUnwrap(idOfNode(structureBeforeUndo, value: "45", removed: true))

        // when — undo revives the ORIGINAL node (un-tombstone), not a new copy:
        // the same id must now be live.
        try doc.undo()

        // then
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, "0123456789")
        XCTAssertTrue(
            ((doc.getRoot().text as? JSONText)?.toTestString ?? "").contains("[\(deletedId) 45]"),
            "undo must revive the same node id, not insert a copy"
        )

        // when — redo re-tombstones exactly that node (same id).
        try doc.redo()

        // then
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, "01236789")
        XCTAssertTrue(((doc.getRoot().text as? JSONText)?.toTestString ?? "").contains("{\(deletedId) 45}"))

        // when — undo again: the restore/retombstone cycle must be stable.
        try doc.undo()

        // then
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, "0123456789")
        XCTAssertTrue(((doc.getRoot().text as? JSONText)?.toTestString ?? "").contains("[\(deletedId) 45]"))
    }

    @MainActor
    func test_recreate_original_node_identities_after_gc_on_undo() throws {
        // given
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.text = JSONText()
            _ = (root.text as? JSONText)?.edit(0, 0, "0123456789")
        }

        // Two deletions that overlap the same original insertion node leave two
        // tombstoned spans "12" and "45".
        try doc.update { root, _ in _ = (root.text as? JSONText)?.edit(4, 6, "") } // delete "45"
        try doc.update { root, _ in _ = (root.text as? JSONText)?.edit(1, 3, "") } // "01236789" -> "036789"
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, "036789")

        let structureBeforeGC = (doc.getRoot().text as? JSONText)?.toTestString ?? ""
        let id45 = try XCTUnwrap(idOfNode(structureBeforeGC, value: "45", removed: true))
        let id12 = try XCTUnwrap(idOfNode(structureBeforeGC, value: "12", removed: true))

        // when — garbage-collect: both tombstones are purged from the tree, so
        // undo can no longer un-tombstone — it must RECREATE the nodes under
        // their original ids via the gap-recreate path.
        let purged = doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))

        // then
        XCTAssertEqual(purged, 2)
        XCTAssertEqual(doc.getGarbageLength(), 0)
        XCTAssertFalse(((doc.getRoot().text as? JSONText)?.toTestString ?? "").contains("\(id45) 45"))
        XCTAssertFalse(((doc.getRoot().text as? JSONText)?.toTestString ?? "").contains("\(id12) 12"))

        // when — undo restores "12" (reverse order), then "45" — both under
        // their ORIGINAL identities, not fresh copies.
        try doc.undo()

        // then
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, "01236789")
        XCTAssertTrue(((doc.getRoot().text as? JSONText)?.toTestString ?? "").contains("[\(id12) 12]"))

        // when
        try doc.undo()

        // then
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, "0123456789")
        XCTAssertTrue(((doc.getRoot().text as? JSONText)?.toTestString ?? "").contains("[\(id12) 12]"))
        XCTAssertTrue(((doc.getRoot().text as? JSONText)?.toTestString ?? "").contains("[\(id45) 45]"))
    }

    @MainActor
    func test_emit_opInfos_for_identity_preserving_undo_redo() throws {
        // given — empty opInfos would silently suppress remote propagation of
        // the undo/redo change, so restore/retombstone must report the content
        // change.
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.text = JSONText()
            _ = (root.text as? JSONText)?.edit(0, 0, "0123456789")
        }
        try doc.update { root, _ in _ = (root.text as? JSONText)?.edit(4, 6, "") }

        var ops: [(from: Int, to: Int, content: String?)] = []
        doc.subscribe { event, _ in
            guard let changeEvent = event as? LocalChangeEvent else { return }
            for op in changeEvent.value.operations {
                if let edit = op as? EditOpInfo {
                    ops.append((from: edit.from, to: edit.to, content: edit.content))
                }
            }
        }

        // when — undo (restore) reports an insertion of "45" at index 4.
        try doc.undo()

        // then
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.from, 4)
        XCTAssertEqual(ops.first?.to, 4)
        XCTAssertEqual(ops.first?.content, "45")

        // when — redo (retombstone) reports a deletion of [4, 6).
        ops.removeAll()
        try doc.redo()

        // then — Swift's EditOpInfo reports a pure deletion's content as nil,
        // not "" (see RGATreeSplit.makeChanges for the ordinary edit path, which
        // uses the same convention); this is a pre-existing, codebase-wide
        // convention, not something specific to the retombstone path.
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.from, 4)
        XCTAssertEqual(ops.first?.to, 6)
        XCTAssertNil(ops.first?.content)
    }
}
