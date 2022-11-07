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

// Copyright (c) 2016 Matthijs Hollemans and contributors. Licensed under the MIT license.
// See LICENSE in the project root for license information.

import Foundation

private enum RBTreeColor {
    case red
    case black
}

private enum RotationDirection {
    case left
    case right
}

// MARK: - RBNode

class RBTreeNode<T: Comparable, V>: Equatable {
    typealias RBNode = RBTreeNode<T, V>

    fileprivate var color: RBTreeColor = .black
    fileprivate var key: T?
    fileprivate var value: V?
    var leftChild: RBNode?
    var rightChild: RBNode?
    fileprivate weak var parent: RBNode?

    init(key: T?, value: V?, leftChild: RBNode?, rightChild: RBNode?, parent: RBNode?) {
        self.key = key
        self.value = value

        self.leftChild = leftChild
        self.rightChild = rightChild
        self.parent = parent

        self.leftChild?.parent = self
        self.rightChild?.parent = self
    }

    convenience init(key: T?, value: V?) {
        self.init(key: key, value: value, leftChild: RBNode(), rightChild: RBNode(), parent: RBNode())
    }

    // For initialising the nullLeaf
    convenience init() {
        self.init(key: nil, value: nil, leftChild: nil, rightChild: nil, parent: nil)
        self.color = .black
    }

    var isRoot: Bool {
        return self.parent == nil
    }

    var isLeaf: Bool {
        return self.rightChild == nil && self.leftChild == nil
    }

    var isNullLeaf: Bool {
        return self.key == nil && self.isLeaf && self.color == .black
    }

    var isLeftChild: Bool {
        return self.parent?.leftChild === self
    }

    var isRightChild: Bool {
        return self.parent?.rightChild === self
    }

    var grandparent: RBNode? {
        return self.parent?.parent
    }

    var sibling: RBNode? {
        if self.isLeftChild {
            return self.parent?.rightChild
        } else {
            return self.parent?.leftChild
        }
    }

    var uncle: RBNode? {
        return self.parent?.sibling
    }
}

// MARK: - RedBlackTree

class RedBlackTree<T: Comparable, V> {
    typealias RBNode = RBTreeNode<T, V>

    fileprivate(set) var root: RBNode
    fileprivate(set) var size = 0
    fileprivate let nullLeaf = RBNode()
    fileprivate let allowDuplicateNode: Bool

    init(_ allowDuplicateNode: Bool = false) {
        self.root = self.nullLeaf
        self.allowDuplicateNode = allowDuplicateNode
    }
}

// MARK: - Size

extension RedBlackTree {
    func count() -> Int {
        return self.size
    }

    func isEmpty() -> Bool {
        return self.size == 0
    }

    func allValues() -> [V] {
        return self.allElements().compactMap { $0.value }
    }

    private func allElements() -> [RBNode] {
        var nodes: [RBNode] = []

        self.getAllElements(node: self.root, nodes: &nodes)

        return nodes
    }

    private func getAllElements(node: RBTreeNode<T, V>, nodes: inout [RBNode]) {
        guard !node.isNullLeaf else {
            return
        }

        if let left = node.leftChild {
            self.getAllElements(node: left, nodes: &nodes)
        }

        if node.key != nil {
            nodes.append(node)
        }

        if let right = node.rightChild {
            self.getAllElements(node: right, nodes: &nodes)
        }
    }
}

// MARK: - Equatable protocol

extension RBTreeNode {
    static func == <T>(lhs: RBTreeNode<T, V>, rhs: RBTreeNode<T, V>) -> Bool {
        return lhs.key == rhs.key
    }
}

// MARK: - Finding a nodes successor

extension RBTreeNode {
    /*
     * Returns the inorder successor node of a node
     * The successor is a node with the next larger key value of the current node
     */
    func getSuccessor() -> RBNode? {
        // If node has right child: successor min of this right tree
        if let rightChild = self.rightChild {
            if !rightChild.isNullLeaf {
                return rightChild.minimum()
            }
        }
        // Else go upward until node left child
        var currentNode = self
        var parent = currentNode.parent
        while currentNode.isRightChild {
            if let parent = parent {
                currentNode = parent
            }
            parent = currentNode.parent
        }
        return parent
    }
}

// MARK: - Searching

extension RBTreeNode {
    /*
     * Returns the node with the minimum key of the current subtree
     */
    func minimum() -> RBNode? {
        if let leftChild = leftChild {
            if !leftChild.isNullLeaf {
                return leftChild.minimum()
            }
            return self
        }
        return self
    }

    /*
     * Returns the node with the maximum key of the current subtree
     */
    func maximum() -> RBNode? {
        if let rightChild = rightChild {
            if !rightChild.isNullLeaf {
                return rightChild.maximum()
            }
            return self
        }
        return self
    }
}

extension RedBlackTree {
    /*
     * Returns the node with the given key |input| if existing
     */
    func search(input: T) -> RBNode? {
        var floorNode: RBNode?
        return self.search(key: input, node: self.root, floorNode: &floorNode)
    }

    /*
     * Returns the node with given |key| in subtree of |node|
     */
    private func search(key: T, node: RBNode?, floorNode: inout RBNode?) -> RBNode? {
        // If node nil -> key not found
        guard let node = node else {
            return nil
        }
        // If node is nullLeaf == semantically same as if nil
        if !node.isNullLeaf {
            if let nodeKey = node.key {
                // Node found
                if key == nodeKey {
                    return node
                } else if key < nodeKey {
                    return self.search(key: key, node: node.leftChild, floorNode: &floorNode)
                } else {
                    if floorNode == nil {
                        floorNode = node
                    } else if let floorNodeKey = floorNode?.key, floorNodeKey < nodeKey {
                        floorNode = node
                    }

                    return self.search(key: key, node: node.rightChild, floorNode: &floorNode)
                }
            }
        }
        return nil
    }

    /*
     * Returns the node with given |key| in subtree of |node|
     */
    func floorEntry(input: T) -> T? {
        var floorNode: RBNode?
        var result = self.search(key: input, node: self.root, floorNode: &floorNode)
        if result == nil {
            result = floorNode
        }
        return result?.key
    }
}

// MARK: - Finding maximum and minimum value

extension RedBlackTree {
    /*
     * Returns the minimum key value of the whole tree
     */
    func minValue() -> V? {
        guard let minNode = root.minimum() else {
            return nil
        }
        return minNode.value
    }

    /*
     * Returns the maximum key value of the whole tree
     */
    func maxValue() -> V? {
        guard let maxNode = root.maximum() else {
            return nil
        }
        return maxNode.value
    }
}

// MARK: - Inserting new nodes

extension RedBlackTree {
    /*
     * Insert a node with key |key| into the tree
     * 1. Perform normal insert operation as in a binary search tree
     * 2. Fix red-black properties
     * Runntime: O(log n)
     */
    func insert(key: T, value: V) {
        // If key must be unique and find the key already existed, quit
        if self.search(input: key) != nil, !self.allowDuplicateNode {
            return
        }

        if self.root.isNullLeaf {
            self.root = RBNode(key: key, value: value)
        } else {
            self.insert(input: RBNode(key: key, value: value), node: self.root)
        }

        self.size += 1
    }

    /*
     * Nearly identical insert operation as in a binary search tree
     * Differences: All nil pointers are replaced by the nullLeaf, we color the inserted node red,
     * after inserting we call insertFixup to maintain the red-black properties
     */
    private func insert(input: RBNode, node: RBNode) {
        guard let inputKey = input.key, let nodeKey = node.key else {
            return
        }
        if inputKey < nodeKey {
            guard let child = node.leftChild else {
                self.addAsLeftChild(child: input, parent: node)
                return
            }
            if child.isNullLeaf {
                self.addAsLeftChild(child: input, parent: node)
            } else {
                self.insert(input: input, node: child)
            }
        } else {
            guard let child = node.rightChild else {
                self.addAsRightChild(child: input, parent: node)
                return
            }
            if child.isNullLeaf {
                self.addAsRightChild(child: input, parent: node)
            } else {
                self.insert(input: input, node: child)
            }
        }
    }

    private func addAsLeftChild(child: RBNode, parent: RBNode) {
        parent.leftChild = child
        child.parent = parent
        child.color = .red
        self.insertFixup(node: child)
    }

    private func addAsRightChild(child: RBNode, parent: RBNode) {
        parent.rightChild = child
        child.parent = parent
        child.color = .red
        self.insertFixup(node: child)
    }

    /*
     * Fixes possible violations of the red-black property after insertion
     * Only violation of red-black properties occurs at inserted node |z| and z.parent
     * We have 3 distinct cases: case 1, 2a and 2b
     * - case 1: may repeat, but only h/2 steps, where h is the height of the tree
     * - case 2a -> case 2b -> red-black tree
     * - case 2b -> red-black tree
     */
    private func insertFixup(node zNode: RBNode) {
        if !zNode.isNullLeaf {
            guard let parentZ = zNode.parent else {
                return
            }
            // If both |z| and his parent are red -> violation of red-black property -> need to fix it
            if parentZ.color == .red {
                guard let uncle = zNode.uncle else {
                    return
                }
                // Case 1: Uncle red -> recolor + move z
                if uncle.color == .red {
                    parentZ.color = .black
                    uncle.color = .black
                    if let grandparentZ = parentZ.parent {
                        grandparentZ.color = .red
                        // Move z to grandparent and check again
                        self.insertFixup(node: grandparentZ)
                    }
                }
                // Case 2: Uncle black
                else {
                    var zNew = zNode
                    // Case 2.a: z right child -> rotate
                    if parentZ.isLeftChild, zNode.isRightChild {
                        zNew = parentZ
                        leftRotate(node: zNew)
                    } else if parentZ.isRightChild, zNode.isLeftChild {
                        zNew = parentZ
                        rightRotate(node: zNew)
                    }
                    // Case 2.b: z left child -> recolor + rotate
                    zNew.parent?.color = .black
                    if let grandparentZnew = zNew.grandparent {
                        grandparentZnew.color = .red
                        if zNode.isLeftChild {
                            rightRotate(node: grandparentZnew)
                        } else {
                            leftRotate(node: grandparentZnew)
                        }
                        // We have a valid red-black-tree
                    }
                }
            }
        }
        self.root.color = .black
    }
}

// MARK: - Deleting a node

extension RedBlackTree {
    /*
     * Delete a node with key |key| from the tree
     * 1. Perform standard delete operation as in a binary search tree
     * 2. Fix red-black properties
     * Runntime: O(log n)
     */
    func delete(key: T) {
        var floorNode: RBNode?
        if self.size == 1 {
            self.root = self.nullLeaf
            self.size -= 1
        } else if let node = search(key: key, node: root, floorNode: &floorNode) {
            if !node.isNullLeaf {
                self.delete(node: node)
                self.size -= 1
            }
        }
    }

    /*
     * Nearly identical delete operation as in a binary search tree
     * Differences: All nil pointers are replaced by the nullLeaf,
     * after deleting we call insertFixup to maintain the red-black properties if the delted node was
     * black (as if it was red -> no violation of red-black properties)
     */
    private func delete(node zNode: RBNode) {
        var nodeY = RBNode()
        var nodeX = RBNode()
        if let leftChild = zNode.leftChild, let rightChild = zNode.rightChild {
            if leftChild.isNullLeaf || rightChild.isNullLeaf {
                nodeY = zNode
            } else {
                if let successor = zNode.getSuccessor() {
                    nodeY = successor
                }
            }
        }
        if let leftChild = nodeY.leftChild {
            if !leftChild.isNullLeaf {
                nodeX = leftChild
            } else if let rightChild = nodeY.rightChild {
                nodeX = rightChild
            }
        }
        nodeX.parent = nodeY.parent
        if let parentY = nodeY.parent {
            // Should never be the case, as parent of root = nil
            if parentY.isNullLeaf {
                self.root = nodeX
            } else {
                if nodeY.isLeftChild {
                    parentY.leftChild = nodeX
                } else {
                    parentY.rightChild = nodeX
                }
            }
        } else {
            self.root = nodeX
        }
        if nodeY != zNode {
            zNode.key = nodeY.key
            zNode.value = nodeY.value
        }
        // If sliced out node was red -> nothing to do as red-black-property holds
        // If it was black -> fix red-black-property
        if nodeY.color == .black {
            self.deleteFixup(node: nodeX)
        }
    }

    /*
     * Fixes possible violations of the red-black property after deletion
     * We have w distinct cases: only case 2 may repeat, but only h many steps, where h is the height
     * of the tree
     * - case 1 -> case 2 -> red-black tree
     *   case 1 -> case 3 -> case 4 -> red-black tree
     *   case 1 -> case 4 -> red-black tree
     * - case 3 -> case 4 -> red-black tree
     * - case 4 -> red-black tree
     */
    private func deleteFixup(node xNode: RBNode) {
        var xTmp = xNode
        if !xNode.isRoot, xNode.color == .black {
            guard var sibling = xNode.sibling else {
                return
            }
            // Case 1: Sibling of x is red
            if sibling.color == .red {
                // Recolor
                sibling.color = .black
                if let parentX = xNode.parent {
                    parentX.color = .red
                    // Rotation
                    if xNode.isLeftChild {
                        leftRotate(node: parentX)
                    } else {
                        rightRotate(node: parentX)
                    }
                    // Update sibling
                    if let sibl = xNode.sibling {
                        sibling = sibl
                    }
                }
            }
            // Case 2: Sibling is black with two black children
            if sibling.leftChild?.color == .black, sibling.rightChild?.color == .black {
                // Recolor
                sibling.color = .red
                // Move fake black unit upwards
                if let parentX = xNode.parent {
                    self.deleteFixup(node: parentX)
                }
                // We have a valid red-black-tree
            } else {
                // Case 3: a. Sibling black with one black child to the right
                if xNode.isLeftChild, sibling.rightChild?.color == .black {
                    // Recolor
                    sibling.leftChild?.color = .black
                    sibling.color = .red
                    // Rotate
                    rightRotate(node: sibling)
                    // Update sibling of x
                    if let sibl = xNode.sibling {
                        sibling = sibl
                    }
                }
                // Still case 3: b. One black child to the left
                else if xNode.isRightChild, sibling.leftChild?.color == .black {
                    // Recolor
                    sibling.rightChild?.color = .black
                    sibling.color = .red
                    // Rotate
                    leftRotate(node: sibling)
                    // Update sibling of x
                    if let sibl = xNode.sibling {
                        sibling = sibl
                    }
                }
                // Case 4: Sibling is black with red right child
                // Recolor
                if let parentX = xNode.parent {
                    sibling.color = parentX.color
                    parentX.color = .black
                    // a. x left and sibling with red right child
                    if xNode.isLeftChild {
                        sibling.rightChild?.color = .black
                        // Rotate
                        leftRotate(node: parentX)
                    }
                    // b. x right and sibling with red left child
                    else {
                        sibling.leftChild?.color = .black
                        // Rotate
                        rightRotate(node: parentX)
                    }
                    // We have a valid red-black-tree
                    xTmp = self.root
                }
            }
        }
        xTmp.color = .black
    }
}

// MARK: - Rotation

private extension RedBlackTree {
    /*
     * Left rotation around node x
     * Assumes that x.rightChild y is not a nullLeaf, rotates around the link from x to y,
     * makes y the new root of the subtree with x as y's left child and y's left child as x's right
     * child, where n = a node, [n] = a subtree
     *     |                |
     *     x                y
     *   /   \     ~>     /   \
     * [A]    y          x    [C]
     *       / \        / \
     *     [B] [C]    [A] [B]
     */
    func leftRotate(node xNode: RBNode) {
        self.rotate(node: xNode, direction: .left)
    }

    /*
     * Right rotation around node y
     * Assumes that y.leftChild x is not a nullLeaf, rotates around the link from y to x,
     * makes x the new root of the subtree with y as x's right child and x's right child as y's left
     * child, where n = a node, [n] = a subtree
     *     |                |
     *     x                y
     *   /   \     <~     /   \
     * [A]    y          x    [C]
     *       / \        / \
     *     [B] [C]    [A] [B]
     */
    func rightRotate(node xNode: RBNode) {
        self.rotate(node: xNode, direction: .right)
    }

    /*
     * Rotation around a node x
     * Is a local operation preserving the binary-search-tree property that only exchanges pointers.
     * Runntime: O(1)
     */
    private func rotate(node xNode: RBNode, direction: RotationDirection) {
        var nodeY: RBNode? = RBNode()

        // Set |nodeY| and turn |nodeY|'s left/right subtree into |x|'s right/left subtree
        switch direction {
        case .left:
            nodeY = xNode.rightChild
            xNode.rightChild = nodeY?.leftChild
            xNode.rightChild?.parent = xNode
        case .right:
            nodeY = xNode.leftChild
            xNode.leftChild = nodeY?.rightChild
            xNode.leftChild?.parent = xNode
        }

        // Link |x|'s parent to nodeY
        nodeY?.parent = xNode.parent
        if xNode.isRoot {
            if let node = nodeY {
                self.root = node
            }
        } else if xNode.isLeftChild {
            xNode.parent?.leftChild = nodeY
        } else if xNode.isRightChild {
            xNode.parent?.rightChild = nodeY
        }

        // Put |x| on |nodeY|'s left
        switch direction {
        case .left:
            nodeY?.leftChild = xNode
        case .right:
            nodeY?.rightChild = xNode
        }
        xNode.parent = nodeY
    }
}

// MARK: - Verify

extension RedBlackTree {
    /*
     * Verifies that the existing tree fulfills all red-black properties
     * Returns true if the tree is a valid red-black tree, false otherwise
     */
    func verify() -> Bool {
        if self.root.isNullLeaf {
            Logger.trivial("The tree is empty")
            return true
        }
        return self.property2() && self.property4() && self.property5()
    }

    // Property 1: Every node is either red or black -> fullfilled through setting node.color of type
    // RBTreeColor

    // Property 2: The root is black
    private func property2() -> Bool {
        if self.root.color == .red {
            Logger.trivial("Property-Error: Root is red")
            return false
        }
        return true
    }

    // Property 3: Every nullLeaf is black -> fullfilled through initialising nullLeafs with color = black

    // Property 4: If a node is red, then both its children are black
    private func property4() -> Bool {
        return self.property4(node: self.root)
    }

    private func property4(node: RBNode) -> Bool {
        if node.isNullLeaf {
            return true
        }
        if let leftChild = node.leftChild, let rightChild = node.rightChild {
            if node.color == .red {
                if !leftChild.isNullLeaf, leftChild.color == .red {
                    Logger.trivial("Property-Error: Red node with key \(String(describing: node.key)) has red left child")
                    return false
                }
                if !rightChild.isNullLeaf, rightChild.color == .red {
                    Logger.trivial("Property-Error: Red node with key \(String(describing: node.key)) has red right child")
                    return false
                }
            }
            return self.property4(node: leftChild) && self.property4(node: rightChild)
        }
        return false
    }

    // Property 5: For each node, all paths from the node to descendant leaves contain the same number
    // of black nodes (same blackheight)
    private func property5() -> Bool {
        if self.property5(node: self.root) == -1 {
            return false
        } else {
            return true
        }
    }

    private func property5(node: RBNode) -> Int {
        if node.isNullLeaf {
            return 0
        }
        guard let leftChild = node.leftChild, let rightChild = node.rightChild else {
            return -1
        }
        let left = self.property5(node: leftChild)
        let right = self.property5(node: rightChild)

        if left == -1 || right == -1 {
            return -1
        } else if left == right {
            let addedHeight = node.color == .black ? 1 : 0
            return left + addedHeight
        } else {
            Logger.trivial("Property-Error: Black height violated at node with key \(String(describing: node.key))")
            return -1
        }
    }
}

// MARK: - Debugging

extension RBTreeNode: CustomDebugStringConvertible {
    var debugDescription: String {
        var str = ""
        if self.isNullLeaf {
            str = "nullLeaf"
        } else {
            if let key = key {
                str = "key: \(key)"
            } else {
                str = "key: nil"
            }
            if let parent = parent {
                str += ", parent: \(String(describing: parent.key))"
            }
            if let left = leftChild {
                str += ", left = [" + left.debugDescription + "]"
            }
            if let right = rightChild {
                str += ", right = [" + right.debugDescription + "]"
            }
            str += ", color = \(self.color)"
        }
        return str
    }
}

extension RedBlackTree: CustomDebugStringConvertible {
    var debugDescription: String {
        return self.root.debugDescription
    }
}

extension RBTreeNode: CustomStringConvertible {
    var description: String {
        var str = ""
        if self.isNullLeaf {
            str += "nullLeaf"
        } else {
            if let left = leftChild {
                str += "(\(left.description)) <- "
            }
            if let key = key {
                str += "\(key)"
            } else {
                str += "nil"
            }
            str += ", \(self.color)"
            if let right = rightChild {
                str += " -> (\(right.description))"
            }
        }
        return str
    }
}

extension RedBlackTree: CustomStringConvertible {
    var description: String {
        if self.root.isNullLeaf {
            return "[]"
        } else {
            return self.root.description
        }
    }
}
