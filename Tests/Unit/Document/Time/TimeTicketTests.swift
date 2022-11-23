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

class TimeTicketTests: XCTestCase {
    func test_compare_with_a_big_thing() {
        let small = TimeTicket.initial
        let big = TimeTicket.max

        XCTAssertTrue(small < big)
    }

    func test_compare_with_a_small_thing() {
        let big = TimeTicket.max
        let small = TimeTicket.initial

        XCTAssertTrue(big > small)
    }

    func test_compare_with_a_same_thing() {
        let big = TimeTicket.max
        let big2 = TimeTicket.max

        XCTAssertTrue(big == big2)
    }
}
