/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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
 * `ElementRHTNode` is a node of ElementRHT.
 */
struct ElementRHTNode: Equatable {
    let key: String
    let value: CRDTElement

    fileprivate init(key: String, value: CRDTElement) {
        self.key = key
        self.value = value
    }

    /**
     * `isRemoved` checks whether this value was removed.
     */
    var isRemoved: Bool {
        return self.value.isRemoved
    }

    /**
     * `remove` removes a value base on removing time.
     */
    @discardableResult
    fileprivate func remove(removedAt: TimeTicket) -> Bool {
        return self.value.remove(removedAt)
    }

    static func == (lhs: ElementRHTNode, rhs: ElementRHTNode) -> Bool {
        return lhs.key == rhs.key && lhs.value.equals(rhs.value)
    }
}

/**
 * ElementRHT is replicated hash table with priority queue by creation time.
 */
class ElementRHT {
    // nodeMapByKey is a map with values of nodes by key.
    private var nodeMapByKey: [String: ElementRHTNode] = [:]
    // nodeMapByCreatedAt is a map with values of nodes by creation time.
    private var nodeMapByCreatedAt: [String: ElementRHTNode] = [:]

    /**
     * `set` sets the value of the given key.
     */
    @discardableResult
    func set(key: String, value: CRDTElement) -> CRDTElement? {
        var removed: CRDTElement?

        let node = self.nodeMapByKey[key]
        if node != nil, node!.isRemoved == false, node!.remove(removedAt: value.createdAt) {
            removed = node!.value
        }

        let newNode = ElementRHTNode(key: key, value: value)
        self.nodeMapByCreatedAt[value.createdAt.toIDString] = newNode

        if node == nil || value.createdAt.after(node!.value.createdAt) {
            self.nodeMapByKey[key] = newNode
        }

        return removed
    }

    /**
     * `delete` deletes  the Element of the given creation time
     */
    @discardableResult
    func delete(createdAt: TimeTicket, executedAt: TimeTicket) throws -> CRDTElement {
        guard let node = nodeMapByCreatedAt[createdAt.toIDString] else {
            throw YorkieError(code: .errInvalidArgument, message: "Can't find node of given createdAt [\(createdAt)] or executedAt [\(executedAt)]")
        }

        node.remove(removedAt: executedAt)
        return node.value
    }

    /**
     * `subPath` returns the sub path of the given element.
     */
    func subPath(createdAt: TimeTicket) throws -> String {
        guard let node = self.nodeMapByCreatedAt[createdAt.toIDString] else {
            let log = "can't find the given node: \(createdAt)"

            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        return node.key
    }

    /**
     * purge physically purge child element.
     */
    func purge(element: CRDTElement) throws {
        guard let node = nodeMapByCreatedAt[element.createdAt.toIDString] else {
            throw YorkieError(code: .errInvalidArgument, message: "fail to find: \(element.createdAt)")
        }

        if node == self.nodeMapByKey[node.key] {
            self.nodeMapByKey.removeValue(forKey: self.nodeMapByKey[node.key]!.key)
        }

        self.nodeMapByCreatedAt.removeValue(forKey: node.value.createdAt.toIDString)
    }

    /**
     * `deleteByKey` deletes the Element of the given key and removed time.
     */
    @discardableResult
    func deleteByKey(key: String, executedAt: TimeTicket) throws -> CRDTElement {
        guard let node = nodeMapByKey[key] else {
            throw YorkieError(code: .errInvalidArgument, message: "Can't find node of given key [\(key)] or executedAt [\(executedAt)]")
        }

        node.remove(removedAt: executedAt)

        return node.value
    }

    /**
     * `has` returns whether the element exists of the given key or not.
     */
    func has(key: String) -> Bool {
        if let node = nodeMapByKey[key] {
            return node.isRemoved == false
        } else {
            return false
        }
    }

    /**
     * `get` returns the value of the given key.
     */
    func get(key: String) -> CRDTElement? {
        self.nodeMapByKey[key]?.value
    }
}

extension ElementRHT: Sequence {
    typealias Element = ElementRHTNode

    func makeIterator() -> ElementRHTIterator {
        return ElementRHTIterator(self.nodeMapByKey)
    }
}

class ElementRHTIterator: IteratorProtocol {
    private var target: [ElementRHTNode]
    private var currentNodes: [ElementRHTNode] = []

    init(_ target: [String: ElementRHTNode]) {
        self.target = Array(target.values)
    }

    func next() -> ElementRHTNode? {
        while true {
            guard self.currentNodes.isEmpty else {
                return self.currentNodes.removeFirst()
            }

            guard self.target.isEmpty == false else {
                return nil
            }

            self.currentNodes.append(self.target.removeFirst())
        }
    }
}
