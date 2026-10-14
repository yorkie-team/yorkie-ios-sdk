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

/// Ports `packages/sdk/test/unit/api/reissue_test.ts` from yorkie-js-sdk v0.7.25
/// (yorkie-js-sdk#1449 "Re-issue pre-attach tickets to the client's actor on attach").
@MainActor
final class ReissueTests: XCTestCase {
    private let actorA = "000000000000000000000001"

    /// Returns the operations of every local change of the document.
    private func opsOf(_ doc: Document) -> [Yorkie.Operation] {
        doc.getPendingChangeStructs().flatMap(\.operations)
    }

    /// Returns the tickets of the given operations as they travel.
    private func wireTickets(_ ops: [Yorkie.Operation]) throws -> [WireTicket] {
        try ticketsOf(ops.map { try Converter.toOperation($0) })
    }

    private func para(_ value: String) -> JSONTreeElementNode {
        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: value)])
    }

    func test_re_issues_the_tickets_nested_in_object_array_and_tree_values() throws {
        // given
        let doc = Document(key: "d")
        try doc.update { root, _ in
            root.obj = ["k": "v", "arr": [Int64(1), ["n": Int64(2)]]] as [String: Any]
            root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [self.para("ab")]))
        }
        let ops = self.opsOf(doc)
        let before = try self.wireTickets(ops)
        XCTAssertTrue(before.contains { $0.actor == ActorIDs.initial && $0.lamport > 0 })

        // when
        let after = try self.wireTickets(Reissue.reissueOperations(ops, from: ActorIDs.initial, to: self.actorA))

        // then
        XCTAssertEqual(after.count, before.count)
        for (index, ticket) in after.enumerated() {
            XCTAssertEqual(ticket.lamport, before[index].lamport)
            // The lamport-0 ticket is the root's and every sentinel's identity, shared by all
            // replicas, and keeps the initial actor.
            XCTAssertEqual(ticket.actor, ticket.lamport == 0 ? ActorIDs.initial : self.actorA, "ticket \(index)")
        }
    }

    func test_does_not_mutate_the_given_operations() throws {
        // given
        let doc = Document(key: "d")
        try doc.update { root, _ in
            root.obj = ["k": "v"]
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "hello")
        }
        let ops = self.opsOf(doc)
        let before = try ops.map { try Converter.toOperation($0).serializedData() }

        // when
        _ = try Reissue.reissueOperations(ops, from: ActorIDs.initial, to: self.actorA)

        // then
        XCTAssertEqual(try ops.map { try Converter.toOperation($0).serializedData() }, before)
    }

    func test_keeps_the_content_of_a_text_value() throws {
        // given -- the wire drops a Text value's content; a Set restoring a removed Text carries it
        // in the value itself.
        let doc = Document(key: "d")
        try doc.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "hello")
        }
        try doc.update { root, _ in root.remove(key: "t") }
        try doc.undo()
        let restore = try XCTUnwrap(self.opsOf(doc).last as? SetOperation)
        XCTAssertEqual((restore.value as? CRDTText)?.toString, "hello")

        // when
        let reissued = try Reissue.reissueOperations([restore], from: ActorIDs.initial, to: self.actorA)

        // then
        let set = try XCTUnwrap(reissued.first as? SetOperation)
        let text = try XCTUnwrap(set.value as? CRDTText)
        XCTAssertEqual(text.toString, "hello")
        XCTAssertEqual(text.createdAt.actorID, self.actorA)
        XCTAssertFalse(text.toTestString.contains(ActorIDs.initial))
    }

    func test_keeps_the_content_of_an_object_value_restored_by_undo() throws {
        // given -- an Object value travels with its whole content (`toElementSimple` encodes it),
        // so the re-issue has nested bytes to walk and the restored children survive.
        let doc = Document(key: "d")
        try doc.update { root, _ in root.obj = ["k": "v", "arr": [Int64(1), Int64(2)]] as [String: Any] }
        try doc.update { root, _ in root.remove(key: "obj") }
        try doc.undo()
        let restore = try XCTUnwrap(self.opsOf(doc).last as? SetOperation)
        XCTAssertTrue(try self.wireTickets([restore]).contains { $0.actor == ActorIDs.initial && $0.lamport > 0 })

        // when
        let reissued = try Reissue.reissueOperations([restore], from: ActorIDs.initial, to: self.actorA)

        // then
        let set = try XCTUnwrap(reissued.first as? SetOperation)
        XCTAssertEqual((set.value as? CRDTObject)?.toSortedJSON(), (restore.value as? CRDTObject)?.toSortedJSON())
        let actors = try countActors(self.wireTickets(reissued))
        XCTAssertNil(actors[ActorIDs.initial])
        XCTAssertNotNil(actors[self.actorA])
    }

    func test_leaves_an_attribute_named_like_the_actor_alone() throws {
        // given
        let doc = Document(key: "d")
        try doc.update { root, _ in
            root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [self.para("ab")]))
        }
        try doc.update { root, _ in
            try (root.tree as? JSONTree)?.style(0, 1, [ActorIDs.initial: "v"])
        }
        let style = try XCTUnwrap(self.opsOf(doc).last as? TreeStyleOperation)

        // when
        let reissued = try Reissue.reissueOperations([style], from: ActorIDs.initial, to: self.actorA)

        // then
        let attributes = try XCTUnwrap(reissued.first as? TreeStyleOperation).attributes
        XCTAssertEqual(attributes, [ActorIDs.initial: "v"])
    }

    func test_does_not_set_the_presence_of_an_optional_ticket_that_was_absent() throws {
        // given -- a generated message field is a computed property, and passing it inout sets its
        // presence, so the walk has to guard each one. An absent `removedAt` must stay absent.
        let doc = Document(key: "d")
        try doc.update { root, _ in root.t = JSONText() }
        let operation = try XCTUnwrap(self.opsOf(doc).first)
        let pb = try Converter.toOperation(operation)
        guard case .set(let set)? = pb.body else {
            return XCTFail("expected a Set")
        }
        XCTAssertFalse(set.value.hasRemovedAt)
        XCTAssertFalse(set.value.hasMovedAt)

        // when
        var walked = pb
        TicketReissuer(from: ActorIDs.initial, to: self.actorA).walk(&walked)

        // then
        guard case .set(let walkedSet)? = walked.body else { return XCTFail("expected a Set") }
        XCTAssertFalse(walkedSet.value.hasRemovedAt)
        XCTAssertFalse(walkedSet.value.hasMovedAt)
        XCTAssertTrue(walkedSet.value.hasCreatedAt)
    }
}
