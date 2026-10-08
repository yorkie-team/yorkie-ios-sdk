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

    /**
     * `getDataSize` returns the data size of the element.
     *
     * A tombstone charges its key only. The value it still carries is dead
     * weight: nothing reads it -- ``RHT/has(key:)``, ``RHT/toJSON()`` and
     * ``RHT/toObject()`` all gate on `isRemoved` -- and charging it made the
     * running `docSize` disagree with a rebuild of the same document, which
     * replays the same removals. The value is left on the node rather than
     * cleared so that what this SDK stores and serializes for a tombstone is
     * byte-for-byte what it was, and what a peer sends us is kept verbatim: the
     * convergence fix belongs in the accounting, not in the wire format.
     */
    func getDataSize() -> DataSize {
        // Charge the LOGICAL value in UTF-8 bytes, which is what the Go SDK stores
        // and charges. A JSON-encoded string is stored with its quotes, and
        // `count` counted grapheme clusters where Go's `len()` counts UTF-8
        // bytes, so the same document had a different size allowance per SDK.
        .init(
            data: self.key.utf8.count * 2 + (self.isRemoved ? 0 : attrValueSize(self.value)),
            meta: timeTicketSize
        )
    }
}

/**
 * `attrValueSize` returns the `DataSize.data` bytes an attribute value of the
 * given stored form contributes, on the same terms as ``RHTNode/getDataSize()``.
 */
private func attrValueSize(_ stored: String) -> Int {
    logicalAttrValue(stored).utf8.count * 2
}

/**
 * `RHTRemoval` is what an ``RHT/remove(key:executedAt:)`` reports back.
 */
struct RHTRemoval {
    /// The tombstones this removal made collectable.
    var gcNodes: [RHTNode]

    /**
     * `valueDropped` is the size of the value the removal stopped charging for,
     * which no node's `getDataSize` accounts for any more. The caller subtracts
     * it from whichever side of the ledger was holding it: live for an
     * attribute that was live on a live node, gc for one on a node that is
     * itself a tombstone. Zero when the attribute was already a tombstone,
     * since a tombstone's value was not being charged in the first place.
     */
    var valueDropped: DataSize
}

/**
 * `RHTWrite` is what an ``RHT/set(key:value:executedAt:)`` reports back, so the
 * caller can keep docSize honest without inspecting the map afterwards. Reading
 * the map cannot tell a write that installed a node from one that lost LWW and
 * left the incumbent in place, and charging live for the latter makes the
 * running size depend on delivery order.
 */
struct RHTWrite {
    /// The node this write put in the map, `nil` when the write lost LWW and
    /// changed nothing. Its size is what enters docSize.live.
    var installed: RHTNode?
    /// A tombstone this write replaced. It was registered as garbage when it was
    /// removed, so the caller re-registers the pair to cancel that registration.
    var revived: RHTNode?
    /// A LIVE node this write replaced. RHT overrides immutably, so the old node
    /// is dropped with no tombstone, but its bytes were counted in docSize.live
    /// and have to leave it.
    var superseded: RHTNode?
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
    func set(key: String, value: String, executedAt: TimeTicket) -> RHTWrite {
        let prev = self.nodeMapByKey[key]

        if let prev, !executedAt.after(prev.updatedAt) {
            return RHTWrite()
        }

        if let prev, prev.isRemoved {
            self.numberOfRemovedElement -= 1
        }

        let installed = RHTNode(key: key, value: value, updatedAt: executedAt, isRemoved: false)
        self.nodeMapByKey[key] = installed

        guard let prev else {
            return RHTWrite(installed: installed)
        }
        if prev.isRemoved {
            return RHTWrite(installed: installed, revived: prev)
        }
        return RHTWrite(installed: installed, superseded: prev)
    }

    /**
     * SetInternal sets the value of the given key internally.
     */
    func setInternal(key: String, value: String, executedAt: TimeTicket, removed: Bool) {
        let node = RHTNode(key: key, value: value, updatedAt: executedAt, isRemoved: removed)
        self.nodeMapByKey[key] = node

        if removed {
            self.numberOfRemovedElement += 1
        }
    }

    /**
     * `remove` removes the Element of the given key.
     *
     * The tombstone still STORES the value -- what goes on the wire is
     * unchanged -- but stops being CHARGED for it, because
     * ``RHTNode/getDataSize()`` skips a removed node's value.
     * ``RHTRemoval/valueDropped`` is what the caller has to take back out of
     * whichever side of the ledger was holding those bytes.
     */
    @discardableResult
    func remove(key: String, executedAt: TimeTicket) -> RHTRemoval {
        let prev = self.nodeMapByKey[key]
        var gcNodes = [RHTNode]()
        var valueDropped = DataSize(data: 0, meta: 0)

        if prev == nil || executedAt.after(prev!.updatedAt) {
            if prev == nil {
                self.numberOfRemovedElement += 1
                let node = RHTNode(key: key, value: "", updatedAt: executedAt, isRemoved: true)
                self.nodeMapByKey[key] = node

                gcNodes.append(node)
                return RHTRemoval(gcNodes: gcNodes, valueDropped: valueDropped)
            }

            let alreadyRemoved = prev!.isRemoved
            if !alreadyRemoved {
                self.numberOfRemovedElement += 1
                valueDropped.data = attrValueSize(prev!.value)
            }

            if alreadyRemoved {
                gcNodes.append(prev!)
            }

            let node = RHTNode(key: key, value: prev!.value, updatedAt: executedAt, isRemoved: true)
            self.nodeMapByKey[key] = node
            gcNodes.append(node)

            return RHTRemoval(gcNodes: gcNodes, valueDropped: valueDropped)
        }

        return RHTRemoval(gcNodes: gcNodes, valueDropped: valueDropped)
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
        guard self.has(key: key), let node = self.nodeMapByKey[key] else {
            let log = "can't find the given node with: \(key)"
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        return node.value
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> RHT {
        let rht = RHT()
        self.nodeMapByKey.forEach {
            rht.setInternal(key: $1.key, value: $1.value, executedAt: $1.updatedAt, removed: $1.isRemoved)
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
    func toXML() -> String {
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
    var size: Int {
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
     * `toDictionaryStringObject` returns a simplified dictionary representation of this hashtable.
     * - Returns: `[String: String]` containing only active (non-removed) key-value pairs
     */
    func toDictionaryStringObject() -> [String: String] {
        var result = [String: String]()
        for (key, node) in self.nodeMapByKey where node.isRemoved == false {
            result[key] = node.value
        }

        return result
    }

    var toDictionary: [String: Any] {
        self.nodeMapByKey.compactMapValues { node -> Any? in
            guard !node.isRemoved else { return nil }
            // `toJSONObject` falls back to the raw string: a peer that stores
            // values raw writes ones that do not parse, and dropping them here
            // would hide the attribute.
            return node.value.toJSONObject
        }
    }

    /**
     * `purge` purges the given child node.
     */
    func purge(_ child: RHTNode) {
        let node = self.nodeMapByKey[child.key]
        if node == nil || node!.toIDString != child.toIDString {
            // TODO(hackerwins): Should we return an error when the child is not found?
            return
        }

        self.nodeMapByKey.removeValue(forKey: child.key)
        self.numberOfRemovedElement -= 1
    }

    /**
     * `getNodeMapByKey` returns the hashtable of RHT.
     */
    func getNodeByKey(_ key: String) -> RHTNode? {
        return self.nodeMapByKey[key]
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
