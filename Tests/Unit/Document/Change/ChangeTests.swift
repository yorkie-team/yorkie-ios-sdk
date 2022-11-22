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

class ChangeTests: XCTestCase {
    private let actorId = "actor-1"

    func test_can_change_actor() throws {
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("a1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "k-a1", value: a1)

        let object2Ticket = TimeTicket(lamport: 4, delimiter: 0, actorID: actorId)
        let object2 = CRDTObject(createdAt: object2Ticket)
        let b1 = Primitive(value: .string("b1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2.set(key: "k-b1", value: b1)

        rootObject.set(key: "k-a3", value: object2)

        let object3 = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "k-c1", value: c1)

        let setOperation = SetOperation(key: "k-d2", value: object3,
                                        parentCreatedAt: object2.createdAt,
                                        executedAt: TimeTicket(lamport: 8, delimiter: 0, actorID: self.actorId))

        let changeID = ChangeID(clientSeq: 1, lamport: 2, actor: self.actorId)

        var target = Change(id: changeID, operations: [setOperation])

        XCTAssertEqual(target.operations[0].executedAt.structureAsString, "8:actor-1:0")

        target.setActor("actor-2")

        XCTAssertEqual(target.operations[0].executedAt.structureAsString, "8:actor-2:0")
    }

    func test_can_execute() throws {
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("a1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "k-a1", value: a1)

        let object2Ticket = TimeTicket(lamport: 4, delimiter: 0, actorID: actorId)
        let object2 = CRDTObject(createdAt: object2Ticket)
        let b1 = Primitive(value: .string("b1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2.set(key: "k-b1", value: b1)

        rootObject.set(key: "k-a3", value: object2)

        let root = CRDTRoot(rootObject: rootObject)

        let object3 = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "k-c1", value: c1)

        let setOperation = SetOperation(key: "k-d2", value: object3,
                                        parentCreatedAt: object2.createdAt,
                                        executedAt: TimeTicket(lamport: 8, delimiter: 0, actorID: self.actorId))

        let changeID = ChangeID(clientSeq: 1, lamport: 2, actor: self.actorId)

        let target = Change(id: changeID, operations: [setOperation])

        XCTAssertEqual(root.debugDescription,
                       """
                       {"k-a1":"a1","k-a3":{"k-b1":"b1"}}
                       """)

        try target.execute(root: root)

        XCTAssertEqual(root.debugDescription,
                       """
                       {"k-a1":"a1","k-a3":{"k-b1":"b1","k-d2":{"k-c1":"c1"}}}
                       """)
    }
}
