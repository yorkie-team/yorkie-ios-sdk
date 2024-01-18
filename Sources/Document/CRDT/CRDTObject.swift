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

/**
 * `CRDTObject` represents object datatype, but unlike regular JSON, it has time
 * tickets which is created by logical clock.
 */
class CRDTObject: CRDTContainer {
    var createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    private var memberNodes: ElementRHT

    init(createdAt: TimeTicket, memberNodes: ElementRHT = ElementRHT()) {
        self.createdAt = createdAt
        self.memberNodes = memberNodes
    }

    /**
     * `set` sets the given element of the given key.
     * - Returns: Removed value with the key
     */
    @discardableResult
    func set(key: String, value: CRDTElement) -> CRDTElement? {
        return self.memberNodes.set(key: key, value: value)
    }

    /**
     * `deleteByKey` deletes the element of the given key and execution time.
     */
    @discardableResult
    func deleteByKey(key: String, executedAt: TimeTicket) throws -> CRDTElement {
        return try self.memberNodes.deleteByKey(key: key, executedAt: executedAt)
    }

    /**
     * `get` returns the value of the given key.
     */
    func get(key: String) -> CRDTElement? {
        self.memberNodes.get(key: key)
    }

    /**
     * `has` returns whether the element exists of the given key or not.
     */
    func has(key: String) -> Bool {
        return self.memberNodes.has(key: key)
    }

    /**
     * `keys` returns array of keys in this object.
     */
    var keys: [String] {
        return self.map { $0.key }
    }

    /**
     * `rht` RHTNodes returns the RHTPQMap nodes.
     */
    var rht: ElementRHT {
        return self.memberNodes
    }
}

// MARK: - CRDTContainer

extension CRDTObject {
    /**
     * `toJSON` returns the JSON encoding of this object.
     */
    func toJSON() -> String {
        let value = self
            .map { "\"\($0.key)\":\($0.value.toJSON())" }
            .joined(separator: ",")
        return "{\(value)}"
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of this object.
     */
    func toSortedJSON() -> String {
        let value = self.keys.sorted()
            .compactMap {
                guard let node = self.memberNodes.get(key: $0) else {
                    return nil
                }

                return "\"\($0)\":\(node.toSortedJSON())"
            }
            .joined(separator: ",")

        return "{\(value)}"
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> CRDTElement {
        let clone = CRDTObject(createdAt: self.createdAt)
        for memberNode in self.memberNodes {
            clone.memberNodes.set(key: memberNode.key, value: memberNode.value.deepcopy())
        }

        clone.remove(self.removedAt)
        return clone
    }

    /**
     * `subPath` returns the sub path of the given element.
     */
    func subPath(createdAt: TimeTicket) throws -> String {
        return try self.memberNodes.subPath(createdAt: createdAt)
    }

    /**
     * `delete` physically deletes the given element.
     */
    func purge(element: CRDTElement) {
        self.memberNodes.purge(element: element)
    }

    /**
     * `delete` deletes the element of the given key.
     */
    func delete(createdAt: TimeTicket, executedAt: TimeTicket) throws -> CRDTElement {
        return try self.memberNodes.delete(createdAt: createdAt, executedAt: executedAt)
    }

    /**
     * `getDescendants` returns the descendants of this object by traversing.
     */
    func getDescendants(callback: (_ element: CRDTElement, _ parent: CRDTContainer?) -> Bool) {
        for node in self.memberNodes {
            let element = node.value
            if callback(element, self) {
                return
            }

            if let element = element as? CRDTContainer {
                element.getDescendants(callback: callback)
            }
        }
    }
}

extension CRDTObject: Sequence {
    typealias Element = (key: String, value: CRDTElement)

    func makeIterator() -> CRDTObjectIterator {
        return CRDTObjectIterator(self.memberNodes)
    }
}

class CRDTObjectIterator: IteratorProtocol {
    private var keys = Set<String>()
    private var nodes: [ElementRHTNode]
    private var iteratorNext: Int = 0

    init(_ rhtPqMap: ElementRHT) {
        self.nodes = rhtPqMap.filter { $0.isRemoved == false }
    }

    func next() -> (key: String, value: CRDTElement)? {
        defer {
            self.iteratorNext += 1
        }

        while self.iteratorNext < self.nodes.count {
            let node = self.nodes[self.iteratorNext]

            if self.keys.contains(node.key) {
                self.iteratorNext += 1
                continue
            } else {
                self.keys.insert(node.key)
                return (key: node.key, value: node.value)
            }
        }

        return nil
    }
}
