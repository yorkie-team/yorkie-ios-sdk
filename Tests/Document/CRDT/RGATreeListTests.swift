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

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]-[4:999:0:\"D1234\"]-[5:999:0:\"E12345\"]-[6:999:0:\"F123456\"]")

        XCTAssertEqual(target.length, 6)
    }

    func test_concurrent_insert_first() throws {
        let target = RGATreeList()

        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e2 = Primitive(value: .string("B2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2, afterCreatedAt: e1.createdAt)

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B2\"]")

        let e3 = Primitive(value: .string("C3"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3, afterCreatedAt: e1.createdAt)

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[3:999:0:\"C3\"]-[2:999:0:\"B2\"]")
    }

    func test_concurrent_insert_second() throws {
        let target = RGATreeList()

        let e1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(e1)

        let e3 = Primitive(value: .string("C3"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(e3, afterCreatedAt: e1.createdAt)

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[3:999:0:\"C3\"]")

        let e2 = Primitive(value: .string("B2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(e2, afterCreatedAt: e1.createdAt)

        XCTAssertEqual(target.structureAsString,
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

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        try target.move(createdAt: e1.createdAt, afterCreatedAt: e1.createdAt, executedAt: e1.createdAt)

        XCTAssertEqual(target.structureAsString,
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

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]-[4:999:0:\"D1234\"]-[5:999:0:\"E12345\"]-[6:999:0:\"F123456\"]")

        let executedAt = TimeTicket(lamport: 7, delimiter: 0, actorID: actorId)
        try target.move(createdAt: e1.createdAt, afterCreatedAt: e3.createdAt, executedAt: executedAt)

        XCTAssertEqual(target.structureAsString,
                       "[2:999:0:\"B12\"]-[3:999:0:\"C123\"]-[1:999:0:\"A1\"]-[4:999:0:\"D1234\"]-[5:999:0:\"E12345\"]-[6:999:0:\"F123456\"]")

        let executedAt2 = TimeTicket(lamport: 8, delimiter: 0, actorID: actorId)
        try target.move(createdAt: e1.createdAt, afterCreatedAt: e4.createdAt, executedAt: executedAt2)

        XCTAssertEqual(target.structureAsString,
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

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        try target.delete(e1)
        XCTAssertEqual(target.structureAsString,
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

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        try target.delete(e2)
        XCTAssertEqual(target.structureAsString,
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

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        try target.delete(e3)
        XCTAssertEqual(target.structureAsString,
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

        XCTAssertEqual("\(try target.getPreviousCreatedAt(ofCreatedAt: e1.createdAt))",
                       "0:000000000000000000000000:0")

        XCTAssertEqual("\(try target.getPreviousCreatedAt(ofCreatedAt: e2.createdAt))",
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

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        let result = try target.remove(createdAt: e2.createdAt, executedAt: TimeTicket(lamport: 4, delimiter: 0, actorID: self.actorId))

        XCTAssertEqual(result.isRemoved, true)
        XCTAssertEqual(target.structureAsString,
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

        XCTAssertEqual(target.structureAsString,
                       "[1:999:0:\"A1\"]-[2:999:0:\"B12\"]-[3:999:0:\"C123\"]")

        let result = try target.remove(index: 1, executedAt: TimeTicket(lamport: 4, delimiter: 0, actorID: self.actorId))

        XCTAssertEqual(result.isRemoved, true)
        XCTAssertEqual(target.structureAsString,
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
}
