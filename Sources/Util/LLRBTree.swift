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
 * LLRBTree is an implementation of Left-learning Red-Black Tree.
 *
 * Original paper on Left-leaning Red-Black Trees:
 * @see http://www.cs.princeton.edu/~rs/talks/LLRB/LLRB.pdf
 *
 * Invariant 1: No red node has a red child
 * Invariant 2: Every leaf path has the same number of black nodes
 * Invariant 3: Only the left child can be red (left leaning)
 */
public class LLRBTree<K: Comparable, V> {
    public typealias Entry<K, V> = (key: K, value: V)

    /**
     * `LLRBNode` is node of LLRBTree.
     */
    class Node<K, V>: CustomDebugStringConvertible {
        public var key: K
        public var value: V
        public var left: Node<K, V>?
        public var right: Node<K, V>?
        public var isRed: Bool

        init(_ key: K, _ value: V) {
            self.key = key
            self.value = value
            self.isRed = true // new nodes are always red
        }

        var debugDescription: String {
            "[Key: \(self.key)]: [Value: \(self.value)], isRed:\(self.isRed)"
        }

        var isLeaf: Bool {
            self.left == nil && self.right == nil
        }

        var entry: Entry<K, V> {
            (self.key, self.value)
        }
    }

    private var root: Node<K, V>?

    public func search(_ key: K) -> V? {
        var nodeX = self.root

        while nodeX != nil {
            if key == nodeX!.key {
                return nodeX!.value
            } else if key < nodeX!.key {
                nodeX = nodeX!.left
            } else if key > nodeX!.key {
                nodeX = nodeX!.right
            }
        }

        return nil
    }

    public func insert(_ key: K, _ value: V) {
        self.root = self.insert(self.root, key, value)
        self.root?.isRed = false
    }

    public func delete(_ key: K) {
        guard self.root != nil else {
            return
        }

        self.root = self.delete(self.root!, key)
        self.root?.isRed = false
    }

    /*
     * Returns the minimum key value of the whole tree
     */
    public func minValue() -> V? {
        guard let root else {
            return nil
        }

        return self.min(root).value
    }

    /*
     * Returns the maximum key value of the whole tree
     */
    public func maxValue() -> V? {
        guard let root else {
            return nil
        }

        return self.max(root).value
    }

    public func allValues() -> [V] {
        var result = [V]()

        self.traverseInorder(self.root, &result)

        return result
    }

    /**
     * `floorEntry` returns the entry for the greatest key less than or equal to the
     *  given key. If there is no such key, returns `nil`.
     */
    public func floorEntry(_ key: K) -> Entry<K, V>? {
        return self.floorEntry(self.root, key)
    }

    private func floorEntry(_ node: Node<K, V>?, _ key: K) -> Entry<K, V>? {
        guard let node else {
            return nil
        }

        if node.key == key {
            return node.entry
        } else if node.key > key {
            return self.floorEntry(node.left, key)
        } else {
            return self.floorEntry(node.right, key) ?? node.entry
        }
    }

    private func traverseInorder(_ node: Node<K, V>?, _ result: inout [V]) {
        guard let node else {
            return
        }

        self.traverseInorder(node.left, &result)
        result.append(node.value)
        self.traverseInorder(node.right, &result)
    }

    private func insert(_ nodeH: Node<K, V>?, _ key: K, _ value: V) -> Node<K, V> {
        guard nodeH != nil else {
            return Node(key, value)
        }

        guard var newNodeH = nodeH else {
            fatalError()
        }

        if self.isRed(newNodeH.left), self.isRed(newNodeH.right) {
            self.flipColors(&newNodeH)
        }

        if key == newNodeH.key {
            newNodeH.value = value
        } else if key < newNodeH.key {
            newNodeH.left = self.insert(newNodeH.left, key, value)
        } else if key > nodeH!.key {
            newNodeH.right = self.insert(newNodeH.right, key, value)
        }

        if self.isRed(newNodeH.right), !self.isRed(newNodeH.left) {
            newNodeH = self.rotateLeft(newNodeH)
        }
        if self.isRed(newNodeH.left), self.isRed(newNodeH.left?.left) {
            newNodeH = self.rotateRight(newNodeH)
        }

        return newNodeH
    }

    private func rotateLeft(_ nodeH: Node<K, V>) -> Node<K, V> {
        let nodeX = nodeH.right!

        nodeH.right = nodeX.left
        nodeX.left = nodeH
        nodeX.isRed = nodeH.isRed
        nodeH.isRed = true

        return nodeX
    }

    private func rotateRight(_ nodeH: Node<K, V>) -> Node<K, V> {
        let nodeX = nodeH.left!

        nodeH.left = nodeX.right
        nodeX.right = nodeH
        nodeX.isRed = nodeH.isRed
        nodeH.isRed = true

        return nodeX
    }

    private func flipColors(_ nodeH: inout Node<K, V>) {
        nodeH.isRed = !nodeH.isRed
        nodeH.left?.isRed = !nodeH.left!.isRed
        nodeH.right?.isRed = !nodeH.right!.isRed
    }

    private func delete(_ nodeH: Node<K, V>, _ key: K) -> Node<K, V>? {
        var newNodeH = nodeH

        if key < newNodeH.key {
            if !self.isRed(newNodeH.left), !self.isRed(newNodeH.left?.left) {
                newNodeH = self.moveRedLeft(newNodeH)
            }
            newNodeH.left = self.delete(newNodeH.left!, key)
        } else {
            if self.isRed(newNodeH.left) {
                newNodeH = self.rotateRight(newNodeH)
            }
            if key == newNodeH.key, newNodeH.right == nil {
                return nil
            }
            if !self.isRed(newNodeH.right), !self.isRed(newNodeH.right?.left) {
                newNodeH = self.moveRedRight(newNodeH)
            }
            if key == newNodeH.key {
                let minNode = self.min(newNodeH.right!)
                newNodeH.value = minNode.value
                newNodeH.key = minNode.key
                newNodeH.right = self.deleteMin(newNodeH.right!)
            } else {
                newNodeH.right = self.delete(newNodeH.right!, key)
            }
        }

        return self.fixUp(newNodeH)
    }

    private func min(_ nodeH: Node<K, V>) -> Node<K, V> {
        if nodeH.left == nil {
            return nodeH
        }

        return self.min(nodeH.left!)
    }

    private func max(_ nodeH: Node<K, V>) -> Node<K, V> {
        if nodeH.right == nil {
            return nodeH
        }

        return self.max(nodeH.right!)
    }

    private func deleteMin(_ nodeH: Node<K, V>) -> Node<K, V>? {
        if nodeH.left == nil {
            return nil
        }

        var newNodeH = nodeH

        if !self.isRed(newNodeH.left), !self.isRed(newNodeH.left?.left) {
            newNodeH = self.moveRedLeft(newNodeH)
        }

        newNodeH.left = self.deleteMin(newNodeH.left!)

        return self.fixUp(newNodeH)
    }

    private func moveRedLeft(_ nodeH: Node<K, V>) -> Node<K, V> {
        var newNodeH = nodeH

        self.flipColors(&newNodeH)
        if self.isRed(newNodeH.right?.left) {
            newNodeH.right = self.rotateRight(newNodeH.right!)
            newNodeH = self.rotateLeft(newNodeH)
            self.flipColors(&newNodeH)
        }

        return newNodeH
    }

    private func moveRedRight(_ nodeH: Node<K, V>) -> Node<K, V> {
        var newNodeH = nodeH

        self.flipColors(&newNodeH)
        if self.isRed(newNodeH.left?.left) {
            newNodeH = self.rotateRight(newNodeH)
            self.flipColors(&newNodeH)
        }

        return newNodeH
    }

    private func isRed(_ nodeH: Node<K, V>?) -> Bool {
        nodeH?.isRed ?? false
    }

    private func fixUp(_ nodeH: Node<K, V>) -> Node<K, V> {
        var newNodeH = nodeH
        if self.isRed(newNodeH.right) {
            newNodeH = self.rotateLeft(newNodeH)
        }

        if self.isRed(nodeH.left), self.isRed(nodeH.left?.left) {
            newNodeH = self.rotateRight(newNodeH)
        }

        if self.isRed(newNodeH.left), self.isRed(newNodeH.right) {
            self.flipColors(&newNodeH)
        }

        return newNodeH
    }

    func printNode() {
        print(">>>>>>>>>>>>>>>>>>")
        self.print2DUtil(self.root, 0)
        print("<<<<<<<<<<<<<<<<<<")
    }

    func print2DUtil(_ node: Node<K, V>?, _ space: Int) {
        if node == nil {
            return
        }

        let newSpace = space + 10

        self.print2DUtil(node?.right, newSpace)

        var message = ""
        for _ in 0 ..< space {
            message += " "
        }
        print("\(message)\(node.debugDescription)")

        self.print2DUtil(node?.left, newSpace)
    }
}
