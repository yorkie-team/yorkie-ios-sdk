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
}
