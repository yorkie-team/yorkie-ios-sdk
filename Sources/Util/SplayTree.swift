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

    var left: SplayNode<V>?
    var right: SplayNode<V>?
    var parent: SplayNode<V>?
    private(set) var weight: Int = 0

    init(value: V) {
        self.value = value
        self.initWeight()
    }

    func getLength() -> Int {
        fatalError("Must be implemented.")
    }

    /**
     * `getNodeString` returns a string of weight and value of this node.
     */
    var nodeString: String {
        return "\(self.weight)\(self.value)"
    }

    /**
     * `getLeftWeight` returns left weight of this node.
     */
    func getLeftWeight() -> Int {
        if let left = self.left {
            return left.weight
        } else {
            return 0
        }
    }

    /**
     * `getRightWeight` returns right weight of this node.
     */
    func getRightWeight() -> Int {
        if let right = self.right {
            return right.weight
        } else {
            return 0
        }
    }

    func getWeight() -> Int {
        return self.weight
    }

    func getValue() -> V {
        return self.value
    }

    func setLeft(_ node: SplayNode<V>?) {
        self.left = node
    }

    func setRight(_ node: SplayNode<V>?) {
        self.right = node
    }

    func setParent(_ node: SplayNode<V>?) {
        self.parent = node
    }

    func getLeft() -> SplayNode<V>? {
        return self.left
    }

    func getRight() -> SplayNode<V>? {
        return self.right
    }

    func getParent() -> SplayNode<V>? {
        return self.parent
    }

    /**
     * `hasLeft` check if the left node exists
     */
    func hasLeft() -> Bool {
        return self.left != nil
    }

    /**
     * `hasRight` check if the right node exists
     */
    func hasRight() -> Bool {
        return self.right != nil
    }

    /**
     * `hasParent` check if the parent node exists
     */
    func hasParent() -> Bool {
        return self.parent != nil
    }

    /**
     * `unlink` unlink parent, right and left node.
     */
    func unlink() {
        self.parent = nil
        self.right = nil
        self.left = nil
    }

    /**
     * `hasLinks` checks if parent, right and left node exists.
     */
    var hasLinks: Bool {
        return self.hasParent() || self.hasLeft() || self.hasRight()
    }

    /**
     * `increaseWeight` increases weight.
     */
    func increaseWeight(_ weight: Int) {
        self.weight += weight
    }

    /**
     * `initWeight` sets initial weight of this node.
     */
    func initWeight() {
        self.weight = self.getLength()
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
    func find(position: Int) -> (node: SplayNode<V>?, position: Int) {
        guard let root = self.root, position >= 0 else {
            return (nil, 0)
        }
        var pos = position
        var node = root
        while true {
            if node.hasLeft(), pos <= node.getLeftWeight() {
                node = node.getLeft()!
            } else if
                node.hasRight(),
                node.getLeftWeight() + node.getLength() < pos
            {
                pos -= node.getLeftWeight() + node.getLength()
                node = node.getRight()!
            } else {
                pos -= node.getLeftWeight()
                break
            }
        }
        if pos > node.getLength() {
            Logger.error("out of index range: pos: \(pos) > node.length: \(node.getLength())")
        }
        return (node, pos)
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
        var prev: SplayNode<V>?
        while true {
            guard let current = tempCurrent else {
                break
            }

            if prev == nil || prev === current.getRight() {
                index += current.getLength() + (current.hasLeft() ? current.getLeftWeight() : 0)
            }
            prev = current
            tempCurrent = current.getParent()
        }
        return index - node.getLength()
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
        return self.insertAfter(self.root, newNode: newNode)
    }

    /**
     * `insertAfter` inserts the node after the given previous node.
     */
    @discardableResult
    func insertAfter(_ target: SplayNode<V>?, newNode: SplayNode<V>) -> SplayNode<V> {
        guard let target = target else {
            self.root = newNode
            return newNode
        }

        self.splayNode(target)
        self.root = newNode
        newNode.setRight(target.getRight())
        if target.hasRight() {
            target.getRight()?.setParent(newNode)
        }
        newNode.setLeft(target)
        target.setParent(newNode)
        target.setRight(nil)
        self.updateWeight(target)
        self.updateWeight(newNode)

        return newNode
    }

    /**
     * `updateWeight` recalculates the weight of this node with the value and children.
     */
    func updateWeight(_ node: SplayNode<V>) {
        node.initWeight()

        if node.hasLeft() {
            node.increaseWeight(node.getLeftWeight())
        }
        if node.hasRight() {
            node.increaseWeight(node.getRightWeight())
        }
    }

    private func updateTreeWeight(_ node: SplayNode<V>) {
        var tempNode: SplayNode<V>? = node
        while true {
            guard let node = tempNode else {
                break
            }
            self.updateWeight(node)
            tempNode = node.getParent()
        }
    }

    /**
     * `splayNode` moves the given node to the root.
     */
    func splayNode(_ node: SplayNode<V>?) {
        guard let node = node else {
            return
        }

        while true {
            if self.isLeftChild(node.getParent()), self.isRightChild(node) {
                // zig-zag
                self.rotateLeft(node)
                self.rotateRight(node)
            } else if
                self.isRightChild(node.getParent()),
                self.isLeftChild(node)
            {
                // zig-zag
                self.rotateRight(node)
                self.rotateLeft(node)
            } else if self.isLeftChild(node.getParent()), self.isLeftChild(node) {
                // zig-zig
                self.rotateRight(node.getParent()!)
                self.rotateRight(node)
            } else if
                self.isRightChild(node.getParent()),
                self.isRightChild(node)
            {
                // zig-zig
                self.rotateLeft(node.getParent()!)
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

        let leftTree = SplayTree(root: node.getLeft())
        if let root = leftTree.root {
            root.setParent(nil)
        }

        let rightTree = SplayTree(root: node.getRight())
        if let root = rightTree.root {
            root.setParent(nil)
        }

        if let leftTreeRoot = leftTree.root {
            let maxNode = leftTree.getMaximum()
            leftTree.splayNode(maxNode)
            leftTreeRoot.setRight(rightTree.root)
            if let rightTreeRoot = rightTree.root {
                rightTreeRoot.setParent(leftTree.root)
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
     * `deleteRange` separates the range between given 2 boundaries from this Tree.
     * This function separates the range to delete as a subtree
     * by splaying outer boundary nodes.
     * leftBoundary must exist because of 0-indexed initial dummy node of tree,
     * but rightBoundary can be nil means range to delete includes the end of tree.
     * Refer to the design document in https://github.com/yorkie-team/yorkie/tree/main/design
     */
    func deleteRange(leftBoundary: SplayNode<V>, rightBoundary: SplayNode<V>? = nil) {
        guard let rightBoundary = rightBoundary else {
            self.splayNode(leftBoundary)
            self.cutOffRight(root: leftBoundary)
            return
        }
        self.splayNode(leftBoundary)
        self.splayNode(rightBoundary)
        if rightBoundary.getLeft() !== leftBoundary {
            self.rotateRight(leftBoundary)
        }
        self.cutOffRight(root: leftBoundary)
    }

    private func cutOffRight(root: SplayNode<V>) {
        var nodesToFreeWeight: [SplayNode<V>] = []
        self.traversePostorder(root.getRight(), stack: &nodesToFreeWeight)
        for node in nodesToFreeWeight {
            node.initWeight()
        }
        self.updateTreeWeight(root)
    }

    /**
     * `getAnnotatedString` returns a string containing the meta data of the Node
     * for debugging purpose.
     */
    func getAnnotatedString() -> String {
        var metaString: [SplayNode<V>] = []
        self.traverseInorder(self.root!, stack: &metaString)
        return metaString
            .map {
                "[\($0.getWeight()),\($0.getLength())]\($0.getValue())"
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
        for node in nodes where node.getWeight() != node.getLength() + node.getLeftWeight() + node.getRightWeight() {
            return false
        }
        return true
    }

    private func getMaximum() -> SplayNode<V>? {
        guard var node = self.root else {
            return nil
        }
        while node.hasRight() {
            node = node.getRight()!
        }
        return node
    }

    private func traverseInorder(_ node: SplayNode<V>?, stack: inout [SplayNode<V>]) {
        guard let node = node else {
            return
        }

        self.traverseInorder(node.getLeft(), stack: &stack)
        stack.append(node)
        self.traverseInorder(node.getRight(), stack: &stack)
    }

    private func traversePostorder(_ node: SplayNode<V>?, stack: inout [SplayNode<V>]) {
        guard let node = node else {
            return
        }

        self.traversePostorder(node.getLeft(), stack: &stack)
        self.traversePostorder(node.getRight(), stack: &stack)
        stack.append(node)
    }

    private func rotateLeft(_ pivot: SplayNode<V>) {
        guard let root = pivot.getParent() else {
            return
        }
        if root.hasParent() {
            if root === root.getParent()!.getLeft() {
                root.getParent()!.setLeft(pivot)
            } else {
                root.getParent()!.setRight(pivot)
            }
        } else {
            self.root = pivot
        }
        pivot.setParent(root.getParent())

        root.setRight(pivot.getLeft())
        if root.hasRight() {
            root.getRight()!.setParent(root)
        }

        pivot.setLeft(root)
        pivot.getLeft()!.setParent(pivot)

        self.updateWeight(root)
        self.updateWeight(pivot)
    }

    private func rotateRight(_ pivot: SplayNode<V>) {
        guard let root = pivot.getParent() else {
            return
        }
        if root.hasParent() {
            if root === root.getParent()?.getLeft() {
                root.getParent()?.setLeft(pivot)
            } else {
                root.getParent()?.setRight(pivot)
            }
        } else {
            self.root = pivot
        }
        pivot.setParent(root.getParent())

        root.setLeft(pivot.getRight())
        if root.hasLeft() {
            root.getLeft()!.setParent(root)
        }

        pivot.setRight(root)
        pivot.getRight()!.setParent(pivot)

        self.updateWeight(root)
        self.updateWeight(pivot)
    }

    private func isLeftChild(_ node: SplayNode<V>?) -> Bool {
        if let node = node, node.hasParent() {
            return node.getParent()?.getLeft() === node
        }
        return false
    }

    private func isRightChild(_ node: SplayNode<V>?) -> Bool {
        if let node = node, node.hasParent() {
            return node.getParent()?.getRight() === node
        }
        return false
    }
}
