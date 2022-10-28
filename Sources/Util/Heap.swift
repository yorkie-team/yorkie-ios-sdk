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

// Copyright (c) 2016 Matthijs Hollemans and contributors. Licensed under the MIT license.
// See LICENSE in the project root for license information.

import Foundation

/**
 * `HeapNode` is a node of `Heap`.
 */
struct HeapNode<K, V> {
    fileprivate let key: K
    let value: V

    init(key: K, value: V) {
        self.key = key
        self.value = value
    }
}

/**
 * `Heap` is a heap implemented with max heap.
 */
class Heap<K: Comparable, V: Equatable>: Sequence, IteratorProtocol {
    private var nodes: [HeapNode<K, V>] = []

    /**
     * `peek` returns the maximum element from this Heap.
     */
    func peek() -> HeapNode<K, V>? {
        guard self.nodes.isEmpty == false else {
            return nil
        }

        return self.nodes[0]
    }

    /**
     * `length` is the number of elements in this Heap.
     */
    func length() -> Int {
        return self.nodes.count
    }

    var isEmpty: Bool {
        return self.nodes.isEmpty
    }

    /**
     * `delete` deletes the given value from this Heap.
     */
    func delete(_ node: HeapNode<K, V>) {
        let lastIndexBeforeDeleted = self.nodes.count - 1
        guard let targetIndex = self.nodes.firstIndex(where: { $0.value == node.value }),
              let lastNode = self.nodes.popLast()
        else {
            return
        }

        if targetIndex < 0 || self.isEmpty || targetIndex == lastIndexBeforeDeleted {
            return
        }

        self.nodes[targetIndex] = lastNode

        self.heapify(parentIndex: self.getParentIndex(targetIndex), targetIndex: targetIndex)
    }

    /**
     * `push` pushes the given node onto this Heap.
     */
    func push(_ node: HeapNode<K, V>) {
        self.nodes.append(node)
        self.moveUp(self.nodes.count - 1)
    }

    /**
     * `pop` removes and returns the maximum element from this Heap.
     */
    @discardableResult
    func pop() -> HeapNode<K, V>? {
        guard let head = self.nodes[safe: 0] else {
            return nil
        }

        if self.nodes.count == 1 {
            // clear array
            self.nodes.removeAll()
        } else {
            if let node = self.nodes.popLast() {
                self.nodes[0] = node
                self.moveDown(0)
            }
        }

        return head
    }

    private func heapify(parentIndex: Int, targetIndex: Int) {
        if parentIndex > -1, self.nodes[parentIndex].key < self.nodes[targetIndex].key {
            self.moveUp(targetIndex)
        } else {
            self.moveDown(targetIndex)
        }
    }

    private func moveUp(_ index: Int) {
        var index = index
        let node = self.nodes[index]

        while index > 0 {
            let parentIndex = self.getParentIndex(index)
            if self.nodes[parentIndex].key < node.key {
                self.nodes[index] = self.nodes[parentIndex]
                index = parentIndex
            } else {
                break
            }
        }
        self.nodes[index] = node
    }

    private func moveDown(_ index: Int) {
        var index = index
        let count = self.nodes.count

        let node = self.nodes[index]
        while index < count >> 1 {
            let leftChildIndex = self.getLeftChildIndex(index)
            let rightChildIndex = self.getRightChildIndex(index)

            let smallerChildIndex = rightChildIndex < count && self.nodes[leftChildIndex].key < self.nodes[rightChildIndex].key ? rightChildIndex : leftChildIndex

            if self.nodes[smallerChildIndex].key < node.key {
                break
            }

            self.nodes[index] = self.nodes[smallerChildIndex]
            index = smallerChildIndex
        }
        self.nodes[index] = node
    }

    private func getParentIndex(_ index: Int) -> Int {
        return (index - 1) >> 1
    }

    private func getLeftChildIndex(_ index: Int) -> Int {
        return index * 2 + 1
    }

    private func getRightChildIndex(_ index: Int) -> Int {
        return index * 2 + 2
    }

    // MARK: - Iterator

    var iteratorNext: Int = 0

    typealias Element = HeapNode

    func makeIterator() -> Heap {
        self.iteratorNext = 0
        return self
    }

    func next() -> HeapNode<K, V>? {
        defer {
            self.iteratorNext += 1
        }

        guard self.nodes.count > self.iteratorNext else {
            return nil
        }

        return self.nodes[self.iteratorNext]
    }
}
