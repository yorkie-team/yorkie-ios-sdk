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
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

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
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a2)

        let result = target.get(key: "a1")

        XCTAssertEqual(result!.toJSON(), "\"A2\"")
        XCTAssertEqual(result!.isRemoved, false)
    }

    func test_remove_by_createdAt() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

        let executedAt = TimeTicket(lamport: 3, delimiter: 0, actorID: actorId)
        let removed = try target.delete(createdAt: a2.createdAt, executedAt: executedAt)

        XCTAssertEqual(removed.toJSON(), "\"A2\"")
        XCTAssertEqual(target.get(key: "a2")!.isRemoved, true)
        XCTAssertEqual(target.get(key: "a1")!.isRemoved, false)
    }

    func test_remove_by_key() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

        let executedAt = TimeTicket(lamport: 3, delimiter: 0, actorID: actorId)
        let removed = try target.deleteByKey(key: "a2", executedAt: executedAt)

        XCTAssertEqual(removed.toJSON(), "\"A2\"")
        XCTAssertEqual(target.get(key: "a2")!.isRemoved, true)
        XCTAssertEqual(target.get(key: "a1")!.isRemoved, false)
    }

    func test_subPath() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

        let subPath = try target.subPath(createdAt: a2.createdAt)
        XCTAssertEqual(subPath, "a2")
    }

    func test_delete() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

        try target.purge(element: a2)

        let result = target.get(key: "a2")
        XCTAssertNil(result)
    }

    func test_has() throws {
        let target = ElementRHT()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

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
        rht.set(key: "color", value: valueA)

        let ticketB = TimeTicket(lamport: 1, delimiter: 0, actorID: "actorB")
        let valueB = Primitive(value: .string("blue"), createdAt: ticketB)

        // when — Client B's operation arrives with an earlier timestamp; it loses the LWW conflict.
        rht.set(key: "color", value: valueB)

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
        rht.set(key: "key", value: value1)

        // Late-arriving "key"="second" at T1 — loses to T3.
        let ticket2 = TimeTicket(lamport: 1, delimiter: 0, actorID: "actor2")
        let value2 = Primitive(value: .string("second"), createdAt: ticket2)
        rht.set(key: "key", value: value2)

        // Late-arriving "key"="third" at T2 — loses to T3, beats T1, but still loses overall.
        let ticket3 = TimeTicket(lamport: 2, delimiter: 0, actorID: "actor3")
        let value3 = Primitive(value: .string("third"), createdAt: ticket3)

        // when — all late-arriving operations have been applied.
        rht.set(key: "key", value: value3)

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
}
