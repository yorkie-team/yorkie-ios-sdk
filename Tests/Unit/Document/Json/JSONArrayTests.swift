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

class JSONArrayTests: XCTestCase {
    func test_can_append() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = JSONArray()
            let array = root.array as? JSONArray

            XCTAssertNotNil(array?.getID())

            let int64Index = (array?.append(Int64(1)) ?? 0) - 1

            let value = array?[int64Index] as? Int64
            XCTAssertEqual(value, 1)

            array?.append(Int32(2))
            array?.append("a")
            array?.append(Double(1.2345))
            array?.append(true)
            let arrayValueIndex = (array?.append([Int32(11), Int32(12), Int32(13)]) ?? 0) - 1
            let arrayValue = array?[arrayValueIndex] as? JSONArray
            arrayValue?.append(values: [Int32(21), Int32(22), Int32(23)])

            XCTAssertEqual(root.debugDescription,
                           """
                           {"array":[1,2,"a",1.2345,true,[11,12,13,21,22,23]]}
                           """)
        }
    }

    func test_can_append_with_array() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray
            array?.append(Int32(4))
            array?.append(values: [Int32(5), Int32(6)])
            XCTAssertEqual(root.debugDescription,
                           """
                           {"array":[1,2,3,4,5,6]}
                           """)
        }
    }

    func test_can_get_element_by_id_and_index() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray
            let element = array?.getElement(byIndex: 0) as? Primitive
            XCTAssertNotNil(element)

            let elementById = array?.getElement(byID: element!.createdAt)
            XCTAssertNotNil(elementById)
        }
    }

    func test_can_get_last() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray
            guard let primitive = array?.getLast() as? Primitive else {
                XCTFail("primitive is nil.")
                return
            }
            switch primitive.value {
            case .integer(let value):
                XCTAssertEqual(value, 3)
            default:
                XCTFail("value is not equal.")
            }
        }
    }

    func test_can_insert_into_after() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray
            guard let firstElement = array?.getElement(byIndex: 0) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            let insertedElement = try? array?.insertAfter(previousID: firstElement.createdAt, value: [Int32(11), Int32(12), Int32(13)])
            XCTAssertNotNil(insertedElement)

            XCTAssertEqual(root.debugDescription, "{\"array\":[1,[11,12,13],2,3]}")
        }
    }

    func test_can_insert_into_before() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray
            guard let thirdElement = array?.getElement(byIndex: 2) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            let insertedElement = try? array?.insertBefore(nextID: thirdElement.createdAt, value: [Int32(11), Int32(12), Int32(13)])
            XCTAssertNotNil(insertedElement)

            XCTAssertEqual(root.debugDescription, "{\"array\":[1,2,[11,12,13],3]}")
        }
    }

    func test_can_move_to_before() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray
            guard let firstElement = array?.getElement(byIndex: 0) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            guard let lastElement = array?.getElement(byIndex: 2) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            try? array?.moveBefore(nextID: lastElement.createdAt, id: firstElement.createdAt)

            XCTAssertEqual(root.debugDescription, "{\"array\":[2,1,3]}")
        }
    }

    func test_can_move_to_after() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray
            guard let firstElement = array?.getElement(byIndex: 0) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            guard let lastElement = array?.getElement(byIndex: 2) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            try? array?.moveAfter(previousID: lastElement.createdAt, id: firstElement.createdAt)

            XCTAssertEqual(root.debugDescription, "{\"array\":[2,3,1]}")
        }
    }

    func test_can_move_to_front() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray

            guard let lastElement = array?.getElement(byIndex: 2) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            try? array?.moveFront(id: lastElement.createdAt)

            XCTAssertEqual(root.debugDescription, "{\"array\":[3,1,2]}")
        }
    }

    func test_can_move_to_last() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray
            guard let firstElement = array?.getElement(byIndex: 0) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            try? array?.moveLast(id: firstElement.createdAt)

            XCTAssertEqual(root.debugDescription, "{\"array\":[2,3,1]}")
        }
    }

    func test_can_remove() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray
            guard let firstElement = array?.getElement(byIndex: 0) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            let removedByID = array?.remove(byID: firstElement.createdAt)
            XCTAssertNotNil(removedByID)

            let result = root.debugDescription
            XCTAssertEqual(result, "{\"array\":[2,3]}")

            let removedByIndex = array?.remove(index: 0)
            XCTAssertNotNil(removedByIndex)

            XCTAssertEqual(root.debugDescription, "{\"array\":[3]}")
        }
    }

    func test_can_get_length() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3)]
            let array = root.array as? JSONArray

            XCTAssertEqual(array?.length(), 3)
        }
    }

    func test_can_remove_partial_elements() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
            let array = root.array as? JSONArray

            let removed = try? array?.splice(start: 1, deleteCount: 3) as? [Int32]
            XCTAssertEqual(removed?.count, 3)

            XCTAssertEqual(removed, [Int32(2), Int32(3), Int32(4)])
            XCTAssertEqual(root.debugDescription, "{\"array\":[1,5]}")
        }
    }

    func test_can_replace_partial_elements() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
            let array = root.array as? JSONArray

            let removed = try? array?.splice(start: 1, deleteCount: 3, items: Int32(12), Int32(13), Int32(14)) as? [Int32]
            XCTAssertEqual(removed?.count, 3)

            XCTAssertEqual(root.debugDescription, "{\"array\":[1,12,13,14,5]}")
        }
    }

    func test_can_check_to_include() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
            let array = root.array as? JSONArray

            XCTAssertEqual(array?.includes(searchElement: Int32(2)), true)
            XCTAssertEqual(array?.includes(searchElement: Int32(2), fromIndex: 0), true)
            XCTAssertEqual(array?.includes(searchElement: Int32(2), fromIndex: 2), false)
            XCTAssertEqual(array?.includes(searchElement: Int32(100), fromIndex: 2), false)
        }
    }

    func test_can_get_index() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
            let array = root.array as? JSONArray

            XCTAssertEqual(array?.indexOf(Int32(2)), 1)
            XCTAssertEqual(array?.indexOf(Int32(2), fromIndex: 0), 1)
            XCTAssertEqual(array?.indexOf(Int32(2), fromIndex: 2), JSONArray.notFound)
            XCTAssertEqual(array?.indexOf(Int32(100), fromIndex: 2), JSONArray.notFound)
        }
    }

    func test_can_get_last_index() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
            let array = root.array as? JSONArray

            XCTAssertEqual(array?.lastIndexOf(Int32(2)), 1)
            XCTAssertEqual(array?.lastIndexOf(Int32(2), fromIndex: 0), JSONArray.notFound)
            XCTAssertEqual(array?.lastIndexOf(Int32(2), fromIndex: 2), 1)
            XCTAssertEqual(array?.lastIndexOf(Int32(100), fromIndex: 2), JSONArray.notFound)
        }
    }

    func test_can_insert_jsonObject() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.top = JSONObject()
            let object = root.top as? JSONObject

            object?.a = "a"

            XCTAssertEqual(root.debugDescription, "{\"top\":{\"a\":\"a\"}}")
        }
    }

    func test_can_insert_jsonArray() async throws {
        let target = Document(key: "doc1")
        try await target.update { root, _ in
            root.array = JSONArray()
            let array = root.array as? JSONArray

            array?.append(Int32(1))

            XCTAssertEqual(root.debugDescription, "{\"array\":[1]}")
        }
    }

    // MARK: - elements() iterator (#1178)

    /// Verifies that the default `for-in` iterator yields unwrapped Swift values for
    /// primitive elements, while `elements()` yields wrapped `Primitive` objects that
    /// carry CRDT metadata such as `createdAt`.
    func test_default_iterator_yields_unwrapped_values_and_elements_yields_wrapped() async throws {
        // given — an array of three Int32 primitives
        let doc = Document(key: "elements-iterator")
        try await doc.update { root, _ in
            root.array = [Int32(10), Int32(20), Int32(30)]
        }

        try await doc.update { root, _ in
            guard let array = root.array as? JSONArray else {
                XCTFail("array not found")
                return
            }

            // when — collect via the default for-in iterator (unwrapped path)
            var unwrappedValues = [Int32]()
            for element in array {
                if let value = element as? Int32 {
                    unwrappedValues.append(value)
                }
            }

            // then — default iterator returns plain Swift Int32 values
            XCTAssertEqual(unwrappedValues, [10, 20, 30])

            // when — collect via elements() (wrapped path)
            var wrappedElements = [Primitive]()
            for element in array.elements() {
                if let primitive = element as? Primitive {
                    wrappedElements.append(primitive)
                }
            }

            // then — elements() returns Primitive objects carrying CRDT metadata
            XCTAssertEqual(wrappedElements.count, 3)
            XCTAssertNotNil(wrappedElements.first?.createdAt)

            // The wrapped values carry the correct underlying data
            let values = wrappedElements.compactMap { primitive -> Int32? in
                if case .integer(let intValue) = primitive.value { return intValue }
                return nil
            }
            XCTAssertEqual(values, [10, 20, 30])
        }
    }

    /// Verifies that `elements()` and the default for-in iterator both cover the same
    /// number of live elements, confirming the two iterators share the same underlying
    /// `CRDTArray` sequence.
    func test_elements_iterator_count_matches_default_iterator_count() async throws {
        // given
        let doc = Document(key: "elements-iterator-count")
        try await doc.update { root, _ in
            root.array = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
        }

        try await doc.update { root, _ in
            guard let array = root.array as? JSONArray else {
                XCTFail("array not found")
                return
            }

            // when
            var defaultCount = 0
            for _ in array {
                defaultCount += 1
            }

            var wrappedCount = 0
            for _ in array.elements() {
                wrappedCount += 1
            }

            // then
            XCTAssertEqual(defaultCount, 5)
            XCTAssertEqual(wrappedCount, 5)
            XCTAssertEqual(defaultCount, wrappedCount)
        }
    }
}
