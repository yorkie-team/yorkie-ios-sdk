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

class ChangeContextTests: XCTestCase {
    private let actorId = "actor-1"

    func test_push_and_query_operations() {
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("a1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "k-a1", value: a1)

        let object2Ticket = TimeTicket(lamport: 4, delimiter: 0, actorID: actorId)
        let object2 = CRDTObject(createdAt: object2Ticket)
        let b1 = Primitive(value: .string("b1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2.set(key: "k-b1", value: b1)

        rootObject.set(key: "k-a3", value: object2)

        let root = CRDTRoot(rootObject: rootObject)

        let changeID = ChangeID(clientSeq: 1, lamport: 2)
        let target = ChangeContext(id: changeID, root: root, message: "test message.")

        let object3 = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "k-c1", value: c1)

        let setOperation = SetOperation(key: "k-d2", value: object3,
                                        parentCreatedAt: object2.createdAt,
                                        executedAt: TimeTicket(lamport: 8, delimiter: 0, actorID: self.actorId))

        target.push(operation: setOperation)

        XCTAssertTrue(target.hasOperations())

        XCTAssertEqual(target.getChange().structureAsString, "4:actor-1:0.SET")
    }

    func test_can_create_timeticket() {
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("a1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "k-a1", value: a1)

        let object2Ticket = TimeTicket(lamport: 4, delimiter: 0, actorID: actorId)
        let object2 = CRDTObject(createdAt: object2Ticket)
        let b1 = Primitive(value: .string("b1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2.set(key: "k-b1", value: b1)

        rootObject.set(key: "k-a3", value: object2)

        let root = CRDTRoot(rootObject: rootObject)

        let changeID = ChangeID(clientSeq: 1, lamport: 2)
        let target = ChangeContext(id: changeID, root: root, message: "test message.")

        let result = target.issueTimeTicket()
        XCTAssertEqual(result.structureAsString, "2:nil:1")
    }
}
