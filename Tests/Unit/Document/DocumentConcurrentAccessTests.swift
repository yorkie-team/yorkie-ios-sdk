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

import Combine
import XCTest
@testable import Yorkie

class DocumentConcurrentAccessTests: XCTestCase {
    func test_there_is_no_race_condition() async throws {
        let testLoopCount = 500
        let expect = expectation(description: "")
        expect.expectedFulfillmentCount = 5 * testLoopCount

        let target = Document(key: "doc-1")

        for index in 0 ..< testLoopCount {
            Task.detached(priority: .utility) {
                try await target.update { root, _ in
                    root.k1 = "\(index)"
                }

                expect.fulfill()
            }

            Task.detached(priority: .userInitiated) {
                try await target.update { root, _ in
                    root.k1 = "\(index)"
                }

                expect.fulfill()
            }

            Task.detached(priority: .low) {
                try await target.update { root, _ in
                    root.k1 = "\(index)"
                }

                expect.fulfill()
            }

            Task.detached(priority: .high) {
                try await target.update { root, _ in
                    root.k1 = "\(index)"
                }

                expect.fulfill()
            }

            Task.detached(priority: .background) {
                try await target.update { root, _ in
                    root.k1 = "\(index)"
                }

                expect.fulfill()
            }
        }

        await fulfillment(of: [expect], timeout: 5, enforceOrder: true)
    }
}
