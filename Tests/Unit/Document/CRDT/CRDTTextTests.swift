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

        try text.edit(text.indexRangeToPosRange(0, 0), "ABCD", TimeTicket.initial)
        XCTAssertEqual("[{\"val\":\"ABCD\"}]", text.toJSON())

        try text.edit(text.indexRangeToPosRange(1, 3), "12", TimeTicket.initial)
        XCTAssertEqual("[{\"val\":\"A\"},{\"val\":\"12\"},{\"val\":\"D\"}]", text.toJSON())
    }

    func test_should_handle_edit_operations_with_case2() throws {
        let text = CRDTText(rgaTreeSplit: RGATreeSplit(), createdAt: TimeTicket.initial)

        try text.edit(text.indexRangeToPosRange(0, 0), "ABCD", TimeTicket.initial)
        XCTAssertEqual("[{\"val\":\"ABCD\"}]", text.toJSON())

        try text.edit(text.indexRangeToPosRange(3, 3), "\n", TimeTicket.initial)
        XCTAssertEqual("[{\"val\":\"ABC\"},{\"val\":\"\\n\"},{\"val\":\"D\"}]", text.toJSON())
    }

    // An empty version vector is a local change, as yorkie-js-sdk's deleteNodes
    // and the server read it; it must not make every node look unknown.
    func test_should_delete_with_an_empty_version_vector() throws {
        // given
        let text = CRDTText(rgaTreeSplit: RGATreeSplit(), createdAt: TimeTicket.initial)
        let actorID = "000000000000000000000001"
        try text.edit(text.indexRangeToPosRange(0, 0), "ABCD", TimeTicket(lamport: 1, delimiter: 0, actorID: actorID))

        // when
        try text.edit(text.indexRangeToPosRange(1, 3), "",
                      TimeTicket(lamport: 2, delimiter: 0, actorID: actorID), nil, VersionVector())

        // then
        XCTAssertEqual("[{\"val\":\"A\"},{\"val\":\"D\"}]", text.toJSON())
    }
}
