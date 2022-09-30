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
        let target = Heap<Int, Int>()

        for value in [8, 7, 5, 6, 2, 1, 9, 4, 0, 3] {
            target.push(HeapNode(key: value, value: value))
        }

        let result = target.map { "\($0.value)" }.joined(separator: ", ")
        XCTAssertEqual(result, "9, 7, 8, 6, 3, 1, 5, 4, 0, 2")

        for value in (0 ... 9).reversed() {
            XCTAssertEqual(target.pop()?.value, value)
        }
    }

    func test_remove_root() {
        let target = Heap<Int, Int>()
        let root = 9
        [8, 7, 5, 6, 2, 1, root, 4, 0, 3].forEach { value in
            target.push(HeapNode(key: value, value: value))
        }

        target.delete(HeapNode(key: root, value: root))

        for value in (0 ... 8).reversed() {
            XCTAssertEqual(target.pop()?.value, value)
        }
    }

    func test_remove_parent_node() {
        let parent = 5
        let target = Heap<Int, Int>()
        [8, 7, parent, 6, 2, 1, 9, 4, 0, 3].forEach { value in
            target.push(HeapNode(key: value, value: value))
        }

        target.delete(HeapNode(key: parent, value: parent))

        for value in [0, 1, 2, 3, 4, 6, 7, 8, 9].reversed() {
            XCTAssertEqual(target.pop()?.value, value)
        }
    }

    func test_remove_leaf_node() {
        let leaf = 0
        let target = Heap<Int, Int>()
        [8, 7, 5, 6, 2, 1, 9, 4, leaf, 3].forEach { value in
            target.push(HeapNode(key: value, value: value))
        }

        target.delete(HeapNode(key: leaf, value: leaf))

        for value in [1, 2, 3, 4, 5, 6, 7, 8, 9].reversed() {
            XCTAssertEqual(target.pop()?.value, value)
        }
    }

    func test_empty() {
        let target = Heap<Int, Int>()
        [8, 7, 5, 6, 2, 1, 9, 4, 0, 3].forEach { value in
            target.push(HeapNode(key: value, value: value))
        }

        for value in (0 ... 9).reversed() {
            target.delete(HeapNode(key: value, value: value))
        }

        XCTAssertEqual(target.length(), 0)
    }

    func test_remove_root_by_node() {
        let target = Heap<Int, Int>()
        [8, 7, 5, 6, 2, 1, 9, 4, 0, 3].forEach { value in
            target.push(HeapNode(key: value, value: value))
        }

        let current = target.map { "\($0.value)" }.joined(separator: ", ")
        XCTAssertEqual(current, "9, 7, 8, 6, 3, 1, 5, 4, 0, 2")

        target.delete(HeapNode(key: 9, value: 9))

        XCTAssertEqual(target.pop()?.value, 8)

        let result = target.map { "\($0.value)" }.joined(separator: ", ")
        XCTAssertEqual(result, "7, 6, 5, 4, 3, 1, 2, 0")
    }

    func test_if_a_heap_has_one_node() {
        let target = Heap<Int, Int>()
        [3].forEach { value in
            target.push(HeapNode(key: value, value: value))
        }

        target.pop()

        XCTAssertEqual(target.length(), 0)
    }

    func test_iterator() {
        let target = Heap<Int, Int>()

        for value in [8, 7, 5, 6, 2, 1, 9, 4, 0, 3] {
            target.push(HeapNode(key: value, value: value))
        }

        let result = target.map { "\($0.value)" }.joined(separator: ", ")
        XCTAssertEqual(result, "9, 7, 8, 6, 3, 1, 5, 4, 0, 2")
    }

    func test_root_is_maximum() {
        let target = Heap<Int, Int>()

        for value in [8, 7, 5, 6, 2, 1, 9, 4, 0, 3] {
            target.push(HeapNode(key: value, value: value))
        }

        XCTAssertEqual(target.peek()?.value, 9)
    }
}
