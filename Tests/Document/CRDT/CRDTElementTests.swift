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

class TestCRDTElement: CRDTElement {
    var createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    init(createdAt: TimeTicket) {
        self.createdAt = createdAt
    }

    func toJSON() -> String { "" }

    func toSortedJSON() -> String { "" }

    func deepcopy() -> CRDTElement { self }
}

class TestCRDTElementTests: XCTestCase {
    func test_can_set_smaller_movedAt() {
        let small = TimeTicket.initial
        let big = TimeTicket.max

        let target = TestCRDTElement(createdAt: big)
        let movedResult = target.setMovedAt(small)

        XCTAssertEqual(movedResult, true)
        XCTAssertTrue(target.movedAt == small)
    }

    func test_can_set_bigger_movedAt_when_movedAt_is_nil() {
        let small = TimeTicket.initial
        let big = TimeTicket.max

        let target = TestCRDTElement(createdAt: small)
        let movedResult = target.setMovedAt(big)

        XCTAssertEqual(movedResult, true)
        XCTAssertTrue(target.movedAt == big)
    }

    func test_can_not_set_bigger_movedAt_when_movedAt_is_non_nil() {
        let small = TimeTicket.initial
        let big = TimeTicket.max

        let target = TestCRDTElement(createdAt: small)
        target.setMovedAt(big)

        let timeTicket = TimeTicket(lamport: 10, delimiter: 10, actorID: ActorIDs.initial)
        let movedResult = target.setMovedAt(timeTicket)

        XCTAssertEqual(movedResult, false)

        XCTAssertTrue(target.movedAt! > small)
    }

    func test_can_not_remove_when_nil() {
        let target = TestCRDTElement(createdAt: TimeTicket.initial)

        XCTAssertEqual(target.remove(nil), false)
    }

    func test_can_not_remove_when_removeAt_is_before_createdAt() {
        let target = TestCRDTElement(createdAt: TimeTicket.max)

        XCTAssertEqual(target.remove(TimeTicket.initial), false)
    }

    func test_can_remove_when_current_removeAt_is_nil() {
        let target = TestCRDTElement(createdAt: TimeTicket.initial)

        XCTAssertEqual(target.remove(TimeTicket.max), true)
    }

    func test_can_remove_when_current_removeAt_is_not_nil_and_samll() {
        let target = TestCRDTElement(createdAt: TimeTicket.initial)
        target.removedAt = TimeTicket.initial

        XCTAssertEqual(target.remove(TimeTicket.max), true)
    }

    func test_can_not_remove_when_current_removeAt_is_not_nil_and_big() {
        let target = TestCRDTElement(createdAt: TimeTicket.initial)
        target.removedAt = TimeTicket.max

        let timeTicket = TimeTicket(lamport: 10, delimiter: 10, actorID: ActorIDs.initial)
        XCTAssertEqual(target.remove(timeTicket), false)
    }
}
