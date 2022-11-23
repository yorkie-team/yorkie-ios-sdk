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

private class StringNode: SplayNode<String> {
    var removed: Bool = false
    override init(_ value: String) {
        super.init(value)
    }

    static func create(_ value: String) -> StringNode {
        return StringNode(value)
    }

    override var length: Int {
        if self.removed {
            return 0
        }
        return self.value.count
    }
}

class SplayTreeTests: XCTestCase {
    func test_can_insert_values_and_splay_them() {
        let tree = SplayTree<String>()

        let nodeA = tree.insert(StringNode.create("A2"))
        XCTAssertEqual(tree.structureAsString, "[2,2]A2")
        XCTAssertEqual(tree.getRoot()?.value, "A2")
        let nodeB = tree.insert(StringNode.create("B23"))
        XCTAssertEqual(tree.structureAsString, "[2,2]A2[5,3]B23")
        XCTAssertEqual(tree.getRoot()?.value, "B23")
        let nodeC = tree.insert(StringNode.create("C234"))
        XCTAssertEqual(tree.structureAsString, "[2,2]A2[5,3]B23[9,4]C234")
        XCTAssertEqual(tree.getRoot()?.value, "C234")
        let nodeD = tree.insert(StringNode.create("D2345"))
        XCTAssertEqual(tree.structureAsString, "[2,2]A2[5,3]B23[9,4]C234[14,5]D2345")
        XCTAssertEqual(tree.getRoot()?.value, "D2345")

        XCTAssertEqual(tree.indexOf(nodeA), 0)
        XCTAssertEqual(tree.indexOf(nodeB), 2)
        XCTAssertEqual(tree.indexOf(nodeC), 5)
        XCTAssertEqual(tree.indexOf(nodeD), 9)

        var result = tree.find(position: -1)
        XCTAssertNil(result.node)
        XCTAssertEqual(result.offset, 0)

        result = tree.find(position: 0)
        XCTAssertEqual(result.node?.value, "A2")
        XCTAssertEqual(result.offset, 0)

        result = tree.find(position: 1)
        XCTAssertEqual(result.node?.value, "A2")
        XCTAssertEqual(result.offset, 1)

        result = tree.find(position: 2)
        XCTAssertEqual(result.node?.value, "A2")
        XCTAssertEqual(result.offset, 2)

        result = tree.find(position: 3)
        XCTAssertEqual(result.node?.value, "B23")
        XCTAssertEqual(result.offset, 1)

        result = tree.find(position: 4)
        XCTAssertEqual(result.node?.value, "B23")
        XCTAssertEqual(result.offset, 2)

        result = tree.find(position: 5)
        XCTAssertEqual(result.node?.value, "B23")
        XCTAssertEqual(result.offset, 3)

        result = tree.find(position: 6)
        XCTAssertEqual(result.node?.value, "C234")
        XCTAssertEqual(result.offset, 1)
    }

    func test_can_delete_the_given_node() {
        let tree = SplayTree<String>()

        let nodeH = tree.insert(StringNode.create("H"))
        XCTAssertEqual(tree.structureAsString, "[1,1]H")
        let nodeE = tree.insert(StringNode.create("E"))
        XCTAssertEqual(tree.structureAsString, "[1,1]H[2,1]E")
        let nodeL = tree.insert(StringNode.create("LL"))
        XCTAssertEqual(tree.structureAsString, "[1,1]H[2,1]E[4,2]LL")
        let nodeO = tree.insert(StringNode.create("O"))
        XCTAssertEqual(tree.structureAsString, "[1,1]H[2,1]E[4,2]LL[5,1]O")

        tree.delete(nodeE)
        XCTAssertEqual(tree.structureAsString, "[4,1]H[3,2]LL[1,1]O")

        XCTAssertEqual(tree.indexOf(nodeH), 0)
        XCTAssertEqual(tree.indexOf(nodeE), -1)
        XCTAssertEqual(tree.indexOf(nodeL), 1)
        XCTAssertEqual(tree.indexOf(nodeO), 3)
    }

    private var sampleTree: (tree: SplayTree<String>, nodes: [StringNode]) = {
        let tree = SplayTree<String>()
        var nodes = [StringNode]()

        for value in ["A", "BB", "CCC", "DDDD", "EEEEE", "FFFF", "GGG", "HH", "I"] {
            let node = StringNode.create(value)
            tree.insert(node)
            nodes.append(node)
        }

        return (tree, nodes)
    }()

    private func removeNodes(_ nodes: [StringNode], from: Int, to: Int) {
        for index in from ... to {
            nodes[index].removed = true
        }
    }

    private func sumOfWeight(_ nodes: [StringNode], from: Int, to: Int) -> Int {
        var sum = 0
        for index in from ... to {
            sum += nodes[index].weight
        }
        return sum
    }

    func test_can_delete_range_between_the_given_2_boundary_nodes_first() {
        let testTree = self.sampleTree
        // check the filtering of rangeDelete
        XCTAssertEqual("[1,1]A[3,2]BB[6,3]CCC[10,4]DDDD[15,5]EEEEE[19,4]FFFF[22,3]GGG[24,2]HH[25,1]I", testTree.tree.structureAsString)
        self.removeNodes(testTree.nodes, from: 7, to: 8)
        XCTAssertEqual("[1,1]A[3,2]BB[6,3]CCC[10,4]DDDD[15,5]EEEEE[19,4]FFFF[22,3]GGG[24,0]HH[25,0]I", testTree.tree.structureAsString)
        testTree.tree.removeRange(leftBoundary: testTree.nodes[6])
        XCTAssertEqual(testTree.tree.indexOf(testTree.nodes[6]), 19)
        XCTAssertEqual("[1,1]A[3,2]BB[6,3]CCC[10,4]DDDD[15,5]EEEEE[19,4]FFFF[22,3]GGG[0,0]HH[0,0]I", testTree.tree.structureAsString)
        XCTAssertTrue(testTree.nodes[6] === testTree.tree.getRoot())
        XCTAssertEqual(testTree.nodes[6].weight, 22)
        XCTAssertEqual(self.sumOfWeight(testTree.nodes, from: 7, to: 8), 0)
    }

    func test_can_delete_range_between_the_given_2_boundary_nodes_second() {
        let testTree = self.sampleTree
        // check the case 1 of rangeDelete
        self.removeNodes(testTree.nodes, from: 3, to: 6)
        testTree.tree.removeRange(leftBoundary: testTree.nodes[2], rightBoundary: testTree.nodes[7])
        XCTAssertTrue(testTree.nodes[7] === testTree.tree.getRoot())
        XCTAssertEqual(testTree.nodes[7].weight, 9)
        XCTAssertEqual(testTree.nodes[2].weight, 6)
        XCTAssertEqual(self.sumOfWeight(testTree.nodes, from: 3, to: 6), 0)
    }

    func test_can_delete_range_between_the_given_2_boundary_nodes_third() {
        let testTree = self.sampleTree
        testTree.tree.splayNode(testTree.nodes[6])
        testTree.tree.splayNode(testTree.nodes[2])
        // check the case 2 of rangeDelete
        self.removeNodes(testTree.nodes, from: 3, to: 7)
        testTree.tree.removeRange(leftBoundary: testTree.nodes[2], rightBoundary: testTree.nodes[8])
        XCTAssertTrue(testTree.nodes[8] === testTree.tree.getRoot())
        XCTAssertEqual(testTree.nodes[8].weight, 7)
        XCTAssertEqual(testTree.nodes[2].weight, 6)
        XCTAssertEqual(self.sumOfWeight(testTree.nodes, from: 3, to: 7), 0)
    }

    func test_splay() {
        let tree = SplayTree<String>()

        tree.insert(StringNode.create("A2"))
        XCTAssertEqual(tree.structureAsString, "[2,2]A2")
        XCTAssertEqual(tree.getRoot()?.value, "A2")
        let nodeB = tree.insert(StringNode.create("B23"))
        XCTAssertEqual(tree.structureAsString, "[2,2]A2[5,3]B23")
        XCTAssertEqual(tree.getRoot()?.value, "B23")
        tree.insert(StringNode.create("C234"))
        XCTAssertEqual(tree.structureAsString, "[2,2]A2[5,3]B23[9,4]C234")
        XCTAssertEqual(tree.getRoot()?.value, "C234")
        tree.insert(StringNode.create("D2345"))
        XCTAssertEqual(tree.structureAsString, "[2,2]A2[5,3]B23[9,4]C234[14,5]D2345")
        XCTAssertEqual(tree.getRoot()?.value, "D2345")

        tree.splayNode(nodeB)
        XCTAssertEqual(tree.structureAsString, "[2,2]A2[14,3]B23[9,4]C234[5,5]D2345")

        let (node, _) = tree.find(position: 6)
        XCTAssertEqual(node?.value, "C234")
    }
}
