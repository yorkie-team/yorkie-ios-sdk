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

class CRDTElementTests: XCTestCase {
    func test_can_set_smaller_movedAt() {
        let small = TimeTicket.initialTimeTicket
        let big = TimeTicket.maxTimeTicket

        let target = CRDTElement(createdAt: big)
        let movedResult = target.setMovedAt(small)

        XCTAssertEqual(movedResult, true)
        XCTAssertEqual(target.getMovedAt()?.compare(small), .orderedSame)
    }

    func test_can_set_bigger_movedAt_when_movedAt_is_nil() {
        let small = TimeTicket.initialTimeTicket
        let big = TimeTicket.maxTimeTicket

        let target = CRDTElement(createdAt: small)
        let movedResult = target.setMovedAt(big)

        XCTAssertEqual(movedResult, true)
        XCTAssertEqual(target.getMovedAt()?.compare(big), .orderedSame)
    }

    func test_can_not_set_bigger_movedAt_when_movedAt_is_non_nil() {
        let small = TimeTicket.initialTimeTicket
        let big = TimeTicket.maxTimeTicket

        let target = CRDTElement(createdAt: small)
        target.setMovedAt(big)

        let timeTicket = TimeTicket(lamport: 10, delimiter: 10, actorID: ActorIds.initialActorID)
        let movedResult = target.setMovedAt(timeTicket)

        XCTAssertEqual(movedResult, false)
        XCTAssertEqual(target.getMovedAt()?.compare(small), .orderedDescending)
    }

    func test_can_not_remove_when_nil() {
        let target = CRDTElement(createdAt: TimeTicket.initialTimeTicket)

        XCTAssertEqual(target.remove(nil), false)
    }

    func test_can_not_remove_when_removeAt_is_before_createdAt() {
        let target = CRDTElement(createdAt: TimeTicket.maxTimeTicket)

        XCTAssertEqual(target.remove(TimeTicket.initialTimeTicket), false)
    }

    func test_can_remove_when_current_removeAt_is_nil() {
        let target = CRDTElement(createdAt: TimeTicket.initialTimeTicket)

        XCTAssertEqual(target.remove(TimeTicket.maxTimeTicket), true)
    }

    func test_can_remove_when_current_removeAt_is_not_nil_and_samll() {
        let target = CRDTElement(createdAt: TimeTicket.initialTimeTicket)
        target.setRemovedAt(TimeTicket.initialTimeTicket)

        XCTAssertEqual(target.remove(TimeTicket.maxTimeTicket), true)
    }

    func test_can_not_remove_when_current_removeAt_is_not_nil_and_big() {
        let target = CRDTElement(createdAt: TimeTicket.initialTimeTicket)
        target.setRemovedAt(TimeTicket.maxTimeTicket)

        let timeTicket = TimeTicket(lamport: 10, delimiter: 10, actorID: ActorIds.initialActorID)
        XCTAssertEqual(target.remove(timeTicket), false)
    }
}
