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
 * `listEqual` is a helper function that the given tree is equal to the
 * expected list of nodes.
 */
func listEqual(_ tree: JSONTree?, _ expected: [any JSONTreeNode]) {
    guard let tree else {
        XCTAssertTrue(false)

        return
    }

    for (index, node) in tree.enumerated() {
        if let expected = expected[index] as? ElementNode {
            XCTAssertEqual(expected, node as? ElementNode)
        } else if let expected = expected[index] as? TextNode {
            XCTAssertEqual(expected, node as? TextNode)
        }
    }
}

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
func createTwoTreeDocs(_ key: String, _ initial: ElementNode) async throws -> (Document, Document) {
    let docKey = "\(key)-\(Date().description)".toDocKey

    let doc1 = Document(key: docKey)
    let doc2 = Document(key: docKey)
    await doc1.setActor("A")
    await doc2.setActor("B")

    try await doc1.update { root in
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

        try await doc.update { root in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree()
            _ = try? (root.t as? JSONTree)?.edit(0, 0, [ElementNode(type: "p")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p></p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[]}]}}")

            // 02. Create a text into the paragraph.
            _ = try? (root.t as? JSONTree)?.edit(1, 1, [TextNode(value: "AB")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>AB</p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"text\",\"value\":\"AB\"}]}]}}")

            // 03. Insert a text into the paragraph.
            _ = try? (root.t as? JSONTree)?.edit(3, 3, [TextNode(value: "CD")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>ABCD</p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"text\",\"value\":\"AB\"},{\"type\":\"text\",\"value\":\"CD\"}]}]}}")

            // 04. Replace ABCD with Yorkie
            _ = try? (root.t as? JSONTree)?.edit(1, 5, [TextNode(value: "Yorkie")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>Yorkie</p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"text\",\"value\":\"Yorkie\"}]}]}}")
        }
    }

    func test_can_be_created_from_JSON() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root in
            root.t = JSONTree(initialRoot:
                ElementNode(type: "doc",
                            children: [ElementNode(type: "p",
                                                   children: [TextNode(value: "ab")]),
                                       ElementNode(type: "ng",
                                                   children: [ElementNode(type: "note",
                                                                          children: [TextNode(value: "cd")]),
                                                              ElementNode(type: "note",
                                                                          children: [TextNode(value: "ef")])]),
                                       ElementNode(type: "bp",
                                                   children: [TextNode(value: "gh")])]))

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p><ng><note>cd</note><note>ef</note></ng><bp>gh</bp></doc>")
            XCTAssertEqual(try? (root.t as? JSONTree)?.getSize() ?? 0, 18)
            listEqual(root.t as? JSONTree, [
                TextNode(value: "ab"),
                ElementNode(type: "p"),
                TextNode(value: "cd"),
                ElementNode(type: "note"),
                TextNode(value: "ef"),
                ElementNode(type: "note"),
                ElementNode(type: "ng"),
                TextNode(value: "gh"),
                ElementNode(type: "bp"),
                ElementNode(type: "doc")
            ])
        }
    }

    func test_can_edit_its_content() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot: ElementNode(type: "doc",
                                                       children: [ElementNode(type: "p",
                                                                              children: [TextNode(value: "ab")])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")

            _ = try? (root.t as? JSONTree)?.edit(1, 1, [TextNode(value: "X")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>Xab</p></doc>")

            _ = try? (root.t as? JSONTree)?.edit(1, 2)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")

            _ = try? (root.t as? JSONTree)?.edit(2, 2, [TextNode(value: "X")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>aXb</p></doc>")

            _ = try? (root.t as? JSONTree)?.edit(2, 3)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")
        }

        let tree = await doc.getRoot().t as? JSONTree
        XCTAssertEqual(tree?.toXML(), /* html */ "<doc><p>ab</p></doc>")

        try await doc.update { root in
            root.t = JSONTree(initialRoot: ElementNode(type: "doc",
                                                       children: [ElementNode(type: "p",
                                                                              children: [TextNode(value: "ab")])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")

            _ = try? (root.t as? JSONTree)?.edit(3, 3, [TextNode(value: "X")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>abX</p></doc>")

            _ = try? (root.t as? JSONTree)?.edit(3, 4)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")

            _ = try? (root.t as? JSONTree)?.edit(2, 3)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>a</p></doc>")
        }
    }

    func test_can_be_subscribed_by_handler() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot: ElementNode(type: "doc",
                                                       children: [ElementNode(type: "p",
                                                                              children: [TextNode(value: "ab")])]))
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")
        }

        var treeOperations = [TreeEditOpInfo]()

        await doc.subscribe("$.t") { event in
            if let event = event as? LocalChangeEvent {
                treeOperations.append(contentsOf: event.value.operations.compactMap { $0 as? TreeEditOpInfo })
            }
        }

        try await doc.update { root in
            _ = try? (root.t as? JSONTree)?.edit(1, 1, [TextNode(value: "X")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>Xab</p></doc>")
        }

        XCTAssertEqual(treeOperations[0].type, .treeEdit)
        XCTAssertEqual(treeOperations[0].from, 1)
        XCTAssertEqual(treeOperations[0].to, 1)
        XCTAssertEqual(treeOperations[0].value, [TreeNode(type: DefaultTreeNodeType.text.rawValue, value: "X")])
    }

    func test_can_be_subscribed_by_handler_path() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot:
                ElementNode(
                    type: "doc",
                    children: [ElementNode(
                        type: "tc",
                        children: [ElementNode(
                            type: "p",
                            children: [ElementNode(
                                type: "tn",
                                children: [TextNode(value: "ab")]
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

        try await doc.update { root in
            _ = try? (root.t as? JSONTree)?.editByPath([0, 0, 0, 1], [0, 0, 0, 1], [TextNode(value: "X")])

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb</tn></p></tc></doc>")
        }

        XCTAssertEqual(treeOperations[0].type, .treeEdit)
        XCTAssertEqual(treeOperations[0].fromPath, [0, 0, 0, 1])
        XCTAssertEqual(treeOperations[0].toPath, [0, 0, 0, 1])
        XCTAssertEqual(treeOperations[0].value, [TreeNode(type: DefaultTreeNodeType.text.rawValue, value: "X")])
    }

    func test_can_edit_its_content_with_path() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot:
                ElementNode(
                    type: "doc",
                    children: [ElementNode(
                        type: "tc",
                        children: [ElementNode(
                            type: "p",
                            children: [ElementNode(
                                type: "tn",
                                children: [TextNode(value: "ab")]
                            )]
                        )]
                    )]
                )
            )
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>ab</tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 0, 0, 1], [0, 0, 0, 1], [TextNode(value: "X")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb</tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 0, 0, 3], [0, 0, 0, 3], [TextNode(value: "!")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 0, 1], [ElementNode(type: "tn", children: [TextNode(value: "cd")])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 1], [0, 1], [ElementNode(type: "p", children: [ElementNode(type: "tn", children: [TextNode(value: "q")])])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p><p><tn>q</tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 1, 0, 0], [0, 1, 0, 0], [TextNode(value: "a")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p><p><tn>aq</tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 1, 0, 2], [0, 1, 0, 2], [TextNode(value: "B")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p><p><tn>aqB</tn></p></tc></doc>")

            var failed = false

            do {
                _ = try (root.t as? JSONTree)?.editByPath([0, 0, 4], [0, 0, 4], [ElementNode(type: "tn")])
            } catch {
                failed = true
            }

            XCTAssertTrue(failed)
        }
    }

    func test_can_edit_its_content_with_path_2() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root in
            // 01. Create a tree and insert a paragraph.
            root.t = JSONTree(initialRoot:
                ElementNode(
                    type: "doc",
                    children: [ElementNode(
                        type: "tc",
                        children: [ElementNode(
                            type: "p",
                            children: [ElementNode(
                                type: "tn",
                                children: [TextNode(value: "")]
                            )]
                        )]
                    )]
                )
            )
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn></tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 0, 0, 0], [0, 0, 0, 0], [TextNode(value: "a")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), "<doc><tc><p><tn>a</tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 1], [0, 1], [ElementNode(type: "p", children: [ElementNode(type: "tn", children: [TextNode(value: "")])])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn></tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 1, 0, 0], [0, 1, 0, 0], [TextNode(value: "b")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 2], [0, 2], [ElementNode(type: "p", children: [ElementNode(type: "tn", children: [TextNode(value: "")])])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn></tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 2, 0, 0], [0, 2, 0, 0], [TextNode(value: "c")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 3], [0, 3], [ElementNode(type: "p", children: [ElementNode(type: "tn", children: [TextNode(value: "")])])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p><p><tn></tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 3, 0, 0], [0, 3, 0, 0], [TextNode(value: "d")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p><p><tn>d</tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.editByPath([0, 3], [0, 3], [ElementNode(type: "p", children: [ElementNode(type: "tn", children: [TextNode(value: "")])])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p><p><tn></tn></p><p><tn>d</tn></p></tc></doc>")
        }
    }

    func test_can_sync_its_content_with_other_replicas() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root in
                root.t = JSONTree(initialRoot: ElementNode(type: "doc", children: [ElementNode(type: "p", children: [TextNode(value: "hello")])]))
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<doc><p>hello</p></doc>")
            XCTAssertEqual(d2XML, /* html */ "<doc><p>hello</p></doc>")

            try await d1.update { root in
                _ = try? (root.t as? JSONTree)?.edit(7, 7, [ElementNode(type: "p", children: [TextNode(value: "yorkie")])])
            }

            try await c1.sync()
            try await c2.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<doc><p>hello</p><p>yorkie</p></doc>")
            XCTAssertEqual(d2XML, /* html */ "<doc><p>hello</p><p>yorkie</p></doc>")
        }
    }
}

final class TreeIntegrationEditTests: XCTestCase {
    func skip_test_can_insert_text_to_the_same_position_left_concurrently() async throws {
        let (docA, docB) = try await createTwoTreeDocs(self.description,
                                                       ElementNode(type: "r",
                                                                   children: [
                                                                       ElementNode(type: "p",
                                                                                   children: [TextNode(value: "12")])
                                                                   ]))

        var docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docAXML, /* html */ "<r><p>12</p></r>")

        try await docA.update { root in
            _ = try? (root.t as? JSONTree)?.edit(1, 1, [TextNode(value: "A")])
        }
        try await docB.update { root in
            _ = try? (root.t as? JSONTree)?.edit(1, 1, [TextNode(value: "B")])
        }

        docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()
        let docBXML = await(docB.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docAXML, /* html */ "<r><p>A12</p></r>")
        XCTAssertEqual(docBXML, /* html */ "<r><p>B12</p></r>")

        try await syncTwoTreeDocsAndAssertEqual(docA, docB, /* html */ "<r><p>BA12</p></r>")
    }

    func test_can_insert_text_to_the_same_position_middle_concurrently() async throws {
        let (docA, docB) = try await createTwoTreeDocs(self.description,
                                                       ElementNode(type: "r",
                                                                   children: [
                                                                       ElementNode(type: "p",
                                                                                   children: [TextNode(value: "12")])
                                                                   ]))
        var docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docAXML, /* html */ "<r><p>12</p></r>")

        try await docA.update { root in
            _ = try? (root.t as? JSONTree)?.edit(2, 2, [TextNode(value: "A")])
        }
        try await docB.update { root in
            _ = try? (root.t as? JSONTree)?.edit(2, 2, [TextNode(value: "B")])
        }

        docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()
        let docBXML = await(docB.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docAXML, /* html */ "<r><p>1A2</p></r>")
        XCTAssertEqual(docBXML, /* html */ "<r><p>1B2</p></r>")

        try await syncTwoTreeDocsAndAssertEqual(docA, docB, /* html */ "<r><p>1BA2</p></r>")
    }

    func test_can_insert_text_content_to_the_same_position_right_concurrently() async throws {
        let (docA, docB) = try await createTwoTreeDocs(self.description,
                                                       ElementNode(type: "r",
                                                                   children: [
                                                                       ElementNode(type: "p",
                                                                                   children: [TextNode(value: "12")])
                                                                   ]))
        var docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()

        try await docA.update { root in
            _ = try? (root.t as? JSONTree)?.edit(3, 3, [TextNode(value: "A")])
        }
        try await docB.update { root in
            _ = try? (root.t as? JSONTree)?.edit(3, 3, [TextNode(value: "B")])
        }

        docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()
        let docBXML = await(docB.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docAXML, /* html */ "<r><p>12A</p></r>")
        XCTAssertEqual(docBXML, /* html */ "<r><p>12B</p></r>")

        try await syncTwoTreeDocsAndAssertEqual(docA, docB, /* html */ "<r><p>12BA</p></r>")
    }
}

final class TreeIntegrationStyleTests: XCTestCase {
    func test_can_be_inserted_with_attributes() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root in
            root.t = JSONTree(initialRoot:
                ElementNode(type: "doc",
                            children: [ElementNode(type: "p",
                                                   children: [ElementNode(type: "span",
                                                                          attributes: ["bold": "true"],
                                                                          children: [TextNode(value: "hello")])])])
            )
        }

        let docXML = await(doc.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docXML, /* html */ "<doc><p><span bold=\"true\">hello</span></p></doc>")
    }

    func test_can_be_edited_with_index() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root in
            root.t = JSONTree(initialRoot:
                ElementNode(type: "doc",
                            children: [ElementNode(type: "tc",
                                                   children: [ElementNode(type: "p",
                                                                          attributes: ["a": "b"],
                                                                          children: [ElementNode(type: "tn",
                                                                                                 children: [TextNode(value: "")])])])])
            )

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\"><tn></tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.style(4, 5, ["c": "d"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"d\"><tn></tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.style(4, 5, ["c": "q"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn></tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.style(3, 4, ["z": "m"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn z=\"m\"></tn></p></tc></doc>")
        }
    }

    func test_can_be_edited_with_path() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await doc.update { root in
            root.t = JSONTree(initialRoot:
                ElementNode(type: "doc",
                            children: [ElementNode(type: "tc",
                                                   children: [ElementNode(type: "p",
                                                                          attributes: ["a": "b"],
                                                                          children: [ElementNode(type: "tn",
                                                                                                 children: [TextNode(value: "")])])])])
            )

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\"><tn></tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.styleByPath([0, 0], ["c": "d"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"d\"><tn></tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.styleByPath([0, 0], ["c": "q"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn></tn></p></tc></doc>")

            _ = try? (root.t as? JSONTree)?.styleByPath([0, 0, 0], ["z": "m"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn z=\"m\"></tn></p></tc></doc>")

            XCTAssertEqual(root.toJSON(), /* html */ "{\"t\":{\"type\":\"doc\",\"children\":[{\"type\":\"tc\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"tn\",\"children\":[{\"type\":\"text\",\"value\":\"\"}],\"attributes\":{\"z\":\"m\"}}],\"attributes\":{\"a\":\"b\",\"c\":\"q\"}}]}]}}")
        }
    }

    func test_can_sync_its_content_containing_attributes_with_other_replicas() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root in
                root.t = JSONTree(initialRoot:
                    ElementNode(type: "doc",
                                children: [ElementNode(type: "p",
                                                       attributes: ["italic": "true"],
                                                       children: [TextNode(value: "hello")])])
                )
            }

            try await c1.sync()
            try await c2.sync()

            var d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            var d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<doc><p italic=\"true\">hello</p></doc>")
            XCTAssertEqual(d2XML, /* html */ "<doc><p italic=\"true\">hello</p></doc>")

            try await d1.update { root in
                _ = try? (root.t as? JSONTree)?.style(6, 7, ["bold": "true"])
            }

            try await c1.sync()
            try await c2.sync()

            d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()

            XCTAssertEqual(d1XML, /* html */ "<doc><p bold=\"true\" italic=\"true\">hello</p></doc>")
            XCTAssertEqual(d2XML, /* html */ "<doc><p bold=\"true\" italic=\"true\">hello</p></doc>")
        }
    }
}
