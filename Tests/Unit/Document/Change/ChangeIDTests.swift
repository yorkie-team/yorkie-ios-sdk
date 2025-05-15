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

class ChangeIDTests: XCTestCase {
    func test_with_actor() {
        let actorID = "abcdefghijklmnopqrstuvwxyz"
        let versionVector = VersionVector(vector: [actorID: 2])

        let target = ChangeID(clientSeq: 1, lamport: 2, actor: actorID, versionVector: versionVector)

        XCTAssertEqual(target.toTestString, "2:yz:1")
    }

    func test_change_lmport_to_bigger_than_current_lamport() {
        let actor = "actorID"

        let currentVector = VersionVector(vector: [actor: 2])
        let otherVector = VersionVector(vector: [actor: 10])

        let current = ChangeID(clientSeq: 1, lamport: 2, actor: actor, versionVector: currentVector)
        let other = ChangeID(clientSeq: 2, lamport: 10, actor: actor, versionVector: otherVector)

        let synced = current.syncClocks(with: other)

        XCTAssertEqual(synced.getVersionVector().get(actor), 11)
    }

    func test_change_lmport_to_smaller_than_current_lamport() {
        let actor = "actorID"

        let currentVector = VersionVector(vector: [actor: 10])
        let otherVector = VersionVector(vector: [actor: 5])

        let current = ChangeID(clientSeq: 1, lamport: 10, actor: actor, versionVector: currentVector)
        let other = ChangeID(clientSeq: 2, lamport: 5, actor: actor, versionVector: otherVector)

        let synced = current.syncClocks(with: other)

        XCTAssertEqual(synced.getVersionVector().get(actor), 11)
    }

    func test_can_create_time_ticket() {
        let actorID = "actor-1"

        let versionVector = VersionVector(vector: [actorID: 10])
        let target = ChangeID(clientSeq: 1, lamport: 2, actor: actorID, versionVector: versionVector)
        let result = target.createTimeTicket(delimiter: 3)

        XCTAssertEqual(result.toTestString, "2:actor-1:3")
    }
}
