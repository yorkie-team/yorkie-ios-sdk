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

/**
 * `createChangePack` is a helper function that creates a change pack from the
 * given document. It is used to to emulate the behavior of the server.
 */
func createChangePack(_ doc: Document) async throws -> ChangePack {
    // 01. Create a change pack from the given document and emulate the behavior
    // of PushPullChanges API.
    let reqPack = await doc.createChangePack()
    let reqCP = reqPack.getCheckpoint()
    let resPack = ChangePack(key: reqPack.getDocumentKey(),
                             checkpoint: Checkpoint(serverSeq: reqCP.getServerSeq() + Int64(reqPack.getChangeSize()), clientSeq: reqCP.getClientSeq() + UInt32(reqPack.getChangeSize())),
                             isRemoved: false,
                             changes: [])
    try await doc.applyChangePack(resPack)

    // 02. Create a pack to apply the changes to other replicas.
    return ChangePack(key: reqPack.getDocumentKey(),
                      checkpoint: Checkpoint(serverSeq: reqCP.getServerSeq() + Int64(reqPack.getChangeSize()), clientSeq: 0),
                      isRemoved: false,
                      changes: reqPack.getChanges())
}

/**
 * `createTwoDocuments` is a helper function that creates two documents with
 * the given initial tree.
 */
func createTwoTreeDocs(_ key: String, _ initial: JSONTreeElementNode) async throws -> (Document, Document) {
    let docKey = "\(key)-\(Date().description)".toDocKey

    let doc1 = Document(key: docKey)
    let doc2 = Document(key: docKey)
    await doc1.setActor("A")
    await doc2.setActor("B")

    try await doc1.update { root, _ in
        root.t = JSONTree(initialRoot: initial)
    }

    try await doc2.applyChangePack(createChangePack(doc1))

    return (doc1, doc2)
}

/**
 * `syncTwoTreeDocsAndAssertEqual` is a helper function that syncs two documents
 * and asserts that the given expected tree is equal to the two documents.
 */
func syncTwoTreeDocsAndAssertEqual(_ doc1: Document, _ doc2: Document, _ expected: String) async throws {
    try await doc2.applyChangePack(createChangePack(doc1))
    try await doc1.applyChangePack(createChangePack(doc2))

    let doc1XML = await(doc1.getRoot().t as? JSONTree)?.toXML()
    let doc2XML = await(doc2.getRoot().t as? JSONTree)?.toXML()

    XCTAssertEqual(doc1XML, doc2XML)
    XCTAssertEqual(doc1XML, expected)
}

final class TreeIntegrationTests: XCTestCase {
    func test_can_be_created() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree()
            try (root.t as? JSONTree)?.edit(0, 0, JSONTreeElementNode(type: "p"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p></p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[]}]}}")

            // 02. Create a text into the paragraph.
            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "AB"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>AB</p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"text\",\"value\":\"AB\"}]}]}}")

            // 03. Insert a text into the paragraph.
            try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "CD"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>ABCD</p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"text\",\"value\":\"AB\"},{\"type\":\"text\",\"value\":\"CD\"}]}]}}")

            // 04. Replace ABCD with Yorkie
            try (root.t as? JSONTree)?.edit(1, 5, JSONTreeTextNode(value: "Yorkie"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>Yorkie</p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"text\",\"value\":\"Yorkie\"}]}]}}")
        }
    }

    func test_can_be_created_from_JSON() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc",
                                    children: [JSONTreeElementNode(type: "p",
                                                                   children: [JSONTreeTextNode(value: "ab")]),
                                               JSONTreeElementNode(type: "ng",
                                                                   children: [JSONTreeElementNode(type: "note",
                                                                                                  children: [JSONTreeTextNode(value: "cd")]),
                                                                              JSONTreeElementNode(type: "note",
                                                                                                  children: [JSONTreeTextNode(value: "ef")])]),
                                               JSONTreeElementNode(type: "bp",
                                                                   children: [JSONTreeTextNode(value: "gh")])]))

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p><ng><note>cd</note><note>ef</note></ng><bp>gh</bp></doc>")
            XCTAssertEqual(try? (root.t as? JSONTree)?.getSize() ?? 0, 18)
        }
    }

    func test_can_be_created_from_JSON_with_attrebutes() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc",
                                    children: [JSONTreeElementNode(type: "p",
                                                                   children: [
                                                                       JSONTreeElementNode(type: "span", attributes: ["bold": true],
                                                                                           children: [JSONTreeTextNode(value: "hello")])
                                                                   ])])
            )

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p><span bold=\"true\">hello</span></p></doc>")
        }
    }

    func test_can_edit_its_content() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc",
                                                               children: [JSONTreeElementNode(type: "p",
                                                                                              children: [JSONTreeTextNode(value: "ab")])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")

            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "X"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>Xab</p></doc>")

            try (root.t as? JSONTree)?.edit(1, 2)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")

            try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "X"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>aXb</p></doc>")

            try (root.t as? JSONTree)?.edit(2, 3)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")
        }

        let tree = await doc.getRoot().t as? JSONTree
        XCTAssertEqual(tree?.toXML(), /* html */ "<doc><p>ab</p></doc>")

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc",
                                                               children: [JSONTreeElementNode(type: "p",
                                                                                              children: [JSONTreeTextNode(value: "ab")])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")

            try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "X"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>abX</p></doc>")

            try (root.t as? JSONTree)?.edit(3, 4)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")

            try (root.t as? JSONTree)?.edit(2, 3)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>a</p></doc>")
        }
    }

    func test_can_be_subscribed_by_handler() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc",
                                                               children: [JSONTreeElementNode(type: "p",
                                                                                              children: [JSONTreeTextNode(value: "ab")])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")
        }

        var treeOperations = [TreeEditOpInfo]()

        await doc.subscribe("$.t") { event in
            if let event = event as? LocalChangeEvent {
                treeOperations.append(contentsOf: event.value.operations.compactMap { $0 as? TreeEditOpInfo })
            }
        }

        try await doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "X"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>Xab</p></doc>")
        }

        XCTAssertEqual(treeOperations[0].type, .treeEdit)
        XCTAssertEqual(treeOperations[0].from, 1)
        XCTAssertEqual(treeOperations[0].to, 1)
        XCTAssertEqual(treeOperations[0].value as? [JSONTreeTextNode], [JSONTreeTextNode(value: "X")])
    }

    func test_can_be_subscribed_by_handler_path() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(
                    type: "doc",
                    children: [JSONTreeElementNode(
                        type: "tc",
                        children: [JSONTreeElementNode(
                            type: "p",
                            children: [JSONTreeElementNode(
                                type: "tn",
                                children: [JSONTreeTextNode(value: "ab")]
                            )]
                        )]
                    )]
                )
            )
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>ab</tn></p></tc></doc>")
        }

        var treeOperations = [TreeEditOpInfo]()

        await doc.subscribe("$.t") { event in
            if let event = event as? LocalChangeEvent {
                treeOperations.append(contentsOf: event.value.operations.compactMap { $0 as? TreeEditOpInfo })
            }
        }

        try await doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 0, 0, 1], [0, 0, 0, 1], JSONTreeTextNode(value: "X"))

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb</tn></p></tc></doc>")
        }

        XCTAssertEqual(treeOperations[0].type, .treeEdit)
        XCTAssertEqual(treeOperations[0].fromPath, [0, 0, 0, 1])
        XCTAssertEqual(treeOperations[0].toPath, [0, 0, 0, 1])
        XCTAssertEqual(treeOperations[0].value as? [JSONTreeTextNode], [JSONTreeTextNode(value: "X")])
    }

    func test_can_edit_its_content_with_path() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(
                    type: "doc",
                    children: [JSONTreeElementNode(
                        type: "tc",
                        children: [JSONTreeElementNode(
                            type: "p",
                            children: [JSONTreeElementNode(
                                type: "tn",
                                children: [JSONTreeTextNode(value: "ab")]
                            )]
                        )]
                    )]
                )
            )
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>ab</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 0, 0, 1], [0, 0, 0, 1], JSONTreeTextNode(value: "X"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 0, 0, 3], [0, 0, 0, 3], JSONTreeTextNode(value: "!"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 0, 1], JSONTreeElementNode(type: "tn", children: [JSONTreeTextNode(value: "cd")]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 1], [0, 1], JSONTreeElementNode(type: "p", children: [JSONTreeElementNode(type: "tn", children: [JSONTreeTextNode(value: "q")])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p><p><tn>q</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 1, 0, 0], [0, 1, 0, 0], JSONTreeTextNode(value: "a"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p><p><tn>aq</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 1, 0, 2], [0, 1, 0, 2], JSONTreeTextNode(value: "B"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p><p><tn>aqB</tn></p></tc></doc>")

            var failed = false

            do {
                _ = try (root.t as? JSONTree)?.editByPath([0, 0, 4], [0, 0, 4], JSONTreeElementNode(type: "tn"))
            } catch {
                failed = true
            }

            XCTAssertTrue(failed)
        }
    }

    func test_can_edit_its_content_with_path_2() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(
                    type: "doc",
                    children: [JSONTreeElementNode(
                        type: "tc",
                        children: [JSONTreeElementNode(
                            type: "p",
                            children: [JSONTreeElementNode(
                                type: "tn",
                                children: []
                            )]
                        )]
                    )]
                )
            )
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 0, 0, 0], [0, 0, 0, 0], JSONTreeTextNode(value: "a"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), "<doc><tc><p><tn>a</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 1], [0, 1], JSONTreeElementNode(type: "p", children: [JSONTreeElementNode(type: "tn", children: [])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 1, 0, 0], [0, 1, 0, 0], JSONTreeTextNode(value: "b"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 2], [0, 2], JSONTreeElementNode(type: "p", children: [JSONTreeElementNode(type: "tn", children: [])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 2, 0, 0], [0, 2, 0, 0], JSONTreeTextNode(value: "c"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 3], [0, 3], JSONTreeElementNode(type: "p", children: [JSONTreeElementNode(type: "tn", children: [])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p><p><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 3, 0, 0], [0, 3, 0, 0], JSONTreeTextNode(value: "d"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p><p><tn>d</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 3], [0, 3], JSONTreeElementNode(type: "p", children: [JSONTreeElementNode(type: "tn", children: [])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p><p><tn></tn></p><p><tn>d</tn></p></tc></doc>")
        }
    }

    func test_can_sync_its_content_with_other_clients() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "hello")])]))
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<doc><p>hello</p></doc>")
            XCTAssertEqual(d2XML, /* html */ "<doc><p>hello</p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(7, 7, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "yorkie")]))
            }

            try await c1.sync()
            try await c2.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<doc><p>hello</p><p>yorkie</p></doc>")
            XCTAssertEqual(d2XML, /* html */ "<doc><p>hello</p><p>yorkie</p></doc>")
        }
    }

    func test_get_correct_range_from_index() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(
                    type: "root",
                    children: [JSONTreeElementNode(
                        type: "p",
                        children: [JSONTreeElementNode(
                            type: "b",
                            children: [JSONTreeElementNode(
                                type: "i",
                                children: [JSONTreeTextNode(value: "ab")]
                            )]
                        )]
                    )]
                )
            )
        }

        let tree = await doc.getRoot().t as? JSONTree
        //     0  1  2   3 4 5    6   7   8
        // <root><p><b><i> a b </i></b></p></root>
        let docXML = tree?.toXML()
        XCTAssertEqual(docXML, /* html */ "<root><p><b><i>ab</i></b></p></root>")

        var range = try tree?.indexRangeToPosRange((0, 5))
        var resultRange = try tree?.posRangeToIndexRange(range!)

        XCTAssertEqual(resultRange?.0, 0)
        XCTAssertEqual(resultRange?.1, 5)

        range = try tree?.indexRangeToPosRange((5, 7))
        resultRange = try tree?.posRangeToIndexRange(range!)

        XCTAssertEqual(resultRange?.0, 5)
        XCTAssertEqual(resultRange?.1, 7)
    }

    func test_get_correct_range_from_path() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(
                    type: "root",
                    children: [JSONTreeElementNode(
                        type: "p",
                        children: [JSONTreeElementNode(
                            type: "b",
                            children: [JSONTreeElementNode(
                                type: "i",
                                children: [JSONTreeTextNode(value: "ab")]
                            )]
                        )]
                    )]
                )
            )
        }

        let tree = await doc.getRoot().t as? JSONTree
        //     0  1  2   3 4 5    6   7   8
        // <root><p><b><i> a b </i></b></p></root>
        let docXML = tree?.toXML()
        XCTAssertEqual(docXML, /* html */ "<root><p><b><i>ab</i></b></p></root>")

        var range = try tree?.pathRangeToPosRange(([0], [0, 0, 0, 2]))
        var resultRange = try tree?.posRangeToPathRange(range!)

        XCTAssertEqual(resultRange?.0, [0])
        XCTAssertEqual(resultRange?.1, [0, 0, 0, 2])

        range = try tree?.pathRangeToPosRange(([0], [1]))
        resultRange = try tree?.posRangeToPathRange(range!)

        XCTAssertEqual(resultRange?.0, [0])
        XCTAssertEqual(resultRange?.1, [1])
    }
}

final class TreeIntegrationEditTests: XCTestCase {
    func test_can_insert_multiple_text_nodes() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeTextNode(value: "ab")
                                        ])
                ])
            )
        }
        var docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>ab</p></doc>")

        try await doc.update { root, _ in
            try (root.t as? JSONTree)?.editBulk(3, 3, [
                JSONTreeTextNode(value: "c"),
                JSONTreeTextNode(value: "d")
            ])
        }
        docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>abcd</p></doc>")
    }

    func test_can_insert_multiple_element_nodes() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeTextNode(value: "ab")
                                        ])
                ])
            )
        }
        var docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>ab</p></doc>")

        try await doc.update { root, _ in
            try (root.t as? JSONTree)?.editBulk(4, 4, [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")]),
                JSONTreeElementNode(type: "i", children: [JSONTreeTextNode(value: "fg")])
            ])
        }
        docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>ab</p><p>cd</p><i>fg</i></doc>")
    }

    func test_can_edit_its_content_with_path_when_multi_tree_nodes_passed() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(
                    type: "doc",
                    children: [JSONTreeElementNode(
                        type: "tc",
                        children: [JSONTreeElementNode(
                            type: "p",
                            children: [JSONTreeElementNode(
                                type: "tn",
                                children: [JSONTreeTextNode(value: "ab")]
                            )]
                        )]
                    )]
                )
            )

            var docXML = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(docXML, /* html */ "<doc><tc><p><tn>ab</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editBulkByPath([0, 0, 0, 1], [0, 0, 0, 1], [
                JSONTreeTextNode(value: "X"),
                JSONTreeTextNode(value: "X")
            ])

            docXML = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(docXML, /* html */ "<doc><tc><p><tn>aXXb</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editBulkByPath([0, 1], [0, 1], [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeElementNode(type: "tn", children: [
                        JSONTreeTextNode(value: "te"),
                        JSONTreeTextNode(value: "st")
                    ])
                ]),
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeElementNode(type: "tn", children: [
                        JSONTreeTextNode(value: "te"),
                        JSONTreeTextNode(value: "xt")
                    ])
                ])
            ])

            docXML = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(docXML, /* html */ "<doc><tc><p><tn>aXXb</tn></p><p><tn>test</tn></p><p><tn>text</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editBulkByPath([0, 3], [0, 3], [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeElementNode(type: "tn", children: [
                        JSONTreeTextNode(value: "te"),
                        JSONTreeTextNode(value: "st")
                    ])
                ]),
                JSONTreeElementNode(type: "tn", children: [
                    JSONTreeTextNode(value: "te"),
                    JSONTreeTextNode(value: "xt")
                ])
            ])

            docXML = (root.t as? JSONTree)?.toXML()
            XCTAssertEqual(docXML, /* html */ "<doc><tc><p><tn>aXXb</tn></p><p><tn>test</tn></p><p><tn>text</tn></p><p><tn>test</tn></p><tn>text</tn></tc></doc>")
        }
    }

    func test_detecting_error_for_empty_text() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeTextNode(value: "ab")
                                        ])
                ])
            )
        }
        let docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>ab</p></doc>")

        try await doc.update { root, _ in
            XCTAssertThrowsError(try (root.t as? JSONTree)?.editBulk(3, 3, [
                JSONTreeTextNode(value: "C"),
                JSONTreeTextNode(value: "")
            ]))
        }
    }

    func test_detecting_error_for_mixed_type_insertion() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeTextNode(value: "ab")
                                        ])
                ])
            )
        }
        let docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>ab</p></doc>")

        try await doc.update { root, _ in
            XCTAssertThrowsError(try (root.t as? JSONTree)?.editBulk(3, 3, [
                JSONTreeElementNode(type: "p", children: []),
                JSONTreeTextNode(value: "d")
            ]))
        }
    }

    func test_detecting_correct_error_order_1() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeTextNode(value: "ab")
                                        ])
                ])
            )
        }
        let docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>ab</p></doc>")

        try await doc.update { root, _ in
            XCTAssertThrowsError(try (root.t as? JSONTree)?.editBulk(3, 3, [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeTextNode(value: "c"),
                    JSONTreeTextNode(value: "")]),
                JSONTreeTextNode(value: "d")
            ]))
        }
    }

    func test_detecting_correct_error_order_2() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeTextNode(value: "ab")
                                        ])
                ])
            )
        }
        let docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>ab</p></doc>")

        try await doc.update { root, _ in
            XCTAssertThrowsError(try (root.t as? JSONTree)?.editBulk(3, 3, [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeTextNode(value: "c")
                ]),
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeTextNode(value: "")
                ])
            ]))
        }
    }

    func test_detecting_correct_error_order_3() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeTextNode(value: "ab")
                                        ])
                ])
            )
        }
        let docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>ab</p></doc>")

        try await doc.update { root, _ in
            XCTAssertThrowsError(try (root.t as? JSONTree)?.editBulk(3, 3, [
                JSONTreeTextNode(value: "d"),
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeTextNode(value: "c")
                ])
            ]))
        }
    }

    func test_delete_nodes_in_a_multi_level_range_test() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeTextNode(value: "ab"),
                                            JSONTreeElementNode(type: "p",
                                                                children: [
                                                                    JSONTreeTextNode(value: "x")
                                                                ])
                                        ]),
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeElementNode(type: "p",
                                                                children: [
                                                                    JSONTreeTextNode(value: "cd")
                                                                ])
                                        ]),
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeElementNode(type: "p",
                                                                children: [
                                                                    JSONTreeTextNode(value: "y")
                                                                ]),
                                            JSONTreeTextNode(value: "ef")
                                        ])
                ])
            )
        }

        var docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>ab<p>x</p></p><p><p>cd</p></p><p><p>y</p>ef</p></doc>")

        try await doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(2, 18)
        }

        docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>af</p></doc>")
    }
}

final class TreeIntegrationStyleTests: XCTestCase {
    func test_can_be_inserted_with_attributes() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc",
                                    children: [JSONTreeElementNode(type: "p",
                                                                   children: [JSONTreeElementNode(type: "span",
                                                                                                  attributes: ["bold": "true"],
                                                                                                  children: [JSONTreeTextNode(value: "hello")])])])
            )
        }

        let docXML = await(doc.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docXML, /* html */ "<doc><p><span bold=\"true\">hello</span></p></doc>")
    }

    func test_can_be_edited_with_index() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc",
                                    children: [JSONTreeElementNode(type: "tc",
                                                                   children: [JSONTreeElementNode(type: "p",
                                                                                                  attributes: ["a": "b"],
                                                                                                  children: [JSONTreeElementNode(type: "tn",
                                                                                                                                 children: [])])])])
            )

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\"><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.style(1, 2, ["c": "d"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"d\"><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.style(1, 2, ["c": "q"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.style(2, 3, ["z": "m"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn z=\"m\"></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.style(2, 3, ["z": 3])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn z=\"3\"></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.style(2, 3, ["z": nil])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn z=\"null\"></tn></p></tc></doc>")
        }
    }

    func test_can_be_edited_with_path() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc",
                                    children: [JSONTreeElementNode(type: "tc",
                                                                   children: [JSONTreeElementNode(type: "p",
                                                                                                  attributes: ["a": "b"],
                                                                                                  children: [JSONTreeElementNode(type: "tn",
                                                                                                                                 children: [])])])])
            )

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\"><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.styleByPath([0, 0], ["c": "d"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"d\"><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.styleByPath([0, 0], ["c": "q"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.styleByPath([0, 0, 0], ["z": "m"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn z=\"m\"></tn></p></tc></doc>")

            XCTAssertEqual(root.toJSON(), /* html */ "{\"t\":{\"type\":\"doc\",\"children\":[{\"type\":\"tc\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"tn\",\"children\":[],\"attributes\":{\"z\":\"m\"}}],\"attributes\":{\"a\":\"b\",\"c\":\"q\"}}]}]}}")
        }
    }

    func test_can_sync_its_content_containing_attributes_with_other_replicas() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc",
                                        children: [JSONTreeElementNode(type: "p",
                                                                       attributes: ["italic": "true"],
                                                                       children: [JSONTreeTextNode(value: "hello")])])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<doc><p italic=\"true\">hello</p></doc>")
            XCTAssertEqual(d2XML, /* html */ "<doc><p italic=\"true\">hello</p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.style(0, 1, ["bold": "true"])
            }

            try await c1.sync()
            try await c2.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<doc><p bold=\"true\" italic=\"true\">hello</p></doc>")
            XCTAssertEqual(d2XML, /* html */ "<doc><p bold=\"true\" italic=\"true\">hello</p></doc>")
        }
    }

    func test_style_node_with_element_attributes_test() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeTextNode(value: "ab")
                                        ]),
                    JSONTreeElementNode(type: "p",
                                        children: [
                                            JSONTreeTextNode(value: "cd")
                                        ])
                ])
            )

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p><p>cd</p></doc>")

            // 01. style attributes to an element node.
            // style attributes with opening tag
            try (root.t as? JSONTree)?.style(0, 1, ["weight": "bold"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p weight=\"bold\">ab</p><p>cd</p></doc>")

            // style attributes with closing tag
            try (root.t as? JSONTree)?.style(3, 4, ["color": "red"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p color=\"red\" weight=\"bold\">ab</p><p>cd</p></doc>")

            // style attributes with the whole
            try (root.t as? JSONTree)?.style(0, 4, ["size": "small"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p color=\"red\" size=\"small\" weight=\"bold\">ab</p><p>cd</p></doc>")

            // 02. style attributes to elements.
            try (root.t as? JSONTree)?.style(0, 5, ["style": "italic"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p color=\"red\" size=\"small\" style=\"italic\" weight=\"bold\">ab</p><p style=\"italic\">cd</p></doc>")

            // 03. Ignore styling attributes to text nodes.
            try (root.t as? JSONTree)?.style(1, 3, ["bold": true])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p color=\"red\" size=\"small\" style=\"italic\" weight=\"bold\">ab</p><p style=\"italic\">cd</p></doc>")
        }
    }
}

final class TreeIntegrationOverlappingRange: XCTestCase {
    func test_can_concurrently_delete_overlapping_elements() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [JSONTreeElementNode(type: "p"),
                                                   JSONTreeElementNode(type: "i"),
                                                   JSONTreeElementNode(type: "b")])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p><i></i><b></b></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p><i></i><b></b></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 4)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 6)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><b></b></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r></r>")
            XCTAssertEqual(d2XML, /* html */ "<r></r>")
        }
    }

    func test_can_concurrently_delete_overlapping_text() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "abcd")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>abcd</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>abcd</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 4)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 5)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>d</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>a</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")
        }
    }
}

final class TreeIntegrationContainedRange: XCTestCase {
    func test_can_concurrently_insert_and_delete_contained_elements_of_the_same_depth() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "1234")
                                            ]),
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "abcd")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p><p>abcd</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p><p>abcd</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(6, 6, JSONTreeElementNode(type: "p"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 12)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p><p></p><p>abcd</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")
        }
    }

    func test_can_concurrently_multiple_insert_and_delete_contained_elements_of_the_same_depth() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "1234")
                                            ]),
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "abcd")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p><p>abcd</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p><p>abcd</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(6, 6, JSONTreeElementNode(type: "p"))
            }

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(8, 8, JSONTreeElementNode(type: "p"))
            }

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(10, 10, JSONTreeElementNode(type: "p"))
            }

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(12, 12, JSONTreeElementNode(type: "p"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 12)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p><p></p><p></p><p></p><p></p><p>abcd</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p><p></p><p></p><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p><p></p><p></p><p></p></r>")
        }
    }

    func test_detecting_error_when_inserting_and_deleting_contained_elements_at_different_depths() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeElementNode(type: "i")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><i></i></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><i></i></p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeElementNode(type: "i"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 3)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><i><i></i></i></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")
        }
    }

    func test_can_concurrently_delete_contained_elements() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeElementNode(type: "i", children: [
                                                    JSONTreeTextNode(value: "1234")
                                                ])
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><i>1234</i></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><i>1234</i></p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 8)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 7)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r></r>")
            XCTAssertEqual(d2XML, /* html */ "<r></r>")
        }
    }

    func test_can_concurrently_insert_and_delete_contained_text() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "1234")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 5)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "a"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12a34</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>a</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>a</p></r>")
        }
    }

    func test_can_concurrently_delete_contained_text() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "1234")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 5)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 4)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>14</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")
        }
    }

    func test_can_concurrently_insert_and_delete_contained_text_and_elements() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "1234")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 6)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "a"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12a34</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r></r>")
            XCTAssertEqual(d2XML, /* html */ "<r></r>")
        }
    }

    func test_can_concurrently_delete_contained_text_and_elements() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "1234")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 6)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 5)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r></r>")
            XCTAssertEqual(d2XML, /* html */ "<r></r>")
        }
    }
}

final class TreeIntegrationSideBySideRange: XCTestCase {
    func test_can_concurrently_insert_side_by_side_elements_left() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p")
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 0, JSONTreeElementNode(type: "b"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 0, JSONTreeElementNode(type: "i"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><b></b><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><i></i><p></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><i></i><b></b><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><i></i><b></b><p></p></r>")
        }
    }

    func test_can_concurrently_insert_side_by_side_elements_middle() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p")
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 1, JSONTreeElementNode(type: "b"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 1, JSONTreeElementNode(type: "i"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><b></b></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><i></i></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><i></i><b></b></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><i></i><b></b></p></r>")
        }
    }

    func test_can_concurrently_insert_side_by_side_elements_right() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p")
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeElementNode(type: "b"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeElementNode(type: "i"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p><b></b></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p><i></i></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p><i></i><b></b></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p><i></i><b></b></r>")
        }
    }

    func test_can_concurrently_insert_and_delete_side_by_side_elements() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeElementNode(type: "b")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><b></b></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><b></b></p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 3)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 1, JSONTreeElementNode(type: "i"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><i></i><b></b></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><i></i></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><i></i></p></r>")
        }
    }

    func test_can_concurrently_delete_and_insert_side_by_side_elements() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeElementNode(type: "b")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><b></b></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><b></b></p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 3)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeElementNode(type: "i"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><b></b><i></i></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><i></i></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><i></i></p></r>")
        }
    }

    func test_can_concurrently_delete_side_by_side_elements() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeElementNode(type: "b"),
                                                JSONTreeElementNode(type: "i")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><b></b><i></i></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><b></b><i></i></p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 3)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 5)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p><i></i></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p><b></b></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")
        }
    }

    func test_can_insert_text_to_the_same_position_left_concurrently() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "A"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "B"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>A12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>B12</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>BA12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>BA12</p></r>")
        }
    }

    func test_can_insert_text_to_the_same_position_middle_concurrently() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "A"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "B"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1A2</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1B2</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1BA2</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1BA2</p></r>")
        }
    }

    func test_can_insert_text_content_to_the_same_position_right_concurrently() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "A"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "B"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12A</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12B</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12BA</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12BA</p></r>")
        }
    }

    func test_can_concurrently_insert_and_delete_side_by_side_text() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "1234")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "a"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 5)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12a34</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12a</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12a</p></r>")
        }
    }

    func test_can_concurrently_delete_and_insert_side_by_side_text() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "1234")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "a"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 3)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12a34</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>34</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>a34</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>a34</p></r>")
        }
    }

    func test_can_concurrently_delete_side_by_side_text_blocks() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "1234")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 5)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 3)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>34</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")
        }
    }

    func test_can_delete_text_content_at_the_same_position_left_concurrently() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "123")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>123</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>123</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 2)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 2)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>23</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>23</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>23</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>23</p></r>")
        }
    }

    func test_can_delete_text_content_at_the_same_position_middle_concurrently() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "123")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>123</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>123</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 3)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 3)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>13</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>13</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>13</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>13</p></r>")
        }
    }

    func test_can_delete_text_content_at_the_same_position_right_concurrently() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "123")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>123</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>123</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 4)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 4)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12</p></r>")
        }
    }
}

final class TreeIntegrationComplexCases: XCTestCase {
    func test_can_delete_text_content_anchored_to_another_concurrently() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "123")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>123</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>123</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 2)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 3)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>23</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>13</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>3</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>3</p></r>")
        }
    }

    func test_can_produce_complete_deletion_concurrently() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "123")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>123</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>123</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 2)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 4)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>23</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p></p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")
        }
    }

    func test_can_handle_block_delete_concurrently() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12345")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12345</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12345</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 3)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(4, 6)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>345</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>123</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>3</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>3</p></r>")
        }
    }

    func test_can_handle_insert_within_block_delete_concurrently() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12345")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12345</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12345</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 5)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "B"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>15</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12B345</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1B5</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1B5</p></r>")
        }
    }

    func test_can_handle_insert_within_block_delete_concurrently_2() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12345")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12345</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12345</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 6)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.editBulk(3, 3, [JSONTreeTextNode(value: "a"), JSONTreeTextNode(value: "bc")])
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12abc345</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1abc</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1abc</p></r>")
        }
    }

    func test_can_handle_block_element_insertion_within_delete_2() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "1234")
                                            ]),
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "5678")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1234</p><p>5678</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p><p>5678</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 12)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.editBulk(6, 6, [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")]),
                    JSONTreeElementNode(type: "i", children: [JSONTreeTextNode(value: "fg")])
                ])
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>1234</p><p>cd</p><i>fg</i><p>5678</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>cd</p><i>fg</i></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>cd</p><i>fg</i></r>")
        }
    }

    func test_can_handle_concurrent_element_insert_deletion_left() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12345")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12345</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12345</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 7)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.editBulk(0, 0, [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")]),
                    JSONTreeElementNode(type: "i", children: [JSONTreeTextNode(value: "fg")])
                ])
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>cd</p><i>fg</i><p>12345</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>cd</p><i>fg</i></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>cd</p><i>fg</i></r>")
        }
    }

    func test_can_handle_concurrent_element_insert_deletion_right() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12345")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12345</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12345</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(0, 7)
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.editBulk(7, 7, [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")]),
                    JSONTreeElementNode(type: "i", children: [JSONTreeTextNode(value: "fg")])
                ])
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12345</p><p>cd</p><i>fg</i></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>cd</p><i>fg</i></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>cd</p><i>fg</i></r>")
        }
    }

    func test_can_handle_deletion_of_insertion_anchor_concurreltly() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "A"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 2)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>1A2</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>2</p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>A2</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>A2</p></r>")
        }
    }

    func test_can_handle_deletion_after_insertion_concurreltly() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "A"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 3)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>A12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>A</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>A</p></r>")
        }
    }

    func test_can_handle_deletion_before_insertion_concurreltly() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "r",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "12")
                                            ])
                                        ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>12</p></r>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "A"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 3)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>12A</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p></p></r>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<r><p>A</p></r>")
            XCTAssertEqual(d2XML, /* html */ "<r><p>A</p></r>")
        }
    }
}

final class TreeIntegrationEdgeCases: XCTestCase {
    func test_can_delete_very_first_text_when_there_is_tombstone_in_front_of_target_text() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            root.t = JSONTree()

            try (root.t as? JSONTree)?.edit(0, 0, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcdefghi")]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>abcdefghi</p></root>")

            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "12345"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>12345abcdefghi</p></root>")

            try (root.t as? JSONTree)?.edit(2, 5)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>15abcdefghi</p></root>")

            try (root.t as? JSONTree)?.edit(3, 5)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>15cdefghi</p></root>")

            try (root.t as? JSONTree)?.edit(2, 4)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>1defghi</p></root>")

            try (root.t as? JSONTree)?.edit(1, 3)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>efghi</p></root>")

            try (root.t as? JSONTree)?.edit(1, 2)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>fghi</p></root>")

            try (root.t as? JSONTree)?.edit(2, 5)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>f</p></root>")

            try (root.t as? JSONTree)?.edit(1, 2)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p></p></root>")
        }
    }

    func test_can_delete_node_when_there_is_more_than_one_text_node_in_front_which_has_size_bigger_than_1() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root, _ in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree()

            try (root.t as? JSONTree)?.edit(0, 0, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcde")]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>abcde</p></root>")

            try (root.t as? JSONTree)?.edit(6, 6, JSONTreeTextNode(value: "f"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>abcdef</p></root>")

            try (root.t as? JSONTree)?.edit(7, 7, JSONTreeTextNode(value: "g"))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>abcdefg</p></root>")

            try (root.t as? JSONTree)?.edit(7, 8)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>abcdef</p></root>")
            try (root.t as? JSONTree)?.edit(6, 7)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>abcde</p></root>")
            try (root.t as? JSONTree)?.edit(5, 6)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>abcd</p></root>")
            try (root.t as? JSONTree)?.edit(4, 5)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>abc</p></root>")
            try (root.t as? JSONTree)?.edit(3, 4)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>ab</p></root>")
            try (root.t as? JSONTree)?.edit(2, 3)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>a</p></root>")
            try (root.t as? JSONTree)?.edit(1, 2)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p></p></root>")
        }
    }

    func test_split_link_can_transmitted_through_rpc() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "ab")
                                            ])
                                        ])
                )
            }

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "1"))
            }

            try await c1.sync()
            try await c2.sync()

            let d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<doc><p>a1b</p></doc>")
            XCTAssertEqual(d2XML, /* html */ "<doc><p>a1b</p></doc>")

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "1"))
            }

            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d2XML, /* html */ "<doc><p>a11b</p></doc>")

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 3, JSONTreeTextNode(value: "12"))
            }

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(4, 5, JSONTreeTextNode(value: "21"))
            }

            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d2XML, /* html */ "<doc><p>a1221b</p></doc>")

            // if split link is not transmitted, then left sibling in from index below, is "b" not "a"
            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 4, JSONTreeTextNode(value: "123"))
            }

            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d2XML, /* html */ "<doc><p>a12321b</p></doc>")
        }
    }

    func test_can_calculate_size_of_index_tree_correctly() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "ab")
                                            ])
                                        ])
                )
            }

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "123"))
            }

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "456"))
            }

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "789"))
            }

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "0123"))
            }

            let d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>a0123789456123b</p></doc>")

            try await c1.sync()
            try await c2.sync()

            let sized1 = try await(d1.getRoot().t as? JSONTree)?.getIndexTree().root.size
            let sized2 = try await(d2.getRoot().t as? JSONTree)?.getIndexTree().root.size

            XCTAssertEqual(sized1, sized2)
        }
    }

    func test_can_split_and_merge_with_empty_paragraph_left() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "a"),
                                                JSONTreeTextNode(value: "b")
                                            ])
                                        ])
                )
            }

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>ab</p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 1, nil, 1)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p></p><p>ab</p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(1, 3)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>ab</p></doc>")

            try await c1.sync()
            try await c2.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            let d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, d2XML)
        }
    }

    func test_can_split_and_merge_with_empty_paragraph_right() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "a"),
                                                JSONTreeTextNode(value: "b")
                                            ])
                                        ])
                )
            }

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>ab</p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, nil, 1)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>ab</p><p></p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 5)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>ab</p></doc>")

            try await c1.sync()
            try await c2.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            let d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, d2XML)
        }
    }

    func test_can_split_and_merge_with_empty_paragraph_and_multiple_split_level_left() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeElementNode(type: "p", children: [
                                                    JSONTreeTextNode(value: "a"),
                                                    JSONTreeTextNode(value: "b")
                                                ])
                                            ])
                                        ])
                )
            }

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p><p>ab</p></p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, nil, 2)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p><p></p></p><p><p>ab</p></p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 6)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p><p>ab</p></p></doc>")

            try await c1.sync()
            try await c2.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            let d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, d2XML)
        }
    }

    func test_split_at_the_same_offset_multiple_times() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "a"),
                                                JSONTreeTextNode(value: "b")
                                            ])
                                        ])
                )
            }

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>ab</p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, nil, 1)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>a</p><p>b</p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "c"))
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>ac</p><p>b</p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, nil, 1)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>a</p><p>c</p><p>b</p></doc>")

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 7)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>ab</p></doc>")

            try await c1.sync()
            try await c2.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            let d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, d2XML)
        }
    }

    func test_can_concurrently_split_and_insert_into_original_node() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "a"),
                                                JSONTreeTextNode(value: "b"),
                                                JSONTreeTextNode(value: "c"),
                                                JSONTreeTextNode(value: "d")
                                            ])
                                        ])
                )
            }

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>abcd</p></doc>")

            try await c1.sync()
            try await c2.sync()

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, nil, 1)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>ab</p><p>cd</p></doc>")

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "e"))
            }

            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d2XML, /* html */ "<doc><p>aebcd</p></doc>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, d2XML)
        }
    }

    func test_can_concurrently_split_and_insert_into_split_node() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeTextNode(value: "a"),
                                                JSONTreeTextNode(value: "b"),
                                                JSONTreeTextNode(value: "c"),
                                                JSONTreeTextNode(value: "d")
                                            ])
                                        ])
                )
            }

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>abcd</p></doc>")

            try await c1.sync()
            try await c2.sync()

            try await d1.update { root, _ in
                try (root.t as? JSONTree)?.edit(3, 3, nil, 1)
            }

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>ab</p><p>cd</p></doc>")

            try await d2.update { root, _ in
                try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "e"))
            }

            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d2XML, /* html */ "<doc><p>aebcd</p></doc>")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, d2XML)
        }
    }
}
