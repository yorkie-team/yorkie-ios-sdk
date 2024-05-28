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

class StringEscapingTests: XCTestCase {
    func test_can_escape_string() {
        let target = "1\\2\"3'4\n5\r6\t7\u{0008}8\u{000C}9\u{2028}0\u{2029}"
        let escaped = "1\\\\2\\\"3\\'4\\n5\\r6\\t7\\b8\\f9\\u20280\\u2029"

        XCTAssertEqual(target.escaped(), escaped)
        XCTAssertEqual(escaped.unescaped(), target)
    }

    func test_can_escape_string_2() {
        let target = "\\n"
        let escaped = "\\\\n"

        XCTAssertEqual(target.escaped(), escaped)
        XCTAssertEqual(escaped.unescaped(), target)
    }

    func test_can_escape_string_3() {
        let target = "\\\\\\t"
        let escaped = "\\\\\\\\\\\\t"

        XCTAssertEqual(target.escaped(), escaped)
        XCTAssertEqual(escaped.unescaped(), target)
    }

    func test_can_escape_string_4() {
        let target = "\\\\\\\t"
        let escaped = "\\\\\\\\\\\\\\t"

        XCTAssertEqual(target.escaped(), escaped)
        XCTAssertEqual(escaped.unescaped(), target)
    }

    func test_can_escape_string_5() {
        let target = "\\u{000C}"
        let escaped = "\\\\u{000C}"

        XCTAssertEqual(target.escaped(), escaped)
        XCTAssertEqual(escaped.unescaped(), target)
    }

    func test_can_escape_string_6() {
        let target = "\u{000C}"
        let escaped = "\\f"

        XCTAssertEqual(target.escaped(), escaped)
        XCTAssertEqual(escaped.unescaped(), target)
    }
}
