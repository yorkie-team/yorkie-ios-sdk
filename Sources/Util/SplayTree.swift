/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

import Foundation

/**
 * `SplayNode` is a node of SplayTree.
 */
class SplayNode<V> {
    private(set) var value: V

    fileprivate var left: SplayNode<V>?
    fileprivate var right: SplayNode<V>?
    fileprivate var parent: SplayNode<V>?
    fileprivate(set) var weight: Int = 0

    init(_ value: V) {
        self.value = value
        self.initWeight()
    }

    var length: Int {
        fatalError("Must be implemented.")
    }

    /**
     * `getNodeString` returns a string of weight and value of this node.
     */
    private var nodeString: String {
        return "\(self.weight)\(self.value)"
    }

    /**
     * `getLeftWeight` returns left weight of this node.
     */
    fileprivate var leftWeight: Int {
        if let left = self.left {
            return left.weight
        } else {
            return 0
        }
    }

    /**
     * `getRightWeight` returns right weight of this node.
     */
    fileprivate var rightWeight: Int {
        if let right = self.right {
            return right.weight
        } else {
            return 0
        }
    }

    /**
     * `hasLeft` check if the left node exists
     */
    fileprivate var hasLeft: Bool {
        return self.left != nil
    }

    /**
     * `hasRight` check if the right node exists
     */
    fileprivate var hasRight: Bool {
        return self.right != nil
    }

    /**
     * `hasParent` check if the parent node exists
     */
    fileprivate var hasParent: Bool {
        return self.parent != nil
    }

    /**
     * `unlink` unlink parent, right and left node.
     */
    fileprivate func unlink() {
        self.parent = nil
        self.right = nil
        self.left = nil
    }

    /**
     * `hasLinks` checks if parent, right and left node exists.
     */
    fileprivate var hasLinks: Bool {
        return self.hasParent || self.hasLeft || self.hasRight
    }

    /**
     * `increaseWeight` increases weight.
     */
    fileprivate func increaseWeight(_ weight: Int) {
        self.weight += weight
    }

    /**
     * `initWeight` sets initial weight of this node.
     */
    fileprivate func initWeight() {
        self.weight = self.length
    }
}

/**
 * SplayTree is weighted binary search tree which is based on Splay tree.
 * original paper on Splay Trees:
 * @see https://www.cs.cmu.edu/~sleator/papers/self-adjusting.pdf
 */
class SplayTree<V> {
    private var root: SplayNode<V>?

    init(root: SplayNode<V>? = nil) {
        self.root = root
    }

    /**
     * `length` returns the size of this tree.
     */
    var length: Int {
        if let root = self.root {
            return root.weight
        } else {
            return 0
        }
    }

    /**
     * `find` returns the Node and offset of the given index.
     */
    func find(position: Int) -> (node: SplayNode<V>?, offset: Int) {
        guard let root = self.root, position >= 0 else {
            return (nil, 0)
        }

        var offset = position
        var node = root
        while true {
            if let left = node.left, offset <= node.leftWeight {
                node = left
            } else if node.hasRight, offset > node.leftWeight + node.length {
                offset -= node.leftWeight + node.length
                node = node.right!
            } else {
                offset -= node.leftWeight
                break
            }
        }
        if offset > node.length {
            Logger.error("out of index range: pos: \(offset) > node.length: \(node.length)")
        }
        return (node, offset)
    }

    /**
     * Find the index of the given node in BST.
     *
     * - Parameter node: the given node
     * - Returns: the index of given node
     */
    func indexOf(_ node: SplayNode<V>) -> Int {
        guard node.hasLinks else {
            return -1
        }

        var index = 0
        var tempCurrent: SplayNode<V>? = node
        var previousNode: SplayNode<V>?
        while true {
            guard let current = tempCurrent else {
                break
            }

            if previousNode == nil || previousNode === current.right {
                index += current.length + (current.hasLeft ? current.leftWeight : 0)
            }
            previousNode = current
            tempCurrent = current.parent
        }
        return index - node.length
    }

    /**
     * `getRoot` returns root of this tree.
     */
    func getRoot() -> SplayNode<V>? {
        return self.root
    }

    /**
     * `insert` inserts the node at the last.
     */
    @discardableResult
    func insert(_ newNode: SplayNode<V>) -> SplayNode<V> {
        return self.insert(previousNode: self.root, newNode: newNode)
    }

    /**
     * `insertAfter` inserts the node after the given previous node.
     */
    @discardableResult
    func insert(previousNode: SplayNode<V>?, newNode: SplayNode<V>) -> SplayNode<V> {
        guard let previousNode = previousNode else {
            self.root = newNode
            return newNode
        }

        self.splayNode(previousNode)
        self.root = newNode
        newNode.right = previousNode.right
        if previousNode.hasRight {
            previousNode.right?.parent = newNode
        }
        newNode.left = previousNode
        previousNode.parent = newNode
        previousNode.right = nil
        self.updateWeight(previousNode)
        self.updateWeight(newNode)

        return newNode
    }

    /**
     * `updateWeight` recalculates the weight of this node with the value and children.
     */
    func updateWeight(_ node: SplayNode<V>) {
        node.initWeight()

        if node.hasLeft {
            node.increaseWeight(node.leftWeight)
        }
        if node.hasRight {
            node.increaseWeight(node.rightWeight)
        }
    }

    private func updateTreeWeight(_ node: SplayNode<V>) {
        var tempNode: SplayNode<V>? = node
        while true {
            guard let node = tempNode else {
                break
            }
            self.updateWeight(node)
            tempNode = node.parent
        }
    }

    /**
     * `splayNode` moves the given node to the root.
     */
    func splayNode(_ node: SplayNode<V>?) {
        guard let node else {
            return
        }

        while true {
            if self.isLeftChild(node.parent), self.isRightChild(node) {
                // zig-zag
                self.rotateLeft(node)
                self.rotateRight(node)
            } else if
                self.isRightChild(node.parent),
                self.isLeftChild(node)
            {
                // zig-zag
                self.rotateRight(node)
                self.rotateLeft(node)
            } else if self.isLeftChild(node.parent), self.isLeftChild(node) {
                // zig-zig
                self.rotateRight(node.parent!)
                self.rotateRight(node)
            } else if
                self.isRightChild(node.parent),
                self.isRightChild(node)
            {
                // zig-zig
                self.rotateLeft(node.parent!)
                self.rotateLeft(node)
            } else {
                // zig
                if self.isLeftChild(node) {
                    self.rotateRight(node)
                } else if self.isRightChild(node) {
                    self.rotateLeft(node)
                }
                self.updateWeight(node)
                break
            }
        }
    }

    /**
     * `delete` deletes target node of this tree.
     */
    func delete(_ node: SplayNode<V>) {
        self.splayNode(node)

        let leftTree = SplayTree(root: node.left)
        if let root = leftTree.root {
            root.parent = nil
        }

        let rightTree = SplayTree(root: node.right)
        if let root = rightTree.root {
            root.parent = nil
        }

        if let leftTreeRoot = leftTree.root {
            let maxNode = leftTree.getMaximum()
            leftTree.splayNode(maxNode)
            leftTreeRoot.right = rightTree.root
            if let rightTreeRoot = rightTree.root {
                rightTreeRoot.parent = leftTree.root
            }
            self.root = leftTree.root
        } else {
            self.root = rightTree.root
        }

        node.unlink()
        if let root = self.root {
            self.updateWeight(root)
        }
    }

    /**
     * `removeRange` separates the range between given 2 boundaries from this Tree.
     * This function separates the range to delete as a subtree
     * by splaying outer boundary nodes.
     * leftBoundary must exist because of 0-indexed initial dummy node of tree,
     * but rightBoundary can be nil means range to delete includes the end of tree.
     * Refer to the design document in https://github.com/yorkie-team/yorkie/tree/main/design
     */
    func removeRange(leftBoundary: SplayNode<V>, rightBoundary: SplayNode<V>? = nil) {
        guard let rightBoundary else {
            self.splayNode(leftBoundary)
            self.cutOffRight(root: leftBoundary)
            return
        }
        self.splayNode(leftBoundary)
        self.splayNode(rightBoundary)
        if rightBoundary.left !== leftBoundary {
            self.rotateRight(leftBoundary)
        }
        self.cutOffRight(root: leftBoundary)
    }

    private func cutOffRight(root: SplayNode<V>) {
        var nodesToFreeWeight: [SplayNode<V>] = []
        self.traversePostorder(root.right, stack: &nodesToFreeWeight)
        for node in nodesToFreeWeight {
            node.initWeight()
        }
        self.updateTreeWeight(root)
    }

    /**
     * `structureAsString` returns a string containing the meta data of the Node
     * for debugging purpose.
     */
    var structureAsString: String {
        var metaString: [SplayNode<V>] = []
        self.traverseInorder(self.root!, stack: &metaString)
        return metaString
            .map {
                "[\($0.weight),\($0.length)]\($0.value)"
            }
            .joined(separator: "")
    }

    /**
     * `checkWeight` returns false when there is an incorrect weight node.
     * for debugging purpose.
     */
    func checkWeight() -> Bool {
        var nodes: [SplayNode<V>] = []
        self.traverseInorder(self.root!, stack: &nodes)
        for node in nodes where node.weight != node.length + node.leftWeight + node.rightWeight {
            return false
        }
        return true
    }

    private func getMaximum() -> SplayNode<V>? {
        guard var node = self.root else {
            return nil
        }
        while node.hasRight {
            node = node.right!
        }
        return node
    }

    private func traverseInorder(_ node: SplayNode<V>?, stack: inout [SplayNode<V>]) {
        guard let node else {
            return
        }

        self.traverseInorder(node.left, stack: &stack)
        stack.append(node)
        self.traverseInorder(node.right, stack: &stack)
    }

    private func traversePostorder(_ node: SplayNode<V>?, stack: inout [SplayNode<V>]) {
        guard let node else {
            return
        }

        self.traversePostorder(node.left, stack: &stack)
        self.traversePostorder(node.right, stack: &stack)
        stack.append(node)
    }

    private func rotateLeft(_ pivot: SplayNode<V>) {
        guard let root = pivot.parent else {
            return
        }
        if root.hasParent {
            if root === root.parent!.left {
                root.parent!.left = pivot
            } else {
                root.parent!.right = pivot
            }
        } else {
            self.root = pivot
        }
        pivot.parent = root.parent

        root.right = pivot.left
        if root.hasRight {
            root.right!.parent = root
        }

        pivot.left = root
        pivot.left!.parent = pivot

        self.updateWeight(root)
        self.updateWeight(pivot)
    }

    private func rotateRight(_ pivot: SplayNode<V>) {
        guard let root = pivot.parent else {
            return
        }
        if root.hasParent {
            if root === root.parent?.left {
                root.parent?.left = pivot
            } else {
                root.parent?.right = pivot
            }
        } else {
            self.root = pivot
        }
        pivot.parent = root.parent

        root.left = pivot.right
        if root.hasLeft {
            root.left!.parent = root
        }

        pivot.right = root
        pivot.right!.parent = pivot

        self.updateWeight(root)
        self.updateWeight(pivot)
    }

    private func isLeftChild(_ node: SplayNode<V>?) -> Bool {
        if let node = node, node.hasParent {
            return node.parent?.left === node
        }
        return false
    }

    private func isRightChild(_ node: SplayNode<V>?) -> Bool {
        if let node = node, node.hasParent {
            return node.parent?.right === node
        }
        return false
    }
}
