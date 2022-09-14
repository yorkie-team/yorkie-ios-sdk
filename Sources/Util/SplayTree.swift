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
 *
 *  Splay Tree
 *
 * Based on Binary Search Tree Implementation written by Nicolas Ameghino and Matthijs Hollemans for Swift Algorithms Club
 * https://github.com/raywenderlich/swift-algorithm-club/blob/master/Binary%20Search%20Tree
 * And extended for the specifics of a Splay Tree by Barbara Martina Rodeker
 *
 */

import Foundation

/**
    Represent the 3 possible operations (combinations of rotations) that
    could be performed during the Splay phase in Splay Trees

    - zigZag       Left child of a right child OR right child of a left child
    - zigZig       Left child of a left child OR right child of a right child
    - zig          Only 1 parent and that parent is the root

 */
enum SplayOperation {
    case zigZag
    case zigZig
    case zig

    /**
        Splay the given node up to the root of the tree

        - Parameters:
            - node      SplayTree node to move up to the root
     */
    static func splay<T: Comparable>(node: Node<T>) {
        while node.parent != nil {
            self.operation(forNode: node).apply(onNode: node)
        }
    }

    /**
        Compares the node and its parent and determine
        if the rotations should be performed in a zigZag, zigZig or zig case.

        - Parmeters:
            - forNode       SplayTree node to be checked
        - Returns
            - Operation     Case zigZag - zigZig - zig
     */
    static func operation<T>(forNode node: Node<T>) -> SplayOperation {
        if let parent = node.parent, parent.parent != nil {
            if (node.isLeftChild && parent.isRightChild) || (node.isRightChild && parent.isLeftChild) {
                return .zigZag
            }
            return .zigZig
        }
        return .zig
    }

    /**
        Applies the rotation associated to the case
        Modifying the splay tree and briging the received node further to the top of the tree

        - Parameters:
            - onNode    Node to splay up. Should be alwayas the node that needs to be splayed, neither its parent neither it's grandparent
     */
    func apply<T: Comparable>(onNode node: Node<T>) {
        switch self {
        case .zigZag:
            assert(node.parent != nil && node.parent!.parent != nil, "Should be at least 2 nodes up in the tree")
            self.rotate(child: node, parent: node.parent!)
            self.rotate(child: node, parent: node.parent!)

        case .zigZig:
            assert(node.parent != nil && node.parent!.parent != nil, "Should be at least 2 nodes up in the tree")
            self.rotate(child: node.parent!, parent: node.parent!.parent!)
            self.rotate(child: node, parent: node.parent!)

        case .zig:
            assert(node.parent != nil && node.parent!.parent == nil, "There should be a parent which is the root")
            self.rotate(child: node, parent: node.parent!)
        }
    }

    /**
        Performs a single rotation from a node to its parent
        re-arranging the children properly
     */
    func rotate<T: Comparable>(child: Node<T>, parent: Node<T>) {
        assert(child.parent != nil && child.parent!.value == parent.value, "Parent and child.parent should match here")

        var grandchildToMode: Node<T>?

        if child.isLeftChild {
            grandchildToMode = child.right
            parent.left = grandchildToMode
            grandchildToMode?.parent = parent

            let grandParent = parent.parent
            child.parent = grandParent

            if parent.isLeftChild {
                grandParent?.left = child
            } else {
                grandParent?.right = child
            }

            child.right = parent
            parent.parent = child

        } else {
            grandchildToMode = child.left
            parent.right = grandchildToMode
            grandchildToMode?.parent = parent

            let grandParent = parent.parent
            child.parent = grandParent

            if parent.isLeftChild {
                grandParent?.left = child
            } else {
                grandParent?.right = child
            }

            child.left = parent
            parent.parent = child
        }
    }
}

class Node<T: Comparable> {
    fileprivate(set) var value: T?
    fileprivate(set) var parent: Node<T>?
    fileprivate(set) var left: Node<T>?
    fileprivate(set) var right: Node<T>?

    init(value: T) {
        self.value = value
    }

    var isRoot: Bool {
        return self.parent == nil
    }

    var isLeaf: Bool {
        return self.left == nil && self.right == nil
    }

    var isLeftChild: Bool {
        return self.parent?.left === self
    }

    var isRightChild: Bool {
        return self.parent?.right === self
    }

    var hasLeftChild: Bool {
        return self.left != nil
    }

    var hasRightChild: Bool {
        return self.right != nil
    }

    var hasAnyChild: Bool {
        return self.hasLeftChild || self.hasRightChild
    }

    var hasBothChildren: Bool {
        return self.hasLeftChild && self.hasRightChild
    }

    /* How many nodes are in this subtree. Performance: O(n). */
    var count: Int {
        return (self.left?.count ?? 0) + 1 + (self.right?.count ?? 0)
    }
}

class SplayTree<T: Comparable> {
    internal var root: Node<T>?

    var value: T? {
        return self.root?.value
    }

    // MARK: - Initializer

    init() {
        self.root = nil
    }

    init(value: T) {
        self.root = Node(value: value)
    }

    func insert(value: T) {
        if let root = root {
            self.root = root.insert(value: value)
        } else {
            root = Node(value: value)
        }
    }

    func remove(value: T) {
        self.root = self.root?.remove(value: value)
    }

    func search(value: T) -> Node<T>? {
        self.root = self.root?.search(value: value)
        return self.root
    }

    func minimum() -> Node<T>? {
        self.root = self.root?.minimum(splayed: true)
        return self.root
    }

    func maximum() -> Node<T>? {
        self.root = self.root?.maximum(splayed: true)
        return self.root
    }

    func splay(value: T) {
        guard let node = search(value: value) else {
            return
        }

        SplayOperation.splay(node: node)
    }

    func indexOf(value: T) -> Int? {
        guard let node = search(value: value) else {
            return nil
        }
        var index = 0
        var current: Node<T>? = node
        var previous: Node<T>?
        while true {
            guard let current = current {
                break
            }
            if let previous = previous, previous === current.right {
                index += current.
            }
        }
    }
}

// MARK: - Adding items

extension Node {
    /*
     Inserts a new element into the node tree.

     - Parameters:
            - value T value to be inserted. Will be splayed to the root position

     - Returns:
            - Node inserted
     */
    func insert(value: T) -> Node {
        if let selfValue = self.value {
            if value < selfValue {
                if let left = left {
                    return left.insert(value: value)
                } else {
                    left = Node(value: value)
                    left?.parent = self

                    if let left = left {
                        SplayOperation.splay(node: left)
                        return left
                    }
                }
            } else {
                if let right = right {
                    return right.insert(value: value)
                } else {
                    right = Node(value: value)
                    right?.parent = self

                    if let right = right {
                        SplayOperation.splay(node: right)
                        return right
                    }
                }
            }
        }
        return self
    }
}

// MARK: - Deleting items

extension Node {
    /*
     Deletes the given node from the nodes tree.
     Return the new tree generated by the removal.
     The removed node (not necessarily the one containing the value), will be splayed to the root.

     - Parameters:
            - value         To be removed

     - Returns:
            - Node     Resulting from the deletion and the splaying of the removed node

     */
    fileprivate func remove(value: T) -> Node<T>? {
        guard let target = search(value: value) else { return self }

        if let left = target.left, let right = target.right {
            let largestOfLeftChild = left.maximum()
            left.parent = nil
            right.parent = nil

            SplayOperation.splay(node: largestOfLeftChild)
            largestOfLeftChild.right = right

            return largestOfLeftChild

        } else if let left = target.left {
            self.replace(node: target, with: left)
            return left

        } else if let right = target.right {
            self.replace(node: target, with: right)
            return right

        } else {
            return nil
        }
    }

    private func replace(node: Node<T>, with newNode: Node<T>?) {
        guard let sourceParent = newNode?.parent else { return }

        if newNode?.isLeftChild == true {
            sourceParent.left = newNode
        } else {
            sourceParent.right = newNode
        }

        newNode?.parent = sourceParent
    }
}

// MARK: - Searching

extension Node {
    /*
     Finds the "highest" node with the specified value.
     Performance: runs in O(h) time, where h is the height of the tree.
     */
    func search(value: T) -> Node<T>? {
        var node: Node? = self
        var nodeParent: Node? = self
        while case let currentNode? = node, currentNode.value != nil {
            if value < currentNode.value! {
                if currentNode.left != nil { nodeParent = currentNode.left }
                node = currentNode.left
            } else if value > currentNode.value! {
                node = currentNode.right
                if currentNode.right != nil { nodeParent = currentNode.right }
            } else {
                break
            }
        }

        if let node = node {
            SplayOperation.splay(node: node)
            return node
        } else if let nodeParent = nodeParent {
            SplayOperation.splay(node: nodeParent)
            return nodeParent
        }

        return nil
    }

    func contains(value: T) -> Bool {
        return self.search(value: value) != nil
    }

    /*
     Returns the leftmost descendent. O(h) time.
     */
    func minimum(splayed: Bool = false) -> Node<T> {
        var node = self
        while case let next? = node.left {
            node = next
        }

        if splayed == true {
            SplayOperation.splay(node: node)
        }

        return node
    }

    /*
     Returns the rightmost descendent. O(h) time.
     */
    func maximum(splayed: Bool = false) -> Node<T> {
        var node = self
        while case let next? = node.right {
            node = next
        }

        if splayed == true {
            SplayOperation.splay(node: node)
        }

        return node
    }

    /*
     Calculates the depth of this node, i.e. the distance to the root.
     Takes O(h) time.
     */
    func depth() -> Int {
        var node = self
        var edges = 0
        while case let parent? = node.parent {
            node = parent
            edges += 1
        }
        return edges
    }

    /*
     Calculates the height of this node, i.e. the distance to the lowest leaf.
     Since this looks at all children of this node, performance is O(n).
     */
    func height() -> Int {
        if self.isLeaf {
            return 0
        } else {
            return 1 + max(self.left?.height() ?? 0, self.right?.height() ?? 0)
        }
    }

    /*
     Finds the node whose value precedes our value in sorted order.
     */
    func predecessor() -> Node<T>? {
        if let left = left {
            return left.maximum()
        } else {
            var node = self
            while case let parent? = node.parent, parent.value != nil, self.value != nil {
                if parent.value! < value! { return parent }
                node = parent
            }
            return nil
        }
    }

    /*
     Finds the node whose value succeeds our value in sorted order.
     */
    func successor() -> Node<T>? {
        if let right = right {
            return right.minimum()
        } else {
            var node = self
            while case let parent? = node.parent, parent.value != nil, self.value != nil {
                if parent.value! > value! { return parent }
                node = parent
            }
            return nil
        }
    }
}

// MARK: - Traversal

extension Node {
    func traverseInOrder(process: (T) -> Void) {
        self.left?.traverseInOrder(process: process)
        process(self.value!)
        self.right?.traverseInOrder(process: process)
    }

    func traversePreOrder(process: (T) -> Void) {
        process(self.value!)
        self.left?.traversePreOrder(process: process)
        self.right?.traversePreOrder(process: process)
    }

    func traversePostOrder(process: (T) -> Void) {
        self.left?.traversePostOrder(process: process)
        self.right?.traversePostOrder(process: process)
        process(self.value!)
    }

    /*
     Performs an in-order traversal and collects the results in an array.
     */
    func map(formula: (T) -> T) -> [T] {
        var array = [T]()
        if let left = left { array += left.map(formula: formula) }
        array.append(formula(self.value!))
        if let right = right { array += right.map(formula: formula) }
        return array
    }
}

/*
 Is this binary tree a valid binary search tree?
 */
extension Node {
    func isBST(minValue: T, maxValue: T) -> Bool {
        if let value = value {
            if value < minValue || value > maxValue { return false }
            let leftBST = self.left?.isBST(minValue: minValue, maxValue: value) ?? true
            let rightBST = self.right?.isBST(minValue: value, maxValue: maxValue) ?? true
            return leftBST && rightBST
        }
        return false
    }
}

// MARK: - Debugging

extension Node: CustomStringConvertible {
    var description: String {
        var result = ""
        if let left = left {
            result += "left: (\(left.description)) <- "
        }
        if let value = value {
            result += "\(value)"
        }
        if let right = right {
            result += " -> (right: \(right.description))"
        }
        return result
    }
}

extension SplayTree: CustomStringConvertible {
    var description: String {
        return self.root?.description ?? "Empty tree"
    }
}

extension Node: CustomDebugStringConvertible {
    var debugDescription: String {
        var result = "value: \(String(describing: value))"
        if let parent = parent, let value = parent.value {
            result += ", parent: \(value)"
        }
        if let left = left {
            result += ", left = [" + left.debugDescription + "]"
        }
        if let right = right {
            result += ", right = [" + right.debugDescription + "]"
        }
        return result
    }

    func toArray() -> [T] {
        return self.map { $0 }
    }
}

extension SplayTree: CustomDebugStringConvertible {
    var debugDescription: String {
        return self.root?.debugDescription ?? "Empty tree"
    }
}
