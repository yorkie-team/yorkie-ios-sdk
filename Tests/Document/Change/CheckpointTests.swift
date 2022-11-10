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

class CheckpointTests: XCTestCase {
    func test_can_increase_client_seq() {
        let target = Checkpoint(serverSeq: 1, clientSeq: 10)
        let result = target.increasedClientSeq(by: 100)
        XCTAssertEqual(result.structureAsString, "serverSeq=1, clientSeq=110")
    }

    func test_can_forward() {
        var target = Checkpoint(serverSeq: 1, clientSeq: 2)
        let other = Checkpoint(serverSeq: 100, clientSeq: 200)
        target.forward(other: other)
        XCTAssertEqual(target.structureAsString, "serverSeq=100, clientSeq=200")
    }

    func test_can_not_forward() {
        var target = Checkpoint(serverSeq: 100, clientSeq: 200)
        let other = Checkpoint(serverSeq: 1, clientSeq: 2)
        target.forward(other: other)
        XCTAssertEqual(target.structureAsString, "serverSeq=100, clientSeq=200")
    }

    func test_can_forward_clientSeq() {
        var target = Checkpoint(serverSeq: 100, clientSeq: 2)
        let other = Checkpoint(serverSeq: 1, clientSeq: 200)
        target.forward(other: other)
        XCTAssertEqual(target.structureAsString, "serverSeq=100, clientSeq=200")
    }

    func test_can_forward_serverSeq() {
        var target = Checkpoint(serverSeq: 1, clientSeq: 200)
        let other = Checkpoint(serverSeq: 100, clientSeq: 2)
        target.forward(other: other)
        XCTAssertEqual(target.structureAsString, "serverSeq=100, clientSeq=200")
    }
}
