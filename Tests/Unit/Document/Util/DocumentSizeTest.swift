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

final class DocumentSizeTest: XCTestCase {
    var doc: Document!
    override func setUp() {
        self.doc = .init(key: "test-doc")
        super.setUp()
    }

    override func tearDown() {
        self.doc = nil
        super.tearDown()
    }
}

// MARK: - Helpers

extension DocumentSizeTest {
    func expectLive(with dataSize: DataSize) async {
        let size = await self.doc.getDocSize().live
        XCTAssertEqual(size, dataSize)
    }

    func expectGC(with dataSize: DataSize) async {
        let size = await self.doc.getDocSize().gc
        XCTAssertEqual(size, dataSize)
    }
}

extension DocumentSizeTest {
    // split tree node test
    func test_split_tree_node_test() async throws {
        let root = CRDTTreeNode(id: .initial, type: "r", children: [])
        let para = CRDTTreeNode(id: .initial, type: "p", children: [])

        try root.append(contentsOf: [para])
        try para.append(contentsOf: [.init(id: .initial, type: "text", value: "helloworld")])

        guard let left = para.children.first else { fatalError() }

        let (rightText, difftext) = try left.splitText(5, 0)
        XCTAssertEqual(difftext, .init(data: 0, meta: 24))
        XCTAssertEqual(left.getDataSize(), .init(data: 10, meta: 24))
        XCTAssertEqual(rightText?.getDataSize(), .init(data: 10, meta: 24))

        let (rightElem, diffElem) = try para.splitElement(1, .initial)
        XCTAssertEqual(diffElem, .init(data: 0, meta: 24))
        XCTAssertEqual(rightElem!.toXML, "<p>world</p>")
        XCTAssertEqual(para.toXML, "<p>hello</p>")
    }

    // this test case must be skipped due to uncorrect from  JS (skipped also)
    // refactor split element later on!
    // split tree node with attribute test
    func skip_test_split_tree_node_with_attribute_test() async throws {
        // TODO(raararaara): We need to check if the attributes are copied correctly when splitting elements.
        let attributes = RHT()

        attributes.set(key: "bold", value: "true", executedAt: .initial)

        let root = CRDTTreeNode(id: .initial, type: "r")
        let para = CRDTTreeNode(id: .initial, type: "p", children: nil, attributes: attributes)

        try root.append(contentsOf: [para])
        try para.append(contentsOf: [CRDTTreeNode(id: .initial, type: "text", value: "helloworld")])

        XCTAssertEqual(root.toXML, "<r><p bold=\"true\">helloworld</p></r>")

        // split text node
        guard let left = para.children.first else { fatalError() }

        _ = try left.splitText(5, 0)

        // split element node
        let (rightElem, diffElem) = try para.splitElement(1, .initial)
        XCTAssertEqual(diffElem, .init(data: 0, meta: 24))
        XCTAssertEqual(rightElem!.toXML, "<p bold=\"true\">world</p>")
        XCTAssertEqual(para.toXML, "<p bold=\"true\">hello</p>")
    }

    func test_if_primitive_type_has_correct_live_size() async throws {
        try await self.doc.update({ root, _ in
            root["k0"] = nil
        }, "test NULL")
        await self.expectLive(with: .init(data: 8, meta: 72))

        try await self.doc.update({ root, _ in
            root["k1"] = true
        }, "test BOOL")
        await self.expectLive(with: .init(data: 12, meta: 120))

        try await self.doc.update({ root, _ in
            root["k2"] = Int32(1234)
        }, "test INT 32")
        await self.expectLive(with: .init(data: 16, meta: 168))

        try await self.doc.update({ root, _ in
            root["k3"] = Int64(12345)
        }, "test INT 64")
        await self.expectLive(with: .init(data: 24, meta: 216))

        try await self.doc.update({ root, _ in
            root["k4"] = 1.79
        }, "test DOUBLE")
        await self.expectLive(with: .init(data: 32, meta: 264))

        try await self.doc.update({ root, _ in
            root["k5"] = "40"
        }, "test STRING x2")
        await self.expectLive(with: .init(data: 36, meta: 312))

        try await self.doc.update({ root, _ in
            let byteArray = Data(repeating: .zero, count: 2)
            root["k6"] = byteArray
        }, "test DATA")
        await self.expectLive(with: .init(data: 38, meta: 360))
    }

    // array test
    func test_if_array_type_has_correct_size() async throws {
        try await self.doc.update { root, _ in
            root["arr"] = [String]()
        }
        await self.expectLive(with: .init(data: 0, meta: 72))

        try await self.doc.update { root, _ in
            (root["arr"] as? JSONArray)?.append("a")
        }
        await self.expectLive(with: .init(data: 2, meta: 96))
        await self.expectGC(with: .init(data: 0, meta: 0))

        try await self.doc.update { root, _ in
            (root["arr"] as? JSONArray)?.remove(at: 0)
        }
        await self.expectLive(with: .init(data: 0, meta: 72))
        await self.expectGC(with: .init(data: 2, meta: 48))
    }

    // counter test
    func test_counter_type_has_correct_size() async throws {
        try await self.doc.update { root, _ in
            root["counter"] = JSONCounter(value: Int32(1))
        }
        await self.expectLive(with: .init(data: 4, meta: 72))
    }

    // text test
    func test_text_type_has_correct_size() async throws {
        try await self.doc.update { root, _ in
            root.text = JSONText()
        }
        await self.expectLive(with: .init(data: 0, meta: 72))
        await self.expectGC(with: .init(data: 0, meta: 0))

        try await self.doc.update { root, _ in
            (root.text as? JSONText)?.edit(0, 0, "helloworld")
        }

        await self.expectLive(with: .init(data: 20, meta: 96))
        await self.expectGC(with: .init(data: 0, meta: 0))

        try await self.doc.update { root, _ in
            (root.text as? JSONText)?.edit(5, 5, " ")
        }

        await self.expectLive(with: .init(data: 22, meta: 144))
        await self.expectGC(with: .init(data: 0, meta: 0))

        try await self.doc.update { root, _ in
            (root.text as? JSONText)?.edit(6, 11, "")
        }

        await self.expectLive(with: .init(data: 12, meta: 120))
        await self.expectGC(with: .init(data: 10, meta: 48))

        try await self.doc.update { root, _ in
            (root.text as? JSONText)?.setStyle(0, 5, ["bold": true])
        }

        await self.expectLive(with: .init(data: 28, meta: 144))
        await self.expectGC(with: .init(data: 10, meta: 48))

        try await self.doc.update { root, _ in
            (root.text as? JSONText)?.edit(1, 1, "")

            let text = "[{\"attrs\":{\"bold\":true},\"val\":\"h\"},{\"attrs\":{\"bold\":true},\"val\":\"ello\"},{\"val\":\" \"}]"
            let xml = (root.text as? JSONText)?.toSortedJSON()
            XCTAssertEqual(xml, text)
        }

        await self.expectLive(with: .init(data: 44, meta: 192))
        await self.expectGC(with: .init(data: 10, meta: 48))
    }

    // tree test
    func test_tree_type_has_correct_size() async throws {
        try await self.doc.update { root, _ in
            root.t = JSONTree(initialRoot: .init(type: "doc", children: []))

            try (root.t as? JSONTree)?.edit(0, 0, JSONTreeElementNode(type: "p", children: []))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), "<doc><p></p></doc>")
        }

        await self.expectLive(with: .init(data: 0, meta: 120))
        await self.expectGC(with: .init(data: 0, meta: 0))

        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "helloworld"))

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p>helloworld</p></doc>")
        }

        await self.expectLive(with: .init(data: 20, meta: 144))

        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 7, JSONTreeTextNode(value: "w"))

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p>world</p></doc>")
        }

        await self.expectLive(with: .init(data: 10, meta: 168))
        await self.expectGC(with: .init(data: 12, meta: 48))

        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(
                7, 7,
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeTextNode(value: "abcd")
                ])
            )

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p>world</p><p>abcd</p></doc>")
        }

        await self.expectLive(with: .init(data: 18, meta: 216))
        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(
                7, 13
            )

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p>world</p></doc>")
        }

        await self.expectLive(with: .init(data: 10, meta: 168))
        await self.expectGC(with: .init(data: 20, meta: 144))

        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.style(0, 7, ["bold": true])

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p bold=\"true\">world</p></doc>")
        }

        await self.expectLive(with: .init(data: 26, meta: 192))

        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.removeStyle(0, 7, ["bold"])

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p>world</p></doc>")
        }

        await self.expectLive(with: .init(data: 10, meta: 168))
        // gc gains the tombstone's KEY only (`bold`, 4 chars, 8 bytes): a removed
        // attribute holds no value, so the 8 bytes `true` was charging leave live
        // without arriving in gc. This used to read 36 -- the value counted twice
        // over, once in the tombstone and once in a rebuild it disagreed with
        // (yorkie-js-sdk#1392).
        await self.expectGC(with: .init(data: 28, meta: 168))
    }

    // gc test
    func test_if_primitive_type_has_correct_gc_size() async throws {
        try await self.doc.update { root, _ in
            root["num"] = Int32(1)
            root["str"] = "hello"
        }
        await self.expectLive(with: .init(data: 14, meta: 120))

        try await self.doc.update { root, _ in
            root.remove(key: "num")
        }
        await self.expectLive(with: .init(data: 10, meta: 72))
        await self.expectGC(with: .init(data: 4, meta: 72))
    }

    // deep copy test
    func test_deep_copy() async throws {
        try await self.doc.update { root, _ in
            root.cnt = JSONCounter(value: Int64(1))
        }
        let expectedDocSize = await doc.getDocSize()
        let clone = await doc.cloned.root.deepcopy()
        let cloneSize = clone.getDocSize()
        XCTAssertEqual(expectedDocSize, cloneSize)
    }

    // deep copy for nested element test
    func test_deep_copy_for_nested_element() async throws {
        try await self.doc.update { root, _ in
            root["arr"] = [JSONCounter<Int32>(value: 0)]
        }
        let expectedDocSize = await doc.getDocSize()
        let clone = await doc.cloned.root.deepcopy()
        let cloneSize = clone.getDocSize()
        XCTAssertEqual(expectedDocSize, cloneSize)
    }

    func test_accounts_for_the_element_a_split_creates() async throws {
        // A split mints a new element node, and the phase that does it dropped
        // the size its own `split` call reported, so live never carried it. A
        // split and the merge that undoes it then did not cancel out: live.meta
        // walked down by a ticket per cycle, without bound. Tracked as
        // yorkie-team/yorkie#1998.
        try await self.doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "span", children: [JSONTreeTextNode(value: "abcdefghij")])
                    ])
                ])
            )
        }
        var size = await self.doc.getDocSize()
        XCTAssertEqual(size.live, DataSize(data: 20, meta: 168))

        // Split after `a`: a new <span> and a text split, one ticket each.
        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 0, 1], nil, 1)
        }
        var xml = await(self.doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(xml, "<doc><p><span>a</span><span>bcdefghij</span></p></doc>")
        size = await self.doc.getDocSize()
        XCTAssertEqual(size.live, DataSize(data: 20, meta: 216))

        // Merge the boundary back. The <span> the split created is tombstoned, so
        // its size moves to gc. The text stays two nodes, which is why live keeps
        // the ticket the text split added rather than returning to its pre-split
        // value -- the expectation #1998 states.
        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 1, 0])
        }
        xml = await(self.doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(xml, "<doc><p><span>abcdefghij</span></p></doc>")
        size = await self.doc.getDocSize()
        XCTAssertEqual(size.live, DataSize(data: 20, meta: 192))
        XCTAssertEqual(size.gc, DataSize(data: 0, meta: 48))

        // Every further cycle needs no text split, so live returns to the same
        // two values instead of drifting.
        for _ in 0 ..< 100 {
            try await self.doc.update { root, _ in
                try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 0, 1], nil, 1)
            }
            size = await self.doc.getDocSize()
            XCTAssertEqual(size.live, DataSize(data: 20, meta: 216))
            try await self.doc.update { root, _ in
                try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 1, 0])
            }
            size = await self.doc.getDocSize()
            XCTAssertEqual(size.live, DataSize(data: 20, meta: 192))
        }
    }

    func test_charges_live_only_for_attribute_values_it_was_holding() async throws {
        // RHT mints a tombstone even for a key the element never carried -- so a
        // remove arriving before its set still wins -- and supersedes an existing
        // tombstone when the same key is removed twice or set again. None of
        // those replace a live value, yet live was debited for each, so toggling
        // one key walked it down without bound and eventually negative, at which
        // point the document size limit stops applying.
        func newDoc() async throws -> Document {
            let doc = Document(key: "test-doc")
            try await doc.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abc")])
                    ])
                )
            }
            let size = await doc.getDocSize()
            XCTAssertEqual(size.live, DataSize(data: 6, meta: 144))
            return doc
        }

        let absent = try await newDoc()
        try await absent.update { root, _ in
            try (root.t as? JSONTree)?.removeStyleByPath([0], [1], ["never-set"])
        }
        var size = await absent.getDocSize()
        XCTAssertEqual(size.live, DataSize(data: 6, meta: 144))
        XCTAssertEqual(size.gc, DataSize(data: 18, meta: 24))

        let twice = try await newDoc()
        try await twice.update { root, _ in
            try (root.t as? JSONTree)?.styleByPath([0], [1], ["bold": "true"])
        }
        // 22, not 26: an attribute is charged for its LOGICAL value in UTF-8
        // bytes, so `bold="true"` costs (4 + 4) * 2 = 16 here exactly as it does
        // on the Go side. The old number counted the JSON quotes this SDK adds
        // when it stores the value (yorkie-team/yorkie#2003).
        size = await twice.getDocSize()
        XCTAssertEqual(size.live, DataSize(data: 22, meta: 168))
        for _ in 0 ..< 2 {
            try await twice.update { root, _ in
                try (root.t as? JSONTree)?.removeStyleByPath([0], [1], ["bold"])
            }
            size = await twice.getDocSize()
            XCTAssertEqual(size.live, DataSize(data: 6, meta: 144))
        }

        // Toggling was already correct here -- the restyle credits live for the
        // node it revives, which cancels the debit -- and has to stay that way.
        let toggled = try await newDoc()
        for _ in 0 ..< 100 {
            try await toggled.update { root, _ in
                try (root.t as? JSONTree)?.styleByPath([0], [1], ["bold": "true"])
            }
            size = await toggled.getDocSize()
            XCTAssertEqual(size.live, DataSize(data: 22, meta: 168))
            try await toggled.update { root, _ in
                try (root.t as? JSONTree)?.removeStyleByPath([0], [1], ["bold"])
            }
            size = await toggled.getDocSize()
            XCTAssertEqual(size.live, DataSize(data: 6, meta: 144))
        }
    }
}
