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

import Combine
import XCTest
@testable import Yorkie

final class JSONTextTest: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    // swiftlint: disable force_cast
    func test_should_handle_edit_operations() async throws {
        let doc = Document(key: "test-doc")

        var docContent = await doc.toSortedJSON()
        XCTAssertEqual("{}", docContent)

        //           ------ ins links ----
        //           |            |      |
        // [init] - [A] - [12] - {BC} - [D]
        try await doc.update { root, _ in
            root.k1 = JSONText()
            (root.k1 as? JSONText)?.edit(0, 0, "ABCD")
            (root.k1 as? JSONText)?.edit(1, 3, "12")
        }

        try await doc.update { root, _ in
            XCTAssertEqual("[0:00:0:0 ][1:00:2:0 A][1:00:3:0 12]{1:00:2:1 BC}[1:00:2:3 D]", (root.k1 as? JSONText)?.toTestString)

            var range = (root.k1 as? JSONText)?.createRangeForTest(0, 0)
            XCTAssertEqual("0:00:0:0:0", range?.0.toTestString)

            range = (root.k1 as? JSONText)!.createRangeForTest(1, 1)
            XCTAssertEqual("1:00:2:0:1", range?.0.toTestString)

            range = (root.k1 as? JSONText)!.createRangeForTest(2, 2)
            XCTAssertEqual("1:00:3:0:1", range?.0.toTestString)

            range = (root.k1 as? JSONText)!.createRangeForTest(3, 3)
            XCTAssertEqual("1:00:3:0:2", range?.0.toTestString)

            range = (root.k1 as? JSONText)!.createRangeForTest(4, 4)
            XCTAssertEqual("1:00:2:3:1", range?.0.toTestString)
        }

        docContent = await doc.toSortedJSON()

        XCTAssertEqual("{\"k1\":[{\"val\":\"A\"},{\"val\":\"12\"},{\"val\":\"D\"}]}", docContent)
    }

    func test_should_handle_edit_operations2() async throws {
        let doc = Document(key: "test-doc")

        var docContent = await doc.toSortedJSON()
        XCTAssertEqual("{}", docContent)

        //           -- ins links ---
        //           |              |
        // [init] - [ABC] - [\n] - [D]
        try await doc.update { root, _ in
            root.k1 = JSONText()
            (root.k1 as? JSONText)?.edit(0, 0, "ABCD")
            (root.k1 as? JSONText)?.edit(3, 3, "\n")
        }

        try await doc.update { root, _ in
            XCTAssertEqual(
                "[0:00:0:0 ][1:00:2:0 ABC][1:00:3:0 \n][1:00:2:3 D]",
                (root.k1 as? JSONText)?.toTestString
            )
        }

        docContent = await doc.toSortedJSON()
        XCTAssertEqual("{\"k1\":[{\"val\":\"ABC\"},{\"val\":\"\\n\"},{\"val\":\"D\"}]}", docContent)
    }

    func test_should_handle_type_하늘() async throws {
        let doc = Document(key: "test-doc")

        var docContent = await doc.toSortedJSON()
        XCTAssertEqual("{}", docContent)

        try await doc.update { root, _ in
            root.k1 = JSONText()
            (root.k1 as? JSONText)?.edit(0, 0, "ㅎ")
            (root.k1 as? JSONText)?.edit(0, 1, "하")
            (root.k1 as? JSONText)?.edit(0, 1, "한")
            (root.k1 as? JSONText)?.edit(0, 1, "하")
            (root.k1 as? JSONText)?.edit(1, 1, "느")
            (root.k1 as? JSONText)?.edit(1, 2, "늘")
        }

        docContent = await doc.toSortedJSON()
        XCTAssertEqual("{\"k1\":[{\"val\":\"하\"},{\"val\":\"늘\"}]}", docContent)
    }

    func test_should_handle_deletion_of_nested_nodes() async throws {
        let doc = Document(key: "test-doc")
        let view = TextView()

        try await doc.update { root, _ in root.text = JSONText() }

        await doc.subscribe("$.text") {
            view.applyChanges(operations: ($0 as! ChangeEvent).value.operations)
        }

        let commands: [(from: Int, to: Int, content: String)] = [
            (from: 0, to: 0, content: "ABC"),
            (from: 3, to: 3, content: "DEF"),
            (from: 2, to: 4, content: "1"),
            (from: 1, to: 4, content: "2")
        ]

        for cmd in commands {
            try await doc.update { root, _ in
                (root.text as? JSONText)?.edit(cmd.from, cmd.to, cmd.content)
            }

            let text = await(doc.getRoot()["text"] as? JSONText)?.plainText
            XCTAssertEqual(view.toString, text)
        }
    }

    func test_should_handle_deletion_of_the_last_nodes() async throws {
        let doc = Document(key: "test-doc")
        let view = TextView()

        try await doc.update { root, _ in root.text = JSONText() }

        await doc.subscribe("$.text") {
            view.applyChanges(operations: ($0 as! ChangeEvent).value.operations)
        }

        let commands: [(from: Int, to: Int, content: String)] = [
            (from: 0, to: 0, content: "A"),
            (from: 1, to: 1, content: "B"),
            (from: 2, to: 2, content: "C"),
            (from: 3, to: 3, content: "DE"),
            (from: 5, to: 5, content: "F"),
            (from: 6, to: 6, content: "GHI"),
            (from: 9, to: 9, content: ""), // delete no last node
            (from: 8, to: 9, content: ""), // delete one last node with split
            (from: 6, to: 8, content: ""), // delete one last node without split
            (from: 4, to: 6, content: ""), // delete last nodes with split
            (from: 2, to: 4, content: ""), // delete last nodes without split
            (from: 0, to: 2, content: "") // delete last nodes containing the first
        ]

        for cmd in commands {
            try await doc.update { root, _ in
                (root.text as? JSONText)?.edit(cmd.from, cmd.to, cmd.content)
            }

            let text = await(doc.getRoot()["text"] as? JSONText)?.plainText
            XCTAssertEqual(view.toString, text)
        }
    }

    func test_should_handle_deletion_with_boundary_nodes_already_removed() async throws {
        let doc = Document(key: "test-doc")
        let view = TextView()

        try await doc.update { root, _ in root.text = JSONText() }

        await doc.subscribe("$.text") {
            view.applyChanges(operations: ($0 as! ChangeEvent).value.operations)
        }

        let commands: [(from: Int, to: Int, content: String)] = [
            (from: 0, to: 0, content: "1A1BCXEF1"),
            (from: 8, to: 9, content: ""),
            (from: 2, to: 3, content: ""),
            (from: 0, to: 1, content: ""), // ABCXEF
            (from: 0, to: 1, content: ""), // delete A with two removed boundaries
            (from: 0, to: 1, content: ""), // delete B with removed left boundary
            (from: 3, to: 4, content: ""), // delete F with removed right boundary
            (from: 1, to: 2, content: ""),
            (from: 0, to: 2, content: "") // delete CE with removed inner node X
        ]

        for cmd in commands {
            try await doc.update { root, _ in
                (root.text as? JSONText)?.edit(cmd.from, cmd.to, cmd.content)
            }

            let text = await(doc.getRoot()["text"] as? JSONText)?.plainText
            XCTAssertEqual(view.toString, text)
        }
    }

    func test_should_handle_select_operations() async throws {
        let doc = Document(key: "test-doc")

        try await doc.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "ABCD")
        }

        await doc.subscribe("$.text") { event in
            XCTAssertEqual((event as! ChangeEvent).value.operations[0] as! SelectOpInfo, SelectOpInfo(path: "$.text", from: 2, to: 4))
        }
    }

    func test_should_handle_rich_text_edit_operations() async throws {
        let doc = Document(key: "test-doc")

        var docContent = await doc.toSortedJSON()
        XCTAssertEqual("{}", docContent)

        try await doc.update { root, _ in
            root.k1 = JSONText()
            (root.k1 as? JSONText)?.edit(0, 0, "ABCD", ["b": 1])
            (root.k1 as? JSONText)?.edit(3, 3, "\n")
        }

        try await doc.update { root, _ in
            XCTAssertEqual("[0:00:0:0 ][1:00:2:0 ABC][1:00:3:0 \n][1:00:2:3 D]",
                           (root.k1 as? JSONText)?.toTestString)
        }

        docContent = await doc.toSortedJSON()
        XCTAssertEqual("{\"k1\":[{\"attrs\":{\"b\":1},\"val\":\"ABC\"},{\"val\":\"\\n\"},{\"attrs\":{\"b\":1},\"val\":\"D\"}]}",
                       docContent)
    }
    // swiftlint: enable force_cast
}
