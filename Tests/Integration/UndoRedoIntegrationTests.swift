/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

final class UndoRedoIntegrationTests: XCTestCase {
    /// Two clients attach to the same document. Client A edits a shared text field and then
    /// undoes its change while client B concurrently edits the same text. After syncing both
    /// clients their `toSortedJSON()` must converge.
    @MainActor
    func test_can_sync_text_undo_with_concurrent_edits() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — both clients establish a shared text field
            try d1.update { root, _ in
                root.text = JSONText()
                (root.text as? JSONText)?.edit(0, 0, "Hello World")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = d1.toSortedJSON()
            var d2JSON = d2.toSortedJSON()
            XCTAssertEqual(d1JSON, d2JSON)

            // when — c1 appends " from A" and c2 inserts "! " concurrently
            try d1.update { root, _ in
                (root.text as? JSONText)?.edit(11, 11, " from A")
            }

            try d2.update { root, _ in
                (root.text as? JSONText)?.edit(5, 5, "! ")
            }

            // c1 undoes its own addition before syncing
            try d1.undo()

            // sync both clients
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = d1.toSortedJSON()
            d2JSON = d2.toSortedJSON()

            // then — both documents converge to the same state
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }
}
