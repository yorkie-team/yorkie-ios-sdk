/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

class ElementRHTTests: XCTestCase {
    private let actorId = "actor-1"
    func test_set_value_by_key_is_new() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1, executedAt: a1.createdAt)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2, executedAt: a2.createdAt)

        let elementA1 = target.get(key: "a1")!
        let elementA2 = target.get(key: "a2")!

        XCTAssertEqual(elementA1.toJSON(), "\"A1\"")
        XCTAssertEqual(elementA1.isRemoved, false)
        XCTAssertEqual(elementA2.toJSON(), "\"A2\"")
        XCTAssertEqual(elementA2.isRemoved, false)
    }

    func test_set_value_by_key_is_used_alreay() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1, executedAt: a1.createdAt)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a2, executedAt: a2.createdAt)

        let result = target.get(key: "a1")

        XCTAssertEqual(result!.toJSON(), "\"A2\"")
        XCTAssertEqual(result!.isRemoved, false)
    }

    func test_remove_by_createdAt() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1, executedAt: a1.createdAt)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2, executedAt: a2.createdAt)

        let executedAt = TimeTicket(lamport: 3, delimiter: 0, actorID: actorId)
        let removed = try target.delete(createdAt: a2.createdAt, executedAt: executedAt)

        XCTAssertEqual(removed.toJSON(), "\"A2\"")
        XCTAssertEqual(target.get(key: "a2")!.isRemoved, true)
        XCTAssertEqual(target.get(key: "a1")!.isRemoved, false)
    }

    func test_remove_by_key() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1, executedAt: a1.createdAt)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2, executedAt: a2.createdAt)

        let executedAt = TimeTicket(lamport: 3, delimiter: 0, actorID: actorId)
        let removed = try target.deleteByKey(key: "a2", executedAt: executedAt)

        XCTAssertEqual(removed.toJSON(), "\"A2\"")
        XCTAssertEqual(target.get(key: "a2")!.isRemoved, true)
        XCTAssertEqual(target.get(key: "a1")!.isRemoved, false)
    }

    func test_subPath() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1, executedAt: a1.createdAt)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2, executedAt: a2.createdAt)

        let subPath = try target.subPath(createdAt: a2.createdAt)
        XCTAssertEqual(subPath, "a2")
    }

    func test_delete() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1, executedAt: a1.createdAt)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2, executedAt: a2.createdAt)

        try target.purge(element: a2)

        let result = target.get(key: "a2")
        XCTAssertNil(result)
    }

    func test_has() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1, executedAt: a1.createdAt)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2, executedAt: a2.createdAt)

        try target.purge(element: a2)

        XCTAssertTrue(target.has(key: "a1"))
        XCTAssertFalse(target.has(key: "a2"))
    }

    // MARK: - Concurrent set / LWW conflict tests (ported from element_rht_test.ts, yorkie-js-sdk 0.7.2)

    func test_should_not_produce_duplicate_keys_on_concurrent_set_with_earlier_timestamp() throws {
        // given — two clients concurrently set the same key.
        // Client A sets "color"="red" at T2 (lamport=2, actorA) — this arrives first and wins.
        // Client B sets "color"="blue" at T1 (lamport=1, actorB) — this arrives later and loses.
        let rht = ElementRHT()

        let ticketA = TimeTicket(lamport: 2, delimiter: 0, actorID: "actorA")
        let valueA = Primitive(value: .string("red"), createdAt: ticketA)
        rht.set(key: "color", value: valueA, executedAt: valueA.createdAt)

        let ticketB = TimeTicket(lamport: 1, delimiter: 0, actorID: "actorB")
        let valueB = Primitive(value: .string("blue"), createdAt: ticketB)

        // when — Client B's operation arrives with an earlier timestamp; it loses the LWW conflict.
        rht.set(key: "color", value: valueB, executedAt: valueB.createdAt)

        // then — the losing value must be marked removed so it does not appear as a live entry.
        XCTAssertTrue(valueB.isRemoved, "the losing value must be marked removed by the fix")

        // The object must expose exactly one "color" key and the winner's value.
        let obj = CRDTObject(createdAt: TimeTicket.initial, memberNodes: rht)
        let keys = obj.keys
        XCTAssertEqual(keys.count, 1, "keys must not contain a duplicate")
        XCTAssertEqual(keys, ["color"], "keys must contain only the single winning key")

        // toJSON() iterates nodeMapByCreatedAt; without the fix the loser (earlier createdAt,
        // sorted first) would surface here instead of the winner.
        XCTAssertEqual(obj.toJSON(), "{\"color\":\"red\"}", "toJSON() must reflect the winner's value")

        // get() via nodeMapByKey always returns the winner.
        let winner = obj.get(key: "color") as? Primitive
        XCTAssertNotNil(winner)
        XCTAssertEqual(winner?.toJSON(), "\"red\"", "get(key:) must return the winner's value")
    }

    func test_should_handle_multiple_concurrent_sets_on_the_same_key() throws {
        // given — three concurrent set operations targeting the same key, applied out of
        // timestamp order to simulate late-arriving remote operations.
        let rht = ElementRHT()

        // Set "key"="first" at T3 (highest lamport) — this is the ultimate winner.
        let ticket1 = TimeTicket(lamport: 3, delimiter: 0, actorID: "actor1")
        let value1 = Primitive(value: .string("first"), createdAt: ticket1)
        rht.set(key: "key", value: value1, executedAt: value1.createdAt)

        // Late-arriving "key"="second" at T1 — loses to T3.
        let ticket2 = TimeTicket(lamport: 1, delimiter: 0, actorID: "actor2")
        let value2 = Primitive(value: .string("second"), createdAt: ticket2)
        rht.set(key: "key", value: value2, executedAt: value2.createdAt)

        // Late-arriving "key"="third" at T2 — loses to T3, beats T1, but still loses overall.
        let ticket3 = TimeTicket(lamport: 2, delimiter: 0, actorID: "actor3")
        let value3 = Primitive(value: .string("third"), createdAt: ticket3)

        // when — all late-arriving operations have been applied.
        rht.set(key: "key", value: value3, executedAt: value3.createdAt)

        // then — both losing values must be marked removed.
        XCTAssertTrue(value2.isRemoved, "value at T1 must be marked removed")
        XCTAssertTrue(value3.isRemoved, "value at T2 must be marked removed")

        // Exactly one live key must remain.
        let obj = CRDTObject(createdAt: TimeTicket.initial, memberNodes: rht)
        let keys = obj.keys
        XCTAssertEqual(keys.count, 1, "keys must have exactly one entry")
        XCTAssertEqual(keys, ["key"], "keys must contain only the single winning key")

        // toJSON() must surface the winner (T3 = "first"), not a loser.
        XCTAssertEqual(obj.toJSON(), "{\"key\":\"first\"}", "toJSON() must reflect the winning value")

        // get() must also resolve to the winner.
        let winner = obj.get(key: "key") as? Primitive
        XCTAssertNotNil(winner)
        XCTAssertEqual(winner?.toJSON(), "\"first\"", "get(key:) must return the winner's value")
    }

    // MARK: - Losing tombstone removedAt (ported from element_rht_order_test.ts, yorkie-js-sdk#1395)

    /// The two members one key carries after Set → Set → undo: a live member restored by
    /// undo (`createdAt` T1, `movedAt` T5) and a tombstone (`createdAt` T3, `removedAt` T4)
    /// that sorts between them, so it loses the LWW conflict against the live occupant.
    private func losingTombstoneMembers() -> (live: Primitive, tomb: Primitive, removedAt: TimeTicket) {
        let actorA = "actorA"
        let actorB = "actorB"
        let t1 = TimeTicket(lamport: 1, delimiter: 0, actorID: actorA)
        let t3 = TimeTicket(lamport: 3, delimiter: 0, actorID: actorB)
        let t4 = TimeTicket(lamport: 4, delimiter: 0, actorID: actorB)
        let t5 = TimeTicket(lamport: 5, delimiter: 0, actorID: actorA)

        let live = Primitive(value: .string("kept"), createdAt: t1)
        live.setMovedAt(t5)
        let tomb = Primitive(value: .string("displaced"), createdAt: t3)
        tomb.remove(t4)
        return (live, tomb, t4)
    }

    /// The losing branch used to mark the incoming value removed unconditionally, so it does
    /// not appear as a duplicate in `ownKeys` iteration. A value that arrives already removed
    /// is already skipped there -- the marking has nothing to do -- but `CRDTElement.remove`
    /// accepts any later ticket, so ungated it is not a no-op: it moves the tombstone's
    /// `removedAt` off the ticket of the removal that actually happened and onto the
    /// occupant's `positionedAt`. `converter`'s snapshot decode replays every member through
    /// this same `set`, so this is the shape it hits on every load (yorkie-js-sdk#1377).
    func test_leaves_a_losing_tombstone_removedAt_alone() throws {
        for order in [[0, 1], [1, 0]] {
            let target = ElementRHT()
            let (live, tomb, expectedRemovedAt) = self.losingTombstoneMembers()
            let elems: [CRDTElement] = [live, tomb]

            for idx in order {
                target.set(key: "frame", value: elems[idx], executedAt: elems[idx].getPositionedAt())
            }

            XCTAssertTrue(tomb.isRemoved, "order \(order): tombstone revived")
            XCTAssertEqual(tomb.removedAt, expectedRemovedAt,
                           "order \(order): removedAt moved from its own removal ticket to the occupant's positionedAt")
        }
    }

    /// A snapshot round-trip must be a fixpoint on the tombstones it carries. `Converter.fromObject`
    /// replays every decoded member through `ElementRHT.set`, and a tombstone that sorts after the
    /// live occupant takes the losing branch -- which used to bump its `removedAt` to the
    /// occupant's `positionedAt`. The document then measured differently depending on whether it
    /// had been through a snapshot load (yorkie-js-sdk#1377).
    func test_preserves_each_tombstone_removedAt_across_a_decode() throws {
        // createdAt(live) < createdAt(tomb) < removedAt(tomb) < movedAt(live): the tombstone
        // loses to the undo-restored occupant, and its own removal is strictly older than the
        // ticket that restored the occupant. An undo whose reverse `Set` both removes and
        // restores under one ticket leaves `removedAt == movedAt`, where the bump is invisible.
        // Actor IDs must be the wire's 24-hex form: anything else decodes back as the initial
        // actor and the comparison passes on a technicality.
        let actorA = "000000000000000000000001"
        let actorB = "000000000000000000000002"
        let live = Primitive(value: .string("kept"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorA))
        let tomb = Primitive(value: .string("displaced"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorB))
        tomb.remove(TimeTicket(lamport: 4, delimiter: 0, actorID: actorB))
        live.setMovedAt(TimeTicket(lamport: 5, delimiter: 0, actorID: actorA))
        let rht = ElementRHT()
        rht.set(key: "frame", value: live, executedAt: live.getPositionedAt())
        rht.set(key: "frame", value: tomb, executedAt: tomb.getPositionedAt())
        let root = CRDTObject(createdAt: TimeTicket.initial, memberNodes: rht)

        func removedAts(_ obj: CRDTObject) -> [String: TimeTicket?] {
            var out: [String: TimeTicket?] = [:]
            for node in obj.rht {
                out[node.value.createdAt.toIDString] = node.value.removedAt
            }
            return out
        }

        let want = removedAts(root)
        XCTAssertTrue(want.values.contains { $0 != nil }, "the key must carry a tombstone for this to test anything")

        let pbObject = Converter.toObject(root)
        let bytes = try pbObject.serializedData()
        let decoded = try Converter.fromObject(PbJSONElement(serializedBytes: bytes).jsonObject)

        XCTAssertEqual(removedAts(decoded), want)
    }

    // MARK: - Losing value against a tombstoned occupant (ported from element_rht_test.ts, yorkie-js-sdk#1398)

    /// Before the fix, the losing branch also required the occupant to be live
    /// (`node!.isRemoved == false`). Once the occupant itself was a tombstone, neither branch of
    /// `set` ran for a losing incoming value: it stayed live in `nodeMapByCreatedAt`, never
    /// installed under the key and never collected, so iteration and `get(key:)` disagreed and
    /// replicas diverged permanently (yorkie-js-sdk#1376).
    func test_removes_a_losing_value_when_the_occupant_is_a_tombstone() throws {
        // given — a winner is set under "key" and then removed, leaving the occupant a tombstone.
        let rht = ElementRHT()

        let winnerTicket = TimeTicket(lamport: 6, delimiter: 0, actorID: "actorA")
        let winner = Primitive(value: .string("v2"), createdAt: winnerTicket)
        rht.set(key: "key", value: winner, executedAt: winnerTicket)

        let removedAt = TimeTicket(lamport: 7, delimiter: 0, actorID: "actorA")
        try rht.delete(createdAt: winnerTicket, executedAt: removedAt)
        XCTAssertTrue(winner.isRemoved)

        // when — a live value that sorts before the tombstoned occupant loses the LWW conflict.
        let loserTicket = TimeTicket(lamport: 5, delimiter: 0, actorID: "actorB")
        let loser = Primitive(value: .string("v3"), createdAt: loserTicket)
        rht.set(key: "key", value: loser, executedAt: loserTicket)

        // then — the loser must be marked removed even though the occupant was already a tombstone.
        XCTAssertTrue(loser.isRemoved, "the losing value should be removed")
        XCTAssertFalse(rht.has(key: "key"))

        let obj = CRDTObject(createdAt: TimeTicket.initial, memberNodes: rht)
        XCTAssertEqual(obj.keys, [])
        XCTAssertEqual(obj.toSortedJSON(), "{}")
    }
}
