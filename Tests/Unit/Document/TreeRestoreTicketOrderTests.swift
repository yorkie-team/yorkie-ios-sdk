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

/// Ported from yorkie-js-sdk PR #1364 (commit 248551a1, yorkie-team/yorkie#2008):
/// `packages/sdk/test/unit/document/tree_restore_ticket_test.ts`, itself a port
/// of the Go test `TestTreeRestoreAgreesOnTheTombstoneTicketAcrossDeliveryOrders`.
///
/// `CRDTTree.recreateFromSpan` used to resolve a restored node's parent by
/// IDENTITY and never by LIVENESS: a parent tombstoned since the node was purged
/// still accepted it, so the node was recreated LIVE under a tombstone and
/// registered in `nodeMapByID`. The next collection unlinked the parent and left
/// the node live, registered, and reachable from nothing -- "registered implies
/// reachable" was broken. It is now recreated ALREADY TOMBSTONED, stamped with
/// the PARENT's `removedAt`.
///
/// This exists so the SDKs make the SAME decision on the same history: a
/// content comparison (`toXML`) reports agreement in every delivery order under
/// every candidate, which is exactly why this went unnoticed. The assertions
/// read the restored node's `removedAt` TICKET instead, off `nodeMapByID` rather
/// than a tree walk, because the orphan is a childless leaf no traversal can
/// name.
private let docKey = "tree-restore-ticket"

// The actors. Numbered to match the Go/JS harnesses so a failure can be read
// against them line for line: A authors and undoes, B removes <p> at the LOW
// ticket, C removes <p> concurrently at the HIGHER one, and the six
// permutation observers take 10..15.
private let actorAuthorA = 1
private let actorRemoverB = 2
private let actorRemoverC = 5
private let actorObserverBase = 10

private typealias Changes = [Change]

/// `actorOf` renders an actor number as a 24-hex-digit actor id.
private func actorOf(_ actorNumber: Int) -> ActorID {
    "0000000000000000000000" + String(format: "%02d", actorNumber)
}

/// `newReplica` returns a document with a distinct actor id, so the replicas
/// here are genuinely distinct peers and the changes they produce are
/// genuinely concurrent.
@MainActor
private func newReplica(_ actorNumber: Int) -> Document {
    let doc = Document(key: docKey)
    doc.setActor(actorOf(actorNumber))
    return doc
}

/// `recordChanges` drains a replica's pending local changes so they can be
/// REPLAYED into several observers in different orders. Includes the
/// emptiness check the JS/Go harnesses use: a step that silently produced
/// nothing would make every delivery order trivially agree and the test would
/// pass while measuring nothing.
///
/// The self-ack drops exactly the drained changes from the sender's queue, so
/// a later `recordChanges` on the same replica does not re-send them.
@MainActor
private func recordChanges(_ from: Document, _ what: String) throws -> Changes {
    let pack = from.createChangePack()
    let changes = pack.getChanges()
    XCTAssertFalse(changes.isEmpty, "\(what) produced no change to deliver")

    let lastSeq = changes.last?.id.getClientSeq() ?? 0
    try from.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                        checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                        isRemoved: false,
                                        changes: [],
                                        versionVector: VersionVector.initial))
    return changes
}

/// `deliverInOrder` delivers recorded changes to a replica. The neutral
/// checkpoint (clientSeq 0) keeps the receiver's own pending local changes,
/// and `VersionVector.initial` keeps garbage collection out of the delivery --
/// collection is driven explicitly by each scenario so it controls when a
/// tombstone becomes a purge.
@MainActor
private func deliverInOrder(_ to: Document, _ changes: Changes) throws {
    try to.applyChangePack(ChangePack(key: docKey,
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: changes,
                                      versionVector: VersionVector.initial))
}

/// `treeOf` reaches the CRDT tree under key "t" of a replica's real root.
@MainActor
private func treeOf(_ doc: Document) throws -> CRDTTree {
    try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTTree)
}

/// `nodeByID` answers the question `nodeMapByID` answers, which is NOT the
/// question a traversal answers: the orphan this file pins down is a childless
/// leaf hanging off a detached subtree, which a tree walk never finds.
/// `findFloorNode` only matches on `createdAt`, so the offset has to be
/// checked here.
@MainActor
private func nodeByID(_ doc: Document, _ id: CRDTTreeNodeID) throws -> CRDTTreeNode? {
    guard let node = try treeOf(doc).findFloorNode(id), node.id == id else {
        return nil
    }
    return node
}

/// `tombstoneOf` renders a node's liveness as the TICKET it carries, not as a
/// boolean. Two replicas can both report "removed" while holding different
/// `removedAt`, and `canDelete` compares the ticket, so the difference decides
/// which replica purges the node on which pass.
@MainActor
private func tombstoneOf(_ doc: Document, _ id: CRDTTreeNodeID) throws -> String {
    guard let node = try nodeByID(doc, id) else {
        return "absent"
    }
    guard let removedAt = node.removedAt else {
        return "live"
    }
    return removedAt.toTestString
}

/// `census` returns every node a replica holds that is reachable right now.
@MainActor
private func census(_ doc: Document) throws -> [CRDTTreeNode] {
    var nodes: [CRDTTreeNode] = []
    try treeOf(doc).indexTree.traverseAll { node, _ in nodes.append(node) }
    return nodes
}

/// `reachableCount` counts the nodes actually hanging off the root, tombstones
/// included. Compared against `nodeSize` (the `nodeMapByID` population), a
/// mismatch means a registered node has no path to the root -- the invariant
/// the #2008 crash came from.
@MainActor
private func reachableCount(_ doc: Document) throws -> Int {
    try census(doc).count
}

/// `assertNoOrphans` pins the property every position lookup depends on: every
/// node registered in `nodeMapByID` is reachable from the root.
///
/// Two independent signals, because either can fire alone: the counts catch
/// any mismatch, including an orphan invisible to every traversal, and the
/// `before` census -- taken while the nodes were still reachable -- names the
/// culprits.
@MainActor
private func assertNoOrphans(_ doc: Document, before: [CRDTTreeNode], label: String) throws {
    let tree = try treeOf(doc)
    let registeredCount = tree.nodeSize
    let reachableNodeCount = try reachableCount(doc)
    XCTAssertEqual(registeredCount, reachableNodeCount,
                   "\(label): nodeMapByID holds \(registeredCount) nodes but only \(reachableNodeCount) are reachable from the root (xml=\(tree.toXML()))")

    let root = tree.root
    for node in before {
        guard let held = try nodeByID(doc, node.id), held === node else {
            continue // purged, or the map answers this id with someone else.
        }

        var current: CRDTTreeNode? = held
        var foundRoot = false
        while let walking = current {
            if walking === root {
                foundRoot = true
                break
            }
            current = walking.parent
        }
        XCTAssertTrue(foundRoot,
                      "\(label): \(node.id.toTestString) (removed=\(node.removedAt != nil)) is still " +
                          "registered but no longer reachable from the root")
    }
}

/// Thrown when a fixture step produces no operation to read a ticket from, so
/// a broken assumption fails loudly instead of silently measuring nothing.
private struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

/// `firstTicket` reads the executedAt of the first operation in a recorded
/// change slice, so the fixture can ASSERT the causal facts it depends on
/// instead of assuming them.
private func firstTicket(_ changes: Changes, _ what: String) throws -> TimeTicket {
    for change in changes {
        if let operation = change.operations.first {
            return operation.executedAt
        }
    }
    throw FixtureError(description: "\(what) carried no operation to read a ticket from")
}

/// `buildTree` writes `<r><p>abcd</p></r>` under key "t".
@MainActor
private func buildTree(_ doc: Document) throws {
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")])
        ]))
    }
}

/// One logical history with THREE concurrent changes, recorded so every
/// delivery order replays identical changes:
///
///   removeLow  -- B removes <p>
///   removeHigh -- C removes <p>, concurrently, with a HIGHER ticket
///   restore    -- A undoes its own earlier removal of "bc", concurrently
///
/// All three are produced from the same collected setup state and none of the
/// three authors has seen either of the others, so a replica may legitimately
/// receive them in any of the six orders and a CRDT owes the same result for
/// all six.
private struct TicketFixture {
    let setup: Changes
    let removeLow: Changes
    let removeHigh: Changes
    let restore: Changes
    let lowAt: TimeTicket
    let highAt: TimeTicket
    /// The restored text node, named BEFORE the purge erased it.
    let textID: CRDTTreeNodeID
    /// The <p> above it, whose tombstone the restore reads.
    let parentID: CRDTTreeNodeID
    /// The never-purged siblings "a" and "d". They are the sharpest witness in
    /// the whole test: the removal that swept <p> wrote its ticket onto them,
    /// so the restored node -- which was purged out from between them and then
    /// brought back -- has to rejoin them carrying the SAME ticket.
    let siblingIDs: [CRDTTreeNodeID]
    let actors: [ActorID]
}

@MainActor
private func newTicketFixture() throws -> TicketFixture {
    let authorReplica = newReplica(actorAuthorA)
    let removerBReplica = newReplica(actorRemoverB)
    let removerCReplica = newReplica(actorRemoverC)

    // Every actor that will ever hold this document has to be in the vector,
    // observers included: a collection pass only purges what the whole cluster
    // is past, so a missing actor would silently turn every collect() here
    // into a no-op and the fixture would never reach the purged state the
    // recreate path needs.
    var actors = [actorAuthorA, actorRemoverB, actorRemoverC].map(actorOf)
    for observerOffset in 0 ..< 6 {
        actors.append(actorOf(actorObserverBase + observerOffset))
    }

    try buildTree(authorReplica)
    try authorReplica.update({ root, _ in _ = try (root.t as? JSONTree)?.edit(2, 4) }, "remove bc")
    XCTAssertEqual(try treeOf(authorReplica).toXML(), "<r><p>ad</p></r>")

    var textID: CRDTTreeNodeID?
    var parentID: CRDTTreeNodeID?
    var siblingIDs: [CRDTTreeNodeID] = []
    for node in try census(authorReplica) {
        let value = node.isText ? (node.value as String) : ""
        if node.isText, value == "bc" {
            textID = node.id
        } else if node.isText, value == "a" || value == "d" {
            siblingIDs.append(node.id)
        } else if node.type == "p" {
            parentID = node.id
        }
    }
    let resolvedTextID = try XCTUnwrap(textID, "the tombstoned \"bc\" should be nameable pre-purge")
    let resolvedParentID = try XCTUnwrap(parentID, "the enclosing <p> should be nameable")
    XCTAssertEqual(siblingIDs.count, 2, "both never-purged siblings are named")

    let setupChanges = try recordChanges(authorReplica, "the setup edits")

    // B and C both need the setup collected, so "bc" is PURGED on them too.
    // Otherwise their removal would merely tombstone it and A's restore would
    // take the un-tombstone path instead of the recreate path under test.
    try deliverInOrder(removerBReplica, setupChanges)
    try deliverInOrder(removerCReplica, setupChanges)
    for replica in [authorReplica, removerBReplica, removerCReplica] {
        _ = replica.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: actors))
    }
    XCTAssertEqual(try treeOf(removerBReplica).toXML(), "<r><p>ad</p></r>")
    XCTAssertEqual(try treeOf(removerCReplica).toXML(), "<r><p>ad</p></r>")
    let purgedTextNode = try nodeByID(authorReplica, resolvedTextID)
    XCTAssertNil(purgedTextNode,
                 "the removed text must be PURGED, not merely tombstoned -- otherwise the undo takes the " +
                     "un-tombstone path and never reaches recreateFromSpan")

    // Neither remover has seen the other, so the two removals are concurrent
    // and LWW decides which tombstone survives on every replica.
    try removerBReplica.update({ root, _ in _ = try (root.t as? JSONTree)?.edit(0, 4) }, "remove p")
    let removeLowChanges = try recordChanges(removerBReplica, "b's removal of <p>")
    try removerCReplica.update({ root, _ in _ = try (root.t as? JSONTree)?.edit(0, 4) }, "remove p")
    let removeHighChanges = try recordChanges(removerCReplica, "c's concurrent removal of <p>")

    try authorReplica.undo()
    let restoreChanges = try recordChanges(authorReplica, "a's undo of its own text removal")

    let lowAt = try firstTicket(removeLowChanges, "b's removal")
    let highAt = try firstTicket(removeHighChanges, "c's removal")

    return TicketFixture(setup: setupChanges,
                         removeLow: removeLowChanges,
                         removeHigh: removeHighChanges,
                         restore: restoreChanges,
                         lowAt: lowAt,
                         highAt: highAt,
                         textID: resolvedTextID,
                         parentID: resolvedParentID,
                         siblingIDs: siblingIDs,
                         actors: actors)
}

/// `observer` returns a replica holding the collected setup, ready to receive
/// the three concurrent changes in a chosen order.
@MainActor
private func observer(_ fixture: TicketFixture, _ actorNumber: Int) throws -> Document {
    let doc = newReplica(actorNumber)
    try deliverInOrder(doc, fixture.setup)
    _ = doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: fixture.actors))
    XCTAssertEqual(try treeOf(doc).toXML(), "<r><p>ad</p></r>")
    return doc
}

/// The six delivery orders of the three concurrent changes, as indices into
/// the step list. Written out rather than generated: six lines that can be
/// read against the scenario beat a permutation generator whose output has to
/// be trusted.
private let ticketOrders: [[Int]] = [
    [0, 1, 2],
    [0, 2, 1],
    [1, 0, 2],
    [1, 2, 0],
    [2, 0, 1],
    [2, 1, 0]
]

/// One replica's outcome after replaying the fixture's three changes in one
/// delivery order.
private struct Outcome {
    let label: String
    let doc: Document
    let before: [CRDTTreeNode]
    let restored: String
    let parent: String
    let siblings: [String]
    let xml: String
}

final class TreeRestoreTicketOrderTests: XCTestCase {
    private struct Step {
        let name: String
        let changes: Changes
    }

    /// Mirrors the Go test `TestTreeRestoreAgreesOnTheTombstoneTicketAcrossDeliveryOrders`
    /// and the JS test of the same scenario: the restored node carries the
    /// winning removal's ticket in every one of the six delivery orders, equal
    /// to the parent's and to its never-purged siblings', with
    /// registered == reachable and a stable docSize before and after
    /// collection.
    @MainActor
    func test_stamps_the_restored_node_with_the_winning_removal_ticket_in_all_six_orders() throws {
        // given — one history, recorded once, replayed into six observers.
        let fixture = try newTicketFixture()

        // The premise of the whole scenario. If the tickets came out the other
        // way round, the "later removal overwrites the parent's tombstone"
        // step never happens and the test would quietly measure nothing.
        XCTAssertTrue(fixture.highAt.after(fixture.lowAt),
                      "the fixture needs c's removal to win the LWW race: " +
                          "low=\(fixture.lowAt.toTestString) high=\(fixture.highAt.toTestString)")

        let steps = [
            Step(name: "removeLow", changes: fixture.removeLow),
            Step(name: "removeHigh", changes: fixture.removeHigh),
            Step(name: "restore", changes: fixture.restore)
        ]

        // when — replay the three concurrent changes in all six delivery orders.
        let outcomes = try self.buildOutcomes(fixture: fixture, steps: steps)

        // then — every order agrees with the winning removal, with the parent,
        // and with the never-purged siblings, and every order agrees with
        // every other order.
        try self.assertPerOrderInvariants(outcomes, fixture: fixture)
        self.assertOrdersAgreeWithEachOther(outcomes)

        // Collection is where a divergent removedAt turns into a divergent
        // document -- canDelete compares the ticket -- and where a node
        // recreated live under a tombstone becomes unreachable-but-registered.
        for outcome in outcomes {
            _ = outcome.doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: fixture.actors))
        }
        try self.assertAfterCollection(outcomes, fixture: fixture)
    }

    @MainActor
    private func buildOutcomes(fixture: TicketFixture, steps: [Step]) throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for (orderIndex, order) in ticketOrders.enumerated() {
            let label = order.map { steps[$0].name }.joined(separator: "->")
            let doc = try observer(fixture, actorObserverBase + orderIndex)
            for stepIndex in order {
                try deliverInOrder(doc, steps[stepIndex].changes)
            }

            try outcomes.append(Outcome(label: label,
                                        doc: doc,
                                        before: census(doc),
                                        restored: tombstoneOf(doc, fixture.textID),
                                        parent: tombstoneOf(doc, fixture.parentID),
                                        siblings: fixture.siblingIDs.map { try tombstoneOf(doc, $0) },
                                        xml: treeOf(doc).toXML()))
        }
        return outcomes
    }

    private func assertPerOrderInvariants(_ outcomes: [Outcome], fixture: TicketFixture) throws {
        let winningTicket = fixture.highAt.toTestString

        for outcome in outcomes {
            // The parent first. Its tombstone is pure LWW with no restore
            // involved, so a divergence here would mean the FIXTURE is what
            // broke, and the next assertion's result could not be trusted.
            XCTAssertEqual(outcome.parent, winningTicket,
                           "[\(outcome.label)] the parent <p> should settle on the winning removal ticket by plain LWW")

            // The question this file exists to answer.
            XCTAssertEqual(outcome.restored, winningTicket,
                           "[\(outcome.label)] the restored node's tombstone ticket should be the winning " +
                               "removal's (low=\(fixture.lowAt.toTestString))")

            // The sharpest finding: "a" and "d" were never purged, so the
            // removal that swept <p> wrote its ticket straight onto them. The
            // restored node has to carry what it would have carried had it
            // never been purged, which is exactly that ticket.
            for (siblingIndex, siblingTombstone) in outcome.siblings.enumerated() {
                XCTAssertEqual(outcome.restored, siblingTombstone,
                               "[\(outcome.label)] the restored node should agree with its never-purged " +
                                   "sibling \(fixture.siblingIDs[siblingIndex].toTestString)")
            }
        }
    }

    private func assertOrdersAgreeWithEachOther(_ outcomes: [Outcome]) {
        guard let reference = outcomes.first else {
            XCTFail("no outcomes produced")
            return
        }

        // Every order has to land on the same answer, stated directly rather
        // than inferred from the per-order equalities above, so a candidate
        // that is uniformly wrong is still reported as non-divergent.
        for outcome in outcomes.dropFirst() {
            XCTAssertEqual(outcome.restored, reference.restored,
                           "the restored node's ticket diverged between delivery orders " +
                               "([\(reference.label)] vs [\(outcome.label)])")
            XCTAssertEqual(outcome.xml, reference.xml,
                           "content diverged between delivery orders ([\(reference.label)] vs [\(outcome.label)])")
        }
    }

    @MainActor
    private func assertAfterCollection(_ outcomes: [Outcome], fixture: TicketFixture) throws {
        guard let reference = outcomes.first else {
            XCTFail("no outcomes produced")
            return
        }

        for outcome in outcomes {
            try assertNoOrphans(outcome.doc, before: outcome.before, label: "[\(outcome.label)] after collection")
            XCTAssertEqual(outcome.doc.getGarbageLength(), 0,
                           "[\(outcome.label)] everything is causally stable, so collection must drain")
            XCTAssertEqual(outcome.doc.getDocSize().gc, DataSize(data: 0, meta: 0),
                           "[\(outcome.label)] GC accounting must telescope to zero after collection")
        }

        for outcome in outcomes.dropFirst() {
            XCTAssertEqual(try tombstoneOf(outcome.doc, fixture.textID), try tombstoneOf(reference.doc, fixture.textID),
                           "[\(outcome.label)] the restored node's fate diverged after collection")
            XCTAssertEqual(outcome.doc.getDocSize(), reference.doc.getDocSize(),
                           "[\(outcome.label)] docSize diverged from [\(reference.label)] after collection")
        }
    }
}
