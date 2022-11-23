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

class RemoveOperationTests: XCTestCase {
    private let actorId = "actor-1"

    func test_can_execute() throws {
        // given
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("a1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "k-a1", value: a1)

        let object2Ticket = TimeTicket(lamport: 4, delimiter: 0, actorID: actorId)
        let object2 = CRDTObject(createdAt: object2Ticket)
        let b1 = Primitive(value: .string("b1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2.set(key: "k-b1", value: b1)

        rootObject.set(key: "k-a3", value: object2)

        let root = CRDTRoot(rootObject: rootObject)

        // when
        let objectForTest = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        objectForTest.set(key: "k-c1", value: c1)

        object2.set(key: "k-b2", value: objectForTest)

        let target = RemoveOperation(parentCreatedAt: object2.createdAt,
                                     createdAt: objectForTest.createdAt,
                                     executedAt: TimeTicket(lamport: 8, delimiter: 0, actorID: self.actorId))

        XCTAssertEqual(root.debugDescription, "{\"k-a1\":\"a1\",\"k-a3\":{\"k-b1\":\"b1\",\"k-b2\":{\"k-c1\":\"c1\"}}}")

        try target.execute(root: root)

        // then

        XCTAssertEqual(root.debugDescription, "{\"k-a1\":\"a1\",\"k-a3\":{\"k-b1\":\"b1\"}}")
        XCTAssertEqual(target.structureAsString, "4:actor-1:0.REMOVE")
        XCTAssertEqual(target.effectedCreatedAt, object2.createdAt)
    }
}
