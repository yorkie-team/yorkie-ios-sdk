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
///
/// The cases from "single-insertion run is unaffected" on are the v0.7.26 additions
/// (yorkie-js-sdk#1310 follow-ups, #1497, #1504, #1514).
final class TextRestoreAfterGCTests: XCTestCase {
    private let actor = "000000000000000000000001"
    private let peer = "000000000000000000000002"

    /// Delivers each replica's pending changes to the other and acknowledges them, without a server
    /// and without moving GC forward.
    @MainActor
    private func crossSync(_ lhs: Document, _ rhs: Document) throws {
        let lhsPack = lhs.createChangePack()
        let rhsPack = rhs.createChangePack()
        func pack(_ from: ChangePack, _ clientSeq: UInt32, _ changes: [Change]) -> ChangePack {
            ChangePack(
                key: from.getDocumentKey(),
                checkpoint: Checkpoint(serverSeq: 0, clientSeq: clientSeq),
                isRemoved: false,
                changes: changes,
                versionVector: VersionVector.initial
            )
        }
        func lastSeq(_ from: ChangePack) -> UInt32 {
            from.getChanges().last?.id.getClientSeq() ?? 0
        }
        try rhs.applyChangePack(pack(lhsPack, 0, lhsPack.getChanges()))
        try lhs.applyChangePack(pack(rhsPack, 0, rhsPack.getChanges()))
        try lhs.applyChangePack(pack(lhsPack, lastSeq(lhsPack), []))
        try rhs.applyChangePack(pack(rhsPack, lastSeq(rhsPack), []))
    }

    @MainActor
    private func text(_ doc: Document) -> String? {
        (doc.getRoot().t as? JSONText)?.toString
    }

    /// The attributes of the value at `index`, as the application reads them.
    @MainActor
    private func attributes(_ doc: Document, _ index: Int) -> [String: String] {
        let value = self.values(doc)[index]
        return value.getAttributes().mapValues { logicalAttrValue($0.value) }
    }

    /// The text's values without the empty head sentinel Swift's `values` starts with.
    @MainActor
    private func values(_ doc: Document) -> [CRDTTextValue] {
        ((doc.getRoot().t as? JSONText)?.values ?? []).filter { !$0.toString.isEmpty }
    }

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

    @MainActor
    func test_single_insertion_run_is_unaffected_one_recreate() throws {
        // given
        let doc = Document(key: "text-restore-after-gc-single")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.t = JSONText()
        }
        try doc.update { root, _ in (root.t as? JSONText)?.edit(0, 0, "hello my name is") }
        try doc.update { root, _ in (root.t as? JSONText)?.edit(6, 13, "") }

        // when
        doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [self.actor]))
        try doc.undo()

        // then
        XCTAssertEqual(self.text(doc), "hello my name is")
    }

    // Which pieces survive is per-replica GC state, so where a restore anchors must not depend on
    // it. Here only the undoing replica has purged, so it rebuilds the run through the anchor
    // ladder, while the peer still holds the tombstones and revives them in place. In the second
    // case the text left of the run is purged as well, so no piece of any neighbour survives on
    // the undoing replica and the first fragment falls back to the operation's own position.
    @MainActor
    private func convergesWhenOnlyTheUndoingReplicaPurgedTheRun(purgeLeft: Bool) throws {
        // given
        let d1 = Document(key: "text-restore-after-gc-peer")
        let d2 = Document(key: "text-restore-after-gc-peer")
        d1.setActor(self.actor)
        d2.setActor(self.peer)
        try d1.update { root, _ in
            root.t = JSONText()
        }
        let text = "hello my name is"
        for (index, character) in text.enumerated() {
            try d1.update { root, _ in (root.t as? JSONText)?.edit(index, index, String(character)) }
        }
        try self.crossSync(d1, d2)
        d1.clearHistory()

        if purgeLeft {
            try d2.update { root, _ in (root.t as? JSONText)?.edit(0, 6, "") }
            try self.crossSync(d1, d2)
        }
        let from = purgeLeft ? 0 : 6
        try d1.update { root, _ in (root.t as? JSONText)?.edit(from, from + 7, "") }
        try self.crossSync(d1, d2)

        // when
        XCTAssertGreaterThan(d1.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [self.actor, self.peer])), 0)
        try d1.undo()
        try self.crossSync(d1, d2)

        // then
        let want = purgeLeft ? "my name is" : text
        XCTAssertEqual(self.text(d1), want)
        XCTAssertEqual(self.text(d2), want)
        XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
    }

    @MainActor
    func test_converges_when_only_the_undoing_replica_purged_the_run_its_neighbours_survive() throws {
        try self.convergesWhenOnlyTheUndoingReplicaPurgedTheRun(purgeLeft: false)
    }

    @MainActor
    func test_converges_when_only_the_undoing_replica_purged_the_run_its_left_neighbour_is_purged_too() throws {
        try self.convergesWhenOnlyTheUndoingReplicaPurgedTheRun(purgeLeft: true)
    }

    // The reverse of an insertion records the inserted run as a span. The undo only re-tombstones
    // it, so the span's value is never read; the redo flips the direction and the same span becomes
    // the content to restore. A replica that purged the node rebuilds it from that value alone, so
    // the span has to carry the attributes the edit applied or the two replicas diverge
    // (yorkie-team/yorkie-js-sdk#1497).
    @MainActor
    func test_keeps_the_attributes_of_a_re_inserted_run_when_redoing_after_gc() throws {
        // given
        let d1 = Document(key: "text-redo-attrs-after-gc")
        let d2 = Document(key: "text-redo-attrs-after-gc")
        d1.setActor(self.actor)
        d2.setActor(self.peer)
        try d1.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "ab")
        }
        try self.crossSync(d1, d2)
        d1.clearHistory()

        try d1.update { root, _ in (root.t as? JSONText)?.edit(1, 1, "X", ["b": "1"]) }
        try d1.undo()
        try self.crossSync(d1, d2)

        // when -- only d1 purges the undone run, so its redo must recreate the node from the span
        // while d2 revives the tombstone it still holds.
        XCTAssertGreaterThan(d1.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [self.actor, self.peer])), 0)
        try d1.redo()
        try self.crossSync(d1, d2)

        // then
        XCTAssertEqual(self.text(d1), "aXb")
        XCTAssertEqual(self.attributes(d1, 1), ["b": "1"])
        XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
    }

    // The span is captured when the reversed edit runs, so an attribute applied to the inserted
    // run AFTERWARDS is not in it. The undo re-snapshots the span against the live content before
    // removing it, so the redo's restore payload carries the style the peer added; otherwise a
    // replica that purged the run recreates it unstyled while a replica that un-tombstones keeps
    // the style (yorkie-team/yorkie-js-sdk#1497).
    @MainActor
    func test_keeps_a_style_applied_after_the_insert_when_redoing_after_gc() throws {
        // given
        let d1 = Document(key: "text-redo-late-attrs-after-gc")
        let d2 = Document(key: "text-redo-late-attrs-after-gc")
        d1.setActor(self.actor)
        d2.setActor(self.peer)
        try d1.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "ab")
        }
        try self.crossSync(d1, d2)
        d1.clearHistory()

        try d1.update { root, _ in (root.t as? JSONText)?.edit(1, 1, "X") }
        try self.crossSync(d1, d2)

        // the peer styles the inserted run after the fact, so the span recorded at insert time
        // knows nothing about it.
        try d2.update { root, _ in (root.t as? JSONText)?.setStyle(1, 2, ["b": "1"]) }
        try self.crossSync(d1, d2)
        XCTAssertEqual(self.attributes(d1, 1), ["b": "1"])

        // when
        try d1.undo()
        try self.crossSync(d1, d2)
        XCTAssertGreaterThan(d1.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [self.actor, self.peer])), 0)
        try d1.redo()
        try self.crossSync(d1, d2)

        // then
        XCTAssertEqual(self.text(d1), "aXb")
        XCTAssertEqual(self.attributes(d1, 1), ["b": "1"])
        XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
    }

    // Mirrors the chained case of yorkie's text_redo_attrs_test: every round purges the run again,
    // so each redo recreates it from the span.
    @MainActor
    func test_keeps_the_attributes_across_chained_undo_redo_with_gc() throws {
        // given
        let doc = Document(key: "text-redo-attrs-chained")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "ab")
        }
        doc.clearHistory()
        try doc.update { root, _ in (root.t as? JSONText)?.edit(1, 1, "X", ["b": "1", "i": "1"]) }

        for _ in 0 ..< 3 {
            // when
            try doc.undo()
            doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [self.actor]))
            try doc.redo()

            // then
            XCTAssertEqual(self.text(doc), "aXb")
            XCTAssertEqual(self.attributes(doc, 1), ["b": "1", "i": "1"])
        }
    }

    // The style covers one character of the run, so the undo has to report the pieces separately
    // for the redo to recreate each with its own attributes.
    @MainActor
    func test_keeps_a_style_covering_part_of_the_insert_when_redoing_after_gc() throws {
        // given
        let d1 = Document(key: "text-redo-partial-attrs-after-gc")
        let d2 = Document(key: "text-redo-partial-attrs-after-gc")
        d1.setActor(self.actor)
        d2.setActor(self.peer)
        try d1.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "ab")
        }
        try self.crossSync(d1, d2)
        d1.clearHistory()

        try d1.update { root, _ in (root.t as? JSONText)?.edit(1, 1, "XYZ") }
        try self.crossSync(d1, d2)
        try d2.update { root, _ in (root.t as? JSONText)?.setStyle(2, 3, ["b": "1"]) }
        try self.crossSync(d1, d2)

        // when
        try d1.undo()
        try self.crossSync(d1, d2)
        d1.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [self.actor, self.peer]))
        try d1.redo()
        try self.crossSync(d1, d2)

        // then
        XCTAssertEqual(self.text(d1), "aXYZb")
        XCTAssertEqual(self.values(d1).map { $0.toString }, ["a", "X", "Y", "Z", "b"])
        XCTAssertEqual((0 ..< 5).map { self.attributes(d1, $0) }, [[:], [:], ["b": "1"], [:], [:]])
        XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
    }

    // An edit that carried no attributes must not gain any from the span.
    @MainActor
    func test_keeps_a_plain_re_inserted_run_unstyled_when_redoing_after_gc() throws {
        // given
        let doc = Document(key: "text-redo-plain-after-gc")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "ab")
        }
        doc.clearHistory()
        try doc.update { root, _ in (root.t as? JSONText)?.edit(1, 1, "X") }

        // when
        try doc.undo()
        doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [self.actor]))
        try doc.redo()

        // then
        XCTAssertEqual(self.text(doc), "aXb")
        XCTAssertTrue(self.attributes(doc, 1).isEmpty)
    }
}
