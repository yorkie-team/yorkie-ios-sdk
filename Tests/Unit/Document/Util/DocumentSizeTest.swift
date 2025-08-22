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
        
        XCTAssertEqual(root.toXML, "<r><p bold=true>helloworld</p></r>")
        
        // split text node
        guard let left = para.children.first else { fatalError() }
        
        let (_, _) = try left.splitText(5, 0)
        
        // split element node
        let (rightElem, diffElem) = try para.splitElement(1, .initial)
        XCTAssertEqual(diffElem, .init(data: 0, meta: 24))
        XCTAssertEqual(rightElem!.toXML, "<p bold=true>world</p>")
        XCTAssertEqual(para.toXML, "<p bold=true>hello</p>")
    }
    
    func test_if_primitive_type_has_correct_live_size() async throws {
        try await self.doc.update({ root, _ in
            root["k0"] = nil
        }, "test NULL")
        await self.expectLive(with: .init(data: 8, meta: 48))

        try await self.doc.update({ root, _ in
            root["k1"] = true
        }, "test BOOL")
        await self.expectLive(with: .init(data: 12, meta: 72))

        try await self.doc.update({ root, _ in
            root["k2"] = Int32(1234)
        }, "test INT 32")
        await self.expectLive(with: .init(data: 16, meta: 96))

        try await self.doc.update({ root, _ in
            root["k3"] = Int64(12345)
        }, "test INT 64")
        await self.expectLive(with: .init(data: 24, meta: 120))

        try await self.doc.update({ root, _ in
            root["k4"] = 1.79
        }, "test DOUBLE")
        await self.expectLive(with: .init(data: 32, meta: 144))

        try await self.doc.update({ root, _ in
            root["k5"] = "40"
        }, "test STRING x2")
        await self.expectLive(with: .init(data: 36, meta: 168))

        try await self.doc.update({ root, _ in
            let byteArray = Data(repeating: .zero, count: 2)
            root["k6"] = byteArray
        }, "test DATA")
        await self.expectLive(with: .init(data: 38, meta: 192))
    }

    // array test
    func test_if_array_type_has_correct_size() async throws {
        try await self.doc.update { root, _ in
            root["arr"] = [String]()
        }
        await self.expectLive(with: .init(data: 0, meta: 48))

        try await self.doc.update { root, _ in
            (root["arr"] as? JSONArray)?.append("a")
        }
        await self.expectLive(with: .init(data: 2, meta: 72))
        await self.expectGC(with: .init(data: 0, meta: 0))

        try await self.doc.update { root, _ in
            (root["arr"] as? JSONArray)?.remove(at: 0)
        }
        await self.expectLive(with: .init(data: 0, meta: 48))
        await self.expectGC(with: .init(data: 2, meta: 48))
    }

    // gc test
    func test_if_primitive_type_has_correct_gc_size() async throws {
        try await self.doc.update { root, _ in
            root["num"] = Int32(1)
            root["str"] = "hello"
        }
        await self.expectLive(with: .init(data: 14, meta: 72))

        try await self.doc.update { root, _ in
            root.remove(key: "num")
        }
        await self.expectLive(with: .init(data: 10, meta: 48))
        await self.expectGC(with: .init(data: 4, meta: 48))
    }

    // counter test
    func test_counter_type_has_correct_size() async throws {
        try await self.doc.update { root, _ in
            root["counter"] = JSONCounter(value: Int32(1))
        }
        await self.expectLive(with: .init(data: 4, meta: 48))
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
            
            let text = """
                [{\"attrs\":{\"bold\":true},\"val\":\"h\"},{\"attrs\":{\"bold\":true},\"val\":\"ello\"},{\"val\":\" \"}]
                """
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

        await self.expectLive(with: .init(data: 0, meta: 96))
        await self.expectGC(with: .init(data: 0, meta: 0))

        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "helloworld"))

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p>helloworld</p></doc>")
        }

        await self.expectLive(with: .init(data: 20, meta: 120))

        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 7, JSONTreeTextNode(value: "w"))

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p>world</p></doc>")
        }

        await self.expectLive(with: .init(data: 10, meta: 144))
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

        await self.expectLive(with: .init(data: 18, meta: 192))
        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(
                7, 13
            )

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p>world</p></doc>")
        }

        await self.expectLive(with: .init(data: 10, meta: 144))
        await self.expectGC(with: .init(data: 20, meta: 144))

        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.style(0, 7, ["bold": true])

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p bold=true>world</p></doc>")
        }

        await self.expectLive(with: .init(data: 26, meta: 168))

        try await self.doc.update { root, _ in
            try (root.t as? JSONTree)?.removeStyle(0, 7, ["bold"])

            let xml = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(xml, "<doc><p>world</p></doc>")
        }

        await self.expectLive(with: .init(data: 10, meta: 144))
        await self.expectGC(with: .init(data: 36, meta: 168))
    }
}
