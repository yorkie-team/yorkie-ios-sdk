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
 * `RHTNode` is a node of RHT(Replicated Hashtable).
 */
class RHTNode: GCChild {
    var key: String
    var value: String
    var updatedAt: TimeTicket
    var isRemoved: Bool

    init(key: String, value: String, updatedAt: TimeTicket, isRemoved: Bool) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
        self.isRemoved = isRemoved
    }

    /**
     * `toIDString` returns the IDString of this node.
     */
    var toIDString: String {
        "\(self.updatedAt.toIDString):\(self.key)"
    }

    /**
     * `removedAt` returns the time when this node was removed.
     */
    var removedAt: TimeTicket? {
        if self.isRemoved {
            return self.updatedAt
        }

        return nil
    }
}

/**
 * RHT is replicated hash table by creation time.
 * For more details about RHT: @see http://csl.skku.edu/papers/jpdc11.pdf
 */
class RHT {
    private var nodeMapByKey = [String: RHTNode]()
    private var numberOfRemovedElement: Int = 0

    /**
     * `set` sets the value of the given key.
     */
    @discardableResult
    func set(key: String, value: String, executedAt: TimeTicket) -> (RHTNode?, RHTNode?) {
        let prev = self.nodeMapByKey[key]

        if prev != nil && prev!.isRemoved && executedAt.after(prev!.updatedAt) {
            self.numberOfRemovedElement -= 1
        }

        if prev == nil || executedAt.after(prev!.updatedAt) {
            let node = RHTNode(key: key, value: value, updatedAt: executedAt, isRemoved: false)
            self.nodeMapByKey[key] = node

            if prev != nil, prev!.isRemoved {
                return (prev, node)
            }

            return (nil, node)
        }

        return (prev?.isRemoved ?? false ? prev : nil, nil)
    }

    /**
     * `remove` removes the Element of the given key.
     */
    @discardableResult
    func remove(key: String, executedAt: TimeTicket) -> [RHTNode] {
        let prev = self.nodeMapByKey[key]
        var gcNodes = [RHTNode]()

        if prev == nil || executedAt.after(prev!.updatedAt) {
            if prev == nil {
                self.numberOfRemovedElement += 1
                let node = RHTNode(key: key, value: "", updatedAt: executedAt, isRemoved: true)
                self.nodeMapByKey[key] = node

                gcNodes.append(node)
                return gcNodes
            }

            let alreadyRemoved = prev!.isRemoved
            if !alreadyRemoved {
                self.numberOfRemovedElement += 1
            }

            if alreadyRemoved {
                gcNodes.append(prev!)
            }

            let node = RHTNode(key: key, value: prev!.value, updatedAt: executedAt, isRemoved: true)
            self.nodeMapByKey[key] = node
            gcNodes.append(node)

            return gcNodes
        }

        return gcNodes
    }

    /**
     * `has` returns whether the element exists of the given key or not.
     */
    func has(key: String) -> Bool {
        !(self.nodeMapByKey[key]?.isRemoved ?? true)
    }

    /**
     * `get` returns the value of the given key.
     */
    func get(key: String) throws -> String {
        guard let node = self.nodeMapByKey[key] else {
            let log = "can't find the given node with: \(key)"
            Logger.critical(log)
            throw YorkieError.unexpected(message: log)
        }

        return node.value
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> RHT {
        let rht = RHT()
        self.nodeMapByKey.forEach {
            rht.set(key: $1.key, value: $1.value, executedAt: $1.updatedAt)
        }
        return rht
    }

    /**
     * `toJSON` returns the JSON encoding of this hashtable.
     */
    func toJSON() -> String {
        var result = [String]()
        for (key, node) in self.nodeMapByKey.filter({ _, value in !value.isRemoved }) {
            result.append("\"\(key.escaped())\":\"\(node.value.escaped())\"")
        }

        return result.isEmpty ? "{}" : "{\(result.joined(separator: ","))}"
    }

    /**
     * `toSortedJSON` returns the JSON encoding of this hashtable.
     */
    func toSortedJSON() -> String {
        var result = [String]()
        let sortedKeys = self.nodeMapByKey.filter { _, value in !value.isRemoved }.keys.sorted()

        for key in sortedKeys {
            result.append("\"\(key.escaped())\":\"\(self.nodeMapByKey[key]!.value.escaped())\"")
        }

        return result.isEmpty ? "{}" : "{\(result.joined(separator: ","))}"
    }

    /**
     * `toXML` converts the given RHT to XML string.
     */
    public func toXML() -> String {
        if self.nodeMapByKey.isEmpty {
            return ""
        }

        let sortedKeys = self.nodeMapByKey.keys.sorted()

        let xmlAttributes = sortedKeys.compactMap { key in
            if let value = self.nodeMapByKey[key], value.isRemoved == false {
                return "\(key)=\"\(value.value)\""
            } else {
                return nil
            }
        }.joined(separator: " ")

        return " \(xmlAttributes)"
    }

    /**
     * `size` returns the size of RHT
     */
    public var size: Int {
        self.nodeMapByKey.count - self.numberOfRemovedElement
    }

    /**
     * `toObject` returns the object of this hashtable.
     */
    func toObject() -> [String: (value: String, updatedAt: TimeTicket)] {
        var result = [String: (String, TimeTicket)]()
        for (key, node) in self.nodeMapByKey.filter({ _, node in !node.isRemoved }) {
            result[key] = (node.value, node.updatedAt)
        }

        return result
    }

    /**
     * `purge` purges the given child node.
     */
    func purge(_ child: RHTNode) {
        let node = self.nodeMapByKey[child.key]
        if node == nil || node!.toIDString != child.toIDString {
            return
        }

        self.nodeMapByKey.removeValue(forKey: child.key)
        self.numberOfRemovedElement -= 1
    }
}

extension RHT: Sequence {
    typealias Element = RHTNode

    func makeIterator() -> RHTIterator {
        let nodes = self.nodeMapByKey.map { $1 }
        return RHTIterator(nodes)
    }
}

class RHTIterator: IteratorProtocol {
    private var iteratorNext: Int = 0
    private let nodes: [RHTNode]

    init(_ nodes: [RHTNode]) {
        self.nodes = nodes
    }

    func next() -> RHTNode? {
        defer {
            self.iteratorNext += 1
        }
        guard let node = self.nodes[safe: iteratorNext] else {
            return nil
        }

        return node
    }
}
