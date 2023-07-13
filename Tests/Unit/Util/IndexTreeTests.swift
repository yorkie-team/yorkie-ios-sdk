//
//  IndexTreeTests.swift
//  YorkieTests
//
//  Created by Jung gyun Ahn on 2023/07/03.
//

import XCTest
@testable import Yorkie

final class IndexTreeTests: XCTestCase {
    /**
     * `betweenEqual` is a helper function that checks the nodes between the given
     * indexes.
     */
    func nodesBetweenEqual(_ tree: IndexTree<CRDTTreeNode>,
                           _ from: Int,
                           _ to: Int,
                           _ expected: [String]) throws
    {
        var nodes = [CRDTTreeNode]()
        try tree.nodesBetween(from, to) {
            nodes.append($0)
        }

        for (index, node) in nodes.enumerated() {
            XCTAssertEqual(self.toDiagnostic(node), expected[index])
        }
    }

    /**
     * `toDiagnostic` is a helper function that converts the given node to a
     * diagnostic string.
     */
    func toDiagnostic(_ node: CRDTTreeNode?) -> String {
        guard let node else {
            return ""
        }

        if node.isText {
            return "\(node.type).\(node.value)"
        }
        return node.type
    }

    func test_can_find_position_from_the_given_offset() async throws {
        //    0   1 2 3 4 5 6    7   8 9  10 11 12 13    14
        // <r> <p> h e l l o </p> <p> w  o  r  l  d  </p>  </r>
        let tree = try await buildIndexTree(
            ElementNode(type: "r",
                        children: [
                            ElementNode(type: "p", children: [TextNode(value: "hello")]),
                            ElementNode(type: "p", children: [TextNode(value: "world")])
                        ])
        )

        var pos = try tree?.findTreePos(0)
        XCTAssertEqual(self.toDiagnostic(pos?.node), "r")
        XCTAssertEqual(pos?.offset, 0)
        pos = try tree?.findTreePos(1)
        XCTAssertEqual(self.toDiagnostic(pos?.node), "text.hello")
        XCTAssertEqual(pos?.offset, 0)
        pos = try tree?.findTreePos(6)
        XCTAssertEqual(self.toDiagnostic(pos?.node), "text.hello")
        XCTAssertEqual(pos?.offset, 5)
        pos = try tree?.findTreePos(6, false)
        XCTAssertEqual(self.toDiagnostic(pos?.node), "p")
        XCTAssertEqual(pos?.offset, 1)
        pos = try tree?.findTreePos(7)
        XCTAssertEqual(self.toDiagnostic(pos?.node), "r")
        XCTAssertEqual(pos?.offset, 1)
        pos = try tree?.findTreePos(8)
        XCTAssertEqual(self.toDiagnostic(pos?.node), "text.world")
        XCTAssertEqual(pos?.offset, 0)
        pos = try tree?.findTreePos(13)
        XCTAssertEqual(self.toDiagnostic(pos?.node), "text.world")
        XCTAssertEqual(pos?.offset, 5)
        pos = try tree?.findTreePos(14)
        XCTAssertEqual(self.toDiagnostic(pos?.node), "r")
        XCTAssertEqual(pos?.offset, 2)
    }

    func test_can_find_right_node_from_the_given_offset_in_postorder_traversal() async throws {
        //       0   1 2 3    4   6 7     8
        // <root> <p> a b </p> <p> c d</p> </root>
        guard let tree = try await buildIndexTree(
            ElementNode(type: DefaultTreeNodeType.root.rawValue,
                        children: [
                            ElementNode(type: "p", children: [TextNode(value: "ab")]),
                            ElementNode(type: "p", children: [TextNode(value: "cd")])
                        ])
        ) else {
            XCTAssertTrue(false, "Can't build tree")
            return
        }

        // postorder traversal: "ab", <b>, "cd", <p>, <root>
        XCTAssertEqual(try? tree.findPostorderRight(tree.findTreePos(0)).type, "text")
        XCTAssertEqual(try? tree.findPostorderRight(tree.findTreePos(1)).type, "text")
        XCTAssertEqual(try? tree.findPostorderRight(tree.findTreePos(3)).type, "p")
        XCTAssertEqual(try? tree.findPostorderRight(tree.findTreePos(4)).type, "text")
        XCTAssertEqual(try? tree.findPostorderRight(tree.findTreePos(5)).type, "text")
        XCTAssertEqual(try? tree.findPostorderRight(tree.findTreePos(7)).type, "p")
        XCTAssertEqual(try? tree.findPostorderRight(tree.findTreePos(8)).type, DefaultTreeNodeType.root.rawValue)
    }

    func test_can_find_common_ancestor_of_two_given_nodes() async throws {
        guard let tree = try await buildIndexTree(
            ElementNode(type: DefaultTreeNodeType.root.rawValue,
                        children: [
                            ElementNode(type: "p",
                                        children: [
                                            ElementNode(type: "b", children: [TextNode(value: "ab")]),
                                            ElementNode(type: "b", children: [TextNode(value: "cd")])
                                        ])
                        ])
        ) else {
            XCTAssertTrue(false, "Can't build tree")
            return
        }

        let nodeAB = try tree.findTreePos(3, true).node
        let nodeCD = try tree.findTreePos(7, true).node

        XCTAssertEqual(self.toDiagnostic(nodeAB), "text.ab")
        XCTAssertEqual(self.toDiagnostic(nodeCD), "text.cd")
        XCTAssertEqual(findCommonAncestor(nodeA: nodeAB, nodeB: nodeCD)?.type, "p")
    }

    func test_can_traverse_nodes_between_two_given_positions() async throws {
        //       0   1 2 3    4   5 6 7 8    9   10 11 12   13
        // <root> <p> a b </p> <p> c d e </p> <p>  f  g  </p>  </root>
        guard let tree = try await buildIndexTree(
            ElementNode(type: DefaultTreeNodeType.root.rawValue,
                        children: [
                            ElementNode(type: "p",
                                        children: [
                                            TextNode(value: "a"),
                                            TextNode(value: "b")
                                        ]),
                            ElementNode(type: "p", children: [TextNode(value: "cde")]),
                            ElementNode(type: "p", children: [TextNode(value: "fg")])
                        ])
        ) else {
            XCTAssertTrue(false, "Can't build tree")
            return
        }

        try self.nodesBetweenEqual(tree, 2, 11, [
            "text.b",
            "p",
            "text.cde",
            "p",
            "text.fg",
            "p"
        ])
        try self.nodesBetweenEqual(tree, 2, 6, ["text.b", "p", "text.cde", "p"])
        try self.nodesBetweenEqual(tree, 0, 1, ["p"])
        try self.nodesBetweenEqual(tree, 3, 4, ["p"])
        try self.nodesBetweenEqual(tree, 3, 5, ["p", "p"])
    }

    func test_can_convert_index_to_pos() async throws {
        //       0   1 2 3 4    5   6 7 8 9 10 11 12  13  14 15 16  17 18 19 20   21
        // <root> <p> a b c </p> <p> c d e f  g  h </p> <p> i  j   k  l  m  n  </p>  </root>
        guard let tree = try await buildIndexTree(
            ElementNode(type: DefaultTreeNodeType.root.rawValue,
                        children: [
                            ElementNode(type: "p",
                                        children: [
                                            TextNode(value: "ab"),
                                            TextNode(value: "c")
                                        ]),
                            ElementNode(type: "p",
                                        children: [
                                            TextNode(value: "cde"),
                                            TextNode(value: "fgh")
                                        ]),
                            ElementNode(type: "p",
                                        children: [
                                            TextNode(value: "ij"),
                                            TextNode(value: "k"),
                                            TextNode(value: "l"),
                                            TextNode(value: "mn")
                                        ])
                        ])
        ) else {
            XCTAssertTrue(false, "Can't build tree")
            return
        }

        for index in 0 ..< 22 {
            let pos = try tree.findTreePos(index, true)
            XCTAssertEqual(try tree.indexOf(pos), index)
        }
    }

    func test_can_find_treePos_from_given_path() async throws {
        //       0   1 2 3    4   5 6 7 8    9   10 11 12   13
        // <root> <p> a b </p> <p> c d e </p> <p>  f  g  </p>  </root>
        guard let tree = try await buildIndexTree(
            ElementNode(type: DefaultTreeNodeType.root.rawValue,
                        children: [
                            ElementNode(type: "p",
                                        children: [
                                            TextNode(value: "a"),
                                            TextNode(value: "b")
                                        ]),
                            ElementNode(type: "p",
                                        children: [
                                            TextNode(value: "cde")
                                        ]),
                            ElementNode(type: "p",
                                        children: [
                                            TextNode(value: "fg")
                                        ])
                        ])
        ) else {
            XCTAssertTrue(false, "Can't build tree")
            return
        }

        var pos = try tree.pathToTreePos([0])
        XCTAssertEqual(self.toDiagnostic(pos.node), DefaultTreeNodeType.root.rawValue)
        XCTAssertEqual(pos.offset, 0)

        pos = try tree.pathToTreePos([0, 0])
        XCTAssertEqual(self.toDiagnostic(pos.node), "text.a")
        XCTAssertEqual(pos.offset, 0)

        pos = try tree.pathToTreePos([0, 1])
        XCTAssertEqual(self.toDiagnostic(pos.node), "text.a")
        XCTAssertEqual(pos.offset, 1)

        pos = try tree.pathToTreePos([0, 2])
        XCTAssertEqual(self.toDiagnostic(pos.node), "text.b")
        XCTAssertEqual(pos.offset, 1)

        pos = try tree.pathToTreePos([1])
        XCTAssertEqual(self.toDiagnostic(pos.node), DefaultTreeNodeType.root.rawValue)
        XCTAssertEqual(pos.offset, 1)

        pos = try tree.pathToTreePos([1, 0])
        XCTAssertEqual(self.toDiagnostic(pos.node), "text.cde")
        XCTAssertEqual(pos.offset, 0)

        pos = try tree.pathToTreePos([1, 1])
        XCTAssertEqual(self.toDiagnostic(pos.node), "text.cde")
        XCTAssertEqual(pos.offset, 1)

        pos = try tree.pathToTreePos([1, 2])
        XCTAssertEqual(self.toDiagnostic(pos.node), "text.cde")
        XCTAssertEqual(pos.offset, 2)

        pos = try tree.pathToTreePos([1, 3])
        XCTAssertEqual(self.toDiagnostic(pos.node), "text.cde")
        XCTAssertEqual(pos.offset, 3)

        pos = try tree.pathToTreePos([2])
        XCTAssertEqual(self.toDiagnostic(pos.node), DefaultTreeNodeType.root.rawValue)
        XCTAssertEqual(pos.offset, 2)

        pos = try tree.pathToTreePos([2, 0])
        XCTAssertEqual(self.toDiagnostic(pos.node), "text.fg")
        XCTAssertEqual(pos.offset, 0)

        pos = try tree.pathToTreePos([2, 1])
        XCTAssertEqual(self.toDiagnostic(pos.node), "text.fg")
        XCTAssertEqual(pos.offset, 1)

        pos = try tree.pathToTreePos([2, 2])
        XCTAssertEqual(self.toDiagnostic(pos.node), "text.fg")
        XCTAssertEqual(pos.offset, 2)

        pos = try tree.pathToTreePos([3])
        XCTAssertEqual(self.toDiagnostic(pos.node), DefaultTreeNodeType.root.rawValue)
        XCTAssertEqual(pos.offset, 3)
    }

    func test_can_find_path_from_given_treePos() async throws {
        //       0  1  2    3 4 5 6 7     8   9 10 11 12 13  14 15  16
        // <root><tc><p><tn> A B C D </tn><tn> E  F G  H </tn><p></tc></root>
        guard let tree = try await buildIndexTree(
            ElementNode(type: DefaultTreeNodeType.root.rawValue,
                        children: [
                            ElementNode(type: "tc",
                                        children: [
                                            ElementNode(type: "p",
                                                        children: [
                                                            ElementNode(type: "tn",
                                                                        children: [
                                                                            TextNode(value: "AB"),
                                                                            TextNode(value: "CD")
                                                                        ]),
                                                            ElementNode(type: "tn",
                                                                        children: [
                                                                            TextNode(value: "EF"),
                                                                            TextNode(value: "GH")
                                                                        ])
                                                        ])
                                        ])
                        ])
        ) else {
            XCTAssertTrue(false, "Can't build tree")
            return
        }

        var pos = try tree.findTreePos(0)
        XCTAssertEqual(try tree.treePosToPath(pos), [0])

        pos = try tree.findTreePos(1)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0])

        pos = try tree.findTreePos(2)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 0])

        pos = try tree.findTreePos(3)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 0, 0])

        pos = try tree.findTreePos(4)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 0, 1])

        pos = try tree.findTreePos(5)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 0, 2])

        pos = try tree.findTreePos(6)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 0, 3])

        pos = try tree.findTreePos(7)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 0, 4])

        pos = try tree.findTreePos(8)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 1])

        pos = try tree.findTreePos(9)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 1, 0])

        pos = try tree.findTreePos(10)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 1, 1])

        pos = try tree.findTreePos(11)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 1, 2])

        pos = try tree.findTreePos(12)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 1, 3])

        pos = try tree.findTreePos(13)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 1, 4])

        pos = try tree.findTreePos(14)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 0, 2])

        pos = try tree.findTreePos(15)
        XCTAssertEqual(try tree.treePosToPath(pos), [0, 1])

        pos = try tree.findTreePos(16)
        XCTAssertEqual(try tree.treePosToPath(pos), [1])
    }

    func test_can_find_index_from_given_path() async throws {
        //      <root>
        //        |
        //       <tc>
        //      /   \
        //    <p>   <p>
        //     |     |
        //   <tn>   <tn>
        //    |      |
        //    AB     CD
        //
        //       0    1   2    3 4 5     6    7 8 9     10   11     12
        // <root> <tc> <p> <tn> A B </tn> <tn> C D </tn>  <p>  </tc>  </root>
        guard let tree = try await buildIndexTree(
            ElementNode(type: DefaultTreeNodeType.root.rawValue,
                        children: [
                            ElementNode(type: "tc",
                                        children: [
                                            ElementNode(type: "p",
                                                        children: [
                                                            ElementNode(type: "tn",
                                                                        children: [
                                                                            TextNode(value: "AB")
                                                                        ]),
                                                            ElementNode(type: "tn",
                                                                        children: [
                                                                            TextNode(value: "CD")
                                                                        ])
                                                        ])
                                        ])
                        ])
        ) else {
            XCTAssertTrue(false, "Can't build tree")
            return
        }

        var pos = try tree.pathToIndex([0])
        XCTAssertEqual(pos, 0)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 0])

        pos = try tree.pathToIndex([0, 0])
        XCTAssertEqual(pos, 1)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 0, 0])

        pos = try tree.pathToIndex([0, 0, 0])
        XCTAssertEqual(pos, 2)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 0, 0, 0])

        pos = try tree.pathToIndex([0, 0, 0, 0])
        XCTAssertEqual(pos, 3)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 0, 0, 1])

        pos = try tree.pathToIndex([0, 0, 0, 1])
        XCTAssertEqual(pos, 4)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 0, 0, 2])

        pos = try tree.pathToIndex([0, 0, 0, 2])
        XCTAssertEqual(pos, 5)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 0, 1])

        pos = try tree.pathToIndex([0, 0, 1])
        XCTAssertEqual(pos, 6)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 0, 1, 0])

        pos = try tree.pathToIndex([0, 0, 1, 0])
        XCTAssertEqual(pos, 7)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 0, 1, 1])

        pos = try tree.pathToIndex([0, 0, 1, 1])
        XCTAssertEqual(pos, 8)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 0, 1, 2])

        pos = try tree.pathToIndex([0, 0, 1, 2])
        XCTAssertEqual(pos, 9)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 0, 2])

        pos = try tree.pathToIndex([0, 0, 2])
        XCTAssertEqual(pos, 10)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [0, 1])

        pos = try tree.pathToIndex([0, 1])
        XCTAssertEqual(pos, 11)
        XCTAssertEqual(try tree.indexToPath(pos + 1), [1])
    }
}
