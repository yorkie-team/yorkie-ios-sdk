/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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

/// Ported from yorkie-js-sdk `packages/sdk/src/util/treelist.spec.ts`.
private final class TestValue: TreeListValue {
    var isRemoved: Bool
    var content: String

    init(_ content: String, removed: Bool = false) {
        self.content = content
        self.isRemoved = removed
    }

    var toTestString: String {
        return self.content
    }
}

private func newNode(_ content: String) -> TreeListNode<TestValue> {
    return TreeListNode(TestValue(content))
}

private func newRemovedNode(_ content: String) -> TreeListNode<TestValue> {
    return TreeListNode(TestValue(content, removed: true))
}

private func rebuildLiveList(_ tree: TreeList<TestValue>) throws -> [TreeListNode<TestValue>] {
    var result = [TreeListNode<TestValue>]()
    for index in 0 ..< tree.length {
        try result.append(tree.find(index))
    }
    return result
}

/// Simple seeded LCG so the stress test is deterministic across runs/platforms.
private func makeRng(_ seed: UInt32) -> () -> Double {
    var state = seed
    return {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / Double(0x1_0000_0000)
    }
}

class TreeListTests: XCTestCase {
    func test_insert_and_find() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        XCTAssertEqual(tree.length, 0)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        XCTAssertEqual(tree.length, 1)

        let nodeB = newNode("B")
        tree.insertAfter(nodeA, nodeB)
        XCTAssertEqual(tree.length, 2)

        let nodeC = newNode("C")
        tree.insertAfter(nodeB, nodeC)
        XCTAssertEqual(tree.length, 3)

        XCTAssertTrue(try tree.find(0) === nodeA)
        XCTAssertTrue(try tree.find(1) === nodeB)
        XCTAssertTrue(try tree.find(2) === nodeC)
    }

    func test_insert_in_the_middle() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        let nodeC = newNode("C")
        tree.insertAfter(nodeA, nodeC)

        let nodeB = newNode("B")
        tree.insertAfter(nodeA, nodeB)
        XCTAssertEqual(tree.length, 3)

        XCTAssertTrue(try tree.find(0) === nodeA)
        XCTAssertTrue(try tree.find(1) === nodeB)
        XCTAssertTrue(try tree.find(2) === nodeC)
    }

    func test_insert_after_tombstone() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        let nodeB = newNode("B")
        tree.insertAfter(nodeA, nodeB)

        nodeA.getValue().isRemoved = true
        tree.updateWeight(nodeA)
        XCTAssertEqual(tree.length, 1)

        let nodeC = newNode("C")
        tree.insertAfter(nodeA, nodeC)
        XCTAssertEqual(tree.length, 2)

        XCTAssertTrue(try tree.find(0) === nodeC)
        XCTAssertTrue(try tree.find(1) === nodeB)
    }

    func test_delete() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        let nodeB = newNode("B")
        tree.insertAfter(nodeA, nodeB)
        let nodeC = newNode("C")
        tree.insertAfter(nodeB, nodeC)
        XCTAssertEqual(tree.length, 3)

        tree.delete(nodeB)
        XCTAssertEqual(tree.length, 2)

        XCTAssertTrue(try tree.find(0) === nodeA)
        XCTAssertTrue(try tree.find(1) === nodeC)
    }

    func test_delete_preserves_node_identity() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        var nodes = [TreeListNode<TestValue>]()
        var prev = dummyHead
        for index in 0 ..< 5 {
            let content = String(UnicodeScalar(UInt8(Character("A").asciiValue! + UInt8(index))))
            let node = newNode(content)
            tree.insertAfter(prev, node)
            nodes.append(node)
            prev = node
        }
        XCTAssertEqual(tree.length, 5)

        tree.delete(nodes[2]) // Delete C
        XCTAssertEqual(tree.length, 4)

        XCTAssertTrue(try tree.find(0) === nodes[0]) // A
        XCTAssertTrue(try tree.find(1) === nodes[1]) // B
        XCTAssertTrue(try tree.find(2) === nodes[3]) // D
        XCTAssertTrue(try tree.find(3) === nodes[4]) // E
    }

    func test_delete_first_and_last_nodes() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        let nodeB = newNode("B")
        tree.insertAfter(nodeA, nodeB)
        let nodeC = newNode("C")
        tree.insertAfter(nodeB, nodeC)

        tree.delete(nodeA)
        XCTAssertEqual(tree.length, 2)
        XCTAssertTrue(try tree.find(0) === nodeB)

        tree.delete(nodeC)
        XCTAssertEqual(tree.length, 1)
        XCTAssertTrue(try tree.find(0) === nodeB)
    }

    func test_delete_tombstoned_node() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        let nodeB = newNode("B")
        tree.insertAfter(nodeA, nodeB)
        let nodeC = newNode("C")
        tree.insertAfter(nodeB, nodeC)

        nodeB.getValue().isRemoved = true
        tree.updateWeight(nodeB)
        XCTAssertEqual(tree.length, 2)

        tree.delete(nodeB)
        XCTAssertEqual(tree.length, 2)

        XCTAssertTrue(try tree.find(0) === nodeA)
        XCTAssertTrue(try tree.find(1) === nodeC)
    }

    func test_delete_all_nodes() {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        let nodeB = newNode("B")
        tree.insertAfter(nodeA, nodeB)

        tree.delete(nodeA)
        tree.delete(nodeB)
        tree.delete(dummyHead)

        XCTAssertEqual(tree.length, 0)
    }

    func test_tombstone_and_update_weight() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        let nodeB = newNode("B")
        tree.insertAfter(nodeA, nodeB)
        let nodeC = newNode("C")
        tree.insertAfter(nodeB, nodeC)
        XCTAssertEqual(tree.length, 3)

        nodeB.getValue().isRemoved = true
        tree.updateWeight(nodeB)
        XCTAssertEqual(tree.length, 2)

        XCTAssertTrue(try tree.find(0) === nodeA)
        XCTAssertTrue(try tree.find(1) === nodeC)
        XCTAssertThrowsError(try tree.find(2))
    }

    func test_multiple_tombstones() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        var nodes = [TreeListNode<TestValue>]()
        var prev = dummyHead
        for index in 0 ..< 6 {
            let content = String(UnicodeScalar(UInt8(Character("A").asciiValue! + UInt8(index))))
            let node = newNode(content)
            tree.insertAfter(prev, node)
            nodes.append(node)
            prev = node
        }
        XCTAssertEqual(tree.length, 6)

        nodes[1].getValue().isRemoved = true // B
        tree.updateWeight(nodes[1])
        nodes[3].getValue().isRemoved = true // D
        tree.updateWeight(nodes[3])
        nodes[5].getValue().isRemoved = true // F
        tree.updateWeight(nodes[5])
        XCTAssertEqual(tree.length, 3)

        XCTAssertTrue(try tree.find(0) === nodes[0]) // A
        XCTAssertTrue(try tree.find(1) === nodes[2]) // C
        XCTAssertTrue(try tree.find(2) === nodes[4]) // E
    }

    func test_find_out_of_bounds() {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        XCTAssertThrowsError(try tree.find(0))

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)

        XCTAssertThrowsError(try tree.find(-1))
        XCTAssertThrowsError(try tree.find(1))
    }

    func test_single_live_node_tree() throws {
        let node = newNode("A")
        let tree = TreeList<TestValue>(node)
        XCTAssertEqual(tree.length, 1)

        XCTAssertTrue(try tree.find(0) === node)

        tree.delete(node)
        XCTAssertEqual(tree.length, 0)
    }

    func test_large_sequential_insert_and_find() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let count = 100
        var nodes = [TreeListNode<TestValue>]()
        var prev = dummyHead
        for index in 0 ..< count {
            let node = newNode("\(index)")
            tree.insertAfter(prev, node)
            nodes.append(node)
            prev = node
        }
        XCTAssertEqual(tree.length, count)

        for index in 0 ..< count {
            XCTAssertTrue(try tree.find(index) === nodes[index])
        }
    }

    func test_large_sequential_insert_tombstone_and_find() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let count = 100
        var nodes = [TreeListNode<TestValue>]()
        var prev = dummyHead
        for index in 0 ..< count {
            let node = newNode("\(index)")
            tree.insertAfter(prev, node)
            nodes.append(node)
            prev = node
        }

        var step = 0
        while step < count {
            nodes[step].getValue().isRemoved = true
            tree.updateWeight(nodes[step])
            step += 2
        }
        XCTAssertEqual(tree.length, count / 2)

        var idx = 0
        step = 1
        while step < count {
            XCTAssertTrue(try tree.find(idx) === nodes[step])
            idx += 1
            step += 2
        }
    }

    func test_large_sequential_insert_and_delete() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let count = 100
        var nodes = [TreeListNode<TestValue>]()
        var prev = dummyHead
        for index in 0 ..< count {
            let node = newNode("\(index)")
            tree.insertAfter(prev, node)
            nodes.append(node)
            prev = node
        }

        var step = 0
        while step < count {
            tree.delete(nodes[step])
            step += 2
        }
        XCTAssertEqual(tree.length, count / 2)

        var idx = 0
        step = 1
        while step < count {
            XCTAssertTrue(try tree.find(idx) === nodes[step])
            idx += 1
            step += 2
        }
    }

    func test_interleaved_insert_and_delete() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        let nodeB = newNode("B")
        tree.insertAfter(nodeA, nodeB)
        let nodeC = newNode("C")
        tree.insertAfter(nodeB, nodeC)

        tree.delete(nodeB)
        let nodeD = newNode("D")
        tree.insertAfter(nodeA, nodeD)
        XCTAssertEqual(tree.length, 3)

        XCTAssertTrue(try tree.find(0) === nodeA)
        XCTAssertTrue(try tree.find(1) === nodeD)
        XCTAssertTrue(try tree.find(2) === nodeC)
    }

    func test_insert_after_dummy_head_with_existing_nodes() throws {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let nodeB = newNode("B")
        tree.insertAfter(dummyHead, nodeB)
        let nodeC = newNode("C")
        tree.insertAfter(nodeB, nodeC)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        XCTAssertEqual(tree.length, 3)

        XCTAssertTrue(try tree.find(0) === nodeA)
        XCTAssertTrue(try tree.find(1) === nodeB)
        XCTAssertTrue(try tree.find(2) === nodeC)
    }

    func test_toTestString() {
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        let nodeA = newNode("A")
        tree.insertAfter(dummyHead, nodeA)
        let nodeB = newNode("B")
        tree.insertAfter(nodeA, nodeB)

        let str = tree.toTestString
        XCTAssertTrue(str.contains("dummy"))
        XCTAssertTrue(str.contains("A"))
        XCTAssertTrue(str.contains("B"))
    }

    func test_stress_test_with_random_operations() throws {
        let rng = makeRng(42)
        let dummyHead = newRemovedNode("dummy")
        let tree = TreeList<TestValue>(dummyHead)

        var liveNodes = [TreeListNode<TestValue>]()
        var allNodes = [dummyHead]

        let ops = 500
        for step in 0 ..< ops {
            let op = Int(rng() * 3)

            if op == 0 || allNodes.count < 3 {
                let prevIdx = Int(rng() * Double(allNodes.count))
                let prev = allNodes[prevIdx]
                let node = newNode("n\(step)")
                tree.insertAfter(prev, node)
                allNodes.append(node)
                liveNodes = try rebuildLiveList(tree)
            } else if op == 1, !liveNodes.isEmpty {
                let idx = Int(rng() * Double(liveNodes.count))
                liveNodes[idx].getValue().isRemoved = true
                tree.updateWeight(liveNodes[idx])
                liveNodes = try rebuildLiveList(tree)
            } else if op == 2, allNodes.count > 1 {
                let delIdx = 1 + Int(rng() * Double(allNodes.count - 1))
                tree.delete(allNodes[delIdx])
                allNodes.remove(at: delIdx)
                liveNodes = try rebuildLiveList(tree)
            }

            XCTAssertEqual(tree.length, liveNodes.count, "iteration \(step)")

            for pos in 0 ..< liveNodes.count {
                XCTAssertTrue(try tree.find(pos) === liveNodes[pos], "iteration \(step), find index \(pos)")
            }
        }
    }
}
