/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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

/// Represents the data stored in the nodes of ``TreeList``.
protocol TreeListValue: AnyObject {
    /// Whether this value is a tombstone that must not count toward the live (logical) index.
    var isRemoved: Bool { get }

    /// A debug representation of the value, used by ``TreeList/toTestString``.
    var toTestString: String { get }
}

/// A node of ``TreeList``.
///
/// It tracks two aggregates over its subtree:
///   - `weight`: number of non-removed (live) nodes (logical index)
///   - `count`: total nodes including tombstones (structural index)
final class TreeListNode<V: TreeListValue> {
    /// The value carried by this node.
    ///
    /// The reference is strong: for the RGATreeList integration the value
    /// (`RGATreeListNode`) owns its index node, and this back-reference is
    /// released via `TreeList.delete` when the position is physically purged.
    let value: V

    fileprivate var left: TreeListNode<V>?
    fileprivate var right: TreeListNode<V>?
    fileprivate weak var parent: TreeListNode<V>?

    fileprivate var weight: Int
    fileprivate var count: Int

    fileprivate var red: Bool

    init(_ value: V) {
        self.value = value
        self.red = true
        self.weight = value.isRemoved ? 0 : 1
        self.count = 1
    }

    /// Returns the value of this node.
    func getValue() -> V {
        return self.value
    }

    /// Returns 1 if the node is live, 0 if removed (tombstone).
    fileprivate var size: Int {
        return self.value.isRemoved ? 0 : 1
    }

    /// The cached live-node weight of the left subtree, or 0 if absent.
    fileprivate var leftWeight: Int {
        return self.left?.weight ?? 0
    }

    /// The cached live-node weight of the right subtree, or 0 if absent.
    fileprivate var rightWeight: Int {
        return self.right?.weight ?? 0
    }

    /// The cached total node count of the left subtree, or 0 if absent.
    fileprivate var leftCount: Int {
        return self.left?.count ?? 0
    }

    /// The cached total node count of the right subtree, or 0 if absent.
    fileprivate var rightCount: Int {
        return self.right?.count ?? 0
    }
}

/// Reports whether the given node is a red link. An absent node is treated as
/// black, matching the standard LLRB convention.
private func isRed<V: TreeListValue>(_ node: TreeListNode<V>?) -> Bool {
    return node?.red ?? false
}

/// Recomputes the cached weight and count aggregates of `node` from its
/// children. Call this whenever the structure or liveness of a child changes.
private func updateNode<V: TreeListValue>(_ node: TreeListNode<V>) {
    node.weight = node.leftWeight + node.size + node.rightWeight
    node.count = node.leftCount + 1 + node.rightCount
}

/// Performs a standard LLRB left rotation around `node`, promoting its right
/// child. Parent pointers and aggregate counters are refreshed and the new
/// subtree root is returned.
private func rotateLeft<V: TreeListValue>(_ node: TreeListNode<V>) -> TreeListNode<V> {
    let right = node.right!

    node.right = right.left
    node.right?.parent = node

    right.left = node
    right.parent = node.parent
    node.parent = right

    right.red = node.red
    node.red = true

    updateNode(node)
    updateNode(right)
    return right
}

/// Performs a standard LLRB right rotation around `node`, promoting its left
/// child. Parent pointers and aggregate counters are refreshed and the new
/// subtree root is returned.
private func rotateRight<V: TreeListValue>(_ node: TreeListNode<V>) -> TreeListNode<V> {
    let left = node.left!

    node.left = left.right
    node.left?.parent = node

    left.right = node
    left.parent = node.parent
    node.parent = left

    left.red = node.red
    node.red = true

    updateNode(node)
    updateNode(left)
    return left
}

/// Toggles the colors of `node` and both of its children, used during LLRB
/// splits and merges.
private func flipColors<V: TreeListValue>(_ node: TreeListNode<V>) {
    node.red.toggle()
    node.left?.red.toggle()
    node.right?.red.toggle()
}

/// Ensures the left child or one of its children is red so a deletion
/// descending to the left can proceed without violating LLRB invariants. The
/// new subtree root is returned.
private func moveRedLeft<V: TreeListValue>(_ node: TreeListNode<V>) -> TreeListNode<V> {
    var node = node
    flipColors(node)
    if isRed(node.right!.left) {
        node.right = rotateRight(node.right!)
        node.right?.parent = node
        node = rotateLeft(node)
        flipColors(node)
    }
    return node
}

/// Ensures the right child or one of its children is red so a deletion
/// descending to the right can proceed without violating LLRB invariants. The
/// new subtree root is returned.
private func moveRedRight<V: TreeListValue>(_ node: TreeListNode<V>) -> TreeListNode<V> {
    var node = node
    flipColors(node)
    if isRed(node.left!.left) {
        node = rotateRight(node)
        flipColors(node)
    }
    return node
}

/// Removes the minimum (left-most) node from the subtree rooted at `node` and
/// returns the rebalanced subtree root. Used by `delete` when splicing in the
/// in-order successor.
private func removeMin<V: TreeListValue>(_ node: TreeListNode<V>) -> TreeListNode<V>? {
    var node = node
    if node.left == nil {
        return nil
    }

    if !isRed(node.left), !isRed(node.left!.left) {
        node = moveRedLeft(node)
    }

    node.left = removeMin(node.left!)
    node.left?.parent = node

    return fixUp(node)
}

/// Returns the left-most node of the subtree rooted at `node`, which is the
/// in-order successor used during deletion.
private func minNode<V: TreeListValue>(_ node: TreeListNode<V>) -> TreeListNode<V> {
    var node = node
    while let left = node.left {
        node = left
    }
    return node
}

/// Restores LLRB invariants on the way back up after an insertion or deletion:
/// it leans right-red links left, splits 4-nodes, and refreshes the node's
/// aggregate counters.
private func fixUp<V: TreeListValue>(_ node: TreeListNode<V>) -> TreeListNode<V> {
    var node = node
    if isRed(node.right), !isRed(node.left) {
        node = rotateLeft(node)
    }
    if isRed(node.left), isRed(node.left!.left) {
        node = rotateRight(node)
    }
    if isRed(node.left), isRed(node.right) {
        flipColors(node)
    }
    updateNode(node)
    return node
}

/// Walks the subtree rooted at `node` in left-root-right order, invoking `body`
/// on every node (live and tombstoned).
private func traverseInOrder<V: TreeListValue>(_ node: TreeListNode<V>?, _ body: (TreeListNode<V>) -> Void) {
    guard let node else {
        return
    }
    traverseInOrder(node.left, body)
    body(node)
    traverseInOrder(node.right, body)
}

/// An order-statistic tree based on a Left-leaning Red-Black Tree.
///
/// It is used by ``RGATreeList`` to support index-based operations on a list
/// with tombstones, guaranteeing O(log N) worst-case for all operations.
///
/// It maintains two weights per node:
///   - `weight`: count of non-removed nodes (for index-based lookup)
///   - `count`: total nodes including tombstones (for structural operations)
final class TreeList<V: TreeListValue> {
    private var root: TreeListNode<V>?

    init(_ root: TreeListNode<V>? = nil) {
        root?.red = false
        self.root = root
    }

    /// The number of non-removed (live) nodes.
    var length: Int {
        return self.root?.weight ?? 0
    }

    /// Inserts `target` right after `prev` in the in-order traversal.
    ///
    /// It uses structural (count-based) indexing to correctly handle tombstone
    /// nodes.
    func insertAfter(_ prev: TreeListNode<V>, _ target: TreeListNode<V>) {
        target.left = nil
        target.right = nil
        target.parent = nil
        target.red = true
        target.weight = target.size
        target.count = 1

        let idx = self.structuralIndexOf(prev)
        self.root = self.insertByCount(self.root, idx + 1, target)
        self.root?.red = false
        self.root?.parent = nil
    }

    /// Inserts `newNode` at the given structural index within the subtree
    /// rooted at `node`, descending using each node's left count (tombstones
    /// included) and rebalancing on the way back up.
    private func insertByCount(_ node: TreeListNode<V>?, _ index: Int, _ newNode: TreeListNode<V>) -> TreeListNode<V> {
        guard let node else {
            return newNode
        }

        if index <= node.leftCount {
            node.left = self.insertByCount(node.left, index, newNode)
            node.left?.parent = node
        } else {
            node.right = self.insertByCount(node.right, index - node.leftCount - 1, newNode)
            node.right?.parent = node
        }

        return fixUp(node)
    }

    /// Returns the node at the given logical index (among non-removed nodes).
    ///
    /// - Throws: ``YorkieError`` when the index is out of range.
    func find(_ index: Int) throws -> TreeListNode<V> {
        guard let root = self.root, index >= 0, index < self.length else {
            throw YorkieError(code: .errInvalidArgument, message: "out of index: tree size \(self.length), index \(index)")
        }

        var node = root
        var index = index
        while true {
            if index < node.leftWeight {
                node = node.left!
            } else if index < node.leftWeight + node.size {
                break
            } else {
                index -= node.leftWeight + node.size
                node = node.right!
            }
        }
        return node
    }

    /// Physically removes `node` from the tree.
    ///
    /// Unlike tombstoning, this completely removes the node from the tree
    /// structure. It uses structural (count-based) indexing and swaps the node
    /// structure (not values) with its successor to preserve node identity.
    func delete(_ node: TreeListNode<V>) {
        guard let root = self.root else {
            return
        }

        if !isRed(root.left), !isRed(root.right) {
            root.red = true
        }

        let idx = self.structuralIndexOf(node)
        self.root = self.deleteByCount(root, idx)

        if let root = self.root {
            root.red = false
            root.parent = nil
        }
    }

    /// Removes the node at the given structural index within the subtree rooted
    /// at `node`.
    ///
    /// When deleting an internal node, it swaps in the in-order successor by
    /// re-parenting rather than copying values so external references to the
    /// surviving node remain valid.
    private func deleteByCount(_ node: TreeListNode<V>, _ index: Int) -> TreeListNode<V>? {
        var node = node

        if index < node.leftCount {
            if !isRed(node.left), !isRed(node.left!.left) {
                node = moveRedLeft(node)
            }
            node.left = self.deleteByCount(node.left!, index)
            node.left?.parent = node
        } else {
            if isRed(node.left) {
                node = rotateRight(node)
            }

            if index == node.leftCount, node.right == nil {
                return nil
            }

            if !isRed(node.right), !isRed(node.right!.left) {
                node = moveRedRight(node)
            }

            if index == node.leftCount {
                // Swap the successor into this position instead of copying
                // values. This preserves node identity so external references
                // remain valid.
                let successor = minNode(node.right!)
                let newRight = removeMin(node.right!)

                successor.left = node.left
                successor.right = newRight
                successor.red = node.red
                successor.left?.parent = successor
                successor.right?.parent = successor

                node.left = nil
                node.right = nil
                node.parent = nil

                node = successor
            } else {
                node.right = self.deleteByCount(node.right!, index - node.leftCount - 1)
                node.right?.parent = node
            }
        }

        return fixUp(node)
    }

    /// Propagates weight changes from `node` up to the root.
    ///
    /// Call this after a node's `isRemoved` status changes (i.e., after
    /// tombstoning).
    func updateWeight(_ node: TreeListNode<V>) {
        var cur: TreeListNode<V>? = node
        while let current = cur {
            current.weight = current.leftWeight + current.size + current.rightWeight
            cur = current.parent
        }
    }

    /// Returns a string containing the metadata of the nodes for debugging.
    var toTestString: String {
        var result = ""
        traverseInOrder(self.root) { node in
            result += "[\(node.weight),\(node.size)]\(node.value.toTestString)"
        }
        return result
    }

    /// Returns the logical (live-node) index of `node`, or -1 if the node is a
    /// tombstone.
    func indexOf(_ node: TreeListNode<V>) -> Int {
        if node.size == 0 {
            return -1
        }
        var index = node.leftWeight
        var cur = node
        while let parent = cur.parent {
            if cur === parent.right {
                index += parent.leftWeight + parent.size
            }
            cur = parent
        }
        return index
    }

    /// Returns the structural position of `node`, counting all nodes including
    /// tombstones.
    private func structuralIndexOf(_ node: TreeListNode<V>) -> Int {
        var index = node.leftCount
        var cur = node
        while let parent = cur.parent {
            if cur === parent.right {
                index += parent.leftCount + 1
            }
            cur = parent
        }
        return index
    }
}
