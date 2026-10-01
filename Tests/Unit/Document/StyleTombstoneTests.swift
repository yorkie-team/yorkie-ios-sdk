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

/// Ports: `packages/sdk/test/unit/document/style_tombstone_test.ts` from
/// yorkie-js-sdk PR #1368 "Stop canStyle reading removal state" (commit
/// e0609c7a1199d248545f30c6ccee8ac61a112f9e).
///
/// `canStyle` decides whether a style may land on a node that has been
/// removed. The answer it gives is a convergence decision, not a rendering
/// preference, because a style is applied unconditionally on the replica
/// that issues it -- the node is still live there -- and can never be
/// retracted afterwards. So either every replica applies it or the replicas
/// hold different attributes on the same node forever, invisible while it is
/// a tombstone and rendered the moment the removal is undone.
///
/// The contract these tests pin, shared with the server:
///
/// - a removal the styling change had already SEEN wins, so a user never
///   styles text they already deleted (a local change has seen every
///   removal in its own replica, which is the whole of the local case);
/// - a removal CONCURRENT with the style does not, so the style lands on the
///   tombstone everywhere.
///
/// This SDK used to refuse every removed node, which diverges in both
/// orderings; the server decided it on `editedAt.after(removedAt)`, which
/// made it turn on an actor-ID tie-break.

private let actorA1: ActorID = "000000000000000000000001"
private let actorA2: ActorID = "000000000000000000000002"

/// Exchanges pending local changes between two in-process documents,
/// mimicking a server round-trip without going through real serialization. A
/// neutral checkpoint (clientSeq 0) on delivery keeps the receiver's own
/// pending local changes intact, and `VersionVector.initial` keeps GC out of
/// the exchange.
@MainActor
private func crossSync(_ d1: Document, _ d2: Document) throws {
    let p1 = d1.createChangePack()
    let p2 = d2.createChangePack()

    try d2.applyChangePack(ChangePack(key: p1.getDocumentKey(),
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: p1.getChanges(),
                                      versionVector: VersionVector.initial))
    try d1.applyChangePack(ChangePack(key: p2.getDocumentKey(),
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: p2.getChanges(),
                                      versionVector: VersionVector.initial))

    func ack(_ pack: ChangePack) -> ChangePack {
        let changes = pack.getChanges()
        let lastSeq = changes.last?.id.getClientSeq() ?? 0
        return ChangePack(key: pack.getDocumentKey(),
                          checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                          isRemoved: false,
                          changes: [],
                          versionVector: VersionVector.initial)
    }
    try d1.applyChangePack(ack(p1))
    try d2.applyChangePack(ack(p2))
}

/// Dumps every node of the text under key "t", live and tombstoned, with its
/// attributes. Two replicas are compared on this rather than on rendered
/// content because the whole disagreement is invisible in the rendering
/// until something revives the tombstone.
@MainActor
private func nodeAttrs(_ doc: Document) throws -> [String] {
    guard let text = doc.getRootObject().get(key: "t") as? CRDTText else {
        XCTFail("text not initialized")
        return []
    }

    var out = [String]()
    for node in text.rgaTreeSplit where node !== text.rgaTreeSplit.head {
        var attrs = [String]()
        for attr in node.value.getAttrs() {
            attrs.append("\(attr.key)=\(attr.value)\(attr.isRemoved ? "*" : "")")
        }
        attrs.sort()

        let removedSuffix = node.isRemoved ? " (removed)" : ""
        out.append("\"\(node.value.toString)\"\(removedSuffix) [\(attrs.joined(separator: ","))]")
    }
    return out
}

/// Mirrors a root from the given document's content, the way every client
/// joining an existing document holds one.
@MainActor
private func rebuiltRoot(_ doc: Document) throws -> CRDTRoot {
    guard let rebuiltObject = doc.getRootObject().deepcopy() as? CRDTObject else {
        XCTFail("deepcopy did not produce a CRDTObject")
        return CRDTRoot()
    }
    return CRDTRoot(rootObject: rebuiltObject)
}

/// Pins both halves of `docSize` against a rebuild of the same content, then
/// collects and pins that nothing is left over. `live` and `gc` are running
/// accumulators that cannot detect their own drift; a rebuild recomputes them
/// from the content, and collection is what turns a gc charge that no longer
/// matches its node into a visible residue.
@MainActor
private func assertLedgerExact(
    _ doc: Document,
    _ msg: String,
    actors: [ActorID] = [actorA1, actorA2]
) throws {
    let rebuilt = try rebuiltRoot(doc)
    XCTAssertEqual(doc.getDocSize().live, rebuilt.getDocSize().live, "\(msg): live")
    XCTAssertEqual(doc.getDocSize().gc, rebuilt.getDocSize().gc, "\(msg): gc")

    _ = doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: actors))
    XCTAssertEqual(doc.getGarbageLength(), 0, "\(msg): garbage left behind")
    XCTAssertEqual(doc.getDocSize().gc, DataSize(data: 0, meta: 0), "\(msg): collection left gc residue")
}

/// Builds a document whose Text field (key "t") is seeded with "abcdefghij".
@MainActor
private func seededTextDoc() -> Document {
    let doc = Document(key: "test-doc")
    return doc
}

/// Renders a sequential change batch for the delivery-order scenario: drains
/// a replica's pending local changes and self-acks them so they are not
/// re-sent by a later call.
@MainActor
private func grabChanges(_ doc: Document) throws -> [Change] {
    let pack = doc.createChangePack()
    let changes = pack.getChanges()
    let lastSeq = changes.last?.id.getClientSeq() ?? 0
    try doc.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                       checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                       isRemoved: false,
                                       changes: [],
                                       versionVector: VersionVector.initial))
    return changes
}

/// Delivers a recorded change batch to a replica with a neutral checkpoint,
/// so the receiver's own pending local changes are kept and GC stays out of
/// the delivery.
@MainActor
private func feedChanges(_ doc: Document, _ changes: [Change]) throws {
    try doc.applyChangePack(ChangePack(key: "test-doc",
                                       checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                       isRemoved: false,
                                       changes: changes,
                                       versionVector: VersionVector.initial))
}

/// Returns a document with the given actor id already set, so replicas built
/// from it are genuinely distinct peers.
@MainActor
private func replicaWithActor(_ actorID: ActorID) -> Document {
    let doc = Document(key: "test-doc")
    doc.setActor(actorID)
    return doc
}

final class StyleTombstoneTests: XCTestCase {
    /// The six operations from the issue, single actor, no sync. Step 4
    /// styles a range that spans the node step 3 deleted, and it lands there
    /// -- so step 5's undo strips it, and step 6 brings "ef" back WITHOUT the
    /// attribute step 2 gave it.
    ///
    /// This is the cost of `canStyle` not reading `removedAt`, and it is
    /// deliberate. Skipping a removal the change already knew about reads
    /// better here, but it makes the predicate depend on a field a later
    /// concurrent removal overwrites, and then two clients deleting the same
    /// run leave replicas disagreeing for good.
    @MainActor
    func test_lands_on_a_node_the_same_actor_already_deleted() throws {
        // given
        let doc = seededTextDoc()
        try doc.update { root, _ in
            root.t = JSONText()
            _ = (root.t as? JSONText)?.edit(0, 0, "abcdefghij")
        }

        // when
        try doc.update { root, _ in _ = (root.t as? JSONText)?.setStyle(4, 6, ["b": "OLDOLDOLDOLDOLD"]) }
        try doc.update { root, _ in _ = (root.t as? JSONText)?.edit(4, 6, "") }
        try doc.update { root, _ in _ = (root.t as? JSONText)?.setStyle(0, 8, ["b": "NEW"]) }

        // then
        let text = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTText)
        XCTAssertEqual(
            text.toJSON(),
            "[{\"attrs\":{\"b\":\"NEW\"},\"val\":\"abcd\"},{\"attrs\":{\"b\":\"NEW\"},\"val\":\"ghij\"}]"
        )
        XCTAssertEqual(
            try nodeAttrs(doc),
            ["\"abcd\" [b=NEW]", "\"ef\" (removed) [b=NEW]", "\"ghij\" [b=NEW]"],
            "the dead node took the style too; RHT.set drops the value it held"
        )

        try doc.undo()
        let textAfterFirstUndo = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTText)
        XCTAssertEqual(textAfterFirstUndo.toJSON(), "[{\"val\":\"abcd\"},{\"val\":\"ghij\"}]")

        try doc.undo()
        let textAfterSecondUndo = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTText)
        XCTAssertEqual(
            textAfterSecondUndo.toJSON(),
            "[{\"val\":\"abcd\"},{\"val\":\"ef\"},{\"val\":\"ghij\"}]",
            "the restored run lost the attribute it carried: the cost of the contract"
        )

        // The local path now reaches a tombstone, so it also books through
        // the gc half of `accAttrWrite` -- a branch no local history could
        // reach before.
        let actor = try XCTUnwrap(doc.actorID)
        try assertLedgerExact(doc, "after the local style reached a tombstone", actors: [actor])
    }

    /// A style concurrent with a removal, on both ticket orderings. The only
    /// difference between the two cases is which actor's ticket sorts
    /// higher, which must not decide whether the replicas agree.
    @MainActor
    func test_lands_on_the_tombstone_everywhere_style_on_d1() throws {
        try self.assertLandsOnTheTombstoneEverywhere(styleOnD1: true)
    }

    @MainActor
    func test_lands_on_the_tombstone_everywhere_style_on_d2() throws {
        try self.assertLandsOnTheTombstoneEverywhere(styleOnD1: false)
    }

    @MainActor
    private func assertLandsOnTheTombstoneEverywhere(styleOnD1: Bool) throws {
        // given
        let d1 = replicaWithActor(actorA1)
        let d2 = replicaWithActor(actorA2)

        try d1.update { root, _ in
            root.t = JSONText()
            _ = (root.t as? JSONText)?.edit(0, 0, "abcdefghij")
        }
        try crossSync(d1, d2)

        // when
        let styler = styleOnD1 ? d1 : d2
        let deleter = styleOnD1 ? d2 : d1
        try styler.update { root, _ in _ = (root.t as? JSONText)?.setStyle(4, 6, ["b": "1"]) }
        try deleter.update { root, _ in _ = (root.t as? JSONText)?.edit(4, 6, "") }
        try crossSync(d1, d2)

        // then
        XCTAssertEqual(try nodeAttrs(d1), ["\"abcd\" []", "\"ef\" (removed) [b=\"1\"]", "\"ghij\" []"])
        XCTAssertEqual(
            try nodeAttrs(d1),
            try nodeAttrs(d2),
            "the replicas disagree on the tombstoned node's attributes"
        )

        // The style grew a node whose gc charge was taken when it was
        // removed. Without moving those bytes through gc, the replica that
        // received the style reports a different size for the same document
        // than the one that issued it, and collection then subtracts more
        // than registration added.
        try assertLedgerExact(d1, "on d1")
        try assertLedgerExact(d2, "on d2")
    }

    /// The same, but the tombstoned node already holds the key being written
    /// and the incoming value is much shorter. The write has to debit the
    /// superseded value as well as credit the installed one, and both halves
    /// have to land in gc: booking either to live walks it down by the
    /// signed difference between the two sizes, which is how this first went
    /// negative.
    @MainActor
    func test_shrinks_an_attribute_on_a_tombstone_without_touching_live() throws {
        // given
        let d1 = replicaWithActor(actorA1)
        let d2 = replicaWithActor(actorA2)

        try d1.update { root, _ in
            root.t = JSONText()
            _ = (root.t as? JSONText)?.edit(0, 0, "abcdefghij")
        }
        try d1.update { root, _ in _ = (root.t as? JSONText)?.setStyle(4, 6, ["b": String(repeating: "L", count: 20)]) }
        try crossSync(d1, d2)

        // when
        try d2.update { root, _ in _ = (root.t as? JSONText)?.setStyle(0, 8, ["b": "x"]) }
        try d1.update { root, _ in _ = (root.t as? JSONText)?.edit(4, 6, "") }
        try crossSync(d1, d2)

        // then: the style's range ends inside "ghij", which the boundary
        // split cuts. "x" is stored unquoted where "1" is not: a string that
        // itself parses as JSON keeps its quotes, because raw storage could
        // not tell it apart from the value it encodes.
        XCTAssertEqual(try nodeAttrs(d1), [
            "\"abcd\" [b=x]",
            "\"ef\" (removed) [b=x]",
            "\"gh\" [b=x]",
            "\"ij\" []"
        ])
        XCTAssertEqual(try nodeAttrs(d1), try nodeAttrs(d2))
        XCTAssertGreaterThanOrEqual(d1.getDocSize().live.data, 0, "live went negative")
        try assertLedgerExact(d1, "on the replica that deleted the node")
        try assertLedgerExact(d2, "on the replica that issued the style")
    }

    /// A tombstoned node can also have an attribute REVIVED on it: a remote
    /// removeStyle tombstones the key, a later remote style sets it again.
    /// The pair the first one registered carried zero -- the attribute's
    /// bytes were still inside the node's charge at that point -- but the
    /// revive replaces it with a live node, so the node's charge no longer
    /// covers it and the map entry has to give back its own size on the way
    /// out.
    ///
    /// A text removeStyle only reaches a tombstone as the reverse of a
    /// style, so the sequence is: style, undo, style again, all concurrent
    /// with the removal.
    @MainActor
    func test_gives_an_attribute_back_its_own_size_when_a_revive_unregisters_it() throws {
        // given
        let d1 = replicaWithActor(actorA1)
        let d2 = replicaWithActor(actorA2)

        try d1.update { root, _ in
            root.t = JSONText()
            _ = (root.t as? JSONText)?.edit(0, 0, "abcdefghij")
        }
        try d1.update { root, _ in _ = (root.t as? JSONText)?.setStyle(4, 6, ["b": String(repeating: "L", count: 12)]) }
        try crossSync(d1, d2)

        // when
        try d1.update { root, _ in _ = (root.t as? JSONText)?.edit(4, 6, "") }
        try d2.update { root, _ in _ = (root.t as? JSONText)?.setStyle(0, 8, ["b": "x"]) }
        try d2.undo()
        try d2.update { root, _ in _ = (root.t as? JSONText)?.setStyle(0, 8, ["b": "yy"]) }
        try crossSync(d1, d2)

        // then
        XCTAssertEqual(try nodeAttrs(d1), try nodeAttrs(d2))
        try assertLedgerExact(d1, "on the replica that deleted the node")
        try assertLedgerExact(d2, "on the replica that issued the styles")
    }

    /// The tree's `removeStyle` half of the same question. A remote
    /// `removeStyle` whose range was decided before a concurrent split
    /// follows `insNextID` to the split siblings, one of which is a
    /// tombstone by the time it arrives. A live attribute on a tombstoned
    /// node is not in `live` -- `CRDTTree.getDataSize` excludes the node --
    /// so booking it out of `live` walks `live` down by the attribute's
    /// size, without bound and into the negative.
    @MainActor
    func test_keeps_the_ledger_exact_for_a_remote_removeStyle_on_a_removed_tree_node() throws {
        // given
        let d1 = replicaWithActor(actorA1)
        let d2 = replicaWithActor(actorA2)

        try d1.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcdefgh")])
            ]))
        }
        try d1.update { root, _ in try (root.t as? JSONTree)?.style(0, 10, ["b": String(repeating: "LONG", count: 4)]) }
        try crossSync(d1, d2)

        // d2 removes the style over a range decided before d1 splits.
        try d2.update { root, _ in try (root.t as? JSONTree)?.removeStyle(0, 10, ["b"]) }

        // d1 splits the paragraph and removes the right half.
        try d1.update { root, _ in _ = try (root.t as? JSONTree)?.edit(5, 5, nil, 1) }
        try d1.update { root, _ in _ = try (root.t as? JSONTree)?.edit(6, 11, nil, 0) }

        try crossSync(d1, d2)

        // then
        XCTAssertGreaterThanOrEqual(d1.getDocSize().live.data, 0, "live went negative")
        try assertLedgerExact(d1, "on the replica that removed the node")
        try assertLedgerExact(d2, "on the replica that issued the removeStyle")
    }

    /// The tree half of the same contract. Reaching it needs a remote style,
    /// because an index range cannot address a removed node locally: a style
    /// whose range was decided before a concurrent split follows
    /// `insNextID` to the split siblings, and one of those is removed by the
    /// time it arrives.
    @MainActor
    func test_keeps_the_ledger_exact_for_a_remote_style_on_a_removed_tree_node() throws {
        // given
        let d1 = replicaWithActor(actorA1)
        let d2 = replicaWithActor(actorA2)

        try d1.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcdefgh")])
            ]))
        }
        try crossSync(d1, d2)

        // d2 styles a range decided before d1 splits.
        try d2.update { root, _ in try (root.t as? JSONTree)?.style(0, 10, ["b": String(repeating: "LONG", count: 4)]) }

        // d1 splits the paragraph and removes the right half.
        try d1.update { root, _ in _ = try (root.t as? JSONTree)?.edit(5, 5, nil, 1) }
        try d1.update { root, _ in _ = try (root.t as? JSONTree)?.edit(6, 11, nil, 0) }

        try crossSync(d1, d2)

        // then
        let tree1 = try XCTUnwrap(d1.getRootObject().get(key: "t") as? CRDTTree)
        let tree2 = try XCTUnwrap(d2.getRootObject().get(key: "t") as? CRDTTree)
        XCTAssertEqual(tree1.toXML(), tree2.toXML())
        try assertLedgerExact(d1, "on the replica that removed the node")
        try assertLedgerExact(d2, "on the replica that issued the style")
    }

    /// Toggling a tree attribute on and off has to return the ledger to
    /// where it started, on the CLONE as well as on the root --
    /// `Document.update` reads the clone's total against `maxSizeLimit`.
    /// This SDK is spared the server's gap here because `registerGCPair`
    /// does the live subtraction itself rather than leaving it to a separate
    /// step; pinned so the two stay that way.
    @MainActor
    func test_does_not_drift_the_clone_ledger_when_a_tree_attribute_is_toggled() throws {
        // given
        let doc = Document(key: "test-doc")
        doc.setMaxSizePerDocument(2000)
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")])
            ]))
        }

        // when / then
        let val = String(repeating: "v", count: 200)
        for index in 0 ..< 40 {
            try doc.update { root, _ in try (root.t as? JSONTree)?.style(0, 6, ["b": val]) }
            XCTAssertNoThrow(
                try doc.update { root, _ in try (root.t as? JSONTree)?.removeStyle(0, 6, ["b"]) },
                "toggle \(index) tripped maxSizeLimit; the document itself is \(doc.getDocSize())"
            )
        }
    }

    /// Two clients delete the same run concurrently; a third, which has seen
    /// only one of the two deletions, styles a range covering it. This is
    /// the case that forces `canStyle` not to read `removedAt`.
    ///
    /// `removedAt` is last-writer-wins and MUTABLE, while a style is
    /// evaluated once, when it arrives -- so any predicate over it answers
    /// differently depending on which of the two removals has landed. S
    /// causally depends on B (X applied B before styling), so an order
    /// delivering S first is not legal and is not replayed; the three below
    /// are, and they have to agree.
    @MainActor
    func test_agrees_across_delivery_orders_when_two_removals_are_concurrent() throws {
        // given
        let seed = replicaWithActor("000000000000000000000009")
        try seed.update { root, _ in
            root.t = JSONText()
            _ = (root.t as? JSONText)?.edit(0, 0, "abcdefghij")
        }
        let p0 = try grabChanges(seed)

        let docB = replicaWithActor(actorA1)
        let docC = replicaWithActor(actorA2)
        let docX = replicaWithActor("000000000000000000000003")
        for doc in [docB, docC, docX] {
            try feedChanges(doc, p0)
        }

        try docB.update { root, _ in _ = (root.t as? JSONText)?.edit(4, 6, "") }
        let pB = try grabChanges(docB)
        try docC.update { root, _ in _ = (root.t as? JSONText)?.edit(4, 6, "") }
        let pC = try grabChanges(docC)

        // X knows B's removal but not C's.
        try feedChanges(docX, pB)
        try docX.update { root, _ in _ = (root.t as? JSONText)?.setStyle(0, 8, ["b": "1"]) }
        let pS = try grabChanges(docX)

        let orders: [(name: String, batches: [[Change]])] = [
            ("C,B,S", [pC, pB, pS]),
            ("B,S,C", [pB, pS, pC]),
            ("B,C,S", [pB, pC, pS])
        ]

        // when / then
        var first: [String]?
        for order in orders {
            let observer = replicaWithActor("00000000000000000000000a")
            try feedChanges(observer, p0)
            for batch in order.batches {
                try feedChanges(observer, batch)
            }

            let got = try nodeAttrs(observer)
            guard let existingFirst = first else {
                first = got
                continue
            }
            XCTAssertEqual(got, existingFirst, "delivery order \(order.name) diverges")
        }
    }

    /// Undoing a style whose range covers only a node another client removed
    /// concurrently. The reverse style mutates the tombstone, but a
    /// tombstone has no index, so it produces no `OpInfo` -- and
    /// `Document.executeUndoRedo`'s undo path used to gate propagation on
    /// `opInfos.isEmpty`. The change was applied here and never sent,
    /// leaving the replicas with different attributes on the same node for
    /// good: the exact divergence `canStyle` was changed to prevent, coming
    /// back through undo.
    @MainActor
    func test_sends_an_undo_whose_style_lands_only_on_a_tombstone() throws {
        // given
        let d1 = replicaWithActor(actorA1)
        let d2 = replicaWithActor(actorA2)

        try d1.update { root, _ in
            root.t = JSONText()
            _ = (root.t as? JSONText)?.edit(0, 0, "abcdefghij")
        }
        try crossSync(d1, d2)

        try d1.update { root, _ in _ = (root.t as? JSONText)?.setStyle(4, 6, ["b": "1"]) }
        try d2.update { root, _ in _ = (root.t as? JSONText)?.edit(4, 6, "") }
        try crossSync(d1, d2)
        XCTAssertEqual(try nodeAttrs(d1), try nodeAttrs(d2), "sanity: converged first")

        // when
        try d1.undo()
        XCTAssertGreaterThanOrEqual(
            d1.createChangePack().getChanges().count, 1,
            "the undo mutated the tombstone, so it has to reach the other replica"
        )
        try crossSync(d1, d2)

        // then
        XCTAssertEqual(
            try nodeAttrs(d1),
            try nodeAttrs(d2),
            "the replicas disagree after an undo that showed nothing"
        )
    }

    /// A style range that opens on a tombstone: the reverse operation's
    /// prior values must come from the first LIVE node, not from the dead
    /// run the user had already deleted. Capturing from the tombstone made
    /// the undo write `b="OLD"` onto `"efgh"`, which never carried the
    /// attribute at any point.
    @MainActor
    func test_does_not_restore_a_tombstones_attribute_on_undo() throws {
        // given
        let doc = seededTextDoc()
        try doc.update { root, _ in
            root.t = JSONText()
            _ = (root.t as? JSONText)?.edit(0, 0, "abcdefghij")
        }
        try doc.update { root, _ in _ = (root.t as? JSONText)?.setStyle(0, 4, ["b": "OLD"]) }
        try doc.update { root, _ in _ = (root.t as? JSONText)?.edit(0, 4, "") }
        let textAfterDelete = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTText)
        XCTAssertEqual(textAfterDelete.toJSON(), "[{\"val\":\"efghij\"}]")

        // when
        try doc.update { root, _ in _ = (root.t as? JSONText)?.setStyle(0, 4, ["b": "NEW"]) }
        try doc.undo()

        // then
        let textAfterUndo = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTText)
        XCTAssertEqual(
            textAfterUndo.toJSON(),
            "[{\"val\":\"efgh\"},{\"val\":\"ij\"}]",
            "the undo restored an attribute the visible text never carried"
        )
    }
}
