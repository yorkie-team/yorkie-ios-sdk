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
     * `set` sets the value of the given key. An existing occupant is removed
     * only when the incoming value wins the LWW comparison; when it loses, the
     * occupant stays and the incoming value is marked removed instead.
     *
     * Both the win/lose decision and the eviction of the previous occupant are
     * anchored on the occupant's ``CRDTElement/getPositionedAt()`` (its
     * `movedAt`, falling back to its `createdAt`). Anchoring them on different
     * tickets lets them disagree: ``CRDTElement/remove(_:)`` gates on the raw
     * `createdAt`, so for an occupant whose `createdAt < executedAt <
     * positionedAt` -- which is what an undo/redo restore produces, since it
     * re-places the original element under a fresh ticket -- the eviction
     * fires and tombstones the occupant, while the winner check decides the
     * incoming value must NOT replace it. The occupant is then tombstoned but
     * still linked as the key's value, the incoming value is dropped without
     * being registered as removed, and `get` reports the key as absent
     * although no operation ever removed it.
     *
     * The inner `node.remove(executedAt)` gate is therefore redundant once the
     * eviction sits inside the winner branch -- that branch already guarantees
     * `executedAt > positionedAt >= createdAt`, which is what
     * ``CRDTElement/remove(_:)`` checks. It is kept so this reads as the
     * mirror of Go that it is.
     *
     * That made rebuilding an object from a snapshot depend on the order its
     * members happened to arrive in. Mirrors `ElementRHT.SetWithExecutedAt` in
     * `yorkie/pkg/document/crdt/element_rht.go` (yorkie-js-sdk#1343).
     */
    @discardableResult
    func set(key: String, value: CRDTElement, executedAt: TimeTicket) -> CRDTElement? {
        var removed: CRDTElement?

        let node = self.nodeMapByKey[key]

        let newNode = ElementRHTNode(key: key, value: value)
        self.nodeMapByCreatedAt[value.createdAt.toIDString] = newNode

        if node == nil || executedAt.after(node!.value.getPositionedAt()) {
            if let node, node.isRemoved == false, node.remove(removedAt: executedAt) {
                removed = node.value
            }
            self.nodeMapByKey[key] = newNode
            value.setMovedAt(executedAt)
        } else if node!.isRemoved == false {
            // The new node loses the LWW conflict — mark it as removed so it does not appear as a
            // duplicate in `ownKeys` iteration over `nodeMapByCreatedAt`.
            //
            // NOTE(yorkie-js-sdk#1376): when the occupant is ALREADY a tombstone and the
            // incoming value loses, neither branch runs -- the value is left live in
            // `nodeMapByCreatedAt`, never installed under the key and never collected, so
            // iteration and `get(key:)` disagree and replicas diverge permanently. Kept
            // identical to `element_rht.ts` on purpose: fixing it here alone would diverge
            // from the other SDKs on a path they all have to agree on.
            value.remove(node!.value.getPositionedAt())
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

        // The slot names a creation time, not an element. Undo of a remove
        // re-inserts a copy under the original createdAt and `set` re-points this
        // map at it, so unlinking whatever the key answers with would delete a live
        // member on a tombstone's behalf. The tombstone is already off both maps by
        // then, so there is nothing left to unlink.
        //
        // A genuinely missing key still throws above: that is a mis-registration
        // worth reporting, and this guard is only about a slot that has been taken
        // over.
        guard node.value === element else {
            return
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

    /**
     * `deepcopy` returns a deep copy of this ElementRHT.
     *
     * Copies the node maps directly rather than replaying
     * ``set(key:value:executedAt:)``: `set` stamps `movedAt` on the winner, so
     * replaying it would give every copied member a `movedAt` the original
     * never had.
     */
    func deepcopy() -> ElementRHT {
        let clone = ElementRHT()

        // Deep copy all nodes from nodeMapByCreatedAt to preserve tombstones
        for (key, node) in self.nodeMapByCreatedAt {
            let copiedValue = node.value.deepcopy()
            clone.nodeMapByCreatedAt[key] = ElementRHTNode(key: node.key, value: copiedValue)
        }

        // Copy nodeMapByKey references. Looked up directly rather than searched: both maps
        // are keyed by `createdAt.toIDString`, and the linear scan this replaces made the
        // copy O(n^2) in the member count -- on a path every clone rebuild, `SetOperation`
        // and undo capture goes through.
        for (key, node) in self.nodeMapByKey {
            clone.nodeMapByKey[key] = clone.nodeMapByCreatedAt[node.value.createdAt.toIDString]
        }

        return clone
    }
}

extension ElementRHT: Sequence {
    typealias Element = ElementRHTNode

    func makeIterator() -> ElementRHTIterator {
        return ElementRHTIterator(self.nodeMapByCreatedAt)
    }
}

class ElementRHTIterator: IteratorProtocol {
    private var target: [ElementRHTNode]
    private var currentNodes: [ElementRHTNode] = []

    init(_ target: [String: ElementRHTNode]) {
        // Use sorted array to ensure consistent iteration order
        self.target = Array(target.values).sorted { $0.value.createdAt < $1.value.createdAt }
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
