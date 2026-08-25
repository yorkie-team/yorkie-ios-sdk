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

final class CRDTCountTests: XCTestCase {
    func test_can_increase_numeric_data_of_counter() throws {
        let int = CRDTCounter(value: Int32(10), createdAt: TimeTicket.initial)
        let long = CRDTCounter(value: Int64(100), createdAt: TimeTicket.initial)

        let intOperand = Primitive(value: .integer(10), createdAt: TimeTicket.initial)
        let longOperand = Primitive(value: .long(100), createdAt: TimeTicket.initial)

        try int.increase(intOperand)
        try long.increase(longOperand)
        XCTAssert(int.value == 20)
        XCTAssert(long.value == 200)

        // error process test
        let errorTest = { (couter: CRDTCounter<Int64>, operand: Primitive) in
            var failed = false
            do {
                try couter.increase(operand)
            } catch {
                failed = true
            }

            XCTAssert(failed == true)
        }

        let str = Primitive(value: .string("hello"), createdAt: TimeTicket.initial)
        let bool = Primitive(value: .boolean(true), createdAt: TimeTicket.initial)
        let data = Primitive(value: .bytes(Data()), createdAt: TimeTicket.initial)
        let date = Primitive(value: .date(Date()), createdAt: TimeTicket.initial)

        errorTest(long, str)
        errorTest(long, bool)
        errorTest(long, data)
        errorTest(long, date)

        // subtraction test
        let negative = Primitive(value: .integer(-50), createdAt: TimeTicket.initial)
        let negativeLong = Primitive(value: .long(-100), createdAt: TimeTicket.initial)
        try int.increase(negative)
        try long.increase(negativeLong)
        XCTAssert(int.value == -30)
        XCTAssert(long.value == 100)
    }

    /// An `Int32` counter increased by an out-of-int32 `Long` must wrap around
    /// rather than trap, so it converges with the JS and Go SDKs.
    func test_can_wrap_around_int_counter_when_increased_by_out_of_int32_long() throws {
        // given
        let counter = CRDTCounter(value: Int32(0), createdAt: TimeTicket.initial)
        let outOfInt32 = Primitive(value: .long(2_147_483_648), createdAt: TimeTicket.initial) // 2^31

        // when
        try counter.increase(outOfInt32)

        // then
        XCTAssertEqual(counter.value, -2_147_483_648)

        // given — a nonzero base: truncating the delta before adding would yield
        // -2147483649, which is not representable in int32.
        let nonZeroBase = CRDTCounter(value: Int32(-1), createdAt: TimeTicket.initial)

        // when
        try nonZeroBase.increase(outOfInt32)

        // then
        XCTAssertEqual(nonZeroBase.value, 2_147_483_647)
    }

    /// A `Long` counter still wraps at 64 bits (JS `BigInt.asIntN(64, …)`).
    func test_can_wrap_around_long_counter_on_int64_overflow() throws {
        // given
        let counter = CRDTCounter(value: Int64.max, createdAt: TimeTicket.initial)

        // when
        try counter.increase(Primitive(value: .integer(1), createdAt: TimeTicket.initial))

        // then
        XCTAssertEqual(counter.value, Int64.min)
    }
}
