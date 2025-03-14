//
//  PayloadTests.swift
//  YorkieTests
//
//  Created by hiddenviewer on 3/13/25.
//

import XCTest
@testable import Yorkie

final class PayloadTests: XCTestCase {
    func test_can_store_and_restore_string() throws {
        let value = "Hello, world!"
        let originalPayload = Payload(["string": value])
        let restoredPayload = try encodeAndDecode(originalPayload)

        XCTAssertEqual(restoredPayload["string"] as? String, value)
    }

    func test_can_store_and_restore_int() throws {
        let value = 42
        let originalPayload = Payload(["int": value])
        let restoredPayload = try encodeAndDecode(originalPayload)

        XCTAssertEqual(restoredPayload["int"] as? Int, value)
    }

    func test_can_store_and_restore_int64() throws {
        let value: Int64 = 9_007_199_254_740_991
        let originalPayload = Payload(["int64": value])
        let restoredPayload = try encodeAndDecode(originalPayload)

        // restoredValue is not Int64, but Int
        guard let restoredValue = restoredPayload["int64"] as? Int else {
            XCTFail("restore failed")
            return
        }

        XCTAssert(restoredValue == value)
    }

    func test_can_store_and_restore_double() throws {
        let value = 3.14
        let originalPayload = Payload(["double": value])
        let restoredPayload = try encodeAndDecode(originalPayload)

        XCTAssertEqual(restoredPayload["double"] as? Double, value)
    }

    func test_can_store_and_restore_bool() throws {
        let value = true
        let originalPayload = Payload(["bool": value])
        let restoredPayload = try encodeAndDecode(originalPayload)

        XCTAssertEqual(restoredPayload["bool"] as? Bool, value)
    }

    func test_can_store_and_restore_array() throws {
        let value = [1, 2, 3]
        let originalPayload = Payload(["array": value])
        let restoredPayload = try encodeAndDecode(originalPayload)

        XCTAssertEqual(restoredPayload["array"] as? [Int], value)
    }

    func test_can_store_and_restore_dictionary() throws {
        let value = ["key": "value"]
        let originalPayload = Payload(["dictionary": value])
        let restoredPayload = try encodeAndDecode(originalPayload)

        XCTAssertEqual(restoredPayload["dictionary"] as? [String: String], value)
    }

    func test_can_store_and_restore_nested_dictionary() throws {
        let value = ["key": "value"]
        let originalPayload = Payload([
            "nested1": [
                "nested2:": value
            ]
        ])
        let restoredPayload = try encodeAndDecode(originalPayload)

        XCTAssertEqual(originalPayload, restoredPayload)
    }

    func test_cannot_store_struct_and_throw_error() throws {
        struct User: Codable, Equatable {
            let name: String
            let age: Int
        }

        let user = User(name: "Alice", age: 30)
        let payload = Payload(["user": user])

        XCTAssertThrowsError(try self.encodeAndDecode(payload)) { error in
            XCTAssert(error is EncodingError)
        }
    }

    private func encodeAndDecode(_ payload: Payload) throws -> Payload {
        let jsonData = try payload.toJSONData()
        return Payload(data: jsonData)
    }
}
