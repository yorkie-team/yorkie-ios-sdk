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

class RHTPQMapTests: XCTestCase {
    private let actorId = "actor-1"
    func test_set_value_by_key_is_new() throws {
        let target = RHTPQMap()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

        let elementA1 = try target.get(key: "a1")
        let elementA2 = try target.get(key: "a2")

        XCTAssertEqual(elementA1.toJSON(), "\"A1\"")
        XCTAssertEqual(elementA1.isRemoved, false)
        XCTAssertEqual(elementA2.toJSON(), "\"A2\"")
        XCTAssertEqual(elementA2.isRemoved, false)
    }

    func test_set_value_by_key_is_used_alreay() throws {
        let target = RHTPQMap()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a2)

        let result = try target.get(key: "a1")

        XCTAssertEqual(result.toJSON(), "\"A2\"")
        XCTAssertEqual(result.isRemoved, false)
    }

    func test_remove_by_createdAt() throws {
        let target = RHTPQMap()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

        let executedAt = TimeTicket(lamport: 3, delimiter: 0, actorID: actorId)
        let removed = try target.remove(createdAt: a2.createdAt, executedAt: executedAt)

        XCTAssertEqual(removed.toJSON(), "\"A2\"")
        XCTAssertEqual(try target.get(key: "a2").isRemoved, true)
        XCTAssertEqual(try target.get(key: "a1").isRemoved, false)
    }

    func test_remove_by_key() throws {
        let target = RHTPQMap()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

        let executedAt = TimeTicket(lamport: 3, delimiter: 0, actorID: actorId)
        let removed = try target.remove(key: "a2", executedAt: executedAt)

        XCTAssertEqual(removed.toJSON(), "\"A2\"")
        XCTAssertEqual(try target.get(key: "a2").isRemoved, true)
        XCTAssertEqual(try target.get(key: "a1").isRemoved, false)
    }

    func test_subPath() throws {
        let target = RHTPQMap()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

        let subPath = try target.subPath(createdAt: a2.createdAt)
        XCTAssertEqual(subPath, "a2")
    }

    func test_delete() throws {
        let target = RHTPQMap()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

        try target.delete(value: a2)

        let result = try? target.get(key: "a2")
        XCTAssertNil(result)
    }

    func test_has() throws {
        let target = RHTPQMap()

        let a1 = Primitive(value: .string("A1"), createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        target.set(key: "a1", value: a1)

        let a2 = Primitive(value: .string("A2"), createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        target.set(key: "a2", value: a2)

        try target.delete(value: a2)

        XCTAssertTrue(target.has(key: "a1"))
        XCTAssertFalse(target.has(key: "a2"))
    }
}
