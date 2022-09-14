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

class RedBlackTreeTests: XCTestCase {
    private let sources = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [8, 5, 7, 9, 1, 3, 6, 0, 4, 2],
        [7, 2, 0, 3, 1, 9, 8, 4, 6, 5],
        [2, 0, 3, 5, 8, 6, 4, 1, 9, 7],
        [8, 4, 7, 9, 2, 6, 0, 3, 1, 5],
        [7, 1, 5, 2, 8, 6, 3, 4, 0, 9],
        [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
    ]

    func test_can_put_and_remove_while_keeping_order() {
        for array in self.sources {
            let target = RedBlackTree<Int, Int>()
            for value in array {
                target.insert(key: value, value: value)
            }

            XCTAssertEqual(target.minValue(), 0)
            XCTAssertEqual(target.maxValue(), 9)

            XCTAssertEqual(target.allValues(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])

            target.delete(key: 8)
            XCTAssertEqual(target.allValues(), [0, 1, 2, 3, 4, 5, 6, 7, 9])

            target.delete(key: 2)
            XCTAssertEqual(target.allValues(), [0, 1, 3, 4, 5, 6, 7, 9])

            target.delete(key: 5)
            XCTAssertEqual(target.allValues(), [0, 1, 3, 4, 6, 7, 9])
        }
    }

    func test_can_query_floor_entry() {
        for array in self.sources {
            let target = RedBlackTree<Int, Int>()
            for value in array {
                target.insert(key: value, value: value)
            }

            XCTAssertEqual(target.floorEntry(input: 8), 8)

            target.delete(key: 8)
            XCTAssertEqual(target.floorEntry(input: 8), 7)

            target.delete(key: 7)
            XCTAssertEqual(target.floorEntry(input: 8), 6)
        }
    }
}
