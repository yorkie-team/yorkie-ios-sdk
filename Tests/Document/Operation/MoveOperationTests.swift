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

class MoveOperationTests: XCTestCase {
    private let actorId = "actor-1"

    func test_can_not_execute_if_parent_is_not_array() throws {
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

        let c2 = Primitive(value: .string("c2"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "k-c2", value: c2)

        try object2.insert(value: object3, afterCreatedAt: b1.createdAt)

        let root = CRDTRoot(rootObject: rootObject)

        // when
        let target = MoveOperation(parentCreatedAt: object3.createdAt,
                                   previousCreatedAt: c2.createdAt,
                                   createdAt: c1.getCreatedAt(),
                                   executedAt: TimeTicket(lamport: 10, delimiter: 0, actorID: self.actorId))

        var isFailed = false
        do {
            try target.execute(root: root)
        } catch {
            isFailed = true
        }

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

        let valueToMove = Primitive(value: .string("value-to-move"), createdAt: TimeTicket(lamport: 8, delimiter: 0, actorID: actorId))
        try object2.insert(value: valueToMove, afterCreatedAt: object3.createdAt)

        let root = CRDTRoot(rootObject: rootObject)

        // when
        XCTAssertEqual(root.debugDescription, "{\"k-a1\":\"a1\",\"k-a3\":[\"b1\",{\"k-c1\":\"c1\"},\"value-to-move\"]}")

        let target = MoveOperation(parentCreatedAt: object2.createdAt,
                                   previousCreatedAt: b1.createdAt,
                                   createdAt: valueToMove.getCreatedAt(),
                                   executedAt: TimeTicket(lamport: 10, delimiter: 0, actorID: self.actorId))

        try target.execute(root: root)

        XCTAssertEqual(root.debugDescription, "{\"k-a1\":\"a1\",\"k-a3\":[\"b1\",\"value-to-move\",{\"k-c1\":\"c1\"}]}")
        XCTAssertEqual(target.getStructureAsString(), "4:actor-1:0.MOV")
        XCTAssertEqual(target.getEffectedCreatedAt(), target.getCreatedAt())
    }
}
