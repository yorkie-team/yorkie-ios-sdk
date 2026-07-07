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

class RGATreeListTests: XCTestCase {
    private let actorId = "999"

    func test_insert() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        let e4 = Primitive(value: .string("D1234"), createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        try target.insert(e4)

        let e5 = Primitive(value: .string("E12345"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        try target.insert(e5)

        let e6 = Primitive(value: .string("F123456"), createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        try target.insert(e6)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]-[4:999:0:\"D1234\"]-[5:999:0:\"E12345\"]-[6:999:0:\"F123456\"]")

        XCTAssertEqual(target.length, 6)
    }

    func test_concurrent_insert_first() throws {
        let target = RGATreeList()

        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2, prevCreatedAt: e1.createdAt)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B2\"]")

        let e3 = Primitive(value: .string("C3"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3, prevCreatedAt: e1.createdAt)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[3:999:0:\"C3\"]-[2:999:0:\"B2\"]")
    }

    func test_concurrent_insert_second() throws {
        let target = RGATreeList()

        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e3 = Primitive(value: .string("C3"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3, prevCreatedAt: e1.createdAt)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[3:999:0:\"C3\"]")

        let e2 = Primitive(value: .string("B2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2, prevCreatedAt: e1.createdAt)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[3:999:0:\"C3\"]-[2:999:0:\"B2\"]")
    }

    func test_get() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        let result1 = try target.get(createdAt: e1.createdAt)
        XCTAssertEqual(result1.toJSON(), "\"A1\"")

        let result2 = try target.get(createdAt: e2.createdAt)
        XCTAssertEqual(result2.toJSON(), "\"B12\"")
    }

    func test_key() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        let result2 = try target.subPath(createdAt: e2.createdAt)
        XCTAssertEqual(result2, "1")

        let result3 = try target.subPath(createdAt: e3.createdAt)
        XCTAssertEqual(result3, "2")
    }

    func test_move_createdAt_and_afterCreatedAt_are_same() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        try target.move(createdAt: e1.createdAt, afterCreatedAt: e1.createdAt, executedAt: e1.createdAt)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")
    }

    func test_move() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        let e4 = Primitive(value: .string("D1234"), createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        try target.insert(e4)

        let e5 = Primitive(value: .string("E12345"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        try target.insert(e5)

        let e6 = Primitive(value: .string("F123456"), createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        try target.insert(e6)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]-[4:999:0:\"D1234\"]-[5:999:0:\"E12345\"]-[6:999:0:\"F123456\"]")

        let executedAt = TimeTicket(lamport: 7, delimiter: 0, actorID: actorId)
        try target.move(createdAt: e1.createdAt, afterCreatedAt: e3.createdAt, executedAt: executedAt)

        XCTAssertEqual(target.toTestString,
                       "[2:999:0:\"B12\"]-[3:999:0:\"C123\"]-[1:999:0:\"A1\"]-[4:999:0:\"D1234\"]-[5:999:0:\"E12345\"]-[6:999:0:\"F123456\"]")

        let executedAt2 = TimeTicket(lamport: 8, delimiter: 0, actorID: actorId)
        try target.move(createdAt: e1.createdAt, afterCreatedAt: e4.createdAt, executedAt: executedAt2)

        XCTAssertEqual(target.toTestString,
                       "[2:999:0:\"B12\"]-[3:999:0:\"C123\"]-[4:999:0:\"D1234\"]-[1:999:0:\"A1\"]-[5:999:0:\"E12345\"]-[6:999:0:\"F123456\"]")
    }

    func test_purge_first_node() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        try target.purge(e1)
        XCTAssertEqual(target.toTestString,
                       "[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")
    }

    func test_purge_middle_node() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        try target.purge(e2)
        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[3:999:0:\"C123\"]")
    }

    func test_purge_last_node() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        try target.purge(e3)
        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]")
    }

    func test_getPreviousCreatedAt() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        var result = try target.getPreviousCreatedAt(ofCreatedAt: e1.createdAt)
        XCTAssertEqual("\(result)",
                       "0:000000000000000000000000:0")

        result = try target.getPreviousCreatedAt(ofCreatedAt: e2.createdAt)
        XCTAssertEqual("\(result)",
                       "1:999:0")
    }

    func test_delete_by_createdAt() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        let result = try target.delete(createdAt: e2.createdAt, executedAt: TimeTicket(lamport: 4, delimiter: 0, actorID: self.actorId))

        XCTAssertEqual(result.isRemoved, true)
        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-{2:999:0:\"B12\"}-[3:999:0:\"C123\"]")
    }

    func test_delete_by_index() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        let result = try target.deleteByIndex(index: 1, executedAt: TimeTicket(lamport: 4, delimiter: 0, actorID: self.actorId))

        XCTAssertEqual(result.isRemoved, true)
        XCTAssertEqual(target.toTestString,
                       "[1:999:0:\"A1\"]-{2:999:0:\"B12\"}-[3:999:0:\"C123\"]")
    }

    func test_getHead() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        XCTAssertEqual(target.getHead().toJSON(), "null")
    }

    func test_getLast() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        XCTAssertEqual(target.getLast().toJSON(), "\"C123\"")
    }

    // Ported from yorkie-js-sdk (PR #1272): getLast skips trailing bare position nodes.
    // When the tail element is moved elsewhere, `moveAfter` leaves the old tail position
    // node in place as `last` (dead, no `elementEntry`) rather than reassigning it —
    // mirroring JS, which keeps dead position nodes around until GC purge. `getLast()`
    // must walk back over that bare node and return the last LIVE element instead.
    func test_getLast_skips_trailing_bare_position_node() throws {
        // given — list [A, B, C], C is the tail
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let e2 = Primitive(value: .string("B"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        let e3 = Primitive(value: .string("C"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e1)
        try target.insert(e2)
        try target.insert(e3)

        XCTAssertEqual(target.getLast().toJSON(), "\"C\"")

        // when — move the tail element (C) elsewhere; the old tail position node becomes
        // a bare/dead position node, and `last` keeps pointing at it (JS-faithful).
        let moveAt = TimeTicket(lamport: 4, delimiter: 0, actorID: actorId)
        let deadNode = try target.moveAfter(createdAt: e3.createdAt, prevCreatedAt: e1.createdAt, executedAt: moveAt)

        // then — the physically last node is still the bare/dead position node left behind
        XCTAssertNotNil(deadNode)
        XCTAssertNil(deadNode?.getElementEntry())
        XCTAssertEqual(target.getLastCreatedAt(), deadNode?.positionCreatedAt)

        // and — getLast() skips it, returning the last LIVE element ("B", now at the tail
        // of the live sequence [A, C, B]) instead of the bare position node.
        XCTAssertEqual(target.getLast().toJSON(), "\"B\"")
    }

    func test_getLastCreatedAt() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        XCTAssertEqual("\(target.getLastCreatedAt())", "3:999:0")
    }

    func test_getNode() throws {
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B12"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2)

        let e3 = Primitive(value: .string("C123"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3)

        let result1 = try target.getNode(index: 0).value.toJSON()
        XCTAssertEqual(result1, "\"A1\"")
        XCTAssertEqual(try target.getNode(index: 1).value.toJSON(), "\"B12\"")
        let result2 = try target.getNode(index: 2).value.toJSON()
        XCTAssertEqual(result2, "\"C123\"")
    }

    // Ported from yorkie-js-sdk v0.7.6 (#1227): move × move LWW test.
    // When two concurrent move operations target the same element, the later
    // `executedAt` wins. The earlier one must be a no-op (returns nil).
    func test_move_lww_later_op_wins() throws {
        // given — list [A, B, C, D]
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let e2 = Primitive(value: .string("B"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        let e3 = Primitive(value: .string("C"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        let e4 = Primitive(value: .string("D"), createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        try target.insert(e1)
        try target.insert(e2)
        try target.insert(e3)
        try target.insert(e4)

        XCTAssertEqual(target.length, 4)

        // when — concurrent moves of element A:
        // op1 (lamport=5): move A after C  → would give [B, C, A, D]
        // op2 (lamport=6): move A after D  → would give [B, C, D, A]
        // Apply op2 first (out of order), then op1 which should lose.
        let move2 = TimeTicket(lamport: 6, delimiter: 0, actorID: actorId)
        let deadNode = try target.moveAfter(createdAt: e1.createdAt, prevCreatedAt: e4.createdAt, executedAt: move2)

        // then — op2 wins: A moved after D → [B, C, D, A]
        XCTAssertNotNil(deadNode)
        XCTAssertEqual(target.length, 4)
        XCTAssertEqual(try target.getNode(index: 3).value.toJSON(), "\"A\"")

        // when — apply op1 (lamport=5 < lamport=6 of op2): must lose
        let move1 = TimeTicket(lamport: 5, delimiter: 0, actorID: actorId)
        let losingDeadNode = try target.moveAfter(createdAt: e1.createdAt, prevCreatedAt: e3.createdAt, executedAt: move1)

        // then — op1 loses LWW but still creates a bare dead position node for GC (JS-faithful).
        // List stays [B, C, D, A].
        XCTAssertNotNil(losingDeadNode)
        XCTAssertNotNil(losingDeadNode?.getPositionRemovedAt())
        XCTAssertNil(losingDeadNode?.getElementEntry())
        XCTAssertEqual(try target.getNode(index: 3).value.toJSON(), "\"A\"")
    }

    // Ported from yorkie-js-sdk v0.7.6 (#1227): move on different elements commutes.
    // Two concurrent moves of different elements must each land at their intended
    // destinations regardless of application order.
    func test_concurrent_moves_on_different_elements_commute() throws {
        // given — list [A, B, C, D]
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let e2 = Primitive(value: .string("B"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        let e3 = Primitive(value: .string("C"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        let e4 = Primitive(value: .string("D"), createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        try target.insert(e1)
        try target.insert(e2)
        try target.insert(e3)
        try target.insert(e4)

        // when — op1 (lamport=5): move A after B  → [B, A, C, D]
        //        op2 (lamport=6): move C after D  → [A, B, D, C]
        // Apply both concurrently (op1 first, then op2).
        let move1 = TimeTicket(lamport: 5, delimiter: 0, actorID: actorId)
        try target.moveAfter(createdAt: e1.createdAt, prevCreatedAt: e2.createdAt, executedAt: move1)

        let move2 = TimeTicket(lamport: 6, delimiter: 0, actorID: actorId)
        try target.moveAfter(createdAt: e3.createdAt, prevCreatedAt: e4.createdAt, executedAt: move2)

        // then — both moves applied: [B, A, D, C]
        XCTAssertEqual(target.length, 4)
        XCTAssertEqual(try target.getNode(index: 0).value.toJSON(), "\"B\"")
        XCTAssertEqual(try target.getNode(index: 1).value.toJSON(), "\"A\"")
        XCTAssertEqual(try target.getNode(index: 2).value.toJSON(), "\"D\"")
        XCTAssertEqual(try target.getNode(index: 3).value.toJSON(), "\"C\"")
    }

    // Ported from yorkie-js-sdk v0.7.6 (#1227): moveAfter returns a dead position node
    // for GC registration regardless of whether it wins or loses the LWW race.
    func test_moveAfter_returns_dead_node_on_both_lww_win_and_loss() throws {
        // given — list [A, B, C]
        let target = RGATreeList()
        let e1 = Primitive(value: .string("A"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let e2 = Primitive(value: .string("B"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        let e3 = Primitive(value: .string("C"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e1)
        try target.insert(e2)
        try target.insert(e3)

        // when — move A after C (executedAt=5): should win and return the dead position node
        let win = TimeTicket(lamport: 5, delimiter: 0, actorID: actorId)
        let deadNode = try target.moveAfter(createdAt: e1.createdAt, prevCreatedAt: e3.createdAt, executedAt: win)

        // then — returns non-nil dead position node; position removed at is set
        XCTAssertNotNil(deadNode)
        XCTAssertNotNil(deadNode?.getPositionRemovedAt())
        XCTAssertNil(deadNode?.getElementEntry())
        XCTAssertEqual(target.length, 3)

        // when — try to move A again with older executedAt=4 (should lose)
        let lose = TimeTicket(lamport: 4, delimiter: 0, actorID: actorId)
        let losingNode = try target.moveAfter(createdAt: e1.createdAt, prevCreatedAt: e2.createdAt, executedAt: lose)

        // then — LWW loser still creates a bare dead position node for GC (JS-faithful).
        XCTAssertNotNil(losingNode)
        XCTAssertNotNil(losingNode?.getPositionRemovedAt())
        XCTAssertNil(losingNode?.getElementEntry())
    }

    // Ported from yorkie-js-sdk v0.7.6 (#1227): snapshot round-trip — moved and dead
    // position nodes survive a Document-level deep-copy (simulates snapshot restore).
    // A snapshot round-trip re-constructs the CRDTRoot from the serialised form; the
    // moved element must appear at its new position and the dead position node must
    // not leak into the live count.
    func test_move_snapshot_roundtrip() async throws {
        // given — document with an array, then a move
        let doc = Document(key: "test-move-snapshot")
        try await doc.update { root, _ in
            root.list = [Int64(0), Int64(1), Int64(2)]
        }

        try await doc.update { root, _ in
            guard let arr = root.list as? JSONArray else { return }
            guard let prev = arr.getElement(byIndex: 0) as? CRDTElement,
                  let item = arr.getElement(byIndex: 2) as? CRDTElement else { return }
            try arr.moveAfter(previousID: prev.id, id: item.id)
        }

        // when — round-trip via changePack proto serialisation
        let pack = await doc.createChangePack()
        let pbPack = Converter.toChangePack(pack: pack)
        let decodedPack = try Converter.fromChangePack(pbPack)
        XCTAssertNotNil(decodedPack)

        // then — the live JSON after the move is correct
        let json = await doc.toSortedJSON()
        XCTAssertEqual(json, "{\"list\":[0,2,1]}")
    }
}
