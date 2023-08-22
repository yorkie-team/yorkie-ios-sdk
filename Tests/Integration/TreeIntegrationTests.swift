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
        if let expected = expected[index] as? JSONTreeElementNode, let node = node as? JSONTreeElementNode {
            XCTAssertEqual(expected.type, node.type)
        } else if let expected = expected[index] as? JSONTreeTextNode, let node = node as? JSONTreeTextNode {
            XCTAssertEqual(expected.value, node.value)
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
            try (root.t as? JSONTree)?.edit(0, 0, [JSONTreeElementNode(type: "p")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p></p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[]}]}}")

            // 02. Create a text into the paragraph.
            try (root.t as? JSONTree)?.edit(1, 1, [JSONTreeTextNode(value: "AB")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>AB</p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"text\",\"value\":\"AB\"}]}]}}")

            // 03. Insert a text into the paragraph.
            try (root.t as? JSONTree)?.edit(3, 3, [JSONTreeTextNode(value: "CD")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<root><p>ABCD</p></root>")
            XCTAssertEqual(root.toJSON(), "{\"t\":{\"type\":\"root\",\"children\":[{\"type\":\"p\",\"children\":[{\"type\":\"text\",\"value\":\"AB\"},{\"type\":\"text\",\"value\":\"CD\"}]}]}}")

            // 04. Replace ABCD with Yorkie
            try (root.t as? JSONTree)?.edit(1, 5, [JSONTreeTextNode(value: "Yorkie")])
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
            listEqual(root.t as? JSONTree, [
                JSONTreeTextNode(value: "ab"),
                JSONTreeElementNode(type: "p"),
                JSONTreeTextNode(value: "cd"),
                JSONTreeElementNode(type: "note"),
                JSONTreeTextNode(value: "ef"),
                JSONTreeElementNode(type: "note"),
                JSONTreeElementNode(type: "ng"),
                JSONTreeTextNode(value: "gh"),
                JSONTreeElementNode(type: "bp"),
                JSONTreeElementNode(type: "doc")
            ])
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

            try (root.t as? JSONTree)?.edit(1, 1, [JSONTreeTextNode(value: "X")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>Xab</p></doc>")

            try (root.t as? JSONTree)?.edit(1, 2)
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><p>ab</p></doc>")

            try (root.t as? JSONTree)?.edit(2, 2, [JSONTreeTextNode(value: "X")])
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

            try (root.t as? JSONTree)?.edit(3, 3, [JSONTreeTextNode(value: "X")])
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
            try (root.t as? JSONTree)?.edit(1, 1, [JSONTreeTextNode(value: "X")])
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
            try (root.t as? JSONTree)?.editByPath([0, 0, 0, 1], [0, 0, 0, 1], [JSONTreeTextNode(value: "X")])

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

            try (root.t as? JSONTree)?.editByPath([0, 0, 0, 1], [0, 0, 0, 1], [JSONTreeTextNode(value: "X")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 0, 0, 3], [0, 0, 0, 3], [JSONTreeTextNode(value: "!")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 0, 1], [JSONTreeElementNode(type: "tn", children: [JSONTreeTextNode(value: "cd")])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 1], [0, 1], [JSONTreeElementNode(type: "p", children: [JSONTreeElementNode(type: "tn", children: [JSONTreeTextNode(value: "q")])])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p><p><tn>q</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 1, 0, 0], [0, 1, 0, 0], [JSONTreeTextNode(value: "a")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p><p><tn>aq</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 1, 0, 2], [0, 1, 0, 2], [JSONTreeTextNode(value: "B")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>aXb!</tn><tn>cd</tn></p><p><tn>aqB</tn></p></tc></doc>")

            var failed = false

            do {
                _ = try (root.t as? JSONTree)?.editByPath([0, 0, 4], [0, 0, 4], [JSONTreeElementNode(type: "tn")])
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

            try (root.t as? JSONTree)?.editByPath([0, 0, 0, 0], [0, 0, 0, 0], [JSONTreeTextNode(value: "a")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), "<doc><tc><p><tn>a</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 1], [0, 1], [JSONTreeElementNode(type: "p", children: [JSONTreeElementNode(type: "tn", children: [])])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 1, 0, 0], [0, 1, 0, 0], [JSONTreeTextNode(value: "b")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 2], [0, 2], [JSONTreeElementNode(type: "p", children: [JSONTreeElementNode(type: "tn", children: [])])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 2, 0, 0], [0, 2, 0, 0], [JSONTreeTextNode(value: "c")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 3], [0, 3], [JSONTreeElementNode(type: "p", children: [JSONTreeElementNode(type: "tn", children: [])])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p><p><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 3, 0, 0], [0, 3, 0, 0], [JSONTreeTextNode(value: "d")])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p><p><tn>d</tn></p></tc></doc>")

            try (root.t as? JSONTree)?.editByPath([0, 3], [0, 3], [JSONTreeElementNode(type: "p", children: [JSONTreeElementNode(type: "tn", children: [])])])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p><tn>a</tn></p><p><tn>b</tn></p><p><tn>c</tn></p><p><tn></tn></p><p><tn>d</tn></p></tc></doc>")
        }
    }

    func test_can_sync_its_content_with_other_replicas() async throws {
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
                try (root.t as? JSONTree)?.edit(7, 7, [JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "yorkie")])])
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
            try (root.t as? JSONTree)?.edit(3, 3, [
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
            try (root.t as? JSONTree)?.edit(4, 4, [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")]),
                JSONTreeElementNode(type: "i", children: [JSONTreeTextNode(value: "fg")])
            ])
        }
        docXML = await(doc.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(docXML, /* html */ "<doc><p>ab</p><p>cd</p><i>fg</i></doc>")
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
            XCTAssertThrowsError(try (root.t as? JSONTree)?.edit(3, 3, [
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
            XCTAssertThrowsError(try (root.t as? JSONTree)?.edit(3, 3, [
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
            XCTAssertThrowsError(try (root.t as? JSONTree)?.edit(3, 3, [
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
            XCTAssertThrowsError(try (root.t as? JSONTree)?.edit(3, 3, [
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
            XCTAssertThrowsError(try (root.t as? JSONTree)?.edit(3, 3, [
                JSONTreeTextNode(value: "d"),
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeTextNode(value: "c")
                ])
            ]))
        }
    }

    func skip_test_can_insert_text_to_the_same_position_left_concurrently() async throws {
        let (docA, docB) = try await createTwoTreeDocs(self.description,
                                                       JSONTreeElementNode(type: "r",
                                                                           children: [
                                                                               JSONTreeElementNode(type: "p",
                                                                                                   children: [JSONTreeTextNode(value: "12")])
                                                                           ]))

        var docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docAXML, /* html */ "<r><p>12</p></r>")

        try await docA.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, [JSONTreeTextNode(value: "A")])
        }
        try await docB.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, [JSONTreeTextNode(value: "B")])
        }

        docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()
        let docBXML = await(docB.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docAXML, /* html */ "<r><p>A12</p></r>")
        XCTAssertEqual(docBXML, /* html */ "<r><p>B12</p></r>")

        try await syncTwoTreeDocsAndAssertEqual(docA, docB, /* html */ "<r><p>BA12</p></r>")
    }

    func test_can_insert_text_to_the_same_position_middle_concurrently() async throws {
        let (docA, docB) = try await createTwoTreeDocs(self.description,
                                                       JSONTreeElementNode(type: "r",
                                                                           children: [
                                                                               JSONTreeElementNode(type: "p",
                                                                                                   children: [JSONTreeTextNode(value: "12")])
                                                                           ]))
        var docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docAXML, /* html */ "<r><p>12</p></r>")

        try await docA.update { root, _ in
            try (root.t as? JSONTree)?.edit(2, 2, [JSONTreeTextNode(value: "A")])
        }
        try await docB.update { root, _ in
            try (root.t as? JSONTree)?.edit(2, 2, [JSONTreeTextNode(value: "B")])
        }

        docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()
        let docBXML = await(docB.getRoot().t as? JSONTree)?.toXML()

        XCTAssertEqual(docAXML, /* html */ "<r><p>1A2</p></r>")
        XCTAssertEqual(docBXML, /* html */ "<r><p>1B2</p></r>")

        try await syncTwoTreeDocsAndAssertEqual(docA, docB, /* html */ "<r><p>1BA2</p></r>")
    }

    func test_can_insert_text_content_to_the_same_position_right_concurrently() async throws {
        let (docA, docB) = try await createTwoTreeDocs(self.description,
                                                       JSONTreeElementNode(type: "r",
                                                                           children: [
                                                                               JSONTreeElementNode(type: "p",
                                                                                                   children: [JSONTreeTextNode(value: "12")])
                                                                           ]))
        var docAXML = await(docA.getRoot().t as? JSONTree)?.toXML()

        try await docA.update { root, _ in
            try (root.t as? JSONTree)?.edit(3, 3, [JSONTreeTextNode(value: "A")])
        }
        try await docB.update { root, _ in
            try (root.t as? JSONTree)?.edit(3, 3, [JSONTreeTextNode(value: "B")])
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

            try (root.t as? JSONTree)?.style(4, 5, ["c": "d"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"d\"><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.style(4, 5, ["c": "q"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.style(3, 4, ["z": "m"])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn z=\"m\"></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.style(3, 4, ["z": 100])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn z=100></tn></p></tc></doc>")

            try (root.t as? JSONTree)?.style(3, 4, ["z": true])
            XCTAssertEqual((root.t as? JSONTree)?.toXML(), /* html */ "<doc><tc><p a=\"b\" c=\"q\"><tn z=true></tn></p></tc></doc>")
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
                try (root.t as? JSONTree)?.style(6, 7, ["bold": "true"])
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
