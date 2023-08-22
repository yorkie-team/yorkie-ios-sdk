//
//  CRDTTreeTests.swift
//  YorkieTests
//
//  Created by Jung gyun Ahn on 2023/07/14.
//

import XCTest
@testable import Yorkie

let ITP = CRDTTreePos.initial

/**
 * `betweenEqual` is a helper function that checks the nodes between the given
 * indexes.
 */
func betweenEqual(_ tree: CRDTTree, _ from: Int, _ to: Int, _ expected: [String]) throws {
    var nodes = [CRDTTreeNode]()
    try tree.nodesBetweenByTree(from, to) { node in
        nodes.append(node)
    }

    let results = nodes.compactMap { node in
        if node.isText {
            return "\(node.type).\(node.value)"
        } else {
            return node.type
        }
    }

    for (index, result) in results.enumerated() {
        XCTAssertEqual(result, expected[index])
    }
}

/**
 * `listEqual` is a helper function that checks the nodes in the RGA in Tree.
 */
func listEqual(_ tree: CRDTTree, _ expected: [String]) {
    let results = tree.compactMap { node in
        if node.isText {
            return "\(node.type).\(node.value)"
        } else {
            return node.type
        }
    }

    for (index, result) in results.enumerated() {
        XCTAssertEqual(result, expected[index])
    }
}

/**
 * `dummyContext` is a helper context that is used for testing.
 */
let dummyContext = ChangeContext(id: ChangeID.initial, root: CRDTRoot())

/**
 * `issuePos` is a helper function that issues a new CRDTTreePos.
 */
func issuePos(_ offset: Int32 = 0) -> CRDTTreePos {
    CRDTTreePos(createdAt: dummyContext.issueTimeTicket, offset: offset)
}

/**
 * `issueTime` is a helper function that issues a new TimeTicket.
 */
var issueTime: TimeTicket {
    dummyContext.issueTimeTicket
}

final class CRDTTreeNodeTests: XCTestCase {
    func test_can_be_created() {
        let node = CRDTTreeNode(pos: ITP, type: DefaultTreeNodeType.text.rawValue, value: "hello")

        XCTAssertEqual(node.pos, ITP)
        XCTAssertEqual(node.type, DefaultTreeNodeType.text.rawValue)
        XCTAssertEqual(node.value, "hello")
        XCTAssertEqual(node.size, 5)
        XCTAssertEqual(node.isText, true)
        XCTAssertEqual(node.isRemoved, false)
    }

    func test_can_be_split() throws {
        let para = CRDTTreeNode(pos: ITP, type: "p", children: [])
        try para.append(contentsOf: [CRDTTreeNode(pos: ITP, type: DefaultTreeNodeType.text.rawValue, value: "helloyorkie")])

        XCTAssertEqual(CRDTTreeNode.toXML(node: para), "<p>helloyorkie</p>")
        XCTAssertEqual(para.size, 11)
        XCTAssertEqual(para.isText, false)

        let left = para.children[0]
        let right = try left.split(5)

        XCTAssertEqual(CRDTTreeNode.toXML(node: para), "<p>helloyorkie</p>")
        XCTAssertEqual(para.size, 11)

        XCTAssertEqual(left.value, "hello")
        XCTAssertEqual(right?.value, "yorkie")
        XCTAssertEqual(left.pos, CRDTTreePos(createdAt: TimeTicket.initial, offset: 0))
        XCTAssertEqual(right?.pos, CRDTTreePos(createdAt: TimeTicket.initial, offset: 5))
    }
}

final class CRDTTreeTests: XCTestCase {
    func test_can_inserts_nodes_with_edit() throws {
        //       0
        // <root> </root>
        let tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: "r"), createdAt: issueTime)
        XCTAssertEqual(tree.root.size, 0)
        XCTAssertEqual(tree.toXML(), "<r></r>")
        listEqual(tree, ["r"])

        //           1
        // <root> <p> </p> </root>
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        XCTAssertEqual(tree.toXML(), "<r><p></p></r>")
        listEqual(tree, ["p", "r"])
        XCTAssertEqual(tree.root.size, 2)

        //           1
        // <root> <p> h e l l o </p> </root>
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "hello")], issueTime)
        XCTAssertEqual(tree.toXML(), "<r><p>hello</p></r>")
        listEqual(tree, ["text.hello", "p", "r"])
        XCTAssertEqual(tree.root.size, 7)

        //       0   1 2 3 4 5 6    7   8 9  10 11 12 13    14
        // <root> <p> h e l l o </p> <p> w  o  r  l  d  </p>  </root>
        let para = CRDTTreeNode(pos: issuePos(), type: "p")
        try para.insertAt(CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "world"), 0)
        try tree.editByIndex((7, 7), [para], issueTime)
        XCTAssertEqual(tree.toXML(), "<r><p>hello</p><p>world</p></r>")
        listEqual(tree, ["text.hello", "p", "text.world", "p", "r"])
        XCTAssertEqual(tree.root.size, 14)

        //       0   1 2 3 4 5 6 7    8   9 10 11 12 13 14    15
        // <root> <p> h e l l o ! </p> <p> w  o  r  l  d  </p>  </root>
        try tree.editByIndex((6, 6), [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "!")], issueTime)
        XCTAssertEqual(tree.toXML(), "<r><p>hello!</p><p>world</p></r>")
        listEqual(tree, ["text.hello", "text.!", "p", "text.world", "p", "r"])

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
        try tree.editByIndex((6, 6), [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "~")], issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<r><p>hello~!</p><p>world</p></r>")
        listEqual(tree, [
            "text.hello",
            "text.~",
            "text.!",
            "p",
            "text.world",
            "p",
            "r"
        ])
    }

    func test_can_delete_text_nodes_with_edit() throws {
        // 01. Create a tree with 2 paragraphs.
        //       0   1 2 3    4   5 6 7    8
        // <root> <p> a b </p> <p> c d </p> </root>
        let tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        try tree.editByIndex((4, 4), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((5, 5),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "cd")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), "<root><p>ab</p><p>cd</p></root>")
        listEqual(tree, ["text.ab", "p", "text.cd", "p", "root"])

        var treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 8)
        XCTAssertEqual(treeNode.children![0].size, 2)
        XCTAssertEqual(treeNode.children![0].children![0].size, 2)

        // 02. delete b from first paragraph
        //       0   1 2    3   4 5 6    7
        // <root> <p> a </p> <p> c d </p> </root>
        try tree.editByIndex((2, 3), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>a</p><p>cd</p></root>")
        listEqual(tree, ["text.a", "p", "text.cd", "p", "root"])

        treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 7)
        XCTAssertEqual(treeNode.children![0].size, 1)
        XCTAssertEqual(treeNode.children![0].children![0].size, 1)
    }

    func test_can_delete_nodes_between_element_nodes_with_edit() throws {
        // 01. Create a tree with 2 paragraphs.
        //       0   1 2 3    4   5 6 7    8
        // <root> <p> a b </p> <p> c d </p> </root>
        let tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        try tree.editByIndex((4, 4), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((5, 5),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "cd")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), "<root><p>ab</p><p>cd</p></root>")
        listEqual(tree, ["text.ab", "p", "text.cd", "p", "root"])

        // 02. delete b, c and first paragraph.
        //       0   1 2 3    4
        // <root> <p> a d </p> </root>
        try tree.editByIndex((2, 6), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ad</p></root>")

        // TODO(hackerwins): Uncomment the below line.
        // listEqual(tree, ['text.a', 'text.d', 'p', 'root']);
        let treeNode = tree.toTestTreeNode()
        XCTAssertEqual(treeNode.size, 4) // root
        XCTAssertEqual(treeNode.children![0].size, 2) // p
        XCTAssertEqual(treeNode.children![0].children![0].size, 1) // a
        XCTAssertEqual(treeNode.children![0].children![1].size, 1) // d

        // 03. insert a new text node at the start of the first paragraph.
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "@")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>@ad</p></root>")
    }

    func test_can_merge_different_levels_with_edit() throws {
        // 01. edit between two element nodes in the same hierarchy.
        //       0   1   2   3 4 5    6    7    8
        // <root> <p> <b> <i> a b </i> </b> </p> </root>
        var tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((2, 2), [CRDTTreeNode(pos: issuePos(), type: "i")], issueTime)
        try tree.editByIndex((3, 3),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b><i>ab</i></b></p></root>")
        try tree.editByIndex((5, 6), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>ab</b></p></root>")

        // 02. edit between two element nodes in same hierarchy.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((2, 2), [CRDTTreeNode(pos: issuePos(), type: "i")], issueTime)
        try tree.editByIndex((3, 3),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b><i>ab</i></b></p></root>")
        try tree.editByIndex((6, 7), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><i>ab</i></p></root>")

        // 03. edit between text and element node in same hierarchy.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((2, 2), [CRDTTreeNode(pos: issuePos(), type: "i")], issueTime)
        try tree.editByIndex((3, 3),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b><i>ab</i></b></p></root>")
        try tree.editByIndex((4, 6), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>a</b></p></root>")

        // 04. edit between text and element node in same hierarchy.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((2, 2), [CRDTTreeNode(pos: issuePos(), type: "i")], issueTime)
        try tree.editByIndex((3, 3),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b><i>ab</i></b></p></root>")
        try tree.editByIndex((5, 7), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p></root>")

        // 05. edit between text and element node in same hierarchy.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((2, 2), [CRDTTreeNode(pos: issuePos(), type: "i")], issueTime)
        try tree.editByIndex((3, 3),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b><i>ab</i></b></p></root>")
        try tree.editByIndex((4, 7), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>a</p></root>")

        // 06. edit between text and element node in same hierarchy.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((2, 2), [CRDTTreeNode(pos: issuePos(), type: "i")], issueTime)
        try tree.editByIndex((3, 3),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b><i>ab</i></b></p></root>")
        try tree.editByIndex((3, 7), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p></p></root>")

        // 07. edit between text and element node in same hierarchy.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        try tree.editByIndex((4, 4), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((5, 5), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((6, 6),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "cd")],
                             issueTime)
        try tree.editByIndex((10, 10), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((11, 11),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ef")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p><p><b>cd</b></p><p>ef</p></root>")
        try tree.editByIndex((9, 10), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p><b>cd</b><p>ef</p></root>")
    }

    func test_get_correct_range_from_index() throws {
        let tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((2, 2), [CRDTTreeNode(pos: issuePos(), type: "i")], issueTime)
        try tree.editByIndex((3, 3),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)

        //     0  1  2   3 4 5    6   7   8
        // <root><p><b><i> a b </i></b></p></root>
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b><i>ab</i></b></p></root>")

        var (from, to) = try tree.pathToPosRange([0])
        var fromIdx = try tree.toIndex(from)
        var toIdx = try tree.toIndex(to)
        XCTAssertEqual([fromIdx, toIdx], [7, 8])

        (from, to) = try tree.pathToPosRange([0, 0])
        fromIdx = try tree.toIndex(from)
        toIdx = try tree.toIndex(to)
        XCTAssertEqual([fromIdx, toIdx], [6, 7])

        (from, to) = try tree.pathToPosRange([0, 0, 0])
        fromIdx = try tree.toIndex(from)
        toIdx = try tree.toIndex(to)
        XCTAssertEqual(fromIdx, 5)
        XCTAssertEqual(toIdx, 6)
        XCTAssertEqual(tree.size, 8)

        var range = try tree.toPosRange((0, 5))
        var rangeResult = try tree.toIndexRange(range)
        XCTAssertEqual(rangeResult.0, 0)
        XCTAssertEqual(rangeResult.1, 5)

        range = try tree.toPosRange((5, 7))
        rangeResult = try tree.toIndexRange(range)
        XCTAssertEqual(rangeResult.0, 5)
        XCTAssertEqual(rangeResult.1, 7)
    }
}

final class CRDTTreeSplitTests {
    func skip_test_can_split_text_nodes() throws {
        // 00. Create a tree with 2 paragraphs.
        //       0   1     6     11
        // <root> <p> hello world  </p> </root>
        let tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "helloworld")],
                             issueTime)

        // 01. Split left side of 'helloworld'.
        try tree.split(1, 1)
        try betweenEqual(tree, 1, 11, ["text.helloworld"])

        // 02. Split right side of 'helloworld'.
        try tree.split(11, 1)
        try betweenEqual(tree, 1, 11, ["text.helloworld"])

        // 03. Split 'helloworld' into 'hello' and 'world'.
        try tree.split(6, 1)
        try betweenEqual(tree, 1, 11, ["text.hello", "text.world"])
    }

    func skip_test_can_split_element_nodes() throws {
        // 01. Split position 1.
        var tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p></root>")
        try tree.split(1, 2)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p></p><p>ab</p></root>")
        XCTAssertEqual(tree.size, 6)

        // 02. Split position 2.
        //       0   1 2 3    4
        // <root> <p> a b </p> </root>
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p></root>")
        try tree.split(2, 2)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>a</p><p>b</p></root>")
        XCTAssertEqual(tree.size, 6)

        // 03. Split position 3.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p></root>")
        try tree.split(3, 2)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p><p></p></root>")
        XCTAssertEqual(tree.size, 6)

        // 04. Split position 3.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        try tree.editByIndex((3, 3),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "cd")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>abcd</p></root>")
        try tree.split(3, 2)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p><p>cd</p></root>")
        XCTAssertEqual(tree.size, 8)

        // 05. Split multiple nodes level 1.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((2, 2),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>ab</b></p></root>")
        try tree.split(3, 1)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>ab</b></p></root>")
        XCTAssertEqual(tree.size, 6)

        // Split multiple nodes level 2.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((2, 2),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>ab</b></p></root>")
        try tree.split(3, 2)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>a</b><b>b</b></p></root>")
        XCTAssertEqual(tree.size, 8)

        // Split multiple nodes level 3.
        tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1), [CRDTTreeNode(pos: issuePos(), type: "b")], issueTime)
        try tree.editByIndex((2, 2),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>ab</b></p></root>")
        try tree.split(3, 3)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p><b>a</b></p><p><b>b</b></p></root>")
        XCTAssertEqual(tree.size, 10)
    }

    func skip_test_can_split_and_merge_element_nodes_by_edit() throws {
        let tree = CRDTTree(root: CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.root.rawValue), createdAt: issueTime)
        try tree.editByIndex((0, 0), [CRDTTreeNode(pos: issuePos(), type: "p")], issueTime)
        try tree.editByIndex((1, 1),
                             [CRDTTreeNode(pos: issuePos(), type: DefaultTreeNodeType.text.rawValue, value: "abcd")],
                             issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>abcd</p></root>")
        XCTAssertEqual(tree.size, 6)

        //       0   1 2 3    4   5 6 7    8
        // <root> <p> a b </p> <p> c d </p> </root>
        try tree.split(3, 2)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>ab</p><p>cd</p></root>")
        XCTAssertEqual(tree.size, 8)

        try tree.editByIndex((3, 5), nil, issueTime)
        XCTAssertEqual(tree.toXML(), /* html */ "<root><p>abcd</p></root>")
        XCTAssertEqual(tree.size, 6)
    }
}
