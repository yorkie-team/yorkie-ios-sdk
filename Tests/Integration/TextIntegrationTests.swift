/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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

final class TextIntegrationTests: XCTestCase {
    @MainActor
    func test_should_handle_edit_operations() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "ABCD")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"ABCD\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "1234")
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"1234\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_should_handle_concurrent_edit_operations() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(0, 0, "ABCD")
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"ABCD\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(0, 0, "1234")
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"1234\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(2, 3, "XX")
            }

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(2, 3, "YY")
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(4, 5, "ZZ")
            }

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(2, 3, "TT")
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_should_handle_concurrent_insertion_and_deletion() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "AB")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"AB\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(0, 2, "")
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(1, 1, "C")
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"A\"},{\"val\":\"C\"},{\"val\":\"B\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"C\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_should_handle_concurrent_block_deletions() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "123")
                (root.k1 as? JSONText)?.edit(3, 3, "456")
                (root.k1 as? JSONText)?.edit(6, 6, "789")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"123\"},{\"val\":\"456\"},{\"val\":\"789\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(1, 7, "")
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"1\"},{\"val\":\"89\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(2, 5, "")
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"12\"},{\"val\":\"6\"},{\"val\":\"789\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_should_maintain_the_correct_weight_for_nodes_newly_created_then_concurrently_removed() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
            }

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(0, 0, "O")
                (root.k1 as? JSONText)?.edit(1, 1, "O")
                (root.k1 as? JSONText)?.edit(2, 2, "O")
            }

            try await c1.sync()
            try await c2.sync()

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(1, 2, "X")
                (root.k1 as? JSONText)?.edit(1, 2, "X")
                (root.k1 as? JSONText)?.edit(1, 2, "")
            }

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(0, 3, "N")
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            let d1Check = await(d1.getRoot().k1 as? JSONText)?.getTreeByIndex()?.checkWeight() ?? false
            let d2Check = await(d2.getRoot().k1 as? JSONText)?.getTreeByIndex()?.checkWeight() ?? false
            XCTAssertTrue(d1Check)
            XCTAssertTrue(d2Check)
        }
    }
}

final class TextIntegrationConcurrentTests: XCTestCase {
    @MainActor
    func test_ex1_concurrent_insertions_on_plain_text() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "The fox jumped.")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The fox jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(4, 4, "quick ")
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The \"},{\"val\":\"quick \"},{\"val\":\"fox jumped.\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(14, 14, " over the dog")
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"The fox jumped\"},{\"val\":\" over the dog\"},{\"val\":\".\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The \"},{\"val\":\"quick \"},{\"val\":\"fox jumped\"},{\"val\":\" over the dog\"},{\"val\":\".\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_ex2_concurrent_formatting_and_insertion() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "The fox jumped.")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The fox jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(0, 15, ["bold": true])
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The fox jumped.\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(4, 4, "brown ")
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"The \"},{\"val\":\"brown \"},{\"val\":\"fox jumped.\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, d2JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The \"},{\"val\":\"brown \"},{\"attrs\":{\"bold\":true},\"val\":\"fox jumped.\"}]}")
        }
    }

    @MainActor
    func test_ex3_overlapping_formatting_bold() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "The fox jumped.")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The fox jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(0, 7, ["bold": true])
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The fox\"},{\"val\":\" jumped.\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(4, 15, ["bold": true])
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"The \"},{\"attrs\":{\"bold\":true},\"val\":\"fox jumped.\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The \"},{\"attrs\":{\"bold\":true},\"val\":\"fox\"},{\"attrs\":{\"bold\":true},\"val\":\" jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_ex4_overlapping_different_formatting_bold_and_italic() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "The fox jumped.")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The fox jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(0, 7, ["bold": true])
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The fox\"},{\"val\":\" jumped.\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(4, 15, ["italic": true])
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"The \"},{\"attrs\":{\"italic\":true},\"val\":\"fox jumped.\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The \"},{\"attrs\":{\"bold\":true,\"italic\":true},\"val\":\"fox\"},{\"attrs\":{\"italic\":true},\"val\":\" jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_ex5_conflicting_overlaps_highlighting() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "The fox jumped.")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The fox jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(0, 7, ["highlight": "red"])
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"highlight\":\"red\"},\"val\":\"The fox\"},{\"val\":\" jumped.\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(4, 15, ["highlight": "blue"])
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"The \"},{\"attrs\":{\"highlight\":\"blue\"},\"val\":\"fox jumped.\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"highlight\":\"red\"},\"val\":\"The \"},{\"attrs\":{\"highlight\":\"blue\"},\"val\":\"fox\"},{\"attrs\":{\"highlight\":\"blue\"},\"val\":\" jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    // ex6. conflicting overlaps(bold) - 1
    @MainActor
    func test_ex6_conflicting_overlaps_bold() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "The fox jumped.")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The fox jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(0, 15, ["bold": true])
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The fox jumped.\"}]}")

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(4, 15, ["bold": false])
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The \"},{\"attrs\":{\"bold\":false},\"val\":\"fox jumped.\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(8, 15, ["bold": true])
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"The fox \"},{\"attrs\":{\"bold\":true},\"val\":\"jumped.\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The \"},{\"attrs\":{\"bold\":false},\"val\":\"fox \"},{\"attrs\":{\"bold\":true},\"val\":\"jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_ex6_conflicting_overlaps_bold_2() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "The fox jumped.")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The fox jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(0, 15, ["bold": true])
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The fox jumped.\"}]}")

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(4, 15, ["bold": false])
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The \"},{\"attrs\":{\"bold\":false},\"val\":\"fox jumped.\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(8, 15, ["bold": true])
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"attrs\":{\"bold\":true},\"val\":\"The \"},{\"attrs\":{\"bold\":false},\"val\":\"fox \"},{\"attrs\":{\"bold\":true},\"val\":\"jumped.\"}]}")

            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_ex7_multiple_instances_of_the_same_mark() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "The fox jumped.")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The fox jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(0, 7, ["comment": "Alice's comment"])
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"comment\":\"Alice's comment\"},\"val\":\"The fox\"},{\"val\":\" jumped.\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.setStyle(4, 15, ["comment": "Bob's comment"])
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"The \"},{\"attrs\":{\"comment\":\"Bob's comment\"},\"val\":\"fox jumped.\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"attrs\":{\"comment\":\"Alice's comment\"},\"val\":\"The \"},{\"attrs\":{\"comment\":\"Bob's comment\"},\"val\":\"fox\"},{\"attrs\":{\"comment\":\"Bob's comment\"},\"val\":\" jumped.\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_ex8_text_insertion_at_span_boundaries_bold() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "The fox jumped.")
                (root.k1 as? JSONText)?.setStyle(4, 14, ["bold": true])
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The \"},{\"attrs\":{\"bold\":true},\"val\":\"fox jumped\"},{\"val\":\".\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(4, 4, "quick ")
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The \"},{\"val\":\"quick \"},{\"attrs\":{\"bold\":true},\"val\":\"fox jumped\"},{\"val\":\".\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(14, 14, " over the dog")
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"The \"},{\"attrs\":{\"bold\":true},\"val\":\"fox jumped\"},{\"val\":\" over the dog\"},{\"val\":\".\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The \"},{\"val\":\"quick \"},{\"attrs\":{\"bold\":true},\"val\":\"fox jumped\"},{\"val\":\" over the dog\"},{\"val\":\".\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_ex9_text_insertion_at_span_boundaries_link() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "The fox jumped.")
                (root.k1 as? JSONText)?.setStyle(4, 14, ["link": "https://www.google.com/search?q=jumping+fox"])
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The \"},{\"attrs\":{\"link\":\"https://www.google.com/search?q=jumping+fox\"},\"val\":\"fox jumped\"},{\"val\":\".\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(4, 4, "quick ")
            }

            d1JSON = await d1.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The \"},{\"val\":\"quick \"},{\"attrs\":{\"link\":\"https://www.google.com/search?q=jumping+fox\"},\"val\":\"fox jumped\"},{\"val\":\".\"}]}")

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(14, 14, " over the dog")
            }

            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d2JSON, "{\"k1\":[{\"val\":\"The \"},{\"attrs\":{\"link\":\"https://www.google.com/search?q=jumping+fox\"},\"val\":\"fox jumped\"},{\"val\":\" over the dog\"},{\"val\":\".\"}]}")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"The \"},{\"val\":\"quick \"},{\"attrs\":{\"link\":\"https://www.google.com/search?q=jumping+fox\"},\"val\":\"fox jumped\"},{\"val\":\" over the dog\"},{\"val\":\".\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    // causal deletion preserves original timestamps
    @MainActor
    func test_causal_deletion_preserves_original_timestamps() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "abcd")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"abcd\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(1, 3, "")
            }

            try await c1.sync()
            try await c2.sync()

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(0, 2, "")
            }

            func getAllNodes(from doc: Document) async -> RGATreeSplit<CRDTTextValue>? {
                // Access the root and get the text field (k1 in the test)
                guard let text = await doc.getRoot().k1 as? JSONText else {
                    return nil
                }

                // Access the internal RGATreeSplit structure
                // Note: This assumes a similar internal structure in Swift
                let rga = text.text?.rgaTreeSplit

                // Convert the iterator/sequence to an array
                return rga
            }

            let text = await getAllNodes(from: d2)
            let node = text?.makeIterator()
            print("----------------------------")
            var (aNode, bcNode, dNode): (RGATreeSplitNode<CRDTTextValue>?, RGATreeSplitNode<CRDTTextValue>?, RGATreeSplitNode<CRDTTextValue>?) = (nil, nil, nil)
            while let node = node?.next() {
                switch node.value.toString {
                case "a":
                    aNode = node
                case "bc":
                    bcNode = node
                case "d":
                    dNode = node
                default:
                    continue
                }
            }

            XCTAssertTrue(aNode!.removedAt!.after(bcNode!.removedAt!))
            XCTAssertTrue(dNode!.removedAt!.after(bcNode!.removedAt!))

            // Final sync and ensure convergence
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    // concurrent deletion test for LWW behavior
    @MainActor
    func test_concurrent_deletion_test_for_LWW_behavior() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "abcd")
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, "{\"k1\":[{\"val\":\"abcd\"}]}")
            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                (root.k1 as? JSONText)?.edit(1, 3, "")
            }

            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(0, 4, "")
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, d2JSON)

            func getAllNodes(from doc: Document) async -> RGATreeSplit<CRDTTextValue>? {
                // Access the root and get the text field (k1 in the test)
                guard let text = await doc.getRoot().k1 as? JSONText else {
                    return nil
                }

                // Access the internal RGATreeSplit structure
                // Note: This assumes a similar internal structure in Swift
                let rga = text.text?.rgaTreeSplit

                // Convert the iterator/sequence to an array
                return rga
            }

            func checkAllRemove(document: Document) async -> (Bool, Int) {
                let text = await getAllNodes(from: document)
                let node = text?.makeIterator()
                var timeStampSet = Set<String>()
                while let node = node?.next() {
                    if !node.isRemoved, node.createdAt != .initial {
                        return (false, timeStampSet.count)
                    }
                    if let removed = node.removedAt {
                        timeStampSet.insert(removed.toIDString)
                    }
                }
                return (true, timeStampSet.count)
            }
            var removeAllD1 = await checkAllRemove(document: d1)
            var removeAllD2 = await checkAllRemove(document: d2)
            XCTAssertTrue(removeAllD1.0)
            XCTAssertTrue(removeAllD2.0)

            try await c2.sync()
            try await c1.sync()

            removeAllD1 = await checkAllRemove(document: d1)
            removeAllD2 = await checkAllRemove(document: d2)
            XCTAssertTrue(removeAllD2.1 + removeAllD1.1 == 1)
        }
    }
}
