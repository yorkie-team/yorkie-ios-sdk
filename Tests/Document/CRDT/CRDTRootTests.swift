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

class CRDTRootTests: XCTestCase {
    private let actorId = "actor-1"

    func test_can_find_with_createdAt() {
        // given
        let crdtObject = CRDTObject(createdAt: TimeTicket.initial)

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        crdtObject.set(key: "K1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        crdtObject.set(key: "K2", value: a2)

        let a3 = Primitive(value: .string("A3"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        crdtObject.set(key: "K3", value: a3)

        // when
        let target = CRDTRoot(rootObject: crdtObject)
        let result = target.find(createdAt: a1.createdAt)

        // then
        XCTAssertEqual(result?.toJSON(), "\"A1\"")
    }

    func test_can_create_sub_paths() throws {
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "K-a1", value: a1)
        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        rootObject.set(key: "K-a2", value: a2)

        let object2 = CRDTObject(createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        let b1 = Primitive(value: .string("B1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2.set(key: "K-B1", value: b1)

        let object3 = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "K-c1", value: c1)

        rootObject.set(key: "K-$a3", value: object2)

        object2.set(key: "K-.B2", value: object3)

        let target = CRDTRoot(rootObject: rootObject)

        let findedC1 = target.find(createdAt: c1.createdAt)
        XCTAssertEqual(findedC1?.toJSON(), "\"c1\"")

        let resultA1 = try target.createSubPaths(createdAt: a1.createdAt)
        XCTAssertEqual(resultA1, ["$", "K-a1"])

        let resultC1 = try target.createSubPaths(createdAt: c1.createdAt)
        XCTAssertEqual(resultC1, ["$", "K-\\$a3", "K-\\.B2", "K-c1"])

        let result = try target.createPath(createdAt: c1.createdAt)
        XCTAssertEqual(result, "$.K-\\$a3.K-\\.B2.K-c1")
    }

    func test_can_resturn_elements_count() throws {
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "K-a1", value: a1)
        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        rootObject.set(key: "K-a2", value: a2)

        let object2 = CRDTObject(createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        let b1 = Primitive(value: .string("B1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2.set(key: "K-B1", value: b1)

        let target = CRDTRoot(rootObject: rootObject)

        XCTAssertEqual(target.getElementMapSize(), 3)
    }

    func test_getRemovedElementSetSize() throws {
        // given
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "K-a1", value: a1)
        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        rootObject.set(key: "K-a2", value: a2)

        let object2 = CRDTObject(createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        let b1 = Primitive(value: .string("B1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2.set(key: "K-B1", value: b1)

        let target = CRDTRoot(rootObject: rootObject)

        b1.setRemovedAt(TimeTicket(lamport: 6, delimiter: 0, actorID: self.actorId))
        target.registerRemovedElement(b1)

        a2.setRemovedAt(TimeTicket(lamport: 7, delimiter: 0, actorID: self.actorId))
        target.registerRemovedElement(a2)

        // when
        let result = target.getRemovedElementSetSize()

        // then
        XCTAssertEqual(result, 2)
    }

    func test_can_return_garbage_target_length() throws {
        // given
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "K-a1", value: a1)

        let object2ToRemove = CRDTObject(createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        let b1 = Primitive(value: .string("B1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2ToRemove.set(key: "K-B1", value: b1)

        let object3 = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "K-c1", value: c1)

        rootObject.set(key: "K-a3", value: object2ToRemove)

        object2ToRemove.set(key: "K-B2", value: object3)

        // when
        let target = CRDTRoot(rootObject: rootObject)

        object2ToRemove.setRemovedAt(TimeTicket(lamport: 8, delimiter: 0, actorID: self.actorId))
        target.registerRemovedElement(object2ToRemove)
        let result = target.getGarbageLength()

        // then
        XCTAssertEqual(result, 4)
    }

    func test_garbageCollect() throws {
        // given
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "K-a1", value: a1)

        let object2ToGarbage = CRDTObject(createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        let b1 = Primitive(value: .string("B1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2ToGarbage.set(key: "K-B1", value: b1)

        let object3 = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "K-c1", value: c1)

        rootObject.set(key: "K-a3", value: object2ToGarbage)

        object2ToGarbage.set(key: "K-B2", value: object3)

        // when
        let target = CRDTRoot(rootObject: rootObject)

        let removedAtForGarbage = TimeTicket(lamport: 8, delimiter: 0, actorID: self.actorId)

        object2ToGarbage.setRemovedAt(removedAtForGarbage)
        target.registerRemovedElement(object2ToGarbage)

        a1.setRemovedAt(TimeTicket(lamport: 9, delimiter: 0, actorID: self.actorId))
        target.registerRemovedElement(a1)
        let garbageLength = target.getGarbageLength()
        XCTAssertEqual(garbageLength, 5)
        let result = target.garbageCollect(lessThanOrEqualTo: removedAtForGarbage)

        // then
        XCTAssertEqual(result, 4)

        XCTAssertNil(target.find(createdAt: object2ToGarbage.createdAt))
        XCTAssertNil(target.find(createdAt: b1.createdAt))
        XCTAssertNil(target.find(createdAt: object3.createdAt))
        XCTAssertNil(target.find(createdAt: c1.createdAt))
    }

    func test_toSortedJSON() throws {
        // given
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "K-a1", value: a1)

        let object2ToGarbage = CRDTObject(createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        let b1 = Primitive(value: .string("B1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2ToGarbage.set(key: "K-B1", value: b1)

        let object3 = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "K-c1", value: c1)

        rootObject.set(key: "K-a3", value: object2ToGarbage)

        object2ToGarbage.set(key: "K-B2", value: object3)

        // when
        let target = CRDTRoot(rootObject: rootObject)
        let result = target.debugDescription

        // then
        XCTAssertEqual(result, "{\"K-a1\":\"A1\",\"K-a3\":{\"K-B1\":\"B1\",\"K-B2\":{\"K-c1\":\"c1\"}}}")
    }

    func test_can_deepCopy() {
        // given
        let rootObject = CRDTObject(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        rootObject.set(key: "K-a1", value: a1)

        let object2 = CRDTObject(createdAt: TimeTicket(lamport: 4, delimiter: 0, actorID: actorId))
        let b1 = Primitive(value: .string("B1"), createdAt: TimeTicket(lamport: 5, delimiter: 0, actorID: actorId))
        object2.set(key: "K-B1", value: b1)

        let object3 = CRDTObject(createdAt: TimeTicket(lamport: 6, delimiter: 0, actorID: actorId))
        let c1 = Primitive(value: .string("c1"), createdAt: TimeTicket(lamport: 7, delimiter: 0, actorID: actorId))
        object3.set(key: "K-c1", value: c1)

        rootObject.set(key: "K-a3", value: object2)

        object2.set(key: "K-B2", value: object3)

        let target = CRDTRoot(rootObject: rootObject)

        let expectedJson = "{\"K-a1\":\"A1\",\"K-a3\":{\"K-B1\":\"B1\",\"K-B2\":{\"K-c1\":\"c1\"}}}"
        XCTAssertEqual(rootObject.toSortedJSON(), expectedJson)

        // when
        let deepCopied = target.deepcopy()
        let result = deepCopied.find(createdAt: rootObject.createdAt)

        // then
        XCTAssertEqual(result?.toSortedJSON(), expectedJson)
    }
}
