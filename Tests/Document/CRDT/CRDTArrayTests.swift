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

class CRDTArrayTests: XCTestCase {
    private let actorId = "actor-1"

    func test_get_by_createdAt_returns_a_non_removed_value() throws {
        let time = TimeTicket(lamport: 1, delimiter: 999, actorID: actorId)
        let target = CRDTArray(createdAt: time)

        let e1 = Primitive(value: .string("11"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(value: e1, afterCreatedAt: TimeTicket.initial)

        let e2 = Primitive(value: .string("22"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(value: e2, afterCreatedAt: e1.createdAt)

        let e3 = Primitive(value: .string("33"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(value: e3, afterCreatedAt: e2.createdAt)

        XCTAssertEqual(target.toJSON(), "[\"11\",\"22\",\"33\"]")

        let resultE2 = try target.get(createdAt: e2.createdAt)
        XCTAssertNotNil(resultE2)

        let deletedTime = TimeTicket(lamport: 4, delimiter: 0, actorID: actorId)
        try target.remove(createdAt: e2.createdAt, executedAt: deletedTime)

        let resultRemovedE2 = try? target.get(createdAt: e2.createdAt)
        XCTAssertNil(resultRemovedE2)
    }

    func test_getDescendants_traverse_all_descendants() throws {
        let time = TimeTicket(lamport: 1, delimiter: 999, actorID: actorId)
        let target = CRDTArray(createdAt: time)

        let e1 = Primitive(value: .string("11"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(value: e1, afterCreatedAt: TimeTicket.initial)

        let e2 = Primitive(value: .string("22"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(value: e2, afterCreatedAt: e1.createdAt)

        let e3 = Primitive(value: .string("33"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(value: e3, afterCreatedAt: e2.createdAt)

        var elemetJsons: [String] = []
        target.getDescendants { element, _ in
            elemetJsons.append(element.toJSON())
            return false
        }

        XCTAssertEqual(elemetJsons.joined(separator: ", "), "\"11\", \"22\", \"33\"")
    }

    func test_getDescendants_traverse_one_descendant() throws {
        let time = TimeTicket(lamport: 1, delimiter: 999, actorID: actorId)
        let target = CRDTArray(createdAt: time)

        let e1 = Primitive(value: .string("11"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(value: e1, afterCreatedAt: TimeTicket.initial)

        let e2 = Primitive(value: .string("22"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(value: e2, afterCreatedAt: e1.createdAt)

        let e3 = Primitive(value: .string("33"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(value: e3, afterCreatedAt: e2.createdAt)

        var elemetJsons: [String] = []
        target.getDescendants { element, _ in
            elemetJsons.append(element.toJSON())
            return true
        }

        XCTAssertEqual(elemetJsons.joined(separator: ", "), "\"11\"")
    }

    func test_toJSON() throws {
        let time = TimeTicket(lamport: 1, delimiter: 999, actorID: actorId)
        let target = CRDTArray(createdAt: time)

        let e1 = Primitive(value: .string("11"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(value: e1, afterCreatedAt: TimeTicket.initial)

        let e2 = Primitive(value: .string("22"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(value: e2, afterCreatedAt: e1.createdAt)

        let e3 = Primitive(value: .string("33"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(value: e3, afterCreatedAt: e2.createdAt)

        XCTAssertEqual(target.toJSON(), "[\"11\",\"22\",\"33\"]")
    }

    func test_iterator() throws {
        let time = TimeTicket(lamport: 1, delimiter: 999, actorID: actorId)
        let target = CRDTArray(createdAt: time)

        let e1 = Primitive(value: .string("11"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        try target.insert(value: e1, afterCreatedAt: TimeTicket.initial)

        let e2 = Primitive(value: .string("22"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        try target.insert(value: e2, afterCreatedAt: e1.createdAt)

        let e3 = Primitive(value: .string("33"), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        try target.insert(value: e3, afterCreatedAt: e2.createdAt)

        var elemetJsons: [String] = []
        for each in target {
            elemetJsons.append(each.toJSON())
        }

        XCTAssertEqual(elemetJsons.joined(separator: ", "), "\"11\", \"22\", \"33\"")
    }
}
