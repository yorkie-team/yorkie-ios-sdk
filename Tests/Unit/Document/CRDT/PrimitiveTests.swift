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

    /// Parity guard for yorkie-js-sdk#1291 ("Promote out-of-int32 integers to
    /// Long in Primitive"). JS has a single `number` type, so it classified any
    /// integer as `Integer` and silently overflowed int32 on the wire; the fix
    /// promotes out-of-range values to Long. Swift cannot express that bug —
    /// `.integer` only ever takes a statically-typed `Int32` — so there is no
    /// logic to port. This pins the property that makes it unrepresentable, so a
    /// future widening of the integer path cannot reintroduce it.
    func test_out_of_int32_integers_are_typed_as_long() throws {
        // given — values beyond both ends of the int32 range
        let aboveMax = Int64(Int32.max) + 1
        let belowMin = Int64(Int32.min) - 1

        // when / then — they classify as long, never as integer
        for raw in [aboveMax, belowMin] {
            guard case .long(let value) = Primitive.type(of: raw) else {
                return XCTFail("expected .long for \(raw), got \(String(describing: Primitive.type(of: raw)))")
            }
            XCTAssertEqual(value, raw, "the value survives the promotion intact")
        }

        // and — a platform `Int` is always long, so it cannot overflow int32 either
        guard case .long = Primitive.type(of: Int(aboveMax)) else {
            return XCTFail("expected Int to classify as .long")
        }

        // and — an in-range Int32 still classifies as integer
        guard case .integer(let small) = Primitive.type(of: Int32(42)) else {
            return XCTFail("expected .integer for an Int32")
        }
        XCTAssertEqual(small, 42)
    }

    /// Parity guard for yorkie-js-sdk#1326 ("Reject integers outside the
    /// int64 range instead of wrapping"). JS represents `Long` as an
    /// arbitrary-precision `number`/`bigint` at the API boundary, so a value
    /// past 2^63-1 or below -2^63 could reach `bigintToBytesLE` and silently
    /// wrap via `BigInt.asUintN(64, ...)`, diverging writer and remote peers.
    ///
    /// Swift cannot express that bug: `PrimitiveValue.long` only ever takes a
    /// statically-typed `Int64`, whose bit width IS the int64 range enforced
    /// by the hardware/language — there is no wider integer type upstream of
    /// it that could hold an out-of-range value to wrap. One past either
    /// boundary is not a value that type-checks as `Int64` at all (a literal
    /// there is a compile error, and `Int64.max + 1` traps at runtime rather
    /// than wrapping), so there is no `isWithinInt64Range` guard to add. This
    /// pins the int64 boundary itself, mirroring the one portable upstream
    /// case ("accept the int64 boundary and reject one past it").
    func test_accepts_the_int64_boundary_losslessly() throws {
        // given — the exact boundaries of the represented range
        let maxInt64 = Int64.max
        let minInt64 = Int64.min

        // when
        let maxPrimitive = Primitive(value: .long(maxInt64), createdAt: TimeTicket.initial)
        let minPrimitive = Primitive(value: .long(minInt64), createdAt: TimeTicket.initial)

        // then — both round-trip losslessly through the wire encoding
        guard case .long(let maxValue) = try Converter.valueFrom(.long, data: maxPrimitive.toBytes()) else {
            return XCTFail("expected .long for the int64 max boundary")
        }
        XCTAssertEqual(maxValue, maxInt64)

        guard case .long(let minValue) = try Converter.valueFrom(.long, data: minPrimitive.toBytes()) else {
            return XCTFail("expected .long for the int64 min boundary")
        }
        XCTAssertEqual(minValue, minInt64)
    }
}
