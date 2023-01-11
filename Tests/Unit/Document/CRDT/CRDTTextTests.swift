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

final class CRDTTextTests: XCTestCase {
    func test_should_handle_edit_operations_with_case1() throws {
        let text = CRDTText(rgaTreeSplit: RGATreeSplit(), createdAt: TimeTicket.initial)

        try text.edit(try text.createRange(0, 0), "ABCD", TimeTicket.initial)
        XCTAssertEqual("[{\"attrs\":{},\"val\":\"\"},{\"attrs\":{},\"val\":\"ABCD\"}]", text.toJSON())

        try text.edit(try text.createRange(1, 3), "12", TimeTicket.initial)
        XCTAssertEqual("[{\"attrs\":{},\"val\":\"\"},{\"attrs\":{},\"val\":\"A\"},{\"attrs\":{},\"val\":\"12\"},{\"attrs\":{},\"val\":\"D\"}]", text.toJSON())
    }

    func test_should_handle_edit_operations_with_case2() throws {
        let text = CRDTText(rgaTreeSplit: RGATreeSplit(), createdAt: TimeTicket.initial)

        try text.edit(try text.createRange(0, 0), "ABCD", TimeTicket.initial)
        XCTAssertEqual("[{\"attrs\":{},\"val\":\"\"},{\"attrs\":{},\"val\":\"ABCD\"}]", text.toJSON())

        try text.edit(try text.createRange(3, 3), "\n", TimeTicket.initial)
        XCTAssertEqual("[{\"attrs\":{},\"val\":\"\"},{\"attrs\":{},\"val\":\"ABC\"},{\"attrs\":{},\"val\":\"\\n\"},{\"attrs\":{},\"val\":\"D\"}]", text.toJSON())
    }
}
