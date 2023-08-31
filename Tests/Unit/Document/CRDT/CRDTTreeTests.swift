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

let DTP = CRDTTreeNodeID(createdAt: TimeTicket.initial, offset: 0)

/**
 * `dummyContext` is a helper context that is used for testing.
 */
let dummyContext = ChangeContext(id: ChangeID.initial, root: CRDTRoot())

/**
 * `issuePos` is a helper function that issues a new CRDTTreeNodeID.
 */
func issuePos(_ offset: Int32 = 0) -> CRDTTreeNodeID {
    CRDTTreeNodeID(createdAt: dummyContext.issueTimeTicket, offset: offset)
}

/**
 * `issueTime` is a helper function that issues a new TimeTicket.
 */
var issueTime: TimeTicket {
    dummyContext.issueTimeTicket
}

final class CRDTTreeNodeTests: XCTestCase {
    func test_can_be_created() {
        let node = CRDTTreeNode(id: DTP, type: DefaultTreeNodeType.text.rawValue, value: "hello")

        XCTAssertEqual(node.id, DTP)
        XCTAssertEqual(node.type, DefaultTreeNodeType.text.rawValue)
        XCTAssertEqual(node.value, "hello")
        XCTAssertEqual(node.size, 5)
        XCTAssertEqual(node.isText, true)
        XCTAssertEqual(node.isRemoved, false)
    }

    func test_can_be_split() throws {
        let para = CRDTTreeNode(id: DTP, type: "p", children: [])
        try para.append(contentsOf: [CRDTTreeNode(id: DTP, type: DefaultTreeNodeType.text.rawValue, value: "helloyorkie")])

        XCTAssertEqual(CRDTTreeNode.toXML(node: para), "<p>helloyorkie</p>")
        XCTAssertEqual(para.size, 11)
        XCTAssertEqual(para.isText, false)

        let left = para.children[0]
        let right = try left.split(5, 0)

        XCTAssertEqual(CRDTTreeNode.toXML(node: para), "<p>helloyorkie</p>")
        XCTAssertEqual(para.size, 11)

        XCTAssertEqual(left.value, "hello")
        XCTAssertEqual(right?.value, "yorkie")
        XCTAssertEqual(left.id, CRDTTreeNodeID(createdAt: TimeTicket.initial, offset: 0))
        XCTAssertEqual(right?.id, CRDTTreeNodeID(createdAt: TimeTicket.initial, offset: 5))
    }
}

final class CRDTTreeTests: XCTestCase {
    func test_can_inserts_nodes_with_edit() throws {
        //       0
        // <root> </root>
        let tree = CRDTTree(root: CRDTTreeNode(id: issuePos(), type: "r"), createdAt: issueTime)
        XCTAssertEqual(tree.root.size, 0)
        XCTAssertEqual(tree.toXML(), "<r></r>")

        //           1
        // <root> <p> </p> </root>
        try tree.editByIndex((0, 0), [CRDTTreeNode(id: issuePos(), type: "p")], issueTime)
        XCTAssertEqual(tree.toXML(), "<r><p></p></r>")
        XCTAssertEqual(tree.root.size, 2)

        //           1
        // <root> <p> h e l l o </p> </root>
        try tree.editByIndex((1, 1), [CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "hello")], issueTime)
        XCTAssertEqual(tree.toXML(), "<r><p>hello</p></r>")
        XCTAssertEqual(tree.root.size, 7)

        //       0   1 2 3 4 5 6    7   8 9  10 11 12 13    14
        // <root> <p> h e l l o </p> <p> w  o  r  l  d  </p>  </root>
        let para = CRDTTreeNode(id: issuePos(), type: "p")
        try para.insertAt(CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "world"), 0)
        try tree.editByIndex((7, 7), [para], issueTime)
        XCTAssertEqual(tree.toXML(), "<r><p>hello</p><p>world</p></r>")
        XCTAssertEqual(tree.root.size, 14)

        //       0   1 2 3 4 5 6 7    8   9 10 11 12 13 14    15
        // <root> <p> h e l l o ! </p> <p> w  o  r  l  d  </p>  </root>
        try tree.editByIndex((6, 6), [CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "!")], issueTime)
        XCTAssertEqual(tree.toXML(), "<r><p>hello!</p><p>world</p></r>")

        XCTAssertEqual(tree.toTestTreeNode().createdDictionary as NSDictionary,
                       """
                       {
                           "size" : 15,
                           "isRemoved" : false,
                           "type" : "r",
                           "children" : [
                             {
                               "size" : 6,
                               "isRemoved" : false,
                               "type" : "p",
                               "children" : [
                                 {
                                   "size" : 5,
                                   "value" : "hello",
                                   "isRemoved" : false,
                                   "type" : "text"
                                 },
                                 {
                                   "size" : 1,
                                   "value" : "!",
                                   "isRemoved" : false,
                                   "type" : "text"
                                 }
                               ]
                             },
                             {
                               "size" : 5,
                               "isRemoved" : false,
                               "type" : "p",
                               "children" : [
                                 {
                                   "size" : 5,
                                   "value" : "world",
                                   "isRemoved" : false,
                                   "type" : "text"
                                 }
                               ]
                             }
                           ]
                         }
                       """.createdDictionary as NSDictionary)

        //       0   1 2 3 4 5 6 7 8    9   10 11 12 13 14 15    16
        // <root> <p> h e l l o ~ ! </p> <p>  w  o  r  l  d  </p>  </root>
        try tree.editByIndex((6, 6), [CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "~")], issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<r><p>hello~!</p><p>world</p></r>")
    }

    func test_can_delete_text_nodes_with_edit() throws {
        // 01. Create a tree with 2 paragraphs.
        //       0   1 2 3    4   5 6 7    8
        // <root> <p> a b </p> <p> c d </p> </root>
        let tree = CRDTTree(root: CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(id: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        try tree.editByIndex((4, 4), [CRDTTreeNode(id: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((5, 5),
                             [CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "cd")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), "<root><p>ab</p><p>cd</p></root>")

        var treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 8)
        XCTAssertEqual(treeNode.children![0].size, 2)
        XCTAssertEqual(treeNode.children![0].children![0].size, 2)

        // 02. delete b from first paragraph
        //       0   1 2    3   4 5 6    7
        // <root> <p> a </p> <p> c d </p> </root>
        try tree.editByIndex((2, 3), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>a</p><p>cd</p></root>")

        treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 7)
        XCTAssertEqual(treeNode.children![0].size, 1)
        XCTAssertEqual(treeNode.children![0].children![0].size, 1)
    }

    func test_can_find_the_closest_TreePos_when_parentNode_or_leftSiblingNode_does_not_exist() async throws {
        let tree = CRDTTree(root: CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)

        let pNode = CRDTTreeNode(id: issuePos(), type: "p")
        let textNode = CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")

        //       0   1 2 3    4
        // <root> <p> a b </p> </root>
        try tree.editByIndex((0, 0), [pNode], issueTime)
        try tree.editByIndex((1, 1), [textNode], issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p></root>")

        // Find the closest index.TreePos when leftSiblingNode in crdt.TreePos is removed.
        //       0   1    2
        // <root> <p> </p> </root>
        try tree.editByIndex((1, 3), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p></p></root>")

        var (parent, left) = try tree.findNodesAndSplitText(CRDTTreePos(parentID: pNode.id, leftSiblingID: textNode.id), issueTime)
        XCTAssertEqual(try tree.toIndex(parent, left), 1)

        // Find the closest index.TreePos when parentNode in crdt.TreePos is removed.
        //       0
        // <root> </root>
        try tree.editByIndex((0, 2), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root></root>")

        (parent, left) = try tree.findNodesAndSplitText(CRDTTreePos(parentID: pNode.id, leftSiblingID: textNode.id), issueTime)
        XCTAssertEqual(try tree.toIndex(parent, left), 0)
    }
}

final class CRDTTreeMoveTests: XCTestCase {
    func test_can_delete_nodes_between_element_nodes_with_edit() async throws {
      // 01. Create a tree with 2 paragraphs.
      //       0   1 2 3    4   5 6 7    8
      // <root> <p> a b </p> <p> c d </p> </root>
        let tree = CRDTTree(root: CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(id: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                         [CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                         issueTime)
        try tree.editByIndex((4, 4), [CRDTTreeNode(id: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((5, 5),
                             [CRDTTreeNode(id: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "cd")],
                             issueTime)
        
        XCTAssertEqual(tree.toXML(), /*html*/ "<root><p>ab</p><p>cd</p></root>")

      // 02. delete b, c and first paragraph.
      //       0   1 2 3    4
      // <root> <p> a d </p> </root>
        try tree.editByIndex((2, 6), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /*html*/ "<root><p>a</p><p>d</p></root>")

      // TODO(sejongk): Use the below assertion after implementing Tree.Move.
      // assert.deepEqual(tree.toXML(), /*html*/ `<root><p>ad</p></root>`);

      // const treeNode = tree.toTestTreeNode();
      // assert.equal(treeNode.size, 4); // root
      // assert.equal(treeNode.children![0].size, 2); // p
      // assert.equal(treeNode.children![0].children![0].size, 1); // a
      // assert.equal(treeNode.children![0].children![1].size, 1); // d

      // // 03. insert a new text node at the start of the first paragraph.
      // tree.editByIndex(
      //   [1, 1],
      //   [new CRDTTreeNode(issuePos(), 'text', '@')],
      //   issueTime(),
      // );
      // assert.deepEqual(tree.toXML(), /*html*/ `<root><p>@ad</p></root>`);
    }
}
