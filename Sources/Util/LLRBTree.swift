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
        public var parent: Node<K, V>?
        public var left: Node<K, V>?
        public var right: Node<K, V>?
        public var isRed: Bool

        init(_ key: K, _ value: V, _ isRed: Bool) {
            self.key = key
            self.value = value
            self.isRed = isRed
        }

        var debugDescription: String {
            "[\(self.key)]: \(self.value) (\(self.isRed ? "R" : "B"))"
        }

        var isLeaf: Bool {
            self.left == nil && self.right == nil
        }

        var entry: Entry<K, V> {
            (self.key, self.value)
        }
    }

    private var root: Node<K, V>?
    private var counter: Int = 0

    /**
     * `put` puts the value of the given key.
     */
    @discardableResult
    public func put(_ key: K, _ value: V) -> V {
        self.root = self.putInternal(key, value, self.root)
        self.root?.isRed = false

        return value
    }

    /**
     * `get` gets a value of the given key.
     */
    public func get(_ key: K) -> V? {
        self.getInternal(key, self.root)?.value
    }

    /**
     * `remove` removes a element of key.
     */
    public func remove(_ key: K) {
        guard let root else {
            return
        }

        if self.isRed(root.left), !self.isRed(root.right) {
            self.root?.isRed = true
        }

        self.root = self.removeInternal(root, key)

        self.root?.isRed = false
    }

    public var values: [V] {
        var result = [V]()

        self.traverseInorder(self.root, &result)

        return result
    }

    private func traverseInorder(_ node: Node<K, V>?, _ result: inout [V]) {
        guard let node else {
            return
        }

        self.traverseInorder(node.left, &result)
        result.append(node.value)
        self.traverseInorder(node.right, &result)
    }

    /**
     * `floorEntry` returns the entry for the greatest key less than or equal to the
     *  given key. If there is no such key, returns `undefined`.
     */
    public func floorEntry(_ key: K) -> Entry<K, V>? {
        var node = self.root

        while node != nil {
            if key > node!.key {
                if node!.right != nil {
                    node?.right?.parent = node
                    node = node?.right
                } else {
                    return node?.entry
                }
            } else if key < node!.key {
                if node!.left != nil {
                    node?.left?.parent = node
                    node = node?.left
                } else {
                    var parent = node?.parent
                    var childNode = node
                    while parent != nil, childNode === parent?.left {
                        childNode = parent
                        parent = parent!.parent
                    }

                    return parent?.entry
                }
            } else {
                return node?.entry
            }
        }
        return nil
    }

    /**
     * `lastEntry` returns last entry of LLRBTree.
     */
    public func lastEntry() -> Entry<K, V>? {
        if self.root == nil {
            return nil
        }

        var node = self.root
        while node?.right != nil {
            node = node?.right
        }
        return node?.entry
    }

    /**
     * `size` is a size of LLRBTree.
     */
    public var size: Int {
        self.counter
    }

    /**
     * `isEmpty` checks if size is empty.
     */
    public var isEmpty: Bool {
        self.counter == 0
    }

    public var minValue: V? {
        guard let root else {
            return nil
        }

        return self.min(root).value
    }

    public var maxValue: V? {
        guard let root else {
            return nil
        }

        return self.max(root).value
    }

    private func getInternal(_ key: K, _ node: Node<K, V>?) -> Node<K, V>? {
        var node = node

        while node != nil {
            if key == node!.key {
                return node
            } else if key < node!.key {
                node = node?.left
            } else if key > node!.key {
                node = node?.right
            }
        }

        return nil
    }

    private func putInternal(_ key: K, _ value: V, _ node: Node<K, V>?) -> Node<K, V> {
        var node = node

        if node == nil {
            self.counter += 1
            return Node(key, value, true)
        }

        if key < node!.key {
            node?.left = self.putInternal(key, value, node!.left)
        } else if key > node!.key {
            node?.right = self.putInternal(key, value, node!.right)
        } else {
            node?.value = value
        }

        if self.isRed(node?.right), !self.isRed(node?.left) {
            node = self.rotateLeft(node!)
        }

        if self.isRed(node?.left), self.isRed(node?.left?.left) {
            node = self.rotateRight(node!)
        }

        if self.isRed(node?.left), self.isRed(node?.right) {
            self.flipColors(&node!)
        }

        return node!
    }

    private func removeInternal(_ node: Node<K, V>, _ key: K) -> Node<K, V>? {
        var node = node

        if key < node.key {
            if !self.isRed(node.left), !self.isRed(node.left?.left) {
                node = self.moveRedLeft(node)
            }
            node.left = self.removeInternal(node.left!, key)
        } else {
            if self.isRed(node.left) {
                node = self.rotateRight(node)
            }

            if key == node.key, node.right == nil {
                self.counter -= 1
                return nil
            }

            if !self.isRed(node.right), !self.isRed(node.right?.left) {
                node = self.moveRedRight(node)
            }

            if key == node.key {
                self.counter -= 1
                let smallest = self.min(node.right!)
                node.value = smallest.value
                node.key = smallest.key
                node.right = self.removeMin(node.right!)
            } else {
                node.right = self.removeInternal(node.right!, key)
            }
        }

        return self.fixUp(node)
    }

    private func min(_ node: Node<K, V>) -> Node<K, V> {
        if node.left == nil {
            return node
        } else {
            return self.min(node.left!)
        }
    }

    private func max(_ node: Node<K, V>) -> Node<K, V> {
        if node.right == nil {
            return node
        } else {
            return self.max(node.right!)
        }
    }

    private func removeMin(_ node: Node<K, V>) -> Node<K, V>? {
        var node = node

        if node.left == nil {
            return nil
        }

        if !self.isRed(node.left), !self.isRed(node.left?.left) {
            node = self.moveRedLeft(node)
        }

        node.left = self.removeMin(node.left!)

        return self.fixUp(node)
    }

    private func fixUp(_ node: Node<K, V>) -> Node<K, V> {
        var node = node

        if self.isRed(node.right) {
            node = self.rotateLeft(node)
        }

        if self.isRed(node.left), self.isRed(node.left?.left) {
            node = self.rotateRight(node)
        }

        if self.isRed(node.left), self.isRed(node.right) {
            self.flipColors(&node)
        }

        return node
    }

    private func moveRedLeft(_ node: Node<K, V>) -> Node<K, V> {
        var node = node

        self.flipColors(&node)
        if self.isRed(node.right?.left) {
            node.right = self.rotateRight(node.right!)
            node = self.rotateLeft(node)
            self.flipColors(&node)
        }
        return node
    }

    private func moveRedRight(_ node: Node<K, V>) -> Node<K, V> {
        var node = node

        self.flipColors(&node)
        if self.isRed(node.left?.left) {
            node = self.rotateRight(node)
            self.flipColors(&node)
        }
        return node
    }

    private func isRed(_ node: Node<K, V>?) -> Bool {
        node?.isRed ?? false
    }

    private func rotateLeft(_ node: Node<K, V>) -> Node<K, V> {
        let nodeX = node.right!
        node.right = nodeX.left
        nodeX.left = node
        nodeX.isRed = nodeX.left?.isRed ?? false
        nodeX.left?.isRed = true
        return nodeX
    }

    private func rotateRight(_ node: Node<K, V>) -> Node<K, V> {
        let nodeX = node.left!
        node.left = nodeX.right
        nodeX.right = node
        nodeX.isRed = nodeX.right?.isRed ?? false
        nodeX.right?.isRed = true
        return nodeX
    }

    private func flipColors(_ node: inout Node<K, V>) {
        node.isRed = !node.isRed
        node.left!.isRed = !node.left!.isRed
        node.right!.isRed = !node.right!.isRed
    }

    func printNode() {
        print(">>>>>>>>>>>>>>>>>>")
        self.print2DUtil(self.root, 0, "-")
        print("<<<<<<<<<<<<<<<<<<")
    }

    func print2DUtil(_ node: Node<K, V>?, _ space: Int, _ dir: String) {
        if node == nil {
            return
        }

        let newSpace = space + 10

        self.print2DUtil(node?.right, newSpace, "/")

        var message = ""
        for _ in 0 ..< space {
            message += " "
        }
        print("\(message)\(dir)\(node?.debugDescription ?? "")")

        self.print2DUtil(node?.left, newSpace, "\\")
    }
}
