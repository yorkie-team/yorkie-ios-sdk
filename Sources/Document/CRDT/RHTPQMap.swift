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
class RHTPQMapNode: HeapNode<TimeTicket, CRDTElement> {
    let rhtPqMapKey: String

    init(key: String, value: CRDTElement) {
        self.rhtPqMapKey = key
        super.init(key: value.getCreatedAt(), value: value)
    }

    /**
     * `isRemoved` checks whether this value was removed.
     */
    func isRemoved() -> Bool {
        return self.value.isRemoved()
    }

    /**
     * `remove` removes a value base on removing time.
     */
    @discardableResult
    func remove(removedAt: TimeTicket) -> Bool {
        return self.value.remove(removedAt)
    }
}

/**
 * RHTPQMap is replicated hash table with priority queue by creation time.
 */
class RHTPQMap {
    private var elementQueueMapByKey: [String: Heap<TimeTicket, CRDTElement>] = [:]
    private var nodeMapByCreatedAt: [TimeTicket: RHTPQMapNode] = [:]

    /**
     * `set` sets the value of the given key.
     */
    @discardableResult
    func set(key: String, value: CRDTElement) -> CRDTElement? {
        var removed: CRDTElement?

        if let queue = self.elementQueueMapByKey[key],
           queue.length() >= 1,
           let node = queue.peek() as? RHTPQMapNode
        {
            if node.isRemoved() == false, node.remove(removedAt: value.getCreatedAt()) {
                removed = node.value
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

        let node = RHTPQMapNode(key: key, value: value)
        self.elementQueueMapByKey[key]?.push(node)
        self.nodeMapByCreatedAt[value.getCreatedAt()] = node
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
        return node.value
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

        return node.rhtPqMapKey
    }

    /**
     * `delete` physically purge child element.
     */
    func delete(element: CRDTElement) throws {
        guard let node = self.nodeMapByCreatedAt[element.getCreatedAt()] else {
            let log = "can't find the given node: \(element.getCreatedAt())"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        guard let queue = self.elementQueueMapByKey[node.rhtPqMapKey] else {
            let log = "can't find the given node: \(node.rhtPqMapKey)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        queue.delete(node)
        self.nodeMapByCreatedAt[node.value.getCreatedAt()] = nil
    }

    /**
     * `remove` deletes the Element of the given key and removed time.
     */
    func remove(key: String, executedAt: TimeTicket) throws -> CRDTElement {
        guard let heap = self.elementQueueMapByKey[key],
              let node = heap.peek() as? RHTPQMapNode
        else {
            let log = "can't find the given node: \(key)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        node.remove(removedAt: executedAt)
        return node.value
    }

    /**
     * `has` returns whether the element exists of the given key or not.
     */
    func has(key: String) -> Bool {
        guard let heap = self.elementQueueMapByKey[key],
              let node = heap.peek() as? RHTPQMapNode
        else {
            return false
        }

        return node.isRemoved() == false
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

        return node.value
    }
}

extension RHTPQMap: Sequence {
    typealias Element = RHTPQMapNode

    func makeIterator() -> RHTPQMapIterator {
        return RHTPQMapIterator(self.elementQueueMapByKey)
    }
}

class RHTPQMapIterator: IteratorProtocol {
    private var target: [Heap<TimeTicket, CRDTElement>]
    private var currentNodes: [RHTPQMapNode] = []

    init(_ target: [String: Heap<TimeTicket, CRDTElement>]) {
        self.target = Array(target.values)
    }

    func next() -> RHTPQMapNode? {
        while true {
            guard self.currentNodes.isEmpty else {
                break
            }
            
            guard self.target.isEmpty == false else {
                return nil
            }

            let queue = self.target.removeFirst()

            for node in queue {
                if let node = node as? RHTPQMapNode {
                    self.currentNodes.append(node)
                }
            }
        }

        return self.currentNodes.removeFirst()
    }
}
