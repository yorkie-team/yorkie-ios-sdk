/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

extension JSONArrayTests {
    struct ArrayOp {
        let opName: String
        let executor: (JSONArray, Int) throws -> Void
    }

    func testArrayConcurrencyTable() async throws {
        let initArr = [1, 2, 3, 4]
        struct TestDoc {
            var array: JSONArray
        }

        let initMarshal = #"{"a":[1,2,3,4]}"#
        let oneIdx = 1
        let otherIdxs = [2, 3]
        let newValues = [5, 6]

        // Define the operations as in the JS test
        var operations: [ArrayOp] {
            [
                // insert
                ArrayOp(opName: "insert.prev") { arr, cid in
                    try arr.insertIntegerAfter(index: oneIdx, value: newValues[cid])
                },
                ArrayOp(opName: "insert.prev.next") { arr, cid in
                    try arr.insertIntegerAfter(index: oneIdx - 1, value: newValues[cid])
                },
                // move
                ArrayOp(opName: "move.prev") { arr, cid in
                    try arr.moveAfterByIndex(prevIndex: oneIdx, targetIndex: otherIdxs[cid])
                },

                ArrayOp(opName: "move.prev.next") { arr, cid in
                    try arr.moveAfterByIndex(prevIndex: oneIdx - 1, targetIndex: otherIdxs[cid])
                },
                ArrayOp(opName: "move.target") { arr, cid in
                    try arr.moveAfterByIndex(prevIndex: otherIdxs[cid], targetIndex: oneIdx)
                },
                // set by index
                ArrayOp(opName: "set.target") { arr, cid in
                    try arr.setValue(index: oneIdx, value: newValues[cid])
                },
                // remove
                ArrayOp(opName: "remove.target") { arr, _ in
                    arr.remove(index: oneIdx)
                }
            ]
        }

        for op1 in operations {
            for op2 in operations {
                try await withTwoClientsAndDocuments(
                    op1.opName + op2.opName
                ) { client1, document1, client2, document2 in

                    try await document1.update { root, _ in
                        root.a = initArr
                    }

                    var d1JSON = await document1.toSortedJSON()

                    // Verify initial state
                    XCTAssertEqual(d1JSON, initMarshal)

                    try await client1.sync()
                    try await client2.sync()

                    d1JSON = await document1.toSortedJSON()
                    let d2JSON = await document2.toSortedJSON()

                    XCTAssertEqual(d1JSON, d2JSON)

                    // Apply operations concurrently
                    try await document1.update { root, _ in
                        guard let arr = root.a as? JSONArray else { fatalError() }
                        try op1.executor(arr, 0)
                    }

                    try await document2.update { root, _ in
                        guard let arr = root.a as? JSONArray else { fatalError() }
                        try op2.executor(arr, 1)
                    }

                    let result = try await self.syncClientsThenCheckEqual([
                        (client: client1, doc: document1), (client2, document2)
                    ], ops1: op1, ops2: op2)

                    XCTAssertTrue(result)
                }
            }
        }
    }

    func syncClientsThenCheckEqual(
        _ pairs: [(client: Client, doc: Document)],
        ops1: ArrayOp? = nil,
        ops2: ArrayOp? = nil
    ) async throws -> Bool {
        XCTAssertTrue(pairs.count > 1)

        // Save own changes and get previous changes.
        for pair in pairs {
            try await pair.client.sync()
        }

        // Get last client changes.
        for pair in pairs.dropLast() {
            try await pair.client.sync()
        }

        // Assert start.
        let expectedJSON = await pairs[0].doc.toSortedJSON()

        for pair in pairs.dropFirst() {
            let currentJSON = await pair.doc.toSortedJSON()

            if expectedJSON != currentJSON {
                return false
            }
        }
        return true
    }

    func test_can_handle_complicated_concurrent_array_operations() async throws {
        let initArr: [Int64] = [1, 2, 3, 4]
        struct TestDoc {
            var array: JSONArray
        }
        let oneIdx = 1
        let otherIdx = 0
        let newValue = 5
        let initMarshal = #"{"a":[1,2,3,4]}"#

        var operations: [ArrayOp] {
            [
                // insert
                ArrayOp(opName: "insert") { arr, _ in
                    guard let element = arr.getElement(byIndex: oneIdx) as? CRDTElement else {
                        fatalError()
                    }
                    try arr.insertAfter(previousID: element.id, value: newValue)
                },
                // move
                ArrayOp(opName: "move") { arr, _ in
                    guard let otherElement = arr.getElement(byIndex: otherIdx) as? CRDTElement else {
                        fatalError()
                    }
                    guard let oneElement = arr.getElement(byIndex: oneIdx) as? CRDTElement else {
                        fatalError()
                    }
                    try arr.moveAfter(previousID: oneElement.id, id: otherElement.id)
                },
                // set
                ArrayOp(opName: "set") { arr, _ in
                    guard let oneElement = arr.getElement(byIndex: oneIdx) as? CRDTElement else {
                        fatalError()
                    }

                    arr.remove(byID: oneElement.id)
                    if oneIdx > 0 {
                        guard let previousElement = arr.getElement(byIndex: oneIdx - 1) as? CRDTElement else { fatalError() }
                        _ = try arr.insertAfter(previousID: previousElement.id, value: newValue)
                    } else {
                        guard let firstElement = arr.getElement(byIndex: 0) as? CRDTElement else { fatalError() }
                        _ = try arr.insertBefore(nextID: firstElement.id, value: newValue)
                    }
                },
                // remove
                ArrayOp(opName: "remove") { arr, _ in
                    guard let element = arr.getElement(byIndex: oneIdx) as? CRDTElement else { fatalError() }
                    arr.remove(byID: element.id)
                }
            ]
        }

        for operation in operations {
            try await withTwoClientsAndDocuments(operation.opName) { client1, document1, client2, document2 in

                try await document1.update { root, _ in
                    root.a = initArr
                    XCTAssertEqual(root.toJSON(), initMarshal)
                }

                try await client1.sync()
                try await client2.sync()

                var d1JSON = await document1.toSortedJSON()

                d1JSON = await document1.toSortedJSON()
                let d2JSON = await document2.toSortedJSON()

                XCTAssertEqual(d1JSON, d2JSON)

                // Apply operations concurrently
                try await document1.update { root, _ in
                    guard let arr = root.a as? JSONArray else { fatalError() }
                    try operation.executor(arr, 0)
                }

                try await document2.update { root, _ in
                    let data = root.a as? JSONArray

                    guard let one = data?.getElement(byIndex: oneIdx) as? CRDTElement,
                          let two = data?.getElement(byIndex: 2) as? CRDTElement else { fatalError() }

                    try data?.moveAfter(previousID: one.id, id: two.id)

                    guard let one1 = data?.getElement(byIndex: 2) as? CRDTElement,
                          let two1 = data?.getElement(byIndex: 3) as? CRDTElement else { fatalError() }

                    try data?.moveAfter(previousID: one1.id, id: two1.id)
                }

                let result = try await self.syncClientsThenCheckEqual([
                    (client: client1, doc: document1), (client2, document2)
                ], ops1: operation, ops2: nil)

                XCTAssertTrue(result)
            }
        }
    }

    // Can handle simple array set operations
    func test_can_handle_simple_array_set_operations() async throws {
        try await withTwoClientsAndDocuments(#function) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONArray()
                (root.k1 as? JSONArray)?.push(values: [-1, -2, -3])
                XCTAssertEqual(root.toJSON(), """
                {"k1":[-1,-2,-3]}
                """)
            }

            try await c1.sync()
            try await c2.sync()

            try await d2.update { root, _ in
                try (root.k1 as? JSONArray)?.setValue(index: 1, value: -4)
            }

            var d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, """
            {"k1":[-1,-4,-3]}
            """)

            try await d2.update { root, _ in
                try (root.k1 as? JSONArray)?.setValue(index: 0, value: -5)
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, """
            {"k1":[-5,-4,-3]}
            """)

            let result = try await self.syncClientsThenCheckEqual([
                (client: c1, doc: d1), (c2, d2)
            ], ops1: nil, ops2: nil)

            XCTAssertTrue(result)
        }
    }
}
