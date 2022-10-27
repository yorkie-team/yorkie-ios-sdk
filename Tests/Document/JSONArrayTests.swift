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
    func test_can_append() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = JSONArray()
            let array = root["array"] as? JSONArray

            XCTAssertNotNil(array?.getID())

            let int64Index = array?.append(Int64(1))

            let value = array?[int64Index!] as? Int64
            XCTAssertEqual(value, 1)

            array?.append(Int32(2))
            array?.append("a")
            array?.append(Double(1.2345))
            array?.append(true)
            let arrayValueIndex = array?.append([Int32(11), Int32(12), Int32(13)])
            let arrayValue = array?[arrayValueIndex!] as? JSONArray
            arrayValue?.append(values: [Int32(21), Int32(22), Int32(23)])

            XCTAssertEqual(root.debugDescription, """
            {"array":[1,2,"a",1.2345,"true",[11,12,13,21,22,23]]}
            """)
        }
    }

    func test_can_append_with_array() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray
            array?.append(Int32(4))
            array?.append(values: [Int32(5), Int32(6)])
            XCTAssertEqual(root.debugDescription, """
            {"array":[1,2,3,4,5,6]}
            """)
        }
    }

    func test_can_get_element_by_id_and_index() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray
            let element = array?.getElement(byIndex: 0) as? Primitive
            XCTAssertNotNil(element)

            let elementById = array?.getElement(byID: element!.getCreatedAt())
            XCTAssertNotNil(elementById)
        }
    }

    func test_can_get_last() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray
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

    func test_can_insert_into_after() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray
            guard let firstElement = array?.getElement(byIndex: 0) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            let insertedElement = try? array?.insertAfter(previousID: firstElement.getCreatedAt(), value: [Int32(11), Int32(12), Int32(13)])
            XCTAssertNotNil(insertedElement)

            XCTAssertEqual(root.debugDescription, "{\"array\":[1,[11,12,13],2,3]}")
        }
    }

    func test_can_insert_into_before() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray
            guard let thirdElement = array?.getElement(byIndex: 2) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            let insertedElement = try? array?.insertBefore(nextID: thirdElement.getCreatedAt(), value: [Int32(11), Int32(12), Int32(13)])
            XCTAssertNotNil(insertedElement)

            XCTAssertEqual(root.debugDescription, "{\"array\":[1,2,[11,12,13],3]}")
        }
    }

    func test_can_move_to_before() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray
            guard let firstElement = array?.getElement(byIndex: 0) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            guard let lastElement = array?.getElement(byIndex: 2) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            try? array?.moveBefore(nextID: lastElement.getCreatedAt(), id: firstElement.getCreatedAt())

            XCTAssertEqual(root.debugDescription, "{\"array\":[2,1,3]}")
        }
    }

    func test_can_move_to_after() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray
            guard let firstElement = array?.getElement(byIndex: 0) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            guard let lastElement = array?.getElement(byIndex: 2) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            try? array?.moveAfter(previousID: lastElement.getCreatedAt(), id: firstElement.getCreatedAt())

            XCTAssertEqual(root.debugDescription, "{\"array\":[2,3,1]}")
        }
    }

    func test_can_move_to_front() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray

            guard let lastElement = array?.getElement(byIndex: 2) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            try? array?.moveFront(id: lastElement.getCreatedAt())

            XCTAssertEqual(root.debugDescription, "{\"array\":[3,1,2]}")
        }
    }

    func test_can_move_to_last() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray
            guard let firstElement = array?.getElement(byIndex: 0) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            try? array?.moveLast(id: firstElement.getCreatedAt())

            XCTAssertEqual(root.debugDescription, "{\"array\":[2,3,1]}")
        }
    }

    func test_can_remove() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray
            guard let firstElement = array?.getElement(byIndex: 0) as? Primitive else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }

            let removedByID = try? array?.remove(byID: firstElement.getCreatedAt())
            XCTAssertNotNil(removedByID)

            let result = root.debugDescription
            XCTAssertEqual(result, "{\"array\":[2,3]}")

            let removedByIndex = array?.remove(index: 0)
            XCTAssertNotNil(removedByIndex)

            XCTAssertEqual(root.debugDescription, "{\"array\":[3]}")
        }
    }

    func test_can_get_length() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3)]
            let array = root["array"] as? JSONArray

            XCTAssertEqual(array?.length(), 3)
        }
    }

    func test_can_remove_partial_elements() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
            let array = root["array"] as? JSONArray

            let removed = try? array?.splice(start: 1, deleteCount: 3) as? [Int32]
            XCTAssertEqual(removed?.count, 3)

            XCTAssertEqual(removed, [Int32(2), Int32(3), Int32(4)])
            XCTAssertEqual(root.debugDescription, "{\"array\":[1,5]}")
        }
    }

    func test_can_replace_partial_elements() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
            let array = root["array"] as? JSONArray

            let removed = try? array?.splice(start: 1, deleteCount: 3, items: Int32(12), Int32(13), Int32(14)) as? [Int32]
            XCTAssertEqual(removed?.count, 3)

            XCTAssertEqual(root.debugDescription, "{\"array\":[1,12,13,14,5]}")
        }
    }

    func test_can_check_to_include() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
            let array = root["array"] as? JSONArray

            XCTAssertEqual(array?.includes(searchElement: Int32(2)), true)
            XCTAssertEqual(array?.includes(searchElement: Int32(2), fromIndex: 0), true)
            XCTAssertEqual(array?.includes(searchElement: Int32(2), fromIndex: 2), false)
            XCTAssertEqual(array?.includes(searchElement: Int32(100), fromIndex: 2), false)
        }
    }

    func test_can_get_index() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
            let array = root["array"] as? JSONArray

            XCTAssertEqual(array?.indexOf(searchElement: Int32(2)), 1)
            XCTAssertEqual(array?.indexOf(searchElement: Int32(2), fromIndex: 0), 1)
            XCTAssertEqual(array?.indexOf(searchElement: Int32(2), fromIndex: 2), JSONArray.notFound)
            XCTAssertEqual(array?.indexOf(searchElement: Int32(100), fromIndex: 2), JSONArray.notFound)
        }
    }

    func test_can_get_last_index() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = [Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)]
            let array = root["array"] as? JSONArray

            XCTAssertEqual(array?.lastIndexOf(searchElement: Int32(2)), 1)
            XCTAssertEqual(array?.lastIndexOf(searchElement: Int32(2), fromIndex: 0), JSONArray.notFound)
            XCTAssertEqual(array?.lastIndexOf(searchElement: Int32(2), fromIndex: 2), 1)
            XCTAssertEqual(array?.lastIndexOf(searchElement: Int32(100), fromIndex: 2), JSONArray.notFound)
        }
    }

    func test_can_insert_jsonObject() {
        let target = Document(key: "doc1")
        target.update { root in
            root["top"] = JSONObject()
            let object = root["top"] as? JSONObject

            object?["a"] = "a"

            XCTAssertEqual(root.debugDescription, "{\"top\":{\"a\":\"a\"}}")
        }
    }

    func test_can_insert_jsonArray() {
        let target = Document(key: "doc1")
        target.update { root in
            root["array"] = JSONArray()
            let array = root["array"] as? JSONArray

            array?.append(Int32(1))

            XCTAssertEqual(root.debugDescription, "{\"array\":[1]}")
        }
    }
}
