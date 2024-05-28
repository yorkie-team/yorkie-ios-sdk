/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

class RHTTests: XCTestCase {
    func test_should_set_and_get_a_value() {
        let testKey = "test-key"
        let testValue = "test-value"
        let notExistsKey = "not-exists-key"

        let rht = RHT()

        XCTAssertEqual(rht.toJSON(), "{}")

        rht.set(key: testKey, value: testValue, executedAt: TimeTicket.initial)

        let actualValue = try? rht.get(key: testKey)
        XCTAssertEqual(actualValue, testValue)

        let notExistsValue = try? rht.get(key: notExistsKey)
        XCTAssertEqual(notExistsValue, nil)
    }

    func test_should_handle_remove() throws {
        let testKey = "test-key"
        let testValue = "test-value"

        let rht = RHT()

        XCTAssertEqual(rht.toJSON(), "{}")
        rht.set(key: testKey, value: testValue, executedAt: TimeTicket.initial)

        let actualValue = try rht.get(key: testKey)
        XCTAssertEqual(actualValue, testValue)
        XCTAssertEqual(rht.size, 1)

        rht.remove(key: testKey, executedAt: TimeTicket.next)
        XCTAssertEqual(rht.has(key: testKey), false)
        XCTAssertEqual(rht.size, 0)
    }

    func test_should_not_set_when_same_key_exsits_and_updatedAt_is_bigger() {
        let actorId = "actorId-1"
        let testKey = "test-key"
        let testValue = "test-value"

        let rht = RHT()

        XCTAssertEqual(rht.toJSON(), "{}")

        rht.set(key: testKey,
                value: testValue,
                executedAt: TimeTicket(lamport: 10, delimiter: 10, actorID: actorId))

        let value = try? rht.get(key: testKey)
        XCTAssertEqual(value, testValue)

        rht.set(key: testKey,
                value: "test-value-2",
                executedAt: TimeTicket.initial)

        let result = try? rht.get(key: testKey)
        XCTAssertEqual(result, testValue)
    }

    func test_should_throwing_errors_when_a_key_does_not_exist() {
        let notExistsKey = "not-exists-key"

        let rht = RHT()

        // Check if a rht object is constructed well.
        XCTAssertEqual(rht.toJSON(), "{}")

        let notExistsValue = try? rht.get(key: notExistsKey)
        XCTAssertEqual(notExistsValue, nil)
    }

    func test_should_check_if_a_key_exists() {
        let testKey = "test-key"
        let testValue = "test-value"

        let rht = RHT()

        // Check if a rht object is constructed well.
        XCTAssertEqual(rht.toJSON(), "{}")

        rht.set(key: testKey, value: testValue, executedAt: TimeTicket.initial)

        let actualValue = rht.has(key: testKey)
        XCTAssertTrue(actualValue)
    }

    func test_should_handle_toJSON() {
        let testData = [
            "testKey1": "testValue1",
            "testKey2": "testValue2",
            "testKey3": "testValue3"
        ]

        let rht = RHT()
        for (key, value) in testData {
            rht.set(key: key, value: value, executedAt: TimeTicket.initial)
        }

        let json = rht.toJSON()
        let result = self.dictionary(from: json)

        for (key, value) in testData {
            XCTAssertEqual(result[key], value)
        }
    }

    private func dictionary(from json: String) -> [String: String] {
        guard let data = json.data(using: .utf8) else {
            return [:]
        }

        do {
            return try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] ?? [:]
        } catch {
            XCTFail("Failed to convert json data to dictionary.")
        }
        return [:]
    }

    func test_should_handle_toObject() {
        let testData = [
            "testKey1": "testValue1",
            "testKey2": "testValue2",
            "testKey3": "testValue3"
        ]

        let rht = RHT()
        for (key, value) in testData {
            rht.set(key: key, value: value, executedAt: TimeTicket.initial)
        }

        let result = rht.toObject()

        for (key, value) in testData {
            XCTAssertEqual(result[key]?.value, value)
        }
    }
}

final class GCTestsForRHT: XCTestCase {
    enum OpCode {
        case noOp
        case set
        case remove
    }

    struct Operation {
        let code: OpCode
        let key: String
        let val: String
    }

    struct Step {
        let op: Operation
        let expectJSON: String
        let expectSize: Int?

        init(op: Operation, expectJSON: String, expectSize: Int? = nil) {
            self.op = op
            self.expectJSON = expectJSON
            self.expectSize = expectSize
        }
    }

    struct TestCase {
        let desc: String
        let steps: [Step]
    }

    func test_rht_garbage_collection_marshal() async throws {
        let tests: [TestCase] = [
            TestCase(desc: "1. empty hash table",
                     steps: [
                         Step(op: Operation(code: .noOp, key: "", val: ""),
                              expectJSON: "{}")
                     ]),
            TestCase(desc: "2. only one element",
                     steps: [
                         Step(op: Operation(code: .set, key: "hello\\\\\\\\\\\t", val: "world\"\u{000C}\u{0008}"),
                              expectJSON: "{\"hello\\\\\\\\\\\\\\\\\\\\\\t\":\"world\\\"\\f\\b\"}")
                     ]),
            TestCase(desc: "2. non-empty hash table",
                     steps: [
                         Step(op: Operation(code: .set, key: "hi", val: "test\r"),
                              expectJSON: "{\"hello\\\\\\\\\\\\\\\\\\\\\\t\":\"world\\\"\\f\\b\",\"hi\":\"test\\r\"}")
                     ])
        ]

        let rht = RHT()

        for test in tests {
            for step in test.steps {
                if step.op.code == .set {
                    rht.set(key: step.op.key, value: step.op.val, executedAt: timeT())
                }

                let result = rht.toSortedJSON()
                XCTAssertEqual(result, step.expectJSON)
            }
        }
    }

    func test_rht_garbage_collection_set() async throws {
        let tests: [TestCase] = [
            TestCase(desc: "1. set elements",
                     steps: [
                         Step(op: Operation(code: .set, key: "key1", val: "value1"),
                              expectJSON: "{\"key1\":\"value1\"}",
                              expectSize: 1),
                         Step(op: Operation(code: .set, key: "key2", val: "value2"),
                              expectJSON: "{\"key1\":\"value1\",\"key2\":\"value2\"}",
                              expectSize: 2)
                     ]),
            TestCase(desc: "2. change elements",
                     steps: [
                         Step(op: Operation(code: .set, key: "key1", val: "value2"),
                              expectJSON: "{\"key1\":\"value2\",\"key2\":\"value2\"}",
                              expectSize: 2),
                         Step(op: Operation(code: .set, key: "key2", val: "value1"),
                              expectJSON: "{\"key1\":\"value2\",\"key2\":\"value1\"}",
                              expectSize: 2)
                     ])
        ]

        let rht = RHT()

        for test in tests {
            for step in test.steps {
                if step.op.code == .set {
                    rht.set(key: step.op.key, value: step.op.val, executedAt: timeT())
                }

                let result = rht.toSortedJSON()
                XCTAssertEqual(result, step.expectJSON)
            }
        }
    }

    func test_rht_garbage_collection_remove() async throws {
        let tests: [TestCase] = [
            TestCase(desc: "1. set elements",
                     steps: [
                         Step(op: Operation(code: .set, key: "key1", val: "value1"),
                              expectJSON: "{\"key1\":\"value1\"}",
                              expectSize: 1),
                         Step(op: Operation(code: .set, key: "key2", val: "value2"),
                              expectJSON: "{\"key1\":\"value1\",\"key2\":\"value2\"}",
                              expectSize: 2)
                     ]),
            TestCase(desc: "2. remove elements",
                     steps: [
                         Step(op: Operation(code: .remove, key: "key1", val: "value1"),
                              expectJSON: "{\"key2\":\"value2\"}",
                              expectSize: 1)
                     ]),
            TestCase(desc: "3. set after remove",
                     steps: [
                         Step(op: Operation(code: .set, key: "key1", val: "value11"),
                              expectJSON: "{\"key1\":\"value11\",\"key2\":\"value2\"}",
                              expectSize: 2)
                     ]),
            TestCase(desc: "4. remove elements",
                     steps: [
                         Step(op: Operation(code: .set, key: "key2", val: "value22"),
                              expectJSON: "{\"key1\":\"value11\",\"key2\":\"value22\"}",
                              expectSize: 2),
                         Step(op: Operation(code: .remove, key: "key1", val: "value11"),
                              expectJSON: "{\"key2\":\"value22\"}",
                              expectSize: 1)
                     ]),
            TestCase(desc: "5. remove element again",
                     steps: [
                         Step(op: Operation(code: .remove, key: "key1", val: "value11"),
                              expectJSON: "{\"key2\":\"value22\"}",
                              expectSize: 1)
                     ]),
            TestCase(desc: "6. remove elements(cleared)",
                     steps: [
                         Step(op: Operation(code: .remove, key: "key2", val: "value22"),
                              expectJSON: "{}",
                              expectSize: 0)
                     ]),
            TestCase(desc: "7. remove not exist key",
                     steps: [
                         Step(op: Operation(code: .remove, key: "not-exist-key", val: ""),
                              expectJSON: "{}",
                              expectSize: 0)
                     ])
        ]

        let rht = RHT()

        for test in tests {
            for step in test.steps {
                if step.op.code == .set {
                    rht.set(key: step.op.key, value: step.op.val, executedAt: timeT())
                } else if step.op.code == .remove {
                    rht.remove(key: step.op.key, executedAt: timeT())
                }

                let result = rht.toSortedJSON()
                XCTAssertEqual(result, step.expectJSON, test.desc)
                XCTAssertEqual(rht.size, step.expectSize, test.desc)
                XCTAssertEqual(rht.toObject().count, step.expectSize, test.desc)
            }
        }
    }
}
