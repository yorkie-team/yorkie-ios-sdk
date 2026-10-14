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

/// `mulberry32` is a small seeded PRNG, so a seed replays the same history. The arithmetic is the
/// 32-bit wrapping arithmetic of yorkie-js-sdk's test, step for step.
private struct Mulberry32 {
    private var state: UInt32

    init(seed: UInt32) {
        self.state = seed
    }

    mutating func next() -> Double {
        self.state = self.state &+ 0x6D2B_79F5
        var mixed = self.state
        mixed = (mixed ^ (mixed >> 15)) &* (mixed | 1)
        mixed ^= mixed &+ ((mixed ^ (mixed >> 7)) &* (mixed | 61))
        return Double(mixed ^ (mixed >> 14)) / 4_294_967_296.0
    }

    mutating func pick(_ count: Int) -> Int {
        Int(self.next() * Double(count))
    }
}

/// A recording `Operation` that has nothing to do with the wire: it reports the source it was
/// executed under and is rejected by ``Converter/toOperation(_:)``.
private final class SourceRecordingOperation: Yorkie.Operation {
    let parentCreatedAt: TimeTicket = .initial
    var executedAt: TimeTicket = .initial
    var effectedCreatedAt: TimeTicket { self.executedAt }
    var toTestString: String { "RECORD" }
    private(set) var sources = [OpSource]()

    func resetSources() {
        self.sources.removeAll()
    }

    func execute(root: CRDTRoot, versionVector: VersionVector?, source: OpSource) throws -> ExecutionResult? {
        self.sources.append(source)
        return ExecutionResult(opInfos: [], reverseOp: nil)
    }
}

/// Ports `packages/sdk/test/unit/document/set_actor_reissue_test.ts` from yorkie-js-sdk v0.7.25
/// (yorkie-js-sdk#1449 "Re-issue pre-attach tickets to the client's actor on attach").
///
/// Not ported: the `ReissueToken` tests ("refuses a re-issue asked for without the token" and the
/// forged option bags). Swift has no module-private symbol to forge: the re-issue entry point,
/// ``Document/setActor(_:reissue:)``, is `internal`, which is a compile-time guarantee the test
/// could only restate. The replay-failure test injects its failure through an operation the wire
/// cannot encode, because Swift has no prototype to patch the way the JS test mocks
/// `SetOperation.prototype.execute`.
@MainActor
final class SetActorReissueTests: XCTestCase {
    private let actorA = "000000000000000000000001"
    private let actorB = "000000000000000000000002"

    // MARK: Helpers

    private func para(_ value: String) -> JSONTreeElementNode {
        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: value)])
    }

    /// Edits a detached document with every kind of element, so every place a ticket can hide is
    /// populated before the attach.
    private func fillEverything(_ doc: Document) throws {
        try doc.update { root, presence in
            root.text = JSONText()
            root.obj = ["k": "v", "arr": [Int64(1), Int64(2), Int64(3)]] as [String: Any]
            root.cnt = JSONCounter<Int64>(value: 1)
            root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [self.para("ab")]))
            root.gone = "x"
            presence.set(["cursor": "1"])
        }
        try doc.update { root, _ in
            let text = root.text as? JSONText
            text?.edit(0, 0, "hello")
            text?.edit(1, 3, "XY")
            text?.setStyle(0, 2, ["b": "1"])
            (root.cnt as? JSONCounter<Int64>)?.increase(value: 2)
        }
        let arr = try XCTUnwrap(((doc.getRootObject().get(key: "obj")) as? CRDTObject)?.get(key: "arr") as? CRDTArray)
        let ids = arr.map { $0.createdAt }
        try doc.update { root, _ in
            try (root.tree as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "c"))
            (root.text as? JSONText)?.edit(0, 1, "")
            root.remove(key: "gone")
            try ((root.obj as? JSONObject)?.arr as? JSONArray)?.moveBefore(nextID: ids[0], id: ids[2])
        }
    }

    /// Counts, per actor, the non-initial tickets in the document's root and in the change pack it
    /// would push.
    private func actorsOf(_ doc: Document) throws -> [String: Int] {
        let snapshot = try PbSnapshot(
            serializedBytes: Converter.snapshotToBytes(root: doc.getRootObject(), presences: [:])
        )
        let pack = Converter.toChangePack(pack: doc.createChangePack())
        return countActors(ticketsOf(snapshot) + ticketsOf(pack))
    }

    /// Returns the local changes of the given document as they arrive on another replica.
    private func wire(_ doc: Document) throws -> [Change] {
        try Converter.fromChangePack(Converter.toChangePack(pack: doc.createChangePack())).getChanges()
    }

    /// Rebuilds a document from the change packs the given documents would push, the way the server
    /// does.
    private func serverBuild(_ docs: Document...) throws -> Document {
        let built = Document(key: docs[0].getKey())
        for doc in docs {
            try built.applyChanges(self.wire(doc), source: .remote)
        }
        return built
    }

    /// Re-issues the document's tickets as `Client.attach` does.
    private func reissue(_ doc: Document, _ actor: ActorID) throws {
        try doc.setActor(actor, reissue: true)
    }

    private func localActorsOf(_ doc: Document) -> [ActorID?] {
        doc.createChangePack().getChanges().map { $0.id.getActorID() }
    }

    /// Checks that every local change the document would push carries a version vector naming only
    /// the given actor, at that change's own lamport. An entry left under the initial actor would
    /// make every replica wait on an actor that never syncs again.
    private func assertLocalVectors(_ doc: Document, _ actor: ActorID, file: StaticString = #filePath, line: UInt = #line) {
        let changes = doc.createChangePack().getChanges()
        XCTAssertFalse(changes.isEmpty, file: file, line: line)
        for (index, change) in changes.enumerated() {
            let vector = change.id.getVersionVector()
            for (id, _) in vector {
                XCTAssertEqual(id, actor, "change \(index)", file: file, line: line)
            }
            XCTAssertEqual(vector.get(actor), change.id.getLamport(), "change \(index)", file: file, line: line)
        }
    }

    private func rootBytes(_ doc: Document) throws -> Data {
        try Converter.objectToBytes(obj: doc.getRootObject())
    }

    /// Edits a detached document with a seeded mix of text, tree, array and object edits, removals
    /// and undo/redo. An edit the current state cannot take is skipped.
    private func fillRandomly(_ doc: Document, seed: UInt32) throws {
        var rnd = Mulberry32(seed: seed)

        try doc.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "abcdef")
            root.o = ["k": "v"] as [String: Any]
            (root.o as? JSONObject)?.t = JSONText()
            (((root.o as? JSONObject)?.t) as? JSONText)?.edit(0, 0, "ghij")
            root.a = [Int64(1), JSONText()] as [Any]
            ((root.a as? JSONArray)?.getElement(byIndex: 1) as? JSONText)?.edit(0, 0, "klmn")
            root.tree = JSONTree(initialRoot: JSONTreeElementNode(
                type: "doc", children: [self.para("abcd")]
            ))
        }

        let texts: [(JSONObject) -> JSONText?] = [
            { $0.t as? JSONText },
            { ($0.o as? JSONObject)?.t as? JSONText },
            { ($0.a as? JSONArray)?.getElement(byIndex: 1) as? JSONText }
        ]
        for _ in 0 ..< 16 {
            // The picked target may be gone or the range may not fit; an error skips the step.
            let step = rnd.pick(8)
            do {
                switch step {
                case 0, 1:
                    let which = rnd.pick(texts.count), withX = rnd.pick(2), fromPick = rnd.next(), toPick = rnd.next()
                    try doc.update { root, _ in
                        guard let text = texts[which](root) else { return }
                        let from = Int(fromPick * Double(text.length + 1))
                        let to = from + Int(toPick * Double(text.length - from + 1))
                        text.edit(from, to, withX == 1 ? "x" : "")
                    }
                case 2:
                    let which = rnd.pick(texts.count), fromPick = rnd.next(), toPick = rnd.next(), value = rnd.pick(3)
                    try doc.update { root, _ in
                        guard let text = texts[which](root) else { return }
                        let from = Int(fromPick * Double(text.length + 1))
                        text.setStyle(from, from + Int(toPick * Double(text.length - from + 1)), ["b": "\(value)"])
                    }
                case 3:
                    let atPick = rnd.next(), insertText = rnd.pick(2)
                    try doc.update { root, _ in
                        guard let tree = root.tree as? JSONTree else { return }
                        let size = try tree.getSize()
                        let at = 1 + Int(atPick * Double(size - 1))
                        if insertText == 1 {
                            _ = try tree.edit(at, at, JSONTreeTextNode(value: "q"))
                        } else {
                            _ = try tree.edit(at, at, nil, 1)
                        }
                    }
                case 4:
                    let pushToArray = rnd.pick(2), value = rnd.pick(10)
                    try doc.update { root, _ in
                        if pushToArray == 1 {
                            _ = (root.a as? JSONArray)?.append(Int64(value))
                        } else {
                            (root.o as? JSONObject)?.k = "\(value)"
                        }
                    }
                case 5:
                    let which = rnd.pick(3)
                    try doc.update { root, _ in
                        if which == 0 { root.remove(key: "t") }
                        if which == 1 { root.remove(key: "o") }
                        if which == 2 { _ = (root.a as? JSONArray)?.remove(at: 1) }
                    }
                case 6:
                    if doc.canUndo { try doc.undo() }
                default:
                    if doc.canRedo { try doc.redo() }
                }
            } catch {
                continue
            }
        }
    }

    // MARK: Tests

    func test_leaves_no_ticket_under_the_initial_actor() throws {
        // given
        let doc = Document(key: "d")
        try self.fillEverything(doc)
        let before = doc.toSortedJSON()
        XCTAssertGreaterThan(try self.actorsOf(doc)[ActorIDs.initial] ?? 0, 0)

        // when
        try self.reissue(doc, self.actorA)

        // then
        let actors = try self.actorsOf(doc)
        XCTAssertNil(actors[ActorIDs.initial], "\(actors)")
        XCTAssertGreaterThan(actors[self.actorA] ?? 0, 0)
        XCTAssertEqual(doc.toSortedJSON(), before)

        let vector = doc.getVersionVector()
        XCTAssertFalse(vector.has(ActorIDs.initial))
        XCTAssertEqual(vector.get(self.actorA), doc.changeID.getLamport())
        XCTAssertEqual(doc.changeID.getActorID(), self.actorA)

        self.assertLocalVectors(doc, self.actorA)

        let presences = doc.persistenceSnapshot().presences
        XCTAssertNotNil(presences[self.actorA])
        XCTAssertNil(presences[ActorIDs.initial])
    }

    func test_builds_the_same_root_the_server_builds() throws {
        // given
        let doc = Document(key: "d")
        try self.fillEverything(doc)

        // when
        try self.reissue(doc, self.actorA)

        // then
        let built = try self.serverBuild(doc)
        XCTAssertEqual(doc.toSortedJSON(), built.toSortedJSON())
        XCTAssertEqual(try self.rootBytes(doc), try self.rootBytes(built))
    }

    func test_continues_edits_under_the_new_actor() throws {
        // given
        let doc = Document(key: "d")
        try self.fillEverything(doc)
        try self.reissue(doc, self.actorA)

        // when
        try doc.update { root, _ in
            (root.text as? JSONText)?.edit(0, 0, "Z")
            _ = try (root.tree as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "Q"))
            (root.obj as? JSONObject)?.k = "w"
        }

        // then
        let actors = try self.actorsOf(doc)
        XCTAssertNil(actors[ActorIDs.initial])
        XCTAssertGreaterThan(actors[self.actorA] ?? 0, 0)
        self.assertLocalVectors(doc, self.actorA)
        XCTAssertEqual(doc.toSortedJSON(), try self.serverBuild(doc).toSortedJSON())
    }

    func test_re_issues_a_retried_attach_to_the_next_actor() throws {
        // given
        let doc = Document(key: "d")
        try self.fillEverything(doc)

        // when
        try self.reissue(doc, self.actorA)
        try self.reissue(doc, self.actorB)

        // then
        let actors = try self.actorsOf(doc)
        XCTAssertNil(actors[ActorIDs.initial])
        XCTAssertNil(actors[self.actorA])
        XCTAssertGreaterThan(actors[self.actorB] ?? 0, 0)
        self.assertLocalVectors(doc, self.actorB)
    }

    func test_clears_the_undo_history_it_invalidates() throws {
        // given
        let doc = Document(key: "d")
        try self.fillEverything(doc)
        XCTAssertTrue(doc.canUndo)

        // when
        try self.reissue(doc, self.actorA)

        // then
        XCTAssertFalse(doc.canUndo)
        XCTAssertNil(doc.getClone())
    }

    func test_marks_the_changes_an_undo_produced_and_keeps_the_mark_through_a_re_issue() throws {
        // given -- an undo's change ran as `.undoRedo`, and a replay has to run it that way again.
        let doc = Document(key: "d")
        try doc.update { root, _ in root.obj = ["k": "v"] }
        try doc.update { root, _ in (root.obj as? JSONObject)?.k = "w" }
        try doc.undo()
        let before = doc.toSortedJSON()
        XCTAssertEqual(doc.getPendingChangeStructs().map(\.isUndoRedo), [false, false, true])

        // when
        try self.reissue(doc, self.actorA)

        // then -- the rebuilt root is the live one, and the rebuilt changes carry the mark.
        XCTAssertEqual(doc.getPendingChangeStructs().map(\.isUndoRedo), [false, false, true])
        XCTAssertEqual(doc.toSortedJSON(), before)
        XCTAssertNil(try self.actorsOf(doc)[ActorIDs.initial])
    }

    func test_replays_an_undone_change_under_the_source_it_ran_with() throws {
        // given -- `SetOperation`/`RemoveOperation` skip an operation whose target sits under a
        // removed parent, and `.undoRedo` is the only source they look at. Swift has no prototype to
        // spy on `Change.execute`, so a recording operation reports the source itself.
        let doc = Document(key: "d")
        let recorder = SourceRecordingOperation()
        let local = Change(id: ChangeID.initial.next(), operations: [recorder])
        let undone = Change(id: ChangeID.initial.next().next(), operations: [recorder], isUndoRedo: true)

        // when
        try doc.replayLocalChanges([local, undone])

        // then -- each change runs twice, once on the clone and once on the root.
        XCTAssertEqual(recorder.sources, [.local, .local, .undoRedo, .undoRedo])
        XCTAssertEqual(Document.replaySource(of: local), .local)
        XCTAssertEqual(Document.replaySource(of: undone), .undoRedo)
    }

    func test_replays_an_undone_change_under_its_own_source_after_a_snapshot() throws {
        // given -- `applySnapshot` re-applies the queued local changes on top of the snapshot root,
        // and the re-issue is not the only replay that has to honour the source each change ran under.
        let doc = Document(key: "d")
        let recorder = SourceRecordingOperation()
        try doc.updateWithOperationForTest([recorder])
        try doc.updateWithOperationForTest([recorder])
        let marked = try XCTUnwrap(doc.getPendingChangeStructs().last)
        XCTAssertFalse(marked.isUndoRedo)

        // an undone change joins the queue the way the persisted-log replay does.
        let undone = Change(id: marked.id.next(), operations: [recorder], isUndoRedo: true)
        try doc.appendRestoredChanges([undone], ackedClientSeq: 0)
        XCTAssertEqual(doc.getPendingChangeStructs().map(\.isUndoRedo), [false, false, true])
        recorder.resetSources()

        // when
        let snapshot = try Converter.snapshotToBytes(root: CRDTObject(createdAt: .initial), presences: [:])
        try doc.applySnapshot(1, VersionVector(vector: [:]), snapshot)

        // then -- the three queued changes replay as local, local and undoRedo, each on the clone
        // and on the root.
        XCTAssertEqual(recorder.sources, [.local, .local, .local, .local, .undoRedo, .undoRedo])
    }

    func test_carries_the_undo_mark_through_the_persisted_change_log() throws {
        // given -- the offline-persistence layer writes the queued changes and replays them after a
        // relaunch (`restoreAppendedChanges`). The mark has to survive that round trip.
        let doc = Document(key: "d")
        try doc.update { root, _ in root.obj = ["k": "v"] }
        try doc.update { root, _ in (root.obj as? JSONObject)?.k = "w" }
        try doc.undo()

        // when
        let stored = try doc.getPendingChangesAfter(0)
        let restored = try Converter.fromPersistedChanges(stored.map { try PbChange(serializedBytes: $0.bytes) })

        // then
        XCTAssertEqual(restored.map(\.isUndoRedo), [false, false, true])
    }

    func test_does_not_carry_the_undo_mark_on_the_wire() throws {
        // given
        let doc = Document(key: "d")
        try doc.update { root, _ in root.obj = ["k": "v"] }
        try doc.update { root, _ in (root.obj as? JSONObject)?.k = "w" }
        try doc.undo()

        // when -- a pushed pack goes through the plain converter.
        let pbPack = Converter.toChangePack(pack: doc.createChangePack())

        // then
        XCTAssertTrue(pbPack.changes.allSatisfy { $0.unknownFields.data.isEmpty })
        let received = try Converter.fromChangePack(pbPack).getChanges()
        XCTAssertEqual(received.map(\.isUndoRedo), [false, false, false])
    }

    func test_does_not_re_issue_a_document_that_has_synced() throws {
        // given
        let doc = Document(key: "d")
        try self.fillEverything(doc)
        var checkpoint = doc.createChangePack().getCheckpoint()
        checkpoint.forward(other: Checkpoint(serverSeq: 1, clientSeq: checkpoint.getClientSeq()))
        try doc.applyChangePack(ChangePack(
            key: doc.getKey(),
            checkpoint: checkpoint,
            isRemoved: false,
            changes: [],
            versionVector: doc.getVersionVector()
        ))
        try doc.update { root, _ in root.late = "v" }

        // when
        try self.reissue(doc, self.actorA)

        // then
        XCTAssertGreaterThan(try self.actorsOf(doc)[ActorIDs.initial] ?? 0, 0)

        // The fallback is what sets the actor on a document that has synced, so it has to reach the
        // change ID and every buffered local change.
        XCTAssertEqual(doc.changeID.getActorID(), self.actorA)
        let local = self.localActorsOf(doc)
        XCTAssertFalse(local.isEmpty)
        for actor in local {
            XCTAssertEqual(actor, self.actorA)
        }
    }

    func test_does_not_re_issue_a_document_that_absorbed_a_snapshot() throws {
        // given -- the checkpoint, the status and the version vector all still look untouched after
        // a snapshot pack carrying the initial checkpoint, so only the absorbed guard keeps the
        // rebuild -- which can reproduce the local changes and nothing else -- away from the root.
        let doc = Document(key: "d")
        try self.fillEverything(doc)
        let snapshot = try Converter.snapshotToBytes(root: doc.getRootObject(), presences: [:])
        try doc.applyChangePack(ChangePack(
            key: doc.getKey(),
            checkpoint: .initial,
            isRemoved: false,
            changes: [],
            snapshot: snapshot,
            versionVector: doc.getVersionVector()
        ))
        XCTAssertFalse(doc.getPendingChangeStructs().isEmpty)
        let before = doc.toSortedJSON()

        // when
        try self.reissue(doc, self.actorA)

        // then
        XCTAssertEqual(doc.toSortedJSON(), before)
        XCTAssertGreaterThan(try self.actorsOf(doc)[ActorIDs.initial] ?? 0, 0)
    }

    func test_does_not_re_issue_a_document_restored_from_bytes() throws {
        // given
        let source = Document(key: "d")
        try self.fillEverything(source)

        // when
        let doc = try Document.fromBytes(key: "d", bytes: source.toBytes())
        XCTAssertFalse(doc.getPendingChangeStructs().isEmpty)
        try self.reissue(doc, self.actorA)

        // then
        XCTAssertGreaterThan(try self.actorsOf(doc)[ActorIDs.initial] ?? 0, 0)
    }

    func test_reports_a_document_decoded_from_bytes_as_having_minted() throws {
        // given -- `Client.attach` only takes the re-issue claim for a document that minted
        // something, so the public `fromBytes` factory has to report the way the in-place
        // `restoreFromBytes` does: an app that restores an envelope and attaches the result pushes
        // tickets under the actor, and a later document of that key must not re-issue onto those
        // lamports.
        let source = Document(key: "d")
        try self.fillEverything(source)
        let bytes = try source.toBytes()

        // when
        let decoded = try Document.fromBytes(key: "d", bytes: bytes)
        let inPlace = Document(key: "d")
        try inPlace.restoreFromBytes(bytes)

        // then
        XCTAssertTrue(decoded.hasMintedOperations())
        XCTAssertTrue(inPlace.hasMintedOperations())

        // An untouched document still mints nothing, so the relaxed claim keeps its point: a plain
        // attach of one leaves the key free for a re-issue.
        XCTAssertFalse(Document(key: "d").hasMintedOperations())
    }

    func test_resets_the_absorbed_flag_when_re_anchoring() throws {
        // given
        let source = Document(key: "d")
        try self.fillEverything(source)
        let doc = try Document.fromBytes(key: "d", bytes: source.toBytes())
        XCTAssertTrue(doc.absorbedRemote)

        // when
        doc.resetForReanchor()

        // then -- no longer absorbed, but a push cannot be taken back, so it still counts as minted.
        XCTAssertFalse(doc.absorbedRemote)
        XCTAssertTrue(doc.hasMintedOperations())
    }

    func test_is_plain_set_actor_without_the_option() throws {
        // given
        let doc = Document(key: "d")
        try self.fillEverything(doc)
        let before = doc.toSortedJSON()
        let initial = try self.actorsOf(doc)[ActorIDs.initial] ?? 0
        XCTAssertTrue(doc.canUndo)

        // when
        doc.setActor(self.actorA)

        // then
        XCTAssertEqual(doc.changeID.getActorID(), self.actorA)
        XCTAssertEqual(doc.toSortedJSON(), before)
        XCTAssertTrue(doc.canUndo)
        for actor in self.localActorsOf(doc) {
            XCTAssertEqual(actor, self.actorA)
        }
        // The tickets inside the operations and the root keep the initial actor.
        let left = try self.actorsOf(doc)[ActorIDs.initial] ?? 0
        XCTAssertGreaterThan(left, 0)
        XCTAssertLessThan(left, initial)
    }

    func test_only_sets_the_actor_of_an_empty_document() throws {
        // given
        let doc = Document(key: "d")

        // when
        try self.reissue(doc, self.actorA)

        // then
        XCTAssertEqual(doc.changeID.getActorID(), self.actorA)
        XCTAssertEqual(doc.toSortedJSON(), "{}")
    }

    func test_keeps_the_content_of_a_text_restored_by_undo() throws {
        for editAfterUndo in [false, true] {
            // given -- the wire carries a Text value without its content, so a re-issue that
            // round-trips a restoring Set would empty the Text locally, and the replay of a later
            // Edit on its nodes would fail.
            let doc = Document(key: "d")
            try doc.update { root, _ in
                root.t = JSONText()
                (root.t as? JSONText)?.edit(0, 0, "hello")
                root.a = [JSONText()] as [Any]
                ((root.a as? JSONArray)?.getElement(byIndex: 0) as? JSONText)?.edit(0, 0, "world")
            }
            try doc.update { root, _ in
                root.remove(key: "t")
                _ = (root.a as? JSONArray)?.remove(at: 0)
            }
            try doc.undo()
            if editAfterUndo {
                try doc.update { root, _ in
                    (root.t as? JSONText)?.edit(2, 4, "ZZ")
                    ((root.a as? JSONArray)?.getElement(byIndex: 0) as? JSONText)?.edit(0, 1, "W")
                }
            }
            let before = doc.toSortedJSON()

            // when
            try self.reissue(doc, self.actorA)

            // then
            XCTAssertEqual(doc.toSortedJSON(), before, "edit after: \(editAfterUndo)")
            XCTAssertNil(try self.actorsOf(doc)[ActorIDs.initial])
            XCTAssertGreaterThan(try self.actorsOf(doc)[self.actorA] ?? 0, 0)
        }
    }

    func test_keeps_the_split_links_of_a_text_restored_by_undo() throws {
        for wrap in ["none", "object", "array"] {
            // given -- an Edit after the undo resolves its position through the restored Text's
            // insertion links. The value goes through its element encoding, which has to carry them,
            // or the replay puts the Edit elsewhere.
            let doc = Document(key: "d")
            let text: (JSONObject) -> JSONText? = { root in
                switch wrap {
                case "none": return root.t as? JSONText
                case "object": return (root.o as? JSONObject)?.t as? JSONText
                default: return (root.a as? JSONArray)?.getElement(byIndex: 0) as? JSONText
                }
            }
            try doc.update { root, _ in
                switch wrap {
                case "none":
                    root.t = JSONText()
                case "object":
                    root.o = ["x": Int64(0)] as [String: Any]
                    (root.o as? JSONObject)?.t = JSONText()
                default:
                    root.a = [JSONText()] as [Any]
                }
                text(root)?.edit(0, 0, "abcdef")
            }
            try doc.update { root, _ in text(root)?.edit(2, 4, "x") }
            try doc.update { root, _ in
                switch wrap {
                case "none": root.remove(key: "t")
                case "object": root.remove(key: "o")
                default: _ = (root.a as? JSONArray)?.remove(at: 0)
                }
            }
            try doc.undo()
            try doc.update { root, _ in text(root)?.edit(0, 2, "x") }
            let before = doc.toSortedJSON()

            // when
            try self.reissue(doc, self.actorA)

            // then
            XCTAssertEqual(doc.toSortedJSON(), before, "wrap: \(wrap)")
            XCTAssertNil(try self.actorsOf(doc)[ActorIDs.initial], "wrap: \(wrap)")
            if wrap == "object" {
                // A nested Text travels with its content, so the server builds it.
                XCTAssertEqual(try self.serverBuild(doc).toSortedJSON(), before)
            }
        }
    }

    func test_keeps_tree_splits_undo_redo_tree_style_and_array_set() throws {
        // given
        let doc = Document(key: "d")
        try doc.update { root, _ in
            root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [self.para("abcd")]))
        }
        try doc.update { root, _ in _ = try (root.tree as? JSONTree)?.edit(3, 3, nil, 1) }
        try doc.undo()
        try doc.redo()
        try doc.update { root, _ in
            try (root.tree as? JSONTree)?.style(0, 1, ["a": "b"])
            root.arr = [Int64(1), Int64(2)] as [Any]
            _ = try (root.arr as? JSONArray)?.setValue(index: 0, value: 9)
            root.c = JSONCounter<Int64>(value: 1)
            (root.c as? JSONCounter<Int64>)?.increase(value: 3)
        }
        let before = doc.toSortedJSON()
        let size = doc.getDocSize()
        let garbage = doc.getGarbageLength()

        // when
        try self.reissue(doc, self.actorA)

        // then
        XCTAssertEqual(doc.toSortedJSON(), before)
        XCTAssertEqual(doc.getDocSize(), size)
        XCTAssertEqual(doc.getGarbageLength(), garbage)
        XCTAssertNil(try self.actorsOf(doc)[ActorIDs.initial])
        XCTAssertGreaterThan(try self.actorsOf(doc)[self.actorA] ?? 0, 0)
        XCTAssertEqual(doc.toSortedJSON(), try self.serverBuild(doc).toSortedJSON())
    }

    func test_converges_two_documents_that_filled_the_same_key() throws {
        // given
        let doc1 = Document(key: "d")
        let doc2 = Document(key: "d")
        for (doc, content) in [(doc1, "one"), (doc2, "two")] {
            try doc.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, content)
            }
        }

        // when
        try self.reissue(doc1, self.actorA)
        try self.reissue(doc2, self.actorB)

        // then -- the values no longer share a createdAt.
        let created1 = try XCTUnwrap(doc1.getRootObject().get(key: "k1")).createdAt
        let created2 = try XCTUnwrap(doc2.getRootObject().get(key: "k1")).createdAt
        XCTAssertNotEqual(created1.toIDString, created2.toIDString)

        // doc1 reaches the server first; doc2's later Set wins by LWW on the actor tie-break (same
        // lamport, larger actor).
        let built = try self.serverBuild(doc1, doc2)
        XCTAssertEqual(built.toSortedJSON(), "{\"k1\":[{\"val\":\"two\"}]}")

        let from1 = try self.wire(doc1)
        let from2 = try self.wire(doc2)
        try doc1.applyChanges(from2, source: .remote)
        try doc2.applyChanges(from1, source: .remote)
        XCTAssertEqual(doc1.toSortedJSON(), built.toSortedJSON())
        XCTAssertEqual(doc2.toSortedJSON(), built.toSortedJSON())
    }

    func test_renames_an_online_client_entry_to_the_re_issued_actor() throws {
        // given
        let doc = Document(key: "d")
        try self.fillEverything(doc)
        doc.addOnlineClient(ActorIDs.initial)

        // when
        try self.reissue(doc, self.actorA)

        // then
        XCTAssertTrue(doc.onlineClients.contains(self.actorA))
        XCTAssertFalse(doc.onlineClients.contains(ActorIDs.initial))
    }

    func test_leaves_the_document_untouched_when_the_re_issue_fails() throws {
        // given -- an operation the wire cannot encode makes the re-issue throw before anything is
        // swapped in.
        let doc = Document(key: "d")
        try self.fillEverything(doc)
        try doc.updateWithOperationForTest([SourceRecordingOperation()])
        let before = doc.toSortedJSON()
        let changeCount = doc.getPendingChangeStructs().count
        let root = doc.persistenceSnapshot().root

        // when
        XCTAssertThrowsError(try self.reissue(doc, self.actorA))

        // then
        XCTAssertEqual(doc.getPendingChangeStructs().count, changeCount)
        XCTAssertTrue(doc.persistenceSnapshot().root === root)
        XCTAssertEqual(doc.toSortedJSON(), before)
        XCTAssertEqual(doc.changeID.getActorID(), ActorIDs.initial)
        XCTAssertTrue(doc.canUndo)
    }

    func test_resets_the_devtools_recording_to_a_snapshot_of_the_re_issued_root() throws {
        // given
        let doc = Document(key: "d", opts: DocumentOptions(disableGC: false, enableDevtools: true))
        try self.fillEverything(doc)
        let recorder = try XCTUnwrap(doc.attachDevtoolsRecorder())
        XCTAssertGreaterThan(recorder.count, 1)
        var notified = 0
        recorder.addObserver { notified += 1 }

        // when
        try self.reissue(doc, self.actorA)

        // then -- one baseline snapshot event, and observers told once.
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(notified, 1)
        let events = recorder.dump()
        XCTAssertEqual(events.first?.first?["type"] as? String, DocEventType.snapshot.rawValue)
    }

    func test_keeps_the_content_of_random_pre_attach_histories() throws {
        // Anything the wire drops from a value that a later edit relies on shows up here as content
        // that changes at attach. The JS test sweeps 300 seeds; the same sweep runs here.
        let seeds = 300
        for seed in 1 ... UInt32(seeds) {
            let doc = Document(key: "d")
            try self.fillRandomly(doc, seed: seed)
            let before = doc.toSortedJSON()

            try self.reissue(doc, self.actorA)
            XCTAssertEqual(doc.toSortedJSON(), before, "seed \(seed)")
            XCTAssertNil(try self.actorsOf(doc)[ActorIDs.initial], "seed \(seed)")
        }
    }
}
