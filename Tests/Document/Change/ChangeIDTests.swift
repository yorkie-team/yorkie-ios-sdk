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

class Tests: XCTestCase {
    func test_no_actor() {
        let target = ChangeID(clientSeq: 1, lamport: 2)

        XCTAssertEqual(target.getStructureAsString(), "2:nil:1")
    }

    func test_with_actor() {
        let actorID = "abcdefghijklmnopqrstuvwxyz"
        let target = ChangeID(clientSeq: 1, lamport: 2, actor: actorID)

        XCTAssertEqual(target.getStructureAsString(), "2:wxy:1")
    }

    func test_change_lmport_to_bigger_than_current_lamport() {
        var target = ChangeID(clientSeq: 1, lamport: 2)
        target.syncLamport(with: 10)
        XCTAssertEqual(target.getLamport(), 10)
    }

    func test_change_lmport_to_smaller_than_current_lamport() {
        var target = ChangeID(clientSeq: 1, lamport: 10)
        target.syncLamport(with: 5)
        XCTAssertEqual(target.getLamport(), 11)
    }

    func test_can_create_time_ticket() {
        let target = ChangeID(clientSeq: 1, lamport: 2, actor: "actor-1")
        let result = target.createTimeTicket(delimiter: 3)
        XCTAssertEqual(result.getStructureAsString(), "2:actor-1:3")
    }
}