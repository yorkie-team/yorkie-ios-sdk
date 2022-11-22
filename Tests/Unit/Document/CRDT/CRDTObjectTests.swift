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

class CRDTObjectTests: XCTestCase {
    private let actorId = "actor-1"
    func test_can_set_and_get() throws {
        let target = CRDTObject(createdAt: TimeTicket.initial)

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "K1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "K2", value: a2)

        let a3 = Primitive(value: .string("A3"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        target.set(key: "K3", value: a3)

        let resultK1 = try target.get(key: "K1")
        XCTAssertEqual(resultK1.toJSON(), "\"A1\"")

        let resultK2 = try target.get(key: "K2")
        XCTAssertEqual(resultK2.toJSON(), "\"A2\"")

        let resultK3 = try target.get(key: "K3")
        XCTAssertEqual(resultK3.toJSON(), "\"A3\"")
    }

    func test_can_get_subPath() throws {
        let target = CRDTObject(createdAt: TimeTicket.initial)

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "K1", value: a1)

        let a2CreatedAt = TimeTicket(lamport: 2, delimiter: 0, actorID: actorId)
        let a2 = Primitive(value: .string("A2"), createdAt: a2CreatedAt)
        target.set(key: "K2", value: a2)

        let a3 = Primitive(value: .string("A3"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        target.set(key: "K3", value: a3)

        let result = try target.subPath(createdAt: a2CreatedAt)
        XCTAssertEqual(result, "K2")
    }

    func test_can_delete() throws {
        let targetKey = "K2"
        let target = CRDTObject(createdAt: TimeTicket.initial)

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "K1", value: a1)

        let a2CreatedAt = TimeTicket(lamport: 2, delimiter: 0, actorID: actorId)
        let a2 = Primitive(value: .string("A2"), createdAt: a2CreatedAt)
        target.set(key: targetKey, value: a2)

        let a3 = Primitive(value: .string("A3"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        target.set(key: "K3", value: a3)

        try target.delete(element: a2)

        XCTAssertFalse(target.has(key: targetKey))
    }

    func test_remove() throws {
        let targetKey = "K2"
        let target = CRDTObject(createdAt: TimeTicket.initial)

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "K1", value: a1)

        let a2CreatedAt = TimeTicket(lamport: 2, delimiter: 0, actorID: actorId)
        let a2 = Primitive(value: .string("A2"), createdAt: a2CreatedAt)
        target.set(key: targetKey, value: a2)

        let a3 = Primitive(value: .string("A3"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        target.set(key: "K3", value: a3)

        try target.remove(key: targetKey,
                          executedAt: TimeTicket(lamport: 4, delimiter: 0, actorID: self.actorId))

        XCTAssertFalse(target.has(key: targetKey))

        let result = try target.get(key: targetKey)
        XCTAssertTrue(result.isRemoved)
    }

    func test_toSortedJSON() throws {
        let target = CRDTObject(createdAt: TimeTicket.initial)

        let a1 = Primitive(value: .integer(1), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "K1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "K2", value: a2)

        let a3 = Primitive(value: .boolean(true), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        target.set(key: "K3", value: a3)

        let result = target.toSortedJSON()
        let expected = """
        {"K1":1,"K2":"A2","K3":"true"}
        """
        XCTAssertEqual(result, expected)
    }

    func test_getKeys() throws {
        let target = CRDTObject(createdAt: TimeTicket.initial)

        let a1 = Primitive(value: .integer(1), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "K1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "K2", value: a2)

        let a3 = Primitive(value: .boolean(true), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        target.set(key: "K3", value: a3)

        let result = target.keys.sorted()

        XCTAssertEqual(result, ["K1", "K2", "K3"])
    }

    func test_getDescendants_tarveling_one_element() throws {
        let target = CRDTObject(createdAt: TimeTicket.initial)

        let a1 = Primitive(value: .integer(1), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "K1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "K2", value: a2)

        let a3 = Primitive(value: .boolean(true), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        target.set(key: "K3", value: a3)

        let expect = expectation(description: "")
        var result: [CRDTElement] = []
        target.getDescendants { element, _ in
            defer {
                expect.fulfill()
            }
            result.append(element)
            return true
        }

        wait(for: [expect], timeout: 3)
        XCTAssertEqual(result.count, 1)
    }

    func test_getDescendants_tarveling_all_element() throws {
        let target = CRDTObject(createdAt: TimeTicket.initial)

        let a1 = Primitive(value: .integer(1), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "K1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "K2", value: a2)

        let a3 = Primitive(value: .boolean(true), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        target.set(key: "K3", value: a3)

        let expect = expectation(description: "")
        expect.expectedFulfillmentCount = 3
        var result: [CRDTElement] = []
        target.getDescendants { element, _ in
            defer {
                expect.fulfill()
            }
            result.append(element)
            return false
        }

        wait(for: [expect], timeout: 3)
        XCTAssertEqual(result.count, 3)
    }
}
