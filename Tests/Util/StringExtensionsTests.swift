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

class StringExtensionsTests: XCTestCase {
    func test_sub_string() {
        let result = "0123456789".substring(from: 2, to: 5)
        XCTAssertEqual(result, "2345")
    }

    func test_sub_string_3() {
        let result = "0123456789".substring(from: 2, to: 2)
        XCTAssertEqual(result, "2")
    }

    func test_sub_string_2() {
        let result = "0123456789".substring(from: 2, to: 100)
        XCTAssertEqual(result, "23456789")
    }
}
