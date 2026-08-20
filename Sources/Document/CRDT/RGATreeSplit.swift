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

import Foundation

class ContentChange<T: RGATreeSplitValue> {
    let actor: ActorID
    let from: Int
    let to: Int
    var content: T?

    init(actor: ActorID, from: Int, to: Int, content: T? = nil) {
        self.actor = actor
        self.from = from
        self.to = to
        self.content = content
    }
}

protocol RGATreeSplitValue {
    init()
    var count: Int { get }
    func substring(from: Int, to: Int) -> Self
    func getDataSize() -> DataSize
}

/**
 * `RGATreeSplitPosStruct` is a structure represents the meta data of the node pos.
 * It is used to serialize and deserialize the node pos.
 */
public struct RGATreeSplitPosStruct: Codable {
    let id: RGATreeSplitNodeIDStruct
    let relativeOffset: Int32
}

/**
 * `RGATreeSplitNodeIDStruct` is a structure represents the meta data of the node id.
 * It is used to serialize and deserialize the node id.
 */
public struct RGATreeSplitNodeIDStruct: Codable {
    let createdAt: TimeTicketStruct
    let offset: Int32
}

/**
 * `RGATreeSplitNodeID` is an ID of RGATreeSplitNode.
 */
class RGATreeSplitNodeID: Equatable, Comparable, CustomDebugStringConvertible {
    static let initial = RGATreeSplitNodeID(TimeTicket.initial, 0)

    /**
     * `createdAt` the creation time of this ID.
     */
    let createdAt: TimeTicket
    /**
     * `offset` the offset of this ID.
     */
    let offset: Int32

    init(_ createdAt: TimeTicket, _ offset: Int32) {
        self.createdAt = createdAt
        self.offset = offset
    }

    /**
     * `==` returns whether given ID equals to this ID or not.
     */
    static func == (lhs: RGATreeSplitNodeID, rhs: RGATreeSplitNodeID) -> Bool {
        lhs.createdAt == rhs.createdAt && lhs.offset == rhs.offset
    }

    static func < (lhs: RGATreeSplitNodeID, rhs: RGATreeSplitNodeID) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.offset < rhs.offset
        } else {
            return lhs.createdAt < rhs.createdAt
        }
    }

    /**
     * `hasSameCreatedAt` returns whether given ID has same creation time with this ID.
     */
    func hasSameCreatedAt(_ other: RGATreeSplitNodeID) -> Bool {
        self.createdAt == other.createdAt
    }

    /**
     * `split` creates a new ID with an offset from this ID.
     */
    func split(_ offset: Int32) -> RGATreeSplitNodeID {
        RGATreeSplitNodeID(self.createdAt, self.offset + offset)
    }

    /**
     * `toTestString` returns a String containing
     * the meta data of the node id for debugging purpose.
     */
    var toTestString: String {
        "\(self.createdAt.toTestString):\(self.offset)"
    }

    /**
     * `toIDString` returns a string that can be used as an ID for this node id.
     */
    var toIDString: String {
        "\(self.createdAt.toIDString):\(self.offset)"
    }

    var debugDescription: String {
        self.toTestString
    }
}

extension RGATreeSplitNodeID {
    /**
     * `fromStruct` creates a new instance of RGATreeSplitPos from the given struct.
     */
    static func fromStruct(_ value: RGATreeSplitNodeIDStruct) throws -> RGATreeSplitNodeID {
        try RGATreeSplitNodeID(TimeTicket.fromStruct(value.createdAt), value.offset)
    }

    /**
     * `toStruct` returns the structure of this position.
     */
    var toStruct: RGATreeSplitNodeIDStruct {
        RGATreeSplitNodeIDStruct(createdAt: self.createdAt.toStruct, offset: self.offset)
    }
}

/**
 * `RGATreeSplitNodePos` is the position of the text inside the node.
 */
class RGATreeSplitPos: Equatable {
    /**
     * `id` returns the ID of this RGATreeSplitNodePos.
     */
    let id: RGATreeSplitNodeID

    /**
     * `relativeOffset` returns the relative offset of this RGATreeSplitNodePos.
     */
    let relativeOffset: Int32

    init(_ id: RGATreeSplitNodeID, _ relativeOffset: Int32) {
        self.id = id
        self.relativeOffset = relativeOffset
    }

    /**
     * `absoluteID` returns the absolute id of this RGATreeSplitNodePos.
     */
    var absoluteID: RGATreeSplitNodeID {
        RGATreeSplitNodeID(self.id.createdAt, self.id.offset + self.relativeOffset)
    }

    /**
     *`toTestString` returns a String containing
     * the meta data of the position for debugging purpose.
     */
    var toTestString: String {
        "\(self.id.toTestString):\(self.relativeOffset)"
    }

    /**
     * `==` returns whether given pos equal to this pos or not.
     */
    static func == (lhs: RGATreeSplitPos, rhs: RGATreeSplitPos) -> Bool {
        lhs.id == rhs.id && lhs.relativeOffset == rhs.relativeOffset
    }
}

extension RGATreeSplitPos {
    /**
     * `fromStruct` creates a new instance of RGATreeSplitPos from the given struct.
     */
    static func fromStruct(_ value: RGATreeSplitPosStruct) throws -> RGATreeSplitPos {
        try RGATreeSplitPos(RGATreeSplitNodeID.fromStruct(value.id), value.relativeOffset)
    }

    /**
     * `toStruct` returns the structure of this position.
     */
    var toStruct: RGATreeSplitPosStruct {
        RGATreeSplitPosStruct(id: self.id.toStruct, relativeOffset: self.relativeOffset)
    }
}

typealias RGATreeSplitPosRange = (RGATreeSplitPos, RGATreeSplitPos)

/**
 * `RestoreSpan` identifies a run of characters from a single original
 * insertion: the absolute-offset interval [start, end) of the insertion
 * created at `createdAt`. `value` is a deep copy of the removed content,
 * carried so that purged nodes can be recreated (GC-safe).
 */
struct RestoreSpan<T: RGATreeSplitValue> {
    let createdAt: TimeTicket
    let start: Int32
    let end: Int32
    let value: T
}

/**
 * `RGATreeSplitNode` is a node of RGATreeSplit.
 */
class RGATreeSplitNode<T: RGATreeSplitValue>: SplayNode<T> {
    /**
     * `id` returns the ID of this RGATreeSplitNode.
     */
    let id: RGATreeSplitNodeID

    /**
     * `removedAt` returns the remove time of this node.
     */
    private(set) var removedAt: TimeTicket?

    /**
     * `prev` returns a previous node of this node.
     */
    private(set) weak var prev: RGATreeSplitNode<T>?

    /**
     * `next`  returns a next node of this node.
     */
    private(set) weak var next: RGATreeSplitNode<T>? {
        didSet {}
    }

    /**
     * `insPrev` returns a previous node of this node insertion.
     */
    private(set) weak var insPrev: RGATreeSplitNode<T>?

    /**
     * `insNext` returns a next node of this node insertion.
     */
    private(set) weak var insNext: RGATreeSplitNode<T>?

    init(_ id: RGATreeSplitNodeID, _ value: T? = nil, _ removedAt: TimeTicket? = nil) {
        self.id = id
        self.removedAt = removedAt

        super.init(value ?? T())
    }

    /**
     * `createdAt` returns creation time of the Id of RGATreeSplitNode.
     */
    var createdAt: TimeTicket {
        self.id.createdAt
    }

    /**
     * `length` returns the length of this node.
     */
    override var length: Int {
        guard self.removedAt == nil else {
            return 0
        }

        return self.contentLength
    }

    /**
     * `contentLength` returns the length of this value.
     */
    var contentLength: Int {
        self.value.count
    }

    /**
     * `insPrevID` returns a ID of previous node insertion.
     */
    var insPrevID: RGATreeSplitNodeID? {
        self.insPrev?.id
    }

    /**
     * `setPrev` sets a previous node of this node.
     */
    func setPrev(_ node: RGATreeSplitNode<T>?) {
        self.prev = node
        node?.next = self
    }

    /**
     * `setNext`  sets a next node of this node.
     */
    func setNext(_ node: RGATreeSplitNode<T>?) {
        self.next = node
        node?.prev = self
    }

    /**
     * `setInsPrev` sets a previous node of this node insertion.
     */
    func setInsPrev(_ node: RGATreeSplitNode<T>?) {
        self.insPrev = node
        node?.insNext = self
    }

    /**
     * `setInsNext` sets a next node of this node insertion.
     */
    func setInsNext(_ node: RGATreeSplitNode<T>?) {
        self.insNext = node
        node?.insPrev = self
    }

    /**
     * `hasNext` checks if next node exists.
     */
    var hasNext: Bool {
        self.next != nil
    }

    /**
     * `hasInsPrev` checks if previous insertion node exists.
     */
    var hasInsPrev: Bool {
        self.insPrev != nil
    }

    /**
     * `hasInsPrev` checks if previous insertion node exists.
     */
    var hasInsNext: Bool {
        self.insNext != nil
    }

    /**
     * `isRemoved` checks if removed time exists.
     */
    var isRemoved: Bool {
        self.removedAt != nil
    }

    /**
     * `split` creates a new split node of the given offset.
     */
    func split(_ offset: Int32) -> RGATreeSplitNode<T> {
        RGATreeSplitNode(
            self.id.split(offset),
            self.splitValue(offset),
            self.removedAt
        )
    }

    /**
     * `canRemove` checks if node is able to delete.
     * Returns true if the node can be removed based on the editedAt time.
     * If creationKnown is false, the node cannot be removed.
     * If the node has no removedAt (alive), it can be removed.
     * If tombstoneKnown is false and editedAt is after removedAt, allow overwrite.
     */
    func canRemove(
        _ editedAt: TimeTicket,
        _ creationKnown: Bool,
        _ tombstoneKnown: Bool
    ) -> Bool {
        if !creationKnown {
            return false
        }
        if self.removedAt == nil {
            return true
        }
        // Allow tombstone overwrite when tombstoneKnown is false and editedAt is newer
        if !tombstoneKnown && editedAt.after(self.removedAt!) {
            return true
        }
        return false
    }

    /**
     * `canStyle` checks if node is able to set style.
     */
    func canStyle(
        _ editedAt: TimeTicket,
        clientLamportAtChange: Int64
    ) -> Bool {
        let nodeExisted = self.createdAt.lamport <= clientLamportAtChange
        return nodeExisted && (self.removedAt == nil || editedAt.after(self.removedAt!))
    }

    /**
     * `setRemovedAt` sets the remove time of this node.
     */
    func setRemoveAt(_ removeAt: TimeTicket?) {
        self.removedAt = removeAt
    }

    /**
     * `remove` removes node with the given removedAt timestamp.
     * Updates the timestamp only if the node is not yet removed or if the new timestamp is later (LWW).
     */
    func remove(
        _ removedAt: TimeTicket
    ) {
        if self.removedAt == nil || removedAt.after(self.removedAt!) {
            self.removedAt = removedAt
        }
    }

    /**
     * `createRange` creates ranges of RGATreeSplitNodePos.
     */
    var createPosRange: RGATreeSplitPosRange {
        (RGATreeSplitPos(self.id, 0), RGATreeSplitPos(self.id, Int32(self.length)))
    }

    /**
     * `deepcopy` returns a new instance of this RGATreeSplitNode without structural info.
     */
    func deepcopy() -> RGATreeSplitNode<T> {
        RGATreeSplitNode(self.id, self.value, self.removedAt)
    }

    /**
     * `toTestString` returns a String containing
     * the meta data of the node for debugging purpose.
     */
    var toTestString: String {
        "\(self.id.toTestString) \(String(describing: self.value))"
    }

    private func splitValue(_ offset: Int32) -> T {
        let value = self.value
        self.value = value.substring(from: 0, to: Int(offset))
        return value.substring(from: Int(offset), to: value.count)
    }
}

extension RGATreeSplitNode: GCChild {
    /**
     * `getDataSize` returns the data of this node.
     */
    func getDataSize() -> DataSize {
        let dataSize = self.value.getDataSize()
        var meta = dataSize.meta + timeTicketSize

        // Add meta size for removedAt if present
        if self.removedAt != nil {
            meta += timeTicketSize
        }

        return .init(
            data: dataSize.data,
            meta: meta
        )
    }

    var toIDString: String {
        self.id.toIDString
    }
}

/**
 * `RGATreeSplit` is a block-based list with improved index-based lookup in RGA.
 * The difference from RGATreeList is that it has data on a block basis to
 * reduce the size of CRDT metadata. When an edit occurs on a block,
 * the block is split.
 */
class RGATreeSplit<T: RGATreeSplitValue> {
    /**
     * `head` returns head of RGATreeSplitNode.
     */
    private(set) var head: RGATreeSplitNode<T>
    private var treeByIndex: SplayTree<T>
    private var treeByID: LLRBTree<RGATreeSplitNodeID, RGATreeSplitNode<T>>

    /**
     * `pendingGCPairs` buffers GC pairs for nodes that were created
     * already-tombstoned by splitting a removed node. Such pieces inherit
     * `removedAt` without ever passing through `remove()`, so they would
     * otherwise never be registered for GC. Callers that split nodes
     * (`edit`, `CRDTText.setStyle`, `CRDTText.removeStyle`) drain this
     * buffer into their returned GC pairs.
     */
    private var pendingGCPairs: [GCPair] = []

    init() {
        self.head = RGATreeSplitNode(RGATreeSplitNodeID.initial)
        self.treeByIndex = SplayTree()
        self.treeByID = LLRBTree<RGATreeSplitNodeID, RGATreeSplitNode<T>>()
        self.treeByIndex.insert(self.head)
        self.treeByID.put(self.head.id, self.head)
    }

    /**
     * `edit` does following steps
     * 1. split nodes with from and to
     * 2. delete between from and to
     * 3. insert a new node
     * 4. add removed node
     * @param range - range of RGATreeSplitNode
     * @param editedAt - edited time
     * @param value - value
     * @returns `(RGATreeSplitNodePos, [String: TimeTicket], [GCPair], [Change])`
     */
    @discardableResult
    func edit(
        _ range: RGATreeSplitPosRange,
        _ editedAt: TimeTicket,
        _ value: T?,
        _ versionVector: VersionVector? = nil
    ) throws -> (RGATreeSplitPos, [GCPair], DataSize, [ContentChange<T>], [T], [RestoreSpan<T>]) {
        var diff = DataSize(data: 0, meta: 0)

        // 01. split nodes with from and to
        let (toLeft, diffTo, toRight) = try self.findNodeWithSplit(range.1, editedAt)
        let (fromLeft, diffFrom, fromRight) = try self.findNodeWithSplit(range.0, editedAt)
        diff.addDataSizes(others: diffFrom, diffTo)

        // 02. delete between from and to
        let nodesToDelete = self.findBetween(fromRight, toRight)
        var (changes, removedNodes, alreadyRemovedIDs) = try self.deleteNodes(
            nodesToDelete,
            editedAt,
            versionVector
        )

        let caretID = toRight?.id ?? toLeft.id
        var caretPos = RGATreeSplitPos(caretID, 0)

        // 03. insert a new node
        if let value {
            let idx = try self.posToIndex(fromLeft.createPosRange.1, true)

            let inserted = self.insertAfter(
                fromLeft,
                RGATreeSplitNode(RGATreeSplitNodeID(editedAt, 0), value)
            )

            diff.addDataSizes(others: inserted.getDataSize())

            if !changes.isEmpty, changes[changes.count - 1].from == idx {
                changes[changes.count - 1].content = value
            } else {
                changes.append(ContentChange<T>(actor: editedAt.actorID, from: idx, to: idx, content: value))
            }

            caretPos = RGATreeSplitPos(inserted.id, Int32(inserted.contentLength))
        }

        // 04. add removed node
        var pairs = [GCPair]()
        var removedValues = [T]()
        var removedSpans = [RestoreSpan<T>]()
        for removedNode in removedNodes {
            // NOTE: Nodes that were already tombstoned keep their existing GC
            // pair (the pair reads `removedAt` from the node at collection
            // time); re-registering would toggle the pair off and leak the node.
            if !alreadyRemovedIDs.contains(removedNode.toIDString) {
                pairs.append(GCPair(parent: self, child: removedNode))
            }
            removedValues.append(removedNode.value)
            // Capture split-invariant character identities. `substring` over the
            // whole value deep-copies it, so later splits of the tombstone
            // cannot mutate the captured content.
            removedSpans.append(
                RestoreSpan(
                    createdAt: removedNode.createdAt,
                    start: removedNode.id.offset,
                    end: removedNode.id.offset + Int32(removedNode.contentLength),
                    value: removedNode.value.substring(from: 0, to: removedNode.value.count)
                )
            )
        }

        pairs.append(contentsOf: self.drainPendingGCPairs())

        return (caretPos, pairs, diff, changes, removedValues, removedSpans)
    }

    /**
     * `normalizePos` converts a local position `(id, rel)` into a single absolute offset
     * measured from the head `(0:0)` of the physical chain.
     */
    func normalizePos(_ pos: RGATreeSplitPos) throws -> RGATreeSplitPos {
        guard let node = self.findFloorNode(pos.id) else {
            throw YorkieError(code: .errInvalidArgument, message: "the node of the given id should be found: \(pos.id.toTestString)")
        }

        var total = Int(pos.relativeOffset)
        var curr = node
        var prev = node.prev
        while let prevNode = prev {
            total += prevNode.length
            curr = prevNode
            prev = prevNode.prev
        }

        return RGATreeSplitPos(curr.id, Int32(total))
    }

    /**
     * `refinePos` remaps the given pos to the current split chain.
     *
     * It traverses the physical `next` chain counting only live characters (removed nodes are
     * treated as length 0). When the offset exceeds the current node, it advances, subtracting
     * lengths, until the offset fits; if it runs out of nodes it snaps to the end of the last node.
     */
    func refinePos(_ pos: RGATreeSplitPos) throws -> RGATreeSplitPos {
        guard var node = self.findFloorNode(pos.id) else {
            throw YorkieError(code: .errInvalidArgument, message: "the node of the given id should be found: \(pos.id.toTestString)")
        }

        var offsetInPart = Int(pos.relativeOffset)
        var partLen = node.contentLength
        while offsetInPart > partLen {
            offsetInPart -= partLen
            guard let next = node.next else {
                return RGATreeSplitPos(node.id, Int32(partLen))
            }
            node = next
            partLen = node.length
        }

        return RGATreeSplitPos(node.id, Int32(offsetInPart))
    }

    /**
     * `findNodePos` finds RGATreeSplitNodePos of given offset.
     */
    func indexToPos(_ idx: Int) throws -> RGATreeSplitPos {
        let (node, offset) = try self.treeByIndex.findForText(idx)
        guard let splitNode = node as? RGATreeSplitNode<T> else {
            throw YorkieError(code: .errInvalidArgument, message: "no element for index \(idx)")
        }

        return RGATreeSplitPos(splitNode.id, Int32(offset))
    }

    /**
     * `findIndexesFromRange` finds indexes based on range.
     */
    func findIndexesFromRange(_ range: RGATreeSplitPosRange) throws -> (Int, Int) {
        let (fromPos, toPos) = range
        return try (self.posToIndex(fromPos, false), self.posToIndex(toPos, true))
    }

    /**
     * `posToIndex` finds index based on node position.
     */
    func posToIndex(_ pos: RGATreeSplitPos, _ preferToLeft: Bool) throws -> Int {
        let absoluteID = pos.absoluteID
        guard let node = preferToLeft ? try? self.findFloorNodePreferToLeft(absoluteID) : self.findFloorNode(absoluteID) else {
            let message = "the node of the given id should be found: \(absoluteID.toTestString)"
            throw YorkieError(code: .errInvalidArgument, message: message)
        }
        let index = self.treeByIndex.indexOf(node)
        let offset = node.isRemoved ? 0 : absoluteID.offset - node.id.offset

        return index + Int(offset)
    }

    /**
     * `findNode` finds node of given id.
     */
    func findNode(_ id: RGATreeSplitNodeID) -> RGATreeSplitNode<T>? {
        self.findFloorNode(id)
    }

    /**
     * `length` returns size of RGATreeList.
     */
    var length: Int {
        self.treeByIndex.length
    }

    /**
     * `getTreeByIndex` returns the tree by index for debugging purpose.
     */
    func getTreeByIndex() -> SplayTree<T> {
        return self.treeByIndex
    }

    /**
     * `getTreeByID` returns the tree by ID for debugging purpose.
     */
    func getTreeByID() -> LLRBTree<RGATreeSplitNodeID, RGATreeSplitNode<T>> {
        return self.treeByID
    }

    /**
     * `toJSON` returns the JSON encoding of this Array.
     */
    var toJSON: String {
        var result = [String]()

        for item in self where !item.isRemoved {
            result.append("\(item.value)")
        }

        return result.joined(separator: "")
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> RGATreeSplit<T> {
        let clone = RGATreeSplit<T>()

        var node: RGATreeSplitNode<T>? = self.head.next
        var prev: RGATreeSplitNode<T>? = clone.head
        var current: RGATreeSplitNode<T>?

        while node != nil {
            current = clone.insertAfter(prev!, node!.deepcopy())
            if let insPrevID = node!.insPrevID {
                current?.setInsPrev(clone.findNode(insPrevID))
            }

            prev = current
            node = node!.next
        }

        return clone
    }

    /**
     * `toTestString` returns a String containing the meta data of the node
     * for debugging purpose.
     */
    var toTestString: String {
        var result = [String]()

        for item in self {
            if !item.isRemoved {
                result.append("[\(item.toTestString)]")
            } else {
                result.append("{\(item.toTestString)}")
            }
        }

        return result.joined(separator: "")
    }

    /**
     * `insertAfter` inserts the given node after the given previous node.
     */
    @discardableResult
    func insertAfter(_ prevNode: RGATreeSplitNode<T>, _ newNode: RGATreeSplitNode<T>) -> RGATreeSplitNode<T> {
        let next = prevNode.next
        newNode.setPrev(prevNode)

        if next != nil {
            next!.setPrev(newNode)
        }

        self.treeByID.put(newNode.id, newNode)
        self.treeByIndex.insert(previousNode: prevNode, newNode: newNode)

        return newNode
    }

    /**
     * `findNodeWithSplit` splits and return nodes of the given position.
     */
    func findNodeWithSplit(
        _ pos: RGATreeSplitPos,
        _ editedAt: TimeTicket
    ) throws -> (RGATreeSplitNode<T>, DataSize, RGATreeSplitNode<T>?) {
        let absoluteID = pos.absoluteID
        var node = try self.findFloorNodePreferToLeft(absoluteID)
        let relativeOffset = absoluteID.offset - node.id.offset

        let (_, diff) = try self.splitNode(node, relativeOffset)

        while let next = node.next, next.createdAt.after(editedAt) {
            node = next
        }

        return (node, diff, node.next)
    }

    private func findFloorNodePreferToLeft(_ id: RGATreeSplitNodeID) throws -> RGATreeSplitNode<T> {
        guard let node = self.findFloorNode(id) else {
            let message = "the node of the given id should be found: \(id.toTestString)"
            throw YorkieError(code: .errInvalidArgument, message: message)
        }

        if id.offset > 0, node.id.offset == id.offset {
            // NOTE: InsPrev may not be present due to GC.
            if let insPrev = node.insPrev {
                return insPrev
            }
        }

        return node
    }

    private func findFloorNode(_ id: RGATreeSplitNodeID) -> RGATreeSplitNode<T>? {
        guard let entry = self.treeByID.floorEntry(id) else {
            return nil
        }

        if !(entry.key == id), !entry.key.hasSameCreatedAt(id) {
            return nil
        }

        return entry.value
    }

    /**
     * `findBetween` returns nodes between fromNode and toNode.
     */
    func findBetween(_ fromNode: RGATreeSplitNode<T>?, _ toNode: RGATreeSplitNode<T>?) -> [RGATreeSplitNode<T>] {
        var nodes = [RGATreeSplitNode<T>]()

        var current: RGATreeSplitNode<T>? = fromNode
        while current != nil, current! !== toNode {
            nodes.append(current!)
            current = current!.next
        }

        return nodes
    }

    @discardableResult
    private func splitNode(_ node: RGATreeSplitNode<T>, _ offset: Int32) throws -> (RGATreeSplitNode<T>?, DataSize) {
        var diff = DataSize(data: 0, meta: 0)
        guard offset <= node.contentLength else {
            let message = "offset should be less than or equal to length"
            throw YorkieError(code: .errInvalidArgument, message: message)
        }

        if offset == 0 {
            return (node, diff)
        } else if offset == node.contentLength {
            return (node.next, diff)
        }

        let prvSize = node.getDataSize()

        let splitNode = node.split(offset)
        self.treeByIndex.updateWeight(splitNode)
        self.insertAfter(node, splitNode)

        if node.hasInsNext {
            node.insNext!.setInsPrev(splitNode)
        }
        splitNode.setInsPrev(node)

        diff.addDataSizes(others: node.getDataSize(), splitNode.getDataSize())
        diff.subDataSize(others: prvSize)

        // NOTE: A piece split off an already-tombstoned node inherits
        // `removedAt` without going through `remove()`, so no GC pair is
        // created for it in the normal deletion path. Buffer one here so it
        // can be purged; otherwise it stays in the list forever. The piece
        // was never live, so the net-new size created by the split goes
        // straight to docSize.gc when the pair is registered; report a zero
        // diff to the caller (which accounts diffs to docSize.live).
        if splitNode.isRemoved {
            self.pendingGCPairs.append(GCPair(parent: self, child: splitNode, gcOnlySize: diff))
            return (splitNode, DataSize(data: 0, meta: 0))
        }

        return (splitNode, diff)
    }

    /**
     * `restore` re-establishes the characters described by `spans` under
     * their ORIGINAL identities. For each span, per overlapping region:
     *   - live piece exists       → skip (idempotent; another undo restored it)
     *   - tombstoned piece exists → clear removedAt (un-tombstone)
     *   - no piece exists (GC'd)  → recreate a node with the original ID
     *
     * Returns `(untombstonedNodes, recreatedNodes, changes, liveDiff,
     * pendingGCPairs)`. `changes` describes the revived content as insertions
     * (ascending index) so editor bindings and remote sync can be driven the
     * same way as a normal edit.
     *
     * The caller must, in order: (1) register every pair in `pendingGCPairs` —
     * these are fragments `splitNode` buffered while isolating a target range
     * out of a larger tombstoned piece (see `drainPendingGCPairs`);
     * (2) unregister GC pairs for `untombstonedNodes`. Registering first is
     * required for `untombstonedNodes` entries whose node was itself one of
     * those split-born fragments (a target isolated from the interior of a
     * tombstone) — such a node was never registered under its own id, so
     * step (1) creates the entry that step (2) then correctly walks from gc
     * back to live; entries that remain tombstoned (siblings of the restored
     * target) simply stay registered. Finally, `root.acc(liveDiff)` accounts
     * the size of any nodes recreated from scratch (the GC'd-away case), which
     * `splitNode`'s buffering does not cover.
     *
     * - Parameters:
     *   - spans: The identity-addressed runs to revive.
     *   - executedAt: The timestamp of the operation performing the restore.
     *   - fallbackAnchor: Position used to anchor a recreated fragment when
     *     every related piece has been purged.
     * - Returns: The untombstoned nodes, recreated nodes, resulting changes,
     *   the live-bucket size delta, and the GC pairs buffered by splits.
     */
    func restore(
        _ spans: [RestoreSpan<T>],
        _ executedAt: TimeTicket,
        _ fallbackAnchor: RGATreeSplitPos? = nil
    ) throws -> ([RGATreeSplitNode<T>], [RGATreeSplitNode<T>], [ContentChange<T>], DataSize, [GCPair]) {
        var untombstoned = [RGATreeSplitNode<T>]()
        var recreated = [RGATreeSplitNode<T>]()
        var liveDiff = DataSize(data: 0, meta: 0)

        // The last node placed at the current cursor (un-tombstoned or recreated),
        // in document order. When a recreated fragment has no surviving same-
        // insertion anchor, chaining after this keeps a multi-fragment run in
        // left-to-right order instead of each fragment prepending at the same fixed
        // fallback anchor — which would rebuild the run reversed. Spans arrive in
        // document order, so this is always the recreated fragment's left neighbour.
        var chainAnchor: RGATreeSplitNode<T>?
        for span in spans {
            let pieces = self.findPiecesOverlapping(span.createdAt, span.start, span.end)

            var cursor = span.start
            var pieceIdx = 0
            while cursor < span.end {
                let piece = pieceIdx < pieces.count ? pieces[pieceIdx] : nil
                let pieceStart = piece?.id.offset ?? Int32.max
                let pieceEnd = piece.map { $0.id.offset + Int32($0.contentLength) } ?? Int32.max

                if let piece, pieceStart <= cursor {
                    // Covered by an existing piece.
                    let overlapEnd = Swift.min(pieceEnd, span.end)
                    if piece.isRemoved {
                        let (target, _) = try self.isolateRange(piece, cursor, overlapEnd)
                        target.setRemoveAt(nil)
                        // Repair splay weights on the path to root (length 0 → len).
                        self.treeByIndex.splayNode(target)
                        untombstoned.append(target)
                        chainAnchor = target
                    } else {
                        chainAnchor = piece
                    }
                    cursor = overlapEnd
                    if overlapEnd >= pieceEnd {
                        pieceIdx += 1
                    }
                } else {
                    // Gap: recreate [cursor, gapEnd) with its original ID.
                    let gapEnd = Swift.min(pieceStart, span.end)
                    let value = span.value.substring(from: Int(cursor - span.start), to: Swift.min(Int(gapEnd - span.start), span.value.count))
                    let newNode = RGATreeSplitNode(RGATreeSplitNodeID(span.createdAt, cursor), value)
                    liveDiff.addDataSizes(others: newNode.getDataSize())
                    let prev = try self.findRestoreAnchor(
                        span.createdAt,
                        cursor,
                        gapEnd,
                        executedAt,
                        fallbackAnchor,
                        chainAnchor
                    )
                    _ = self.insertAfter(prev, newNode)
                    recreated.append(newNode)
                    chainAnchor = newNode
                    cursor = gapEnd
                }
            }
        }

        let pendingGCPairs = self.drainPendingGCPairs()

        // Revived nodes are now live; report each as an insertion at its final
        // index. Ascending order keeps the indices valid when applied in
        // sequence (each earlier insertion is already present).
        var changes = [ContentChange<T>]()
        for node in untombstoned + recreated {
            let (from, _) = try self.findIndexesFromRange(node.createPosRange)
            changes.append(ContentChange<T>(actor: executedAt.actorID, from: from, to: from, content: node.value))
        }
        changes.sort { $0.from < $1.from }

        return (untombstoned, recreated, changes, liveDiff, pendingGCPairs)
    }

    /**
     * `retombstone` re-deletes the characters described by `spans` (redo of an
     * identity-preserving undo). Only live pieces are affected; already removed
     * or purged regions are skipped (idempotent).
     *
     * Returns `(pairs, changes, diff)`: GCPairs for the newly tombstoned nodes,
     * the removed regions as deletions so editor bindings and remote sync can
     * be driven the same way as a normal edit, and the metadata-size overhead
     * from splitting the (live) pieces to isolate the target range. The caller
     * must `root.acc(diff)` before registering `pairs`, mirroring how a normal
     * edit's boundary splits are accounted before its resulting tombstones are
     * registered. Indices are captured before each removal, so applying them in
     * emission order stays consistent.
     *
     * - Parameters:
     *   - spans: The identity-addressed runs to re-remove.
     *   - executedAt: The timestamp of the operation performing the removal.
     * - Returns: The GC pairs, resulting changes, and the live-bucket size delta.
     */
    func retombstone(
        _ spans: [RestoreSpan<T>],
        _ executedAt: TimeTicket
    ) throws -> ([GCPair], [ContentChange<T>], DataSize) {
        var pairs = [GCPair]()
        var changes = [ContentChange<T>]()
        var diff = DataSize(data: 0, meta: 0)

        for span in spans {
            let pieces = self.findPiecesOverlapping(span.createdAt, span.start, span.end)
            for piece in pieces {
                if piece.isRemoved {
                    continue
                }
                let pieceStart = piece.id.offset
                let pieceEnd = pieceStart + Int32(piece.contentLength)
                let (target, splitDiff) = try self.isolateRange(
                    piece,
                    Swift.max(pieceStart, span.start),
                    Swift.min(pieceEnd, span.end)
                )
                // `piece` was live, so the split overhead belongs to the live
                // bucket, same as a normal edit's boundary splits.
                diff.addDataSizes(others: splitDiff)
                // Capture the visible range while `target` is still live.
                let (from, to) = try self.findIndexesFromRange(target.createPosRange)
                target.remove(executedAt)
                self.treeByIndex.splayNode(target)
                pairs.append(GCPair(parent: self, child: target))
                if from < to {
                    changes.append(ContentChange<T>(actor: executedAt.actorID, from: from, to: to))
                }
            }
        }

        // Defensive: retombstone only ever isolates live pieces, so splitNode
        // never buffers anything here — drain anyway to stay consistent with
        // every other caller of isolateRange/splitNode.
        pairs.append(contentsOf: self.drainPendingGCPairs())

        return (pairs, changes, diff)
    }

    /**
     * `findPiecesOverlapping` collects existing nodes (live or tombstoned)
     * belonging to the insertion `createdAt` that overlap the absolute-offset
     * interval [start, end), in ascending offset order. Works by descending
     * floorEntry probes over `treeByID`.
     */
    private func findPiecesOverlapping(
        _ createdAt: TimeTicket,
        _ start: Int32,
        _ end: Int32
    ) -> [RGATreeSplitNode<T>] {
        var pieces = [RGATreeSplitNode<T>]()
        var probe = end - 1

        while probe >= 0 {
            let key = RGATreeSplitNodeID(createdAt, probe)
            guard let entry = self.treeByID.floorEntry(key), entry.key.hasSameCreatedAt(key) else {
                break
            }
            let node = entry.value
            let nodeStart = node.id.offset
            let nodeEnd = nodeStart + Int32(node.contentLength)
            if nodeEnd <= start {
                break
            }
            if nodeStart < end, nodeEnd > start {
                pieces.append(node)
            }
            if nodeStart <= start {
                break
            }
            probe = nodeStart - 1
        }

        return pieces.reversed()
    }

    /**
     * `findPieceCovering` returns the node of insertion `createdAt` whose
     * absolute-offset range covers `offset`, if present.
     */
    private func findPieceCovering(
        _ createdAt: TimeTicket,
        _ offset: Int32
    ) -> RGATreeSplitNode<T>? {
        let key = RGATreeSplitNodeID(createdAt, offset)
        guard let entry = self.treeByID.floorEntry(key), entry.key.hasSameCreatedAt(key) else {
            return nil
        }
        let node = entry.value
        let nodeStart = node.id.offset
        let nodeEnd = nodeStart + Int32(node.contentLength)
        if nodeStart <= offset, offset < nodeEnd {
            return node
        }
        return nil
    }

    /**
     * `findRestoreAnchor` returns the physical node to insert a recreated
     * fragment [gapStart, gapEnd) of insertion `createdAt` AFTER.
     *
     * Resolution ladder (all rules key on op-carried data + ID lookups only):
     *  (a) a piece covering gapEnd exists → directly before it
     *      (originally-adjacent successor; exact original slot)
     *  (b) nearest surviving piece of the same insertion left of gapStart
     *      → directly after it
     *  (c) rightmost surviving piece of the same insertion (must be right
     *      of the gap) → directly before it
     *  (d) chain anchor: the previously placed fragment of this same restore
     *      (document order) → after it, so a purged multi-fragment run is
     *      rebuilt left-to-right rather than reversed
     *  (e) the operation's fallback anchor (refined)
     *  (f) head (deterministic last resort)
     */
    private func findRestoreAnchor(
        _ createdAt: TimeTicket,
        _ gapStart: Int32,
        _ gapEnd: Int32,
        _ executedAt: TimeTicket,
        _ fallbackAnchor: RGATreeSplitPos?,
        _ chainAnchor: RGATreeSplitNode<T>? = nil
    ) throws -> RGATreeSplitNode<T> {
        if let succ = self.findPieceCovering(createdAt, gapEnd), let prev = succ.prev {
            return prev
        }

        if gapStart > 0 {
            let key = RGATreeSplitNodeID(createdAt, gapStart - 1)
            if let entry = self.treeByID.floorEntry(key), entry.key.hasSameCreatedAt(key) {
                return entry.value
            }
        }

        let rightmostKey = RGATreeSplitNodeID(createdAt, Int32.max)
        if let rightmost = self.treeByID.floorEntry(rightmostKey),
           rightmost.key.hasSameCreatedAt(rightmostKey),
           rightmost.value.id.offset >= gapEnd,
           let prev = rightmost.value.prev
        {
            return prev
        }

        // (d) No surviving piece of this insertion anchors the fragment. When the
        // whole run was purged, every fragment lands here; anchoring after the
        // fragment placed just before it (document order) keeps the run forward.
        if let chainAnchor {
            return chainAnchor
        }

        if let fallbackAnchor {
            // The anchor may have been fully purged; fall through to the head
            // when it can no longer be resolved.
            if let left = try? self.findNodeWithSplit(self.refinePos(fallbackAnchor), executedAt).0 {
                return left
            }
        }

        return self.head
    }

    /**
     * `isolateRange` splits `piece` so that a node exactly covering the
     * absolute-offset interval [from, to) exists, and returns it along with the
     * net metadata-size overhead the split(s) introduced.
     *
     * When `piece` is live, this overhead is a normal live-bucket cost (same as
     * any other boundary split) and the caller should `root.acc` it. When
     * `piece` is tombstoned, `splitNode` itself buffers the overhead of any
     * born-removed fragment via `pendingGCPairs` (see `drainPendingGCPairs`),
     * so the returned diff is zero in that case — the caller must still drain
     * and register those pairs.
     *
     * Requires: `pieceStart <= from < to <= pieceEnd`.
     */
    private func isolateRange(
        _ piece: RGATreeSplitNode<T>,
        _ from: Int32,
        _ to: Int32
    ) throws -> (RGATreeSplitNode<T>, DataSize) {
        var diff = DataSize(data: 0, meta: 0)
        var node = piece
        let nodeStart = node.id.offset
        if from > nodeStart {
            let (right, splitDiff) = try self.splitNode(node, from - nodeStart)
            diff.addDataSizes(others: splitDiff)
            if let right {
                node = right
            }
        }
        let newStart = node.id.offset
        if to < newStart + Int32(node.contentLength) {
            let (_, splitDiff) = try self.splitNode(node, to - newStart)
            diff.addDataSizes(others: splitDiff)
        }
        return (node, diff)
    }

    /**
     * `drainPendingGCPairs` returns the GC pairs buffered for born-tombstoned
     * split pieces and clears the buffer.
     */
    func drainPendingGCPairs() -> [GCPair] {
        let pairs = self.pendingGCPairs
        self.pendingGCPairs = []
        return pairs
    }

    private func deleteNodes(
        _ candidates: [RGATreeSplitNode<T>],
        _ editedAt: TimeTicket,
        _ vector: VersionVector? = nil
    ) throws -> ([ContentChange<T>],
                 [RGATreeSplitNode<T>],
                 Set<String>)
    {
        guard !candidates.isEmpty else {
            return ([], [], [])
        }
        let isLocal = vector == nil
        // 01. Collect nodes to remove and keep.
        var nodesToRemove: [RGATreeSplitNode<T>] = []
        var nodesToKeep: [RGATreeSplitNode<T>?] = []
        let (leftEdge, rightEdge) = try findEdgesOfCandidates(candidates)
        nodesToKeep.append(leftEdge)

        for node in candidates {
            let creationKnown = isLocal || vector!.afterOrEqual(other: node.createdAt)
            let tombstoneKnown = node.isRemoved && (isLocal || vector!.afterOrEqual(other: node.removedAt!))

            if node.canRemove(editedAt, creationKnown, tombstoneKnown) {
                nodesToRemove.append(node)
            } else {
                nodesToKeep.append(node)
            }
        }
        nodesToKeep.append(rightEdge)

        // 02. Create value changes with previous indexes before deletion.
        let changes = try makeChanges(nodesToKeep, editedAt)

        // 03. Mark tombstones for removal. Keep `nodesToRemove` (document) order so callers can
        // reconstruct the removed content left-to-right (Swift Dictionary is unordered).
        // Nodes that were already removed (concurrent LWW overwrite of an
        // existing tombstone) are tracked separately: they already have a
        // registered GC pair, and registering a second one would
        // toggle-unregister the first.
        var removedNodes: [RGATreeSplitNode<T>] = []
        var alreadyRemovedIDs = Set<String>()
        for node in nodesToRemove {
            if node.isRemoved {
                alreadyRemovedIDs.insert(node.toIDString)
            }
            node.remove(editedAt)
            removedNodes.append(node)
        }

        // 04. Clear the index tree of the given deletion boundaries.
        self.deleteIndexNodes(nodesToKeep)

        return (changes, removedNodes, alreadyRemovedIDs)
    }

    /**
     * `findEdgesOfCandidates` finds the edges outside `candidates`,
     * (which has not already been deleted, or be undefined but not yet implemented)
     * right edge is undefined means `candidates` contains the end of text.
     */
    private func findEdgesOfCandidates(_ candidates: [RGATreeSplitNode<T>]) throws -> (RGATreeSplitNode<T>, RGATreeSplitNode<T>?) {
        guard let prev = candidates[0].prev else {
            throw YorkieError(code: .errInvalidArgument, message: "prev must not nil!")
        }

        return (prev, candidates[safe: candidates.count - 1]?.next)
    }

    private func makeChanges(_ boundaries: [RGATreeSplitNode<T>?], _ editedAt: TimeTicket) throws -> [ContentChange<T>] {
        var changes = [ContentChange<T>]()
        var fromIdx: Int, toIdx: Int

        for index in 0 ..< (boundaries.count - 1) {
            guard let leftBoundary = boundaries[index] else {
                continue
            }

            let rightBoundary = boundaries[index + 1]

            if leftBoundary.next === rightBoundary {
                continue
            }

            guard let range = leftBoundary.next?.createPosRange else {
                throw YorkieError(code: .errUnexpected, message: "The next node of leftBoundary is nil")
            }

            fromIdx = try self.findIndexesFromRange(range).0
            if rightBoundary != nil {
                guard let range = rightBoundary!.prev?.createPosRange else {
                    throw YorkieError(code: .errUnexpected, message: "The prev node of rightBoundary is nil")
                }

                toIdx = try self.findIndexesFromRange(range).1
            } else {
                toIdx = self.treeByIndex.length
            }

            if fromIdx < toIdx {
                changes.append(ContentChange<T>(actor: editedAt.actorID, from: fromIdx, to: toIdx, content: nil))
            }
        }

        return changes.reversed()
    }

    /**
     * `deleteIndexNodes` clears the index nodes of the given deletion boundaries.
     * The boundaries mean the nodes that will not be deleted in the range.
     */
    private func deleteIndexNodes(_ boundaries: [RGATreeSplitNode<T>?]) {
        for index in 0 ..< (boundaries.count - 1) {
            let leftBoundary = boundaries[index]
            let rightBoundary = boundaries[index + 1]
            // If there is no node to delete between boundaries, do notting.
            if leftBoundary != nil, leftBoundary!.next !== rightBoundary {
                self.treeByIndex.cutOffRange(leftBoundary!, rightBoundary)
            }
        }
    }
}

extension RGATreeSplit: GCParent {
    /**
     * `purge` physically purges the given node from RGATreeSplit.
     */
    func purge(node: any GCChild) {
        guard let node = node as? RGATreeSplitNode<T> else {
            return
        }
        self.treeByIndex.delete(node)
        self.treeByID.remove(node.id)

        node.prev?.setNext(node.next)
        node.next?.setPrev(node.prev)

        node.setPrev(nil)
        node.setNext(nil)

        node.insPrev?.setInsNext(node.insNext)
        node.insNext?.setInsPrev(node.insPrev)

        node.setInsPrev(nil)
        node.setInsNext(nil)
    }
}

extension RGATreeSplit: Sequence {
    func makeIterator() -> NodeIterator {
        NodeIterator(head: self.head)
    }

    class NodeIterator: IteratorProtocol {
        // swiftlint: disable nesting
        typealias Element = RGATreeSplitNode<T>

        private var head: Element?

        init(head: Element?) {
            self.head = head
        }

        func next() -> Element? {
            let next = self.head
            self.head = self.head?.next
            return next
        }
        // swiftlint: enable nesting
    }
}
