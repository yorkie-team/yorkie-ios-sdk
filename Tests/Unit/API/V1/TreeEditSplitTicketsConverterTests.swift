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

import SwiftProtobuf
import XCTest
@testable import Yorkie

/// Converter round-trip coverage for `Operation.TreeEdit.split_tickets = 11`,
/// added in yorkie-js-sdk v0.7.16 (yorkie-js-sdk#1319 "Stop undo and element
/// splits from reusing a node's identity"). The tickets an element split
/// consumes are now carried on the wire rather than reconstructed on the
/// receiving side, since a reconstruction that advances by the top-level
/// content count cannot account for a ticket each descendant of that content
/// also took.
final class TreeEditSplitTicketsConverterTests: XCTestCase {
    private let parentCreatedAt = TimeTicket(lamport: 1, delimiter: 0, actorID: ActorIDs.initial)
    private let executedAt = TimeTicket(lamport: 4, delimiter: 0, actorID: ActorIDs.initial)
    private lazy var pos = CRDTTreePos(
        parentID: CRDTTreeNodeID(createdAt: self.parentCreatedAt, offset: 0),
        leftSiblingID: CRDTTreeNodeID(createdAt: self.parentCreatedAt, offset: 0)
    )

    /// Serializes the given operation to bytes and decodes it back, mirroring
    /// `converter.operationToBinary` / `converter.bytesToOperation` in JS.
    private func roundTrip(_ operation: Yorkie.Operation) throws -> TreeEditOperation {
        let pbOperation = try Converter.toOperation(operation)
        let bytes = try pbOperation.serializedData()
        let restoredPb = try PbOperation(serializedBytes: bytes)
        let restoredOps = try Converter.fromOperations([restoredPb])
        guard let treeEditOp = restoredOps.first as? TreeEditOperation else {
            throw YorkieError(code: .errUnexpected, message: "expected a TreeEditOperation after round-trip")
        }
        return treeEditOp
    }

    func test_round_trips_the_split_tickets_in_issue_order() throws {
        // given — the tickets a multi-level split would have issued.
        let op = TreeEditOperation(
            parentCreatedAt: self.parentCreatedAt,
            fromPos: self.pos,
            toPos: self.pos,
            contents: nil,
            splitLevel: 2,
            executedAt: self.executedAt
        )
        let issued = [
            TimeTicket(lamport: 4, delimiter: 1, actorID: ActorIDs.initial),
            TimeTicket(lamport: 4, delimiter: 2, actorID: ActorIDs.initial)
        ]
        op.setSplitTickets(issued)

        // when
        let restored = try self.roundTrip(op)

        // then
        XCTAssertEqual(restored.getSplitTickets().map { $0.toTestString }, issued.map { $0.toTestString })
    }

    func test_leaves_ordinary_edits_without_split_tickets() throws {
        // given — a plain edit that never called setSplitTickets.
        let op = TreeEditOperation(
            parentCreatedAt: self.parentCreatedAt,
            fromPos: self.pos,
            toPos: self.pos,
            contents: nil,
            splitLevel: 0,
            executedAt: self.executedAt
        )

        // when
        let restored = try self.roundTrip(op)

        // then
        XCTAssertTrue(restored.getSplitTickets().isEmpty)
    }

    /// A server or peer older than v0.7.16 does not know field 11 and drops
    /// it, so the op arrives with no split tickets at all — the fallback
    /// reconstruction (delimiter simulation in `TreeEditOperation.execute`)
    /// is what keeps such a change replayable, but decoding itself must not
    /// throw or invent tickets.
    func test_decodes_to_no_tickets_for_a_peer_that_predates_the_field() throws {
        // given — a serialized operation with field 11 stripped, as an old
        // peer that never wrote it would send.
        let op = TreeEditOperation(
            parentCreatedAt: self.parentCreatedAt,
            fromPos: self.pos,
            toPos: self.pos,
            contents: nil,
            splitLevel: 1,
            executedAt: self.executedAt
        )
        op.setSplitTickets([TimeTicket(lamport: 4, delimiter: 1, actorID: ActorIDs.initial)])

        var pbOp = try Converter.toOperation(op)
        guard case .treeEdit(var pbTreeEdit) = pbOp.body else {
            return XCTFail("expected a tree edit operation body")
        }
        pbTreeEdit.splitTickets = []
        pbOp.body = Yorkie_V1_Operation.OneOf_Body.treeEdit(pbTreeEdit)

        // when
        let bytes = try pbOp.serializedData()
        let decoded = try Converter.fromOperations([PbOperation(serializedBytes: bytes)])
        let stripped = try XCTUnwrap(decoded.first as? TreeEditOperation)

        // then
        XCTAssertTrue(stripped.getSplitTickets().isEmpty, "an old peer's change carries no split tickets")
    }
}
