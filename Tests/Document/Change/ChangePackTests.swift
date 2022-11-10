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

class ChangePackTests: XCTestCase {
    func test_create_change_pack() {
        let target = ChangePack(key: "documentKey-1",
                                checkpoint: Checkpoint(serverSeq: 1, clientSeq: 10),
                                changes: [],
                                snapshot: nil,
                                minSyncedTicket: nil)

        XCTAssertEqual(target.getDocumentKey(), "documentKey-1")
        XCTAssertEqual(target.getCheckpoint().structureAsString, "serverSeq=1, clientSeq=10")
        XCTAssertFalse(target.hasChanges())
        XCTAssertEqual(target.getChangeSize(), 0)
        XCTAssertNil(target.getSnapshot())
        XCTAssertNil(target.getMinSyncedTicket())
    }

    func test_can_has_changes() {
        let change1 = Change(id: ChangeID(clientSeq: 1, lamport: 10), operations: [])
        let change2 = Change(id: ChangeID(clientSeq: 2, lamport: 20), operations: [])

        let target = ChangePack(key: "documentKey-1",
                                checkpoint: Checkpoint(serverSeq: 1, clientSeq: 10),
                                changes: [change1, change2],
                                snapshot: nil,
                                minSyncedTicket: nil)

        XCTAssertTrue(target.hasChanges())
        XCTAssertEqual(target.getChangeSize(), 2)
    }
}
