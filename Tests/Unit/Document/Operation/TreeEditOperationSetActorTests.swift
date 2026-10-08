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

/// Ported from yorkie-js-sdk v0.7.24: `packages/sdk/test/unit/document/split_ticket_test.ts`
/// "re-stamps the tickets when the actor is set after the edit"
/// (yorkie-js-sdk#1404 "Port three tree convergence fixes from the Go SDK").
///
/// A document edited before `Client.attach` runs under the initial actor, and
/// `Document.setActor` re-stamps every pending local change once the real actor
/// arrives, by calling `Operation.setActor` through an `Operation` existential
/// (`Change.setActor` holds `[Operation]`, not `[TreeEditOperation]`). Before
/// this port, `setActor` existed only as an `Operation` extension method, never
/// as a protocol requirement, so Swift resolved that call via STATIC dispatch
/// to the extension default regardless of the concrete type underneath the
/// existential -- an override on `TreeEditOperation` would silently never run.
/// These tests exercise the fix through that same existential path, not by
/// calling `TreeEditOperation.setActor` directly, since calling it on the
/// concrete type would pass even with the dispatch bug still in place.
final class TreeEditOperationSetActorTests: XCTestCase {
    private let oldActor: ActorID = "000000000000000000000001"
    private let newActor: ActorID = "000000000000000000000009"

    private func makeSplittingOp(level: Int32) -> TreeEditOperation {
        let parentCreatedAt = TimeTicket(lamport: 1, delimiter: 0, actorID: self.oldActor)
        let pos = CRDTTreePos(
            parentID: CRDTTreeNodeID(createdAt: parentCreatedAt, offset: 0),
            leftSiblingID: CRDTTreeNodeID(createdAt: parentCreatedAt, offset: 0)
        )
        let executedAt = TimeTicket(lamport: 4, delimiter: 0, actorID: self.oldActor)
        let op = TreeEditOperation(
            parentCreatedAt: parentCreatedAt,
            fromPos: pos,
            toPos: pos,
            contents: nil,
            splitLevel: level,
            executedAt: executedAt
        )
        return op
    }

    func test_re_stamps_executed_at_and_split_tickets_through_the_operation_existential() {
        // given — a splitting edit with tickets issued under the old actor,
        // referenced through the `Operation` existential the way
        // `Change.setActor` holds its operations array.
        let op = self.makeSplittingOp(level: 2)
        let issued = [
            TimeTicket(lamport: 4, delimiter: 1, actorID: self.oldActor),
            TimeTicket(lamport: 4, delimiter: 2, actorID: self.oldActor)
        ]
        op.setSplitTickets(issued)
        var existential: Yorkie.Operation = op

        // when
        existential.setActor(self.newActor)

        // then — executedAt moves, same as any other operation.
        XCTAssertEqual(existential.executedAt.actorID, self.newActor)

        // and — every split ticket carries the new actor too, with lamport
        // and delimiter untouched so the identities the split mints, and
        // their order, are unchanged.
        let restamped = op.getSplitTickets()
        XCTAssertEqual(restamped.count, issued.count)
        for (before, after) in zip(issued, restamped) {
            XCTAssertEqual(after.actorID, self.newActor)
            XCTAssertEqual(after.lamport, before.lamport)
            XCTAssertEqual(after.delimiter, before.delimiter)
        }
    }

    func test_leaves_an_empty_split_ticket_list_empty() {
        // given — an ordinary, non-splitting edit: no split tickets to
        // re-stamp in the first place.
        let op = self.makeSplittingOp(level: 0)
        var existential: Yorkie.Operation = op

        // when
        existential.setActor(self.newActor)

        // then
        XCTAssertEqual(existential.executedAt.actorID, self.newActor)
        XCTAssertTrue(op.getSplitTickets().isEmpty)
    }
}
