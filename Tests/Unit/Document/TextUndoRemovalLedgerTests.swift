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

/// Ports `packages/sdk/test/unit/document/text_undo_removal_ledger_test.ts` from yorkie-js-sdk
/// v0.7.26 (yorkie-js-sdk#1514), itself a port of Go's
/// `pkg/document/text_undo_removal_ledger_test.go` (yorkie-team/yorkie#2310). The scenarios are
/// Go's, so a failure on either side points at the same rule.
final class TextUndoRemovalLedgerTests: XCTestCase {
    private let actors = [
        "",
        "000000000000000000000001",
        "000000000000000000000002",
        "000000000000000000000003"
    ]

    // MARK: - Helpers

    /// Delivers the pending changes of `from` to each of `to` through protobuf, so what the wire
    /// carries is part of what is tested.
    @MainActor
    private func send(_ from: Document, _ to: Document...) throws {
        let pack = try Converter.fromChangePack(Converter.toChangePack(pack: from.createChangePack()))
        for doc in to {
            try doc.applyChangePack(ChangePack(
                key: pack.getDocumentKey(),
                checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                isRemoved: false,
                changes: pack.getChanges(),
                versionVector: VersionVector.initial
            ))
        }
    }

    /// Drops the changes `doc` has already sent from its local queue.
    @MainActor
    private func ack(_ doc: Document) throws {
        let lastSeq = doc.createChangePack().getChanges().last?.id.getClientSeq() ?? 0
        try doc.applyChangePack(ChangePack(
            key: doc.getKey(),
            checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
            isRemoved: false,
            changes: [],
            versionVector: VersionVector.initial
        ))
    }

    @MainActor
    private func exchange(_ lhs: Document, _ rhs: Document) throws {
        try self.send(lhs, rhs)
        try self.send(rhs, lhs)
        try self.ack(lhs)
        try self.ack(rhs)
    }

    /// Returns two replicas holding `content` in the Text under `t`.
    @MainActor
    private func replicas(_ content: String) throws -> (Document, Document) {
        let lhs = Document(key: "ledger")
        let rhs = Document(key: "ledger")
        lhs.setActor(self.actors[1])
        rhs.setActor(self.actors[2])
        try lhs.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, content)
        }
        try self.exchange(lhs, rhs)
        return (lhs, rhs)
    }

    /// Returns a third replica loaded from the snapshot of `src`, as a client that attached late
    /// would be.
    @MainActor
    private func fromSnapshot(_ src: Document) throws -> Document {
        let bytes = try Converter.snapshotToBytes(root: src.getRootObject(), presences: [:])
        return try self.load(bytes, versionVector: src.getVersionVector())
    }

    @MainActor
    private func load(_ bytes: Data, versionVector: VersionVector) throws -> Document {
        let doc = Document(key: "ledger")
        doc.setActor(self.actors[3])
        try doc.applyChangePack(ChangePack(
            key: "ledger",
            checkpoint: Checkpoint(serverSeq: 1, clientSeq: 0),
            isRemoved: false,
            changes: [],
            snapshot: bytes,
            versionVector: versionVector
        ))
        return doc
    }

    @MainActor
    private func edit(_ doc: Document, _ from: Int, _ to: Int, _ content: String = "") throws {
        try doc.update { root, _ in
            (root.t as? JSONText)?.edit(from, to, content)
        }
    }

    @MainActor
    private func text(_ doc: Document) -> String {
        (doc.getRoot().t as? JSONText)?.toString ?? "<missing>"
    }

    @MainActor
    private func textOf(_ doc: Document) -> CRDTText {
        guard let text = doc.getRootObject().get(key: "t") as? CRDTText else {
            preconditionFailure("the document has no text under t")
        }
        return text
    }

    @MainActor
    private func nodes(_ doc: Document) -> [RGATreeSplitNode<CRDTTextValue>] {
        Array(self.textOf(doc).rgaTreeSplit)
    }

    /// Deletes the character at 1 and undoes it `n` times on `doc` alone, so no peer sees the
    /// pairs and GC can prune none of them. Returns the most removal events any node of the Text
    /// then carries.
    @MainActor
    private func churn(_ doc: Document, _ cycles: Int) throws -> Int {
        for _ in 0 ..< cycles {
            try self.edit(doc, 1, 2)
            try doc.undo()
        }
        return self.nodes(doc).map { $0.getRemovalEvents().count }.max() ?? 0
    }

    /// Counts the removed nodes still in the Text.
    @MainActor
    private func tombstones(_ doc: Document) -> Int {
        self.nodes(doc).filter { $0.isRemoved }.count
    }

    @MainActor
    private func events(_ doc: Document) -> Int {
        self.nodes(doc).reduce(0) { $0 + $1.getRemovalEvents().count }
    }

    @MainActor
    private func minVV(_ docs: Document...) -> VersionVector {
        advMinVersionVector(docs.map { $0.getVersionVector() })
    }

    @MainActor
    private func collect(_ doc: Document, _ vector: VersionVector) -> Int {
        doc.garbageCollect(minSyncedVersionVector: vector)
    }

    // MARK: - Tests

    @MainActor
    func test_keeps_a_concurrent_deletion_the_undo_never_saw_undoer_first() throws {
        try self.keepsAConcurrentDeletionTheUndoNeverSaw(undoerFirst: true)
    }

    @MainActor
    func test_keeps_a_concurrent_deletion_the_undo_never_saw_deleter_first() throws {
        try self.keepsAConcurrentDeletionTheUndoNeverSaw(undoerFirst: false)
    }

    @MainActor
    private func keepsAConcurrentDeletionTheUndoNeverSaw(undoerFirst: Bool) throws {
        // given -- b deletes `d` and undoes it; a concurrently deletes `defgh`.
        let (lhs, rhs) = try self.replicas("abcdefgh")
        try self.edit(rhs, 3, 4)
        try rhs.undo()
        try self.edit(lhs, 3, 8)

        // when
        if undoerFirst {
            try self.send(rhs, lhs)
            try self.send(lhs, rhs)
        } else {
            try self.send(lhs, rhs)
            try self.send(rhs, lhs)
        }

        // then -- `d` was removed by a's deletion too: b's undo cancels only its own.
        XCTAssertEqual(self.text(lhs), "abc")
        XCTAssertEqual(self.text(rhs), "abc")
    }

    @MainActor
    func test_does_not_remove_text_a_concurrent_undo_revives_yorkie_2237() throws {
        // given
        let (d1, d2) = try self.replicas("efgh")
        try self.edit(d2, 1, 2)
        try self.exchange(d1, d2)
        XCTAssertEqual(self.text(d1), "egh")

        // when -- d1 deletes `g` while d2 undoes its deletion of `f`.
        try self.edit(d1, 1, 2)
        try d2.undo()
        try self.exchange(d1, d2)

        // then -- d1 saw `f` removed, so its deletion leaves the revived `f` alone.
        XCTAssertEqual(self.text(d1), "efh")
        XCTAssertEqual(self.text(d2), "efh")
    }

    @MainActor
    func test_cancels_the_redo_not_the_original_deletion_on_the_next_undo() throws {
        // given -- b: delete `d`, undo, redo, undo. Each undo has to cancel the removal just
        // before it: the second one cancels the redo.
        let (lhs, rhs) = try self.replicas("abcdefgh")
        try self.edit(rhs, 3, 4)
        try rhs.undo()
        try rhs.redo()
        try rhs.undo()
        XCTAssertEqual(self.text(rhs), "abcdefgh")

        // when -- a concurrently removes `defgh`, which keeps `d` removed everywhere.
        try self.edit(lhs, 3, 8)
        try self.exchange(lhs, rhs)

        // then
        XCTAssertEqual(self.text(lhs), "abc")
        XCTAssertEqual(self.text(rhs), "abc")
    }

    @MainActor
    func test_leaves_alone_a_removed_piece_the_deleter_saw_removed() throws {
        // given
        let (lhs, rhs) = try self.replicas("abcdefgh")
        try self.edit(rhs, 3, 4)
        try self.exchange(lhs, rhs)

        // when -- a removes `cef` around the removed `d`; b concurrently undoes.
        try self.edit(lhs, 2, 5)
        try rhs.undo()
        try self.exchange(lhs, rhs)

        // then
        XCTAssertEqual(self.text(lhs), "abdgh")
        XCTAssertEqual(self.text(rhs), "abdgh")
    }

    @MainActor
    func test_keeps_the_ledger_through_a_snapshot() throws {
        // given
        let (lhs, rhs) = try self.replicas("abcdefgh")
        try self.edit(rhs, 3, 4)
        try self.edit(lhs, 3, 8)
        try self.send(lhs, rhs)

        // when -- c loads b's snapshot, where `d` is removed by both deletions; it must not
        // forget a's part when b's undo arrives.
        let other = try self.fromSnapshot(rhs)
        try rhs.undo()
        try self.send(rhs, lhs, other)

        // then
        XCTAssertEqual(self.text(lhs), "abc")
        XCTAssertEqual(self.text(rhs), "abc")
        XCTAssertEqual(self.text(other), "abc")
    }

    @MainActor
    func test_keeps_a_piece_another_deletion_still_holds_out_of_gc() throws {
        // given
        let (lhs, rhs) = try self.replicas("abcdefgh")
        try self.edit(rhs, 3, 4)
        try self.edit(lhs, 3, 8)
        try self.exchange(lhs, rhs)

        // when -- both deletions are known everywhere. b collects `efgh` but keeps `d`: an undo
        // of either deletion must find it held by the other.
        XCTAssertGreaterThan(self.collect(rhs, rhs.getVersionVector()), 0)
        XCTAssertEqual(self.tombstones(rhs), 1)

        try rhs.undo()
        try self.exchange(lhs, rhs)

        // then
        XCTAssertEqual(self.text(lhs), "abc")
        XCTAssertEqual(self.text(rhs), "abc")

        // only a's deletion is left on `d`, so it can be collected now.
        XCTAssertGreaterThan(self.collect(rhs, rhs.getVersionVector()), 0)
        XCTAssertEqual(self.tombstones(rhs), 0)
    }

    @MainActor
    func test_does_not_recreate_a_purged_piece_a_redo_never_removed() throws {
        // given -- b deletes `d` and undoes it while a deletes `d` too.
        let (lhs, rhs) = try self.replicas("abcdefgh")
        try self.edit(rhs, 3, 4)
        try rhs.undo()
        try self.edit(lhs, 3, 4)
        try self.exchange(lhs, rhs)
        XCTAssertEqual(self.text(rhs), "abcefgh")

        // when -- b's redo finds `d` already removed by a, so it records nothing there, and the
        // undo of the redo must not name `d` either: a has collected `d` and would recreate it.
        try rhs.redo()
        try self.exchange(lhs, rhs)
        XCTAssertGreaterThan(self.collect(lhs, lhs.getVersionVector()), 0)
        try rhs.undo()
        try self.exchange(lhs, rhs)

        // then
        XCTAssertEqual(self.text(lhs), "abcefgh")
        XCTAssertEqual(self.text(rhs), "abcefgh")
    }

    @MainActor
    func test_revives_a_deletion_nobody_else_made_also_after_a_snapshot() throws {
        // given
        let (lhs, rhs) = try self.replicas("abcdefgh")
        try self.edit(rhs, 3, 4)
        try self.exchange(lhs, rhs)
        let other = try self.fromSnapshot(lhs)

        // when
        try rhs.undo()
        try self.send(rhs, lhs, other)

        // then
        XCTAssertEqual(self.text(lhs), "abcdefgh")
        XCTAssertEqual(self.text(rhs), "abcdefgh")
        XCTAssertEqual(self.text(other), "abcdefgh")
    }

    @MainActor
    func test_redoes_only_what_the_redoer_saw_live() throws {
        // given -- a and b delete `cd` concurrently; a learns of b's deletion.
        let (lhs, rhs) = try self.replicas("abcdef")
        try self.edit(lhs, 2, 4)
        try self.edit(rhs, 2, 4)
        try self.send(rhs, lhs)
        try self.ack(rhs)

        // when -- a undoes and redoes: `cd` stays removed by b's deletion all along, so a's redo
        // removes nothing. b then undoes its deletion.
        try lhs.undo()
        try lhs.redo()
        try rhs.undo()
        try self.exchange(lhs, rhs)

        // then -- b revived `cd` before a's redo arrived; the redo, which saw `cd` removed,
        // leaves it alone there as it did on a.
        XCTAssertEqual(self.text(lhs), "abcdef")
        XCTAssertEqual(self.text(rhs), "abcdef")
    }

    @MainActor
    func test_propagates_an_undo_that_leaves_the_text_as_it_was() throws {
        // given -- both delete `a` concurrently; b learns of a's deletion first.
        let (lhs, rhs) = try self.replicas("abcdefgh")
        try self.edit(lhs, 0, 1)
        try self.edit(rhs, 0, 1)
        try self.send(lhs, rhs)
        try self.ack(lhs)

        // when -- b's undo cancels its own deletion while a's still holds `a`, so b's text does
        // not change. Its change has to reach a all the same.
        try lhs.undo()
        try rhs.undo()
        XCTAssertEqual(self.text(rhs), "bcdefgh")
        try self.send(rhs, lhs)
        try self.send(lhs, rhs)

        // then
        XCTAssertEqual(self.text(lhs), "abcdefgh")
        XCTAssertEqual(self.text(rhs), "abcdefgh")
    }

    @MainActor
    func test_redo_leaves_alone_a_piece_removed_in_its_view() throws {
        // given
        let (lhs, rhs) = try self.replicas("abcdefgh")
        try self.edit(lhs, 0, 1)
        try self.edit(rhs, 0, 3)
        try self.send(rhs, lhs)
        try self.ack(rhs)

        // when -- b undoes before a hears of it, so in a's view `a` stays removed by b's
        // deletion: a's undo and redo leave it removed, and the redo must not remove it on b,
        // where b's undo already revived it.
        try rhs.undo()
        try lhs.undo()
        try lhs.redo()
        try self.send(lhs, rhs)
        try self.send(rhs, lhs)

        // then
        XCTAssertEqual(self.text(lhs), self.text(rhs))
        XCTAssertEqual(self.text(lhs), "abcdefgh")
    }

    @MainActor
    func test_recreates_a_purged_piece_before_the_piece_that_follows_it() throws {
        // given
        let (lhs, rhs) = try self.replicas("abcdefghij")
        try self.edit(lhs, 1, 3)
        try self.edit(lhs, 0, 1)
        // b splits `defghij` by removing `e`, so two pieces of the insertion survive after the
        // gap a's undo will recreate.
        try self.edit(rhs, 4, 5)
        try self.send(lhs, rhs)
        try self.ack(lhs)
        XCTAssertGreaterThan(self.collect(rhs, rhs.getVersionVector()), 0)

        // when -- a revives `a` and removes `d`. On b, `a` must come back before `d`: placed
        // after a later piece, a's removal would run from `a` to the end of the text.
        try lhs.undo()
        try self.edit(lhs, 1, 2)
        try self.exchange(lhs, rhs)

        // then
        XCTAssertEqual(self.text(lhs), "afghij")
        XCTAssertEqual(self.text(rhs), "afghij")
    }

    @MainActor
    func test_keeps_a_piece_until_its_cancelled_removals_are_known_everywhere() throws {
        // given
        let (lhs, rhs) = try self.replicas("abc")
        let other = try self.fromSnapshot(lhs)
        // a and b remove `b` concurrently; c hears only of a's removal and removes the text
        // around it.
        try self.edit(lhs, 1, 2)
        try self.edit(rhs, 1, 2)
        try self.send(lhs, other)
        try self.edit(other, 0, 2)

        // a undoes its removal. b learns all of it, so only b's own removal holds `b` there; c
        // still knows nothing of a's undo.
        try self.send(lhs, rhs)
        try self.ack(lhs)
        try lhs.undo()
        try self.send(lhs, rhs)
        try self.send(rhs, lhs, other)
        try self.ack(rhs)
        self.collect(rhs, self.minVV(lhs, rhs, other))

        // when -- b's undo revives `b`; c's removal, which saw `b` removed by a, must leave it
        // alone on b as on a, whether or not b purged it.
        try rhs.undo()
        try self.send(rhs, lhs, other)
        try self.send(other, lhs, rhs)
        try self.send(lhs, other)

        // then
        XCTAssertEqual(self.text(lhs), "b")
        XCTAssertEqual(self.text(rhs), "b")
        XCTAssertEqual(self.text(other), "b")
    }

    @MainActor
    func test_links_a_recreated_piece_to_the_nearest_surviving_neighbours() throws {
        // given -- a removes `g`, then `h`; b collects both.
        let (lhs, rhs) = try self.replicas("abcdefghij")
        try self.edit(lhs, 6, 7)
        try self.edit(lhs, 6, 7)
        try self.send(lhs, rhs)
        try self.ack(lhs)
        XCTAssertGreaterThan(self.collect(rhs, rhs.getVersionVector()), 0)

        // b removes `f`, the piece before the gap, and a learns of it.
        try self.edit(rhs, 5, 6)
        try self.send(rhs, lhs)
        try self.ack(rhs)

        // when -- a's undo recreates `h` on b, which then collects `f` too: `f` still pointed
        // past the recreated `h`, so purging it must not hand `ij` an insertion predecessor that
        // skips `h`.
        try lhs.undo()
        try self.send(lhs, rhs)
        try self.ack(lhs)
        XCTAssertGreaterThan(self.collect(rhs, self.minVV(lhs, rhs)), 0)

        // an edit ending right after `h` resolves through `ij`'s predecessor.
        try self.edit(lhs, 5, 6)
        try self.send(lhs, rhs)

        // then
        XCTAssertEqual(self.text(lhs), "abcdeij")
        XCTAssertEqual(self.text(rhs), "abcdeij")
    }

    @MainActor
    func test_keeps_a_recreated_piece_out_of_a_deletion_that_saw_it_removed() throws {
        // given
        let (lhs, rhs) = try self.replicas("abc")
        let other = try self.fromSnapshot(lhs)
        try self.edit(rhs, 1, 2)
        try self.send(rhs, lhs, other)
        try self.ack(rhs)
        XCTAssertGreaterThan(self.collect(lhs, self.minVV(lhs, rhs, other)), 0)

        // when -- b undoes; c, which saw `b` removed but not the undo, removes the text around
        // it. a recreates `b` from the undo, so the recreated node has to answer c's view as b's
        // own ledger does.
        try rhs.undo()
        try self.edit(other, 0, 2)
        try self.send(rhs, lhs, other)
        try self.send(other, lhs, rhs)

        // then
        XCTAssertEqual(self.text(lhs), "b")
        XCTAssertEqual(self.text(rhs), "b")
        XCTAssertEqual(self.text(other), "b")
    }

    @MainActor
    func test_loads_a_snapshot_whose_removal_events_break_the_rules() throws {
        // given
        let (lhs, _) = try self.replicas("abc")
        try self.edit(lhs, 1, 2)
        let bytes = try Converter.snapshotToBytes(root: lhs.getRootObject(), presences: [:])

        // repeat removed_at as an event: no undo can produce that.
        var snapshot = try PbSnapshot(serializedBytes: bytes)
        var object = snapshot.root.jsonObject
        var textElement = object.nodes[0].element
        var pbText = textElement.text
        var removed = 0
        for index in pbText.nodes.indices where pbText.nodes[index].hasRemovedAt {
            pbText.nodes[index].removalEvents = [pbText.nodes[index].removedAt]
            removed += 1
        }
        XCTAssertGreaterThan(removed, 0)
        textElement.text = pbText
        object.nodes[0].element = textElement
        snapshot.root.jsonObject = object

        // when -- the bad ledger is dropped, not thrown on: a throw there wedges the document for
        // good over one node. The node keeps removed_at, so the text still reads the same.
        let loaded = try self.load(snapshot.serializedData(), versionVector: lhs.getVersionVector())

        // then
        XCTAssertEqual(self.text(loaded), "ac")
        XCTAssertEqual(self.events(loaded), 0)
    }

    @MainActor
    func test_reads_back_a_snapshot_whose_ledger_it_grew_itself() throws {
        // given
        let (lhs, _) = try self.replicas("abc")

        // when -- a server holding this document writes the ledger into every snapshot it
        // builds, and a client has to load it whole. Churn past 4096 events, the bound Go puts
        // only on pushed payloads: a reader that bounded snapshots too would drop this ledger and
        // diverge from its peers.
        let grown = try self.churn(lhs, (1 << 11) + 8)
        XCTAssertGreaterThan(grown, 1 << 12)
        let other = try self.fromSnapshot(lhs)

        // then
        XCTAssertEqual(self.text(other), "abc")
        XCTAssertEqual(self.events(other), self.events(lhs))
    }

    @MainActor
    func test_drops_cancelled_removals_every_replica_knows() throws {
        // given
        let (lhs, rhs) = try self.replicas("abcdefgh")
        for _ in 0 ..< 5 {
            try self.edit(lhs, 0, 8)
            try lhs.undo()
            try self.exchange(lhs, rhs)
        }

        // when -- every removal is cancelled, but only a vector both replicas have seen lets the
        // pairs go; until then they decide later deletions.
        XCTAssertGreaterThan(self.events(lhs), 0)
        self.collect(lhs, self.minVV(lhs, rhs))

        // then
        XCTAssertEqual(self.events(lhs), 0)
        XCTAssertEqual(self.text(lhs), "abcdefgh")
    }

    @MainActor
    func test_carries_a_cancelled_removal_through_a_snapshot() throws {
        // given -- a deletes `d` and undoes it; the pair stays in the ledger while b has not seen
        // the cancel, so the snapshot has to carry both halves.
        let (lhs, rhs) = try self.replicas("abcdefgh")
        try self.edit(lhs, 3, 4)
        try lhs.undo()
        XCTAssertGreaterThan(self.events(lhs), 0)

        let other = try self.fromSnapshot(lhs)
        XCTAssertGreaterThan(self.events(other), 0)
        XCTAssertEqual(self.text(other), "abcdefgh")

        // when -- the replica loaded from that snapshot answers a later concurrent deletion as the
        // one that wrote it does: b never saw the undo, so its deletion of `d` holds the piece
        // removed on both.
        try self.edit(rhs, 3, 4)
        try self.send(lhs, rhs)
        try self.send(rhs, lhs, other)

        // then
        XCTAssertEqual(self.text(lhs), "abcefgh")
        XCTAssertEqual(self.text(other), self.text(lhs))
    }

    @MainActor
    func test_reverses_an_undo_that_found_nothing_left_to_undo() throws {
        // given -- b inserts `X`, then deletes `a` and undoes that deletion, leaving one entry on
        // each stack.
        let (lhs, rhs) = try self.replicas("ab")
        try self.edit(rhs, 2, 2, "X")
        try self.edit(rhs, 0, 1)
        try rhs.undo()
        try self.exchange(lhs, rhs)
        XCTAssertEqual(self.text(rhs), "abX")

        // a removes `X`; b's undo of its own insertion then finds nothing live to re-remove, so
        // its reverse names no span.
        try self.edit(lhs, 2, 3)
        try self.exchange(lhs, rhs)
        try rhs.undo()
        try self.exchange(lhs, rhs)
        XCTAssertEqual(self.text(rhs), "ab")

        // when -- that reverse still has to be pushed: dropping it would leave the redo stack one
        // entry short, and this redo would re-run the deletion of `a` instead of doing nothing.
        try rhs.redo()
        try self.exchange(lhs, rhs)

        // then
        XCTAssertEqual(self.text(rhs), "ab")
        XCTAssertEqual(self.text(lhs), "ab")
    }
}
