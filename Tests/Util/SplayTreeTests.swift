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
    func test_can_insert_values_and_splay_them() {
//        let target = SplayTree(value: "A")
//        target.insert(value: "BB")
//        target.insert(value: "CCC")
//        target.insert(value: "DDDD")
//        target.insert(value: "EEEEE")
//        target.insert(value: "FFFF")
//        target.insert(value: "GGG")
//        target.insert(value: "HH")
//        target.insert(value: "I")

        let target = SplayTree<String>()
        target.insert(value: "A2")
        XCTAssertEqual(target.description, "A2")

        target.insert(value: "B23")
        XCTAssertEqual(target.description, "left: (A2) <- B23")

        target.insert(value: "C234")
        XCTAssertEqual(target.description, "left: (left: (A2) <- B23) <- C234")

        target.insert(value: "D2345")
        XCTAssertEqual(target.description, "left: (left: (left: (A2) <- B23) <- C234) <- D2345")

        target.splay(value: "B23")
        XCTAssertEqual(target.description, "left: (A2) <- B23 -> (right: C234 -> (right: D2345))")

        XCTAssertEqual(target.search(value: "A2")?.depth(), 0)
        XCTAssertEqual(target.search(value: "B23")?.depth(), 2)
        XCTAssertEqual(target.search(value: "C234")?.depth(), 5)
        XCTAssertEqual(target.search(value: "D2345")?.depth(), 9)
    }
}
