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

import Foundation

/**
 * `RHTPQMapNode` is a node of RHTPQMap.
 */
struct RHTPQMapNode: Equatable {
    let rhtKey: String
    let rhtValue: CRDTElement

    fileprivate init(key: String, value: CRDTElement) {
        self.rhtKey = key
        self.rhtValue = value
    }

    /**
     * `isRemoved` checks whether this value was removed.
     */
    var isRemoved: Bool {
        return self.rhtValue.isRemoved
    }

    /**
     * `remove` removes a value base on removing time.
     */
    @discardableResult
    fileprivate func remove(removedAt: TimeTicket) -> Bool {
        return self.rhtValue.remove(removedAt)
    }

    static func == (lhs: RHTPQMapNode, rhs: RHTPQMapNode) -> Bool {
        return lhs.rhtKey == rhs.rhtKey && lhs.rhtValue.equals(rhs.rhtValue)
    }
}

/**
 * RHTPQMap is replicated hash table with priority queue by creation time.
 */
class RHTPQMap {
    private var elementQueueMapByKey: [String: Heap<TimeTicket, RHTPQMapNode>] = [:]
    private var nodeMapByCreatedAt: [TimeTicket: RHTPQMapNode] = [:]

    /**
     * `set` sets the value of the given key.
     */
    @discardableResult
    func set(key: String, value: CRDTElement) -> CRDTElement? {
        var removed: CRDTElement?

        if let queue = self.elementQueueMapByKey[key],
           queue.isEmpty == false,
           let node = queue.peek()
        {
            if node.value.isRemoved == false, node.value.remove(removedAt: value.createdAt) {
                removed = node.value.rhtValue
            }
        }

        self.setInternal(key: key, value: value)
        return removed
    }

    /**
     * `setInternal` sets the value of the given key.
     */
    private func setInternal(key: String, value: CRDTElement) {
        if self.elementQueueMapByKey[key] == nil {
            self.elementQueueMapByKey[key] = Heap()
        }

        let pqMapNode = RHTPQMapNode(key: key, value: value)
        let node = HeapNode(key: value.createdAt, value: pqMapNode)
        self.elementQueueMapByKey[key]?.push(node)
        self.nodeMapByCreatedAt[value.createdAt] = pqMapNode
    }

    /**
     * `remove` removes  the Element of the given key.
     */
    @discardableResult
    func remove(createdAt: TimeTicket, executedAt: TimeTicket) throws -> CRDTElement {
        guard let node = self.nodeMapByCreatedAt[createdAt] else {
            let log = "can't find the given node: \(createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        node.remove(removedAt: executedAt)
        return node.rhtValue
    }

    /**
     * `subPath` returns the sub path of the given element.
     */
    func subPath(createdAt: TimeTicket) throws -> String {
        guard let node = self.nodeMapByCreatedAt[createdAt] else {
            let log = "can't find the given node: \(createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        return node.rhtKey
    }

    /**
     * `delete` physically deletes child element.
     */
    func delete(value: CRDTElement) throws {
        guard let node = self.nodeMapByCreatedAt[value.createdAt] else {
            let log = "can't find the given node: \(value.createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        guard let queue = self.elementQueueMapByKey[node.rhtKey] else {
            let log = "can't find the given node: \(node.rhtKey)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        let heapNode = HeapNode(key: node.rhtValue.createdAt, value: node)
        queue.delete(heapNode)
        self.nodeMapByCreatedAt[node.rhtValue.createdAt] = nil
    }

    /**
     * `remove` removes the Element of the given key and removed time.
     */
    func remove(key: String, executedAt: TimeTicket) throws -> CRDTElement {
        guard let heap = self.elementQueueMapByKey[key],
              let node = heap.peek()
        else {
            let log = "can't find the given node: \(key)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        node.value.remove(removedAt: executedAt)
        return node.value.rhtValue
    }

    /**
     * `has` returns whether the element exists of the given key or not.
     */
    func has(key: String) -> Bool {
        guard let heap = self.elementQueueMapByKey[key],
              let node = heap.peek()
        else {
            return false
        }

        return node.value.isRemoved == false
    }

    /**
     * `get` returns the value of the given key.
     */
    func get(key: String) throws -> CRDTElement {
        guard let heap = elementQueueMapByKey[key], let node = heap.peek() else {
            let log = "can't find the given node: \(key)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        return node.value.rhtValue
    }
}

extension RHTPQMap: Sequence {
    typealias Element = RHTPQMapNode

    func makeIterator() -> RHTPQMapIterator {
        return RHTPQMapIterator(self.elementQueueMapByKey)
    }
}

class RHTPQMapIterator: IteratorProtocol {
    private var target: [Heap<TimeTicket, RHTPQMapNode>]
    private var currentNodes: [RHTPQMapNode] = []

    init(_ target: [String: Heap<TimeTicket, RHTPQMapNode>]) {
        self.target = Array(target.values)
    }

    func next() -> RHTPQMapNode? {
        while true {
            guard self.currentNodes.isEmpty else {
                return self.currentNodes.removeFirst()
            }

            guard self.target.isEmpty == false else {
                return nil
            }

            let queue = self.target.removeFirst()

            for node in queue {
                self.currentNodes.append(node.value)
            }
        }
    }
}
