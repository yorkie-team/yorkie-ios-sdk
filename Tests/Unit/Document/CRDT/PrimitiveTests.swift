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

class PrimitiveTests: XCTestCase {
    func test_value_is_null() throws {
        let primitiveValue = Primitive(value: .null, createdAt: TimeTicket.initial)
        let valueFromData = try Converter.valueFrom(.null, data: primitiveValue.toBytes())
        switch valueFromData {
        case .null:
            ()
        default:
            XCTFail("Type error.")
        }
    }

    func test_value_is_bool() throws {
        let primitiveValue = Primitive(value: .boolean(true), createdAt: TimeTicket.initial)
        let valueFromData = try Converter.valueFrom(.boolean, data: primitiveValue.toBytes())
        switch valueFromData {
        case .boolean(let value):
            XCTAssertEqual(value, true)
        default:
            XCTFail("Type error.")
        }
    }

    func test_value_is_integer() throws {
        let primitiveValue = Primitive(value: .integer(12345), createdAt: TimeTicket.initial)
        let valueFromData = try Converter.valueFrom(.integer, data: primitiveValue.toBytes())
        switch valueFromData {
        case .integer(let value):
            XCTAssertEqual(value, 12345)
        default:
            XCTFail("Type error.")
        }
    }

    func test_value_is_long() throws {
        let primitiveValue = Primitive(value: .long(1_234_567_890), createdAt: TimeTicket.initial)
        let valueFromData = try Converter.valueFrom(.long, data: primitiveValue.toBytes())
        switch valueFromData {
        case .long(let value):
            XCTAssertEqual(value, 1_234_567_890)
        default:
            XCTFail("Type error.")
        }
    }

    func test_value_is_double() throws {
        let primitiveValue = Primitive(value: .double(-123_456_789), createdAt: TimeTicket.initial)
        let valueFromData = try Converter.valueFrom(.double, data: primitiveValue.toBytes())
        switch valueFromData {
        case .double(let value):
            XCTAssertEqual(value, -123_456_789)
        default:
            XCTFail("Type error.")
        }
    }

    func test_value_is_string() throws {
        let primitiveValue = Primitive(value: .string("ABCDEFG"), createdAt: TimeTicket.initial)
        let valueFromData = try Converter.valueFrom(.string, data: primitiveValue.toBytes())
        switch valueFromData {
        case .string(let value):
            XCTAssertEqual(value, "ABCDEFG")
        default:
            XCTFail("Type error.")
        }
    }

    func test_value_is_bytes() throws {
        let testData = Data("abcdefg".utf8)
        let primitiveValue = Primitive(value: .bytes(testData), createdAt: TimeTicket.initial)
        let valueFromData = try Converter.valueFrom(.bytes, data: primitiveValue.toBytes())
        switch valueFromData {
        case .bytes(let value):
            XCTAssertEqual(String(data: value, encoding: .utf8), "abcdefg")
        default:
            XCTFail("Type error.")
        }
    }

    func test_value_is_date() throws {
        let testDate = Date()
        let primitiveValue = Primitive(value: .date(testDate), createdAt: TimeTicket.initial)
        let valueFromData = try Converter.valueFrom(.date, data: primitiveValue.toBytes())

        switch valueFromData {
        case .date:
            XCTAssertEqual(primitiveValue.value, valueFromData)
        default:
            XCTFail("Type error.")
        }
    }

    // Ported from yorkie-js-sdk v0.7.6 primitive_test.ts: "toJSON for Bytes and Date".
    // Verifies that Bytes encodes as base64 and Date encodes as an ISO-8601 UTC string,
    // matching JS Primitive.toJSON() behaviour introduced in #1225.
    func test_toJSON_for_bytes_and_date() {
        // given — bytes [0x41, 0x42] == "AB" in ASCII, base64 == "QUI="
        let bytesData = Data([0x41, 0x42])
        let bytesValue = Primitive(value: .bytes(bytesData), createdAt: TimeTicket.initial)

        // then — bytes encodes as a JSON string containing the base64 representation
        XCTAssertEqual(bytesValue.toJSON(), "\"QUI=\"")

        // given — Date corresponding to JS `new Date('1995-12-17T03:24:00.000Z')`
        var components = DateComponents()
        components.year = 1995
        components.month = 12
        components.day = 17
        components.hour = 3
        components.minute = 24
        components.second = 0
        components.nanosecond = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let dateValue = Primitive(value: .date(date), createdAt: TimeTicket.initial)

        // then — date encodes as an ISO-8601 UTC string with fractional seconds
        XCTAssertEqual(dateValue.toJSON(), "\"1995-12-17T03:24:00.000Z\"")
    }
}
