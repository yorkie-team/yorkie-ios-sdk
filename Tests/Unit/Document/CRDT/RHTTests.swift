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
            XCTAssertEqual(result[key], value)
        }
    }
}
