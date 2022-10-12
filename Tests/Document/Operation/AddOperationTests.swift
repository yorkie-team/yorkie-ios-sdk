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

class AddOperationTests: XCTestCase {
    private let actorId = "actor-1"

    func test_can_not_execute_if_parent_is_not_array() throws {
        // given
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("a1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "k-a1", value: a1)

        let object2 = CRDTObject(createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        let b1 = Primitive(value: .string("b1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2.set(key: "k-b1", value: b1)

        rootObject.set(key: "k-a3", value: object2)

        let object3 = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "k-c1", value: c1)

        object2.set(key: "k-b2", value: object3)

        let d1 = Primitive(value: .string("d1"), createdAt: TimeTicket(lamport: 8, delimiter: 0, actorID: actorId))
        object2.set(key: "k-b3", value: d1)

        let root = CRDTRoot(rootObject: rootObject)

        // when
        let valueToAdd = Primitive(value: .string("new-value"), createdAt: TimeTicket(lamport: 9, delimiter: 0, actorID: actorId))

        XCTAssertEqual(root.toSortedJSON(), "{\"k-a1\":\"a1\",\"k-a3\":{\"k-b1\":\"b1\",\"k-b2\":{\"k-c1\":\"c1\"},\"k-b3\":\"d1\"}}")

        let target = AddOperation(parentCreatedAt: object2.createdAt,
                                  previousCreatedAt: object3.createdAt,
                                  value: valueToAdd,
                                  executedAt: TimeTicket(lamport: 10, delimiter: 0, actorID: self.actorId))

        var isFailed = false
        do {
            try target.execute(root: root)
        } catch {
            isFailed = true
        }

        // then
        XCTAssertTrue(isFailed)
    }

    func test_can_execute_if_parent_is_array() throws {
        // given
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("a1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "k-a1", value: a1)

        let object2 = CRDTArray(createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        let b1 = Primitive(value: .string("b1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        try object2.insert(value: b1, afterCreatedAt: TimeTicket.initial)

        rootObject.set(key: "k-a3", value: object2)

        let object3 = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "k-c1", value: c1)

        try object2.insert(value: object3, afterCreatedAt: b1.createdAt)

        let d1 = Primitive(value: .string("d1"), createdAt: TimeTicket(lamport: 8, delimiter: 0, actorID: actorId))
        try object2.insert(value: d1, afterCreatedAt: object3.createdAt)

        let root = CRDTRoot(rootObject: rootObject)

        // when
        let valueToAdd = Primitive(value: .string("new-value"), createdAt: TimeTicket(lamport: 9, delimiter: 0, actorID: actorId))

        XCTAssertEqual(root.toSortedJSON(), "{\"k-a1\":\"a1\",\"k-a3\":[\"b1\",{\"k-c1\":\"c1\"},\"d1\"]}")

        let target = AddOperation(parentCreatedAt: object2.createdAt,
                                  previousCreatedAt: object3.createdAt,
                                  value: valueToAdd,
                                  executedAt: TimeTicket(lamport: 9, delimiter: 0, actorID: self.actorId))

        var isFailed = false
        do {
            try target.execute(root: root)
        } catch {
            isFailed = true
        }

        // then
        XCTAssertFalse(isFailed)

        XCTAssertEqual(root.toSortedJSON(), "{\"k-a1\":\"a1\",\"k-a3\":[\"b1\",{\"k-c1\":\"c1\"},\"new-value\",\"d1\"]}")
        XCTAssertEqual(target.getStructureAsString(), "4:actor-1:0.ADD")
        XCTAssertEqual(target.getEffectedCreatedAt(), valueToAdd.createdAt)
    }
}
