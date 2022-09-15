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

class HeapTests: XCTestCase {
    func test_can_push_and_pop() {
        var target = Heap<Int>()

        for value in [8, 7, 5, 6, 2, 1, 9, 4, 0, 3] {
            target.insert(value)
        }

        for value in (0 ... 9).reversed() {
            XCTAssertEqual(target.remove(), value)
        }
    }

    func test_remove_root() {
        let root = 9
        var target = Heap(array: [8, 7, 5, 6, 2, 1, root, 4, 0, 3])

        XCTAssertEqual(target.remove(), root)

        for value in (0 ... 8).reversed() {
            XCTAssertEqual(target.remove(), value)
        }
    }

    func test_remove_parent_node() {
        let parent = 5
        var target = Heap(array: [8, 7, parent, 6, 2, 1, 9, 4, 0, 3])

        XCTAssertEqual(target.remove(node: parent), parent)

        for value in [0, 1, 2, 3, 4, 6, 7, 8, 9].reversed() {
            XCTAssertEqual(target.remove(), value)
        }
    }

    func test_remove_leaf_node() {
        let leaf = 0
        var target = Heap(array: [8, 7, 5, 6, 2, 1, 9, 4, leaf, 3])

        XCTAssertEqual(target.remove(node: leaf), leaf)

        for value in [1, 2, 3, 4, 5, 6, 7, 8, 9].reversed() {
            XCTAssertEqual(target.remove(), value)
        }
    }

    func test_empty() {
        var target = Heap<Int>()

        for value in [8, 7, 5, 6, 2, 1, 9, 4, 0, 3] {
            target.insert(value)
        }

        for value in (0 ... 9).reversed() {
            target.remove(node: value)
        }

        XCTAssertTrue(target.isEmpty)
        XCTAssertEqual(target.count, 0)
    }

    func test_remove_root_by_node() {
        var target = Heap<Int>()

        for value in [8, 7, 5, 6, 2, 1, 9, 4, 0, 3] {
            target.insert(value)
        }

        target.remove(node: 9)

        XCTAssertEqual(target.remove(), 8)
    }

    func test_remove_root_by_index() {
        var target = Heap<Int>()

        for value in [8, 7, 5, 6, 2, 1, 9, 4, 0, 3] {
            target.insert(value)
        }

        XCTAssertEqual(target.remove(at: 0), 9)

        XCTAssertEqual(target.remove(), 8)
    }
}
