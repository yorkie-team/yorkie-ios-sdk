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

final class CRDTTreeNodeTests: XCTestCase {
    func test_can_be_created() {
        let node = CRDTTreeNode(id: idT, type: DefaultTreeNodeType.text.rawValue, value: "hello")

        XCTAssertEqual(node.id, idT)
        XCTAssertEqual(node.type, DefaultTreeNodeType.text.rawValue)
        XCTAssertEqual(node.value, "hello")
        XCTAssertEqual(node.size, 5)
        XCTAssertEqual(node.isText, true)
        XCTAssertEqual(node.isRemoved, false)
    }

    func test_can_be_split() throws {
        let para = CRDTTreeNode(id: idT, type: "p", children: [])
        try para.append(contentsOf: [CRDTTreeNode(id: idT, type: DefaultTreeNodeType.text.rawValue, value: "helloyorkie")])

        XCTAssertEqual(CRDTTreeNode.toXML(node: para), "<p>helloyorkie</p>")
        XCTAssertEqual(para.size, 11)
        XCTAssertEqual(para.isText, false)

        let left = para.children[0]
        let right = try left.splitText(5, 0).0

        XCTAssertEqual(CRDTTreeNode.toXML(node: para), "<p>helloyorkie</p>")
        XCTAssertEqual(para.size, 11)

        XCTAssertEqual(left.value, "hello")
        XCTAssertEqual(right?.value, "yorkie")
        XCTAssertEqual(left.id, CRDTTreeNodeID(createdAt: TimeTicket.initial, offset: 0))
        XCTAssertEqual(right?.id, CRDTTreeNodeID(createdAt: TimeTicket.initial, offset: 5))
    }

    func test_can_be_escaped_newline() {
        let node = CRDTTreeNode(id: idT, type: DefaultTreeNodeType.text.rawValue, value: "\n")

        XCTAssertEqual(node.id, idT)
        XCTAssertEqual(node.type, DefaultTreeNodeType.text.rawValue)
        XCTAssertEqual(node.value, "\n")
        XCTAssertEqual(node.size, 1)
        XCTAssertEqual(node.isText, true)
        XCTAssertEqual(node.isRemoved, false)

        XCTAssertEqual(node.toJSONString, "{\"type\":\"text\",\"value\":\"\\n\"}")
    }
}

final class CRDTTreeEditTests: XCTestCase {
    func test_can_inserts_nodes_with_edit() throws {
        //       0
        // <root> </root>
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: "r"), createdAt: timeT())
        XCTAssertEqual(tree.root.size, 0)
        XCTAssertEqual(tree.toXML(), "<r></r>")

        //           1
        // <root> <p> </p> </root>
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<r><p></p></r>")
        XCTAssertEqual(tree.root.size, 2)

        //           1
        // <root> <p> h e l l o </p> </root>
        try tree.editT((1, 1), [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "hello")], 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<r><p>hello</p></r>")
        XCTAssertEqual(tree.root.size, 7)

        //       0   1 2 3 4 5 6    7   8 9  10 11 12 13    14
        // <root> <p> h e l l o </p> <p> w  o  r  l  d  </p>  </root>
        let para = CRDTTreeNode(id: posT(), type: "p")
        try para.insertAt(CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "world"), 0)
        try tree.editT((7, 7), [para], 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<r><p>hello</p><p>world</p></r>")
        XCTAssertEqual(tree.root.size, 14)

        //       0   1 2 3 4 5 6 7    8   9 10 11 12 13 14    15
        // <root> <p> h e l l o ! </p> <p> w  o  r  l  d  </p>  </root>
        try tree.editT((6, 6), [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "!")], 0, timeT(), timeT)
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
        try tree.editT((6, 6), [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "~")], 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<r><p>hello~!</p><p>world</p></r>")
    }

    func test_can_delete_text_nodes_with_edit() throws {
        // 01. Create a tree with 2 paragraphs.
        //       0   1 2 3    4   5 6 7    8
        // <root> <p> a b </p> <p> c d </p> </root>
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")], 0,
                       timeT(), timeT)
        try tree.editT((4, 4), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((5, 5),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "cd")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<root><p>ab</p><p>cd</p></root>")

        var treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 8)
        XCTAssertEqual(treeNode.children![0].size, 2)
        XCTAssertEqual(treeNode.children![0].children![0].size, 2)

        // 02. delete b from first paragraph
        //       0   1 2    3   4 5 6    7
        // <root> <p> a </p> <p> c d </p> </root>
        try tree.editT((2, 3), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>a</p><p>cd</p></root>")

        treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 7)
        XCTAssertEqual(treeNode.children![0].size, 1)
        XCTAssertEqual(treeNode.children![0].children![0].size, 1)
    }

    func test_can_delete_tree_nodes_with_edit() throws {
        // 01. Create a tree with 2 paragraphs.
        //       0   1 2 3    4   5 6 7    8
        // <root> <p> a b </p> <p> c d </p> </root>
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")], 0,
                       timeT(), timeT)
        try tree.editT((4, 4), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((5, 5),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "cd")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p><p>cd</p></root>")

        var treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 8)
        XCTAssertEqual(treeNode.children![0].size, 2)
        XCTAssertEqual(treeNode.children![0].children![0].size, 2)

        // 02. delete the first paragraph
        //       0   1 2 3    4
        // <root> <p> c d </p> </root>
        try tree.editT((0, 4), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>cd</p></root>")

        treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 4)
        XCTAssertEqual(treeNode.children![0].size, 2)
        XCTAssertEqual(treeNode.children![0].children![0].size, 2)

        // 03. add a new paragraph
        //       0   1 2 3    4   5 6 7    8
        // <root> <p> e f </p> <p> c d </p> </root>
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ef")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ef</p><p>cd</p></root>")

        treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 8)
        XCTAssertEqual(treeNode.children![1].size, 2)
        XCTAssertEqual(treeNode.children![1].children![0].size, 2)

        // 04. delete all paragraphs
        try tree.editT((0, 8), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root></root>")

        treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 0)
        XCTAssertEqual(treeNode.children!.count, 0)

        // 05. add a new paragraph
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "gh")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>gh</p></root>")

        treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 4)
        XCTAssertEqual(treeNode.children![0].size, 2)
        XCTAssertEqual(treeNode.children![0].children![0].size, 2)
    }

    func test_can_find_the_closest_TreePos_when_parentNode_or_leftSiblingNode_does_not_exist() async throws {
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())

        let pNode = CRDTTreeNode(id: posT(), type: "p")
        let textNode = CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")

        //       0   1 2 3    4
        // <root> <p> a b </p> </root>
        try tree.editT((0, 0), [pNode], 0, timeT(), timeT)
        try tree.editT((1, 1), [textNode], 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p></root>")

        // Find the closest index.TreePos when leftSiblingNode in crdt.TreePos is removed.
        //       0   1    2
        // <root> <p> </p> </root>
        try tree.editT((1, 3), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p></p></root>")

        var ((parent, left), _) = try tree.findNodesAndSplitText(CRDTTreePos(parentID: pNode.id, leftSiblingID: textNode.id), timeT())
        XCTAssertEqual(try tree.toIndex(parent, left), 1)

        // Find the closest index.TreePos when parentNode in crdt.TreePos is removed.
        //       0
        // <root> </root>
        try tree.editT((0, 2), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root></root>")

        ((parent, left), _) = try tree.findNodesAndSplitText(CRDTTreePos(parentID: pNode.id, leftSiblingID: textNode.id), timeT())
        XCTAssertEqual(try tree.toIndex(parent, left), 0)
    }
}

final class CRDTTreeSplitTests: XCTestCase {
    func test_can_split_text_nodes() async throws {
        // 00. Create a tree with 2 paragraphs.
        //       0   1     6     11
        // <root> <p> hello world  </p> </root>
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "helloworld")], 0,
                       timeT(), timeT)

        var expectedIntial = """
        {
            "size" : 12,
            "isRemoved" : false,
            "type" : "root",
            "children" : [
              {
                "size" : 10,
                "isRemoved" : false,
                "type" : "p",
                "children" : [
                  {
                    "size" : 10,
                    "value" : "helloworld",
                    "isRemoved" : false,
                    "type" : "text"
                  }
                ]
              }
            ]
          }
        """.createdDictionary as NSDictionary

        XCTAssertEqual(tree.toTestTreeNode().createdDictionary as NSDictionary, expectedIntial)

        // 01. Split left side of 'helloworld'.
        try tree.editT((1, 1), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toTestTreeNode().createdDictionary as NSDictionary, expectedIntial)

        // 02. Split right side of 'helloworld'.
        try tree.editT((11, 11), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toTestTreeNode().createdDictionary as NSDictionary, expectedIntial)

        // 03. Split 'helloworld' into 'hello' and 'world'.
        try tree.editT((6, 6), nil, 0, timeT(), timeT)

        expectedIntial = """
        {
            "size" : 12,
            "isRemoved" : false,
            "type" : "root",
            "children" : [
              {
                "size" : 10,
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
                    "size" : 5,
                    "value" : "world",
                    "isRemoved" : false,
                    "type" : "text"
                  }
                ]
              }
            ]
          }
        """.createdDictionary as NSDictionary
        XCTAssertEqual(tree.toTestTreeNode().createdDictionary as NSDictionary, expectedIntial)
    }

    func test_can_split_element_nodes_level_1() async throws {
        //       0   1 2 3    4
        // <root> <p> a b </p> </root>

        // 01. Split position 1.
        var tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p></root>")
        try tree.editT((1, 1), nil, 1, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p></p><p>ab</p></root>")
        XCTAssertEqual(tree.size, 6)

        // 02. Split position 2.
        tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p></root>")
        try tree.editT((2, 2), nil, 1, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>a</p><p>b</p></root>")
        XCTAssertEqual(tree.size, 6)

        // 03. Split position 3.
        tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p></root>")
        try tree.editT((3, 3), nil, 1, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p><p></p></root>")
        XCTAssertEqual(tree.size, 6)
    }

    func test_can_split_element_nodes_multi_level() async throws {
        //       0   1   2 3 4    5    6
        // <root> <p> <b> a b </b> </p> </root>

        // 01. Split nodes level 1.
        var tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1), [CRDTTreeNode(id: posT(), type: "b")], 0, timeT(), timeT)
        try tree.editT((2, 2),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>ab</b></p></root>")
        try tree.editT((3, 3), nil, 1, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>a</b><b>b</b></p></root>")

        // 02. Split nodes level 2.
        tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1), [CRDTTreeNode(id: posT(), type: "b")], 0, timeT(), timeT)
        try tree.editT((2, 2),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>ab</b></p></root>")
        try tree.editT((3, 3), nil, 2, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>a</b></p><p><b>b</b></p></root>")
    }

    func test_can_split_and_merge_element_nodes_by_edit() async throws {
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "abcd")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>abcd</p></root>")
        XCTAssertEqual(tree.size, 6)

        //       0   1 2 3    4   5 6 7    8
        // <root> <p> a b </p> <p> c d </p> </root>
        try tree.editT((3, 3), nil, 1, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p><p>cd</p></root>")
        XCTAssertEqual(tree.size, 8)

        try tree.editT((3, 5), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>abcd</p></root>")
        XCTAssertEqual(tree.size, 6)
    }
}

final class CRDTTreeMergeTests: XCTestCase {
    func test_can_delete_nodes_between_element_nodes_with_edit() async throws {
        // 01. Create a tree with 2 paragraphs.
        //       0   1 2 3    4   5 6 7    8
        // <root> <p> a b </p> <p> c d </p> </root>
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")], 0,
                       timeT(), timeT)
        try tree.editT((4, 4), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((5, 5),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "cd")], 0,
                       timeT(), timeT)

        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p><p>cd</p></root>")

        // 02. delete b, c and first paragraph.
        //       0   1 2 3    4
        // <root> <p> a d </p> </root>
        try tree.editT((2, 6), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ad</p></root>")

        let node = tree.toTestTreeNode()
        XCTAssertEqual(node.size, 4)
        XCTAssertEqual(node.children![0].size, 2)
        XCTAssertEqual(node.children![0].children![0].size, 1)
        XCTAssertEqual(node.children![0].children![1].size, 1)

        // 03. insert a new text node at the start of the first paragraph.
        try tree.editT((1, 1), [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "@")], 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>@ad</p></root>")
    }

    func test_can_delete_nodes_between_element_in_different_level_with_edit() async throws {
        // 01. Create a tree with 2 paragraphs.
        //       0   1   2 3 4    5    6   7 8 9    10
        // <root> <p> <b> a b </b> </p> <p> c d </p>  </root>
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.root.rawValue), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1), [CRDTTreeNode(id: posT(), type: "b")], 0, timeT(), timeT)
        try tree.editT((2, 2),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")], 0,
                       timeT(), timeT)
        try tree.editT((6, 6), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((7, 7),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "cd")], 0,
                       timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>ab</b></p><p>cd</p></root>")

        // 02. delete b, c and second paragraph.
        //       0   1   2 3 4    5
        // <root> <p> <b> a d </b> </root>
        try tree.editT((3, 8), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>ad</b></p></root>")
    }
}
