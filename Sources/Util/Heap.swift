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

struct Heap<T: Comparable> {
    /** The array that stores the heap's nodes. */
    var nodes = [T]()

    /**
     * Determines how to compare two nodes in the heap.
     * Use '>' for a max-heap or '<' for a min-heap,
     * or provide a comparing method if the heap is made
     * of custom elements, for example tuples.
     */
    private var orderCriteria: (T, T) -> Bool

    /// Create a max-heap
    init() {
        self.orderCriteria = { left, right -> Bool in
            left > right
        }
    }

    /// Create a max-heap
    init(array: [T]) {
        self.orderCriteria = { left, right -> Bool in
            left > right
        }
        self.configureHeap(from: array)
    }

    /**
     * Creates an empty heap.
     * The sort function determines whether this is a min-heap or max-heap.
     * For comparable data types, > makes a max-heap, < makes a min-heap.
     */
    init(sort: @escaping (T, T) -> Bool) {
        self.orderCriteria = sort
    }

    /**
     * Creates a heap from an array. The order of the array does not matter;
     * the elements are inserted into the heap in the order determined by the
     * sort function. For comparable data types, '>' makes a max-heap,
     * '<' makes a min-heap.
     */
    init(array: [T], sort: @escaping (T, T) -> Bool) {
        self.orderCriteria = sort
        self.configureHeap(from: array)
    }

    /**
     * Configures the max-heap or min-heap from an array, in a bottom-up manner.
     * Performance: This runs pretty much in O(n).
     */
    private mutating func configureHeap(from array: [T]) {
        self.nodes = array
        for index in stride(from: self.nodes.count / 2 - 1, through: 0, by: -1) {
            self.shiftDown(index)
        }
    }

    var isEmpty: Bool {
        return self.nodes.isEmpty
    }

    var count: Int {
        return self.nodes.count
    }

    /**
     * Returns the index of the parent of the element at index i.
     * The element at index 0 is the root of the tree and has no parent.
     */
    @inline(__always) internal func parentIndex(ofIndex index: Int) -> Int {
        return (index - 1) / 2
    }

    /**
     * Returns the index of the left child of the element at index i.
     * Note that this index can be greater than the heap size, in which case
     * there is no left child.
     */
    @inline(__always) internal func leftChildIndex(ofIndex index: Int) -> Int {
        return 2 * index + 1
    }

    /**
     * Returns the index of the right child of the element at index i.
     * Note that this index can be greater than the heap size, in which case
     * there is no right child.
     */
    @inline(__always) internal func rightChildIndex(ofIndex index: Int) -> Int {
        return 2 * index + 2
    }

    /**
     * Returns the maximum value in the heap (for a max-heap) or the minimum
     * value (for a min-heap).
     */
    func peek() -> T? {
        return self.nodes.first
    }

    /**
     * Adds a new value to the heap. This reorders the heap so that the max-heap
     * or min-heap property still holds. Performance: O(log n).
     */
    mutating func insert(_ value: T) {
        self.nodes.append(value)
        self.shiftUp(self.nodes.count - 1)
    }

    /**
     * Adds a sequence of values to the heap. This reorders the heap so that
     * the max-heap or min-heap property still holds. Performance: O(log n).
     */
    mutating func insert<S: Sequence>(_ sequence: S) where S.Iterator.Element == T {
        for value in sequence {
            self.insert(value)
        }
    }

    /**
     * Allows you to change an element. This reorders the heap so that
     * the max-heap or min-heap property still holds.
     */
    mutating func replace(index: Int, value: T) {
        guard index < self.nodes.count else { return }

        self.remove(at: index)
        self.insert(value)
    }

    /**
     * Removes the root node from the heap. For a max-heap, this is the maximum
     * value; for a min-heap it is the minimum value. Performance: O(log n).
     */
    @discardableResult mutating func remove() -> T? {
        guard !self.nodes.isEmpty else { return nil }

        if self.nodes.count == 1 {
            return self.nodes.removeLast()
        } else {
            // Use the last node to replace the first one, then fix the heap by
            // shifting this new first node into its proper position.
            let value = self.nodes[0]
            self.nodes[0] = self.nodes.removeLast()
            self.shiftDown(0)
            return value
        }
    }

    /**
     * Removes an arbitrary node from the heap. Performance: O(log n).
     * Note that you need to know the node's index.
     */
    @discardableResult mutating func remove(at index: Int) -> T? {
        guard index < self.nodes.count else { return nil }

        let size = self.nodes.count - 1
        if index != size {
            self.nodes.swapAt(index, size)
            self.shiftDown(from: index, until: size)
            self.shiftUp(index)
        }
        return self.nodes.removeLast()
    }

    /**
     * Takes a child node and looks at its parents; if a parent is not larger
     * (max-heap) or not smaller (min-heap) than the child, we exchange them.
     */
    internal mutating func shiftUp(_ index: Int) {
        var childIndex = index
        let child = self.nodes[childIndex]
        var parentIndex = self.parentIndex(ofIndex: childIndex)

        while childIndex > 0, self.orderCriteria(child, self.nodes[parentIndex]) {
            self.nodes[childIndex] = self.nodes[parentIndex]
            childIndex = parentIndex
            parentIndex = self.parentIndex(ofIndex: childIndex)
        }

        self.nodes[childIndex] = child
    }

    /**
     * Looks at a parent node and makes sure it is still larger (max-heap) or
     * smaller (min-heap) than its childeren.
     */
    internal mutating func shiftDown(from index: Int, until endIndex: Int) {
        let leftChildIndex = self.leftChildIndex(ofIndex: index)
        let rightChildIndex = leftChildIndex + 1

        // Figure out which comes first if we order them by the sort function:
        // the parent, the left child, or the right child. If the parent comes
        // first, we're done. If not, that element is out-of-place and we make
        // it "float down" the tree until the heap property is restored.
        var first = index
        if leftChildIndex < endIndex, self.orderCriteria(self.nodes[leftChildIndex], self.nodes[first]) {
            first = leftChildIndex
        }
        if rightChildIndex < endIndex, self.orderCriteria(self.nodes[rightChildIndex], self.nodes[first]) {
            first = rightChildIndex
        }
        if first == index { return }

        self.nodes.swapAt(index, first)
        self.shiftDown(from: first, until: endIndex)
    }

    internal mutating func shiftDown(_ index: Int) {
        self.shiftDown(from: index, until: self.nodes.count)
    }
}

// MARK: - Searching

extension Heap where T: Equatable {
    /** Get the index of a node in the heap. Performance: O(n). */
    func index(of node: T) -> Int? {
        return self.nodes.firstIndex(where: { $0 == node })
    }

    /** Removes the first occurrence of a node from the heap. Performance: O(n). */
    @discardableResult mutating func remove(node: T) -> T? {
        if let index = index(of: node) {
            return self.remove(at: index)
        }
        return nil
    }
}
