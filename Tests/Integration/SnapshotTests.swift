/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

final class SnapshotTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    func test_should_handle_snapshot() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // 01. Updates changes over snapshot threshold.
            for idx in 0 ..< defaultSnapshotThreshold {
                try await d1.update { root, _ in
                    root["\(idx)"] = Int32(idx)
                }
            }
            try await c1.sync()

            // 02. Makes local changes then pull a snapshot from the agent.
            try await d2.update { root, _ in
                root["key"] = "value"
            }
            try await c2.sync()

            let value = await d2.getRoot()["key"] as? String
            XCTAssertEqual(value, "value")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            let d1JSON = await d1.toSortedJSON()
            let d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    func test_should_handle_snapshot_for_text_object() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            for _ in 0 ..< defaultSnapshotThreshold {
                try await d1.update { root, _ in
                    root.k1 = JSONText()
                }
            }
            try await c1.sync()
            try await c2.sync()

            // 01. Updates changes over snapshot threshold by c1.
            for idx in 0 ..< defaultSnapshotThreshold {
                try await d1.update { root, _ in
                    (root.k1 as? JSONText)?.edit(idx, idx, "x")
                }
            }

            // 02. Makes local change by c2.
            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(0, 0, "o")
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            let d1JSON = await d1.toSortedJSON()
            let d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    func test_should_handle_snapshot_for_text_with_attributes() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "a")
            }
            try await c1.sync()
            try await c2.sync()

            // 01. Updates changes over snapshot threshold by c1.
            for _ in 0 ..< defaultSnapshotThreshold {
                try await d1.update { root, _ in
                    (root.k1 as? JSONText)?.setStyle(0, 1, ["bold": true])
                }
            }

            try await c1.sync()
            try await c2.sync()

            let d1JSON = await d1.toSortedJSON()
            let d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }
}
