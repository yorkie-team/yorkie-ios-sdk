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
    public let createdAt: TimeTicket
    /**
     * `offset` the offset of this ID.
     */
    public let offset: Int32

    init(_ createdAt: TimeTicket, _ offset: Int32) {
        self.createdAt = createdAt
        self.offset = offset
    }

    /**
     * `==` returns whether given ID equals to this ID or not.
     */
    public static func == (lhs: RGATreeSplitNodeID, rhs: RGATreeSplitNodeID) -> Bool {
        lhs.createdAt == rhs.createdAt && lhs.offset == rhs.offset
    }

    public static func < (lhs: RGATreeSplitNodeID, rhs: RGATreeSplitNodeID) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.offset < rhs.offset
        } else {
            return lhs.createdAt < rhs.createdAt
        }
    }

    /**
     * `hasSameCreatedAt` returns whether given ID has same creation time with this ID.
     */
    public func hasSameCreatedAt(_ other: RGATreeSplitNodeID) -> Bool {
        self.createdAt == other.createdAt
    }

    /**
     * `split` creates a new ID with an offset from this ID.
     */
    public func split(_ offset: Int32) -> RGATreeSplitNodeID {
        RGATreeSplitNodeID(self.createdAt, self.offset + offset)
    }

    /**
     * `toTestString` returns a String containing
     * the meta data of the node id for debugging purpose.
     */
    public var toTestString: String {
        "\(self.createdAt.toTestString):\(self.offset)"
    }

    /**
     * `toIDString` returns a string that can be used as an ID for this node id.
     */
    public var toIDString: String {
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
    public static func == (lhs: RGATreeSplitPos, rhs: RGATreeSplitPos) -> Bool {
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
 * `RGATreeSplitNode` is a node of RGATreeSplit.
 */
class RGATreeSplitNode<T: RGATreeSplitValue>: SplayNode<T> {
    /**
     * `id` returns the ID of this RGATreeSplitNode.
     */
    public let id: RGATreeSplitNodeID

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
    public var createdAt: TimeTicket {
        self.id.createdAt
    }

    /**
     * `length` returns the length of this node.
     */
    override public var length: Int {
        guard self.removedAt == nil else {
            return 0
        }

        return self.contentLength
    }

    /**
     * `contentLength` returns the length of this value.
     */
    public var contentLength: Int {
        self.value.count
    }

    /**
     * `insPrevID` returns a ID of previous node insertion.
     */
    public var insPrevID: RGATreeSplitNodeID? {
        self.insPrev?.id
    }

    /**
     * `setPrev` sets a previous node of this node.
     */
    public func setPrev(_ node: RGATreeSplitNode<T>?) {
        self.prev = node
        node?.next = self
    }

    /**
     * `setNext`  sets a next node of this node.
     */
    public func setNext(_ node: RGATreeSplitNode<T>?) {
        self.next = node
        node?.prev = self
    }

    /**
     * `setInsPrev` sets a previous node of this node insertion.
     */
    public func setInsPrev(_ node: RGATreeSplitNode<T>?) {
        self.insPrev = node
        node?.insNext = self
    }

    /**
     * `setInsNext` sets a next node of this node insertion.
     */
    public func setInsNext(_ node: RGATreeSplitNode<T>?) {
        self.insNext = node
        node?.insPrev = self
    }

    /**
     * `hasNext` checks if next node exists.
     */
    public var hasNext: Bool {
        self.next != nil
    }

    /**
     * `hasInsPrev` checks if previous insertion node exists.
     */
    public var hasInsPrev: Bool {
        self.insPrev != nil
    }

    /**
     * `hasInsPrev` checks if previous insertion node exists.
     */
    public var hasInsNext: Bool {
        self.insNext != nil
    }

    /**
     * `isRemoved` checks if removed time exists.
     */
    public var isRemoved: Bool {
        self.removedAt != nil
    }

    /**
     * `split` creates a new split node of the given offset.
     */
    public func split(_ offset: Int32) -> RGATreeSplitNode<T> {
        RGATreeSplitNode(
            self.id.split(offset),
            self.splitValue(offset),
            self.removedAt
        )
    }

    /**
     * `canDelete` checks if node is able to delete.
     */
    public func canDelete(_ editedAt: TimeTicket, _ latestCreatedAt: TimeTicket) -> Bool {
        !self.createdAt.after(latestCreatedAt) && (self.removedAt == nil || editedAt.after(self.removedAt!))
    }

    /**
     * `remove` removes node of given edited time.
     */
    public func remove(_ editedAt: TimeTicket?) {
        self.removedAt = editedAt
    }

    /**
     * `createRange` creates ranges of RGATreeSplitNodePos.
     */
    public var createPosRange: RGATreeSplitPosRange {
        (RGATreeSplitPos(self.id, 0), RGATreeSplitPos(self.id, Int32(self.length)))
    }

    /**
     * `deepcopy` returns a new instance of this RGATreeSplitNode without structural info.
     */
    public func deepcopy() -> RGATreeSplitNode<T> {
        RGATreeSplitNode(self.id, self.value, self.removedAt)
    }

    /**
     * `toTestString` returns a String containing
     * the meta data of the node for debugging purpose.
     */
    public var toTestString: String {
        "\(self.id.toTestString) \(String(describing: self.value))"
    }

    private func splitValue(_ offset: Int32) -> T {
        let value = self.value
        self.value = value.substring(from: 0, to: Int(offset))
        return value.substring(from: Int(offset), to: value.count)
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
    private var removedNodeMap = [String: RGATreeSplitNode<T>]()

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
     * @param latestCreatedAtMapByActor - latestCreatedAtMapByActor
     * @returns `[RGATreeSplitNodePos, Map<string, TimeTicket>, Array<Change>]`
     */
    @discardableResult
    public func edit(_ range: RGATreeSplitPosRange,
                     _ editedAt: TimeTicket,
                     _ value: T?,
                     _ latestCreatedAtMapByActor: [String: TimeTicket]? = nil) throws -> (RGATreeSplitPos, [String: TimeTicket], [ContentChange<T>])
    {
        // 01. split nodes with from and to
        let (toLeft, toRight) = try self.findNodeWithSplit(range.1, editedAt)
        let (fromLeft, fromRight) = try self.findNodeWithSplit(range.0, editedAt)

        // 02. delete between from and to
        let nodesToDelete = self.findBetween(fromRight, toRight)
        var (changes, latestCreatedAtMap, removedNodeMapByNodeKey) = try self.deleteNodes(nodesToDelete, editedAt, latestCreatedAtMapByActor)

        let caretID = toRight?.id ?? toLeft.id
        var caretPos = RGATreeSplitPos(caretID, 0)

        // 03. insert a new node
        if let value {
            let idx = try self.posToIndex(fromLeft.createPosRange.1, true)

            let inserted = self.insertAfter(
                fromLeft,
                RGATreeSplitNode(RGATreeSplitNodeID(editedAt, 0), value)
            )

            if !changes.isEmpty, changes[changes.count - 1].from == idx {
                changes[changes.count - 1].content = value
            } else {
                changes.append(ContentChange<T>(actor: editedAt.actorID!, from: idx, to: idx, content: value))
            }

            caretPos = RGATreeSplitPos(inserted.id, Int32(inserted.contentLength))
        }

        // 04. add removed node
        for (key, removedNode) in removedNodeMapByNodeKey {
            self.removedNodeMap[key] = removedNode
        }

        return (caretPos, latestCreatedAtMap, changes)
    }

    /**
     * `findNodePos` finds RGATreeSplitNodePos of given offset.
     */
    public func indexToPos(_ idx: Int) throws -> RGATreeSplitPos {
        let (node, offset) = self.treeByIndex.find(idx)
        guard let splitNode = node as? RGATreeSplitNode<T> else {
            throw YorkieError.noSuchElement(message: "no element for index \(idx)")
        }

        return RGATreeSplitPos(splitNode.id, Int32(offset))
    }

    /**
     * `findIndexesFromRange` finds indexes based on range.
     */
    public func findIndexesFromRange(_ range: RGATreeSplitPosRange) throws -> (Int, Int) {
        let (fromPos, toPos) = range
        return try (self.posToIndex(fromPos, false), self.posToIndex(toPos, true))
    }

    /**
     * `posToIndex` finds index based on node position.
     */
    public func posToIndex(_ pos: RGATreeSplitPos, _ preferToLeft: Bool) throws -> Int {
        let absoluteID = pos.absoluteID
        guard let node = preferToLeft ? try? self.findFloorNodePreferToLeft(absoluteID) : self.findFloorNode(absoluteID) else {
            let message = "the node of the given id should be found: \(absoluteID.toTestString)"
            Logger.critical(message)
            throw YorkieError.noSuchElement(message: message)
        }
        let index = self.treeByIndex.indexOf(node)
        let offset = node.isRemoved ? 0 : absoluteID.offset - node.id.offset

        return index + Int(offset)
    }

    /**
     * `findNode` finds node of given id.
     */
    public func findNode(_ id: RGATreeSplitNodeID) -> RGATreeSplitNode<T>? {
        self.findFloorNode(id)
    }

    /**
     * `length` returns size of RGATreeList.
     */
    public var length: Int {
        self.treeByIndex.length
    }

    /**
     * `checkWeight` returns false when there is an incorrect weight node.
     * for debugging purpose.
     */
    public func checkWeight() -> Bool {
        self.treeByIndex.checkWeight()
    }

    /**
     * `toJSON` returns the JSON encoding of this Array.
     */
    public var toJSON: String {
        var result = [String]()

        self.forEach {
            if !$0.isRemoved {
                result.append("\($0.value)")
            }
        }

        return result.joined(separator: "")
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    public func deepcopy() -> RGATreeSplit<T> {
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
    public var toTestString: String {
        var result = [String]()

        self.forEach {
            if !$0.isRemoved {
                result.append("[\($0.toTestString)]")
            } else {
                result.append("{\($0.toTestString)}")
            }
        }

        return result.joined(separator: "")
    }

    /**
     * `insertAfter` inserts the given node after the given previous node.
     */
    @discardableResult
    public func insertAfter(_ prevNode: RGATreeSplitNode<T>, _ newNode: RGATreeSplitNode<T>) -> RGATreeSplitNode<T> {
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
    public func findNodeWithSplit(_ pos: RGATreeSplitPos, _ editedAt: TimeTicket) throws -> (RGATreeSplitNode<T>, RGATreeSplitNode<T>?) {
        let absoluteID = pos.absoluteID
        var node = try self.findFloorNodePreferToLeft(absoluteID)
        let relativeOffset = absoluteID.offset - node.id.offset

        self.splitNode(node, relativeOffset)

        while let next = node.next, next.createdAt.after(editedAt) {
            node = next
        }

        return (node, node.next)
    }

    private func findFloorNodePreferToLeft(_ id: RGATreeSplitNodeID) throws -> RGATreeSplitNode<T> {
        guard let node = self.findFloorNode(id) else {
            let message = "the node of the given id should be found: \(id.toTestString)"
            Logger.critical(message)
            throw YorkieError.noSuchElement(message: message)
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
    public func findBetween(_ fromNode: RGATreeSplitNode<T>?, _ toNode: RGATreeSplitNode<T>?) -> [RGATreeSplitNode<T>] {
        var nodes = [RGATreeSplitNode<T>]()

        var current: RGATreeSplitNode<T>? = fromNode
        while current != nil, current! !== toNode {
            nodes.append(current!)
            current = current!.next
        }

        return nodes
    }

    @discardableResult
    private func splitNode(_ node: RGATreeSplitNode<T>, _ offset: Int32) -> RGATreeSplitNode<T>? {
        guard offset <= node.contentLength else {
            Logger.critical("offset should be less than or equal to length")

            return nil
        }

        if offset == 0 {
            return node
        } else if offset == node.contentLength {
            return node.next
        }

        let splitNode = node.split(offset)
        self.treeByIndex.updateWeight(splitNode)
        self.insertAfter(node, splitNode)

        if node.hasInsNext {
            node.insNext!.setInsPrev(splitNode)
        }
        splitNode.setInsPrev(node)

        return splitNode
    }

    private func deleteNodes(_ candidates: [RGATreeSplitNode<T>],
                             _ editedAt: TimeTicket,
                             _ latestCreatedAtMapByActor: [String: TimeTicket]?) throws -> ([ContentChange<T>],
                                                                                            [String: TimeTicket],
                                                                                            [String: RGATreeSplitNode<T>])
    {
        guard !candidates.isEmpty else {
            return ([], [:], [:])
        }

        // There are 2 types of nodes in `candidates`: should delete, should not delete.
        // `nodesToKeep` contains nodes should not delete,
        // then is used to find the boundary of the range to be deleted.
        let (nodesToDelete, nodesToKeep) = try self.filterNodes(candidates, editedAt, latestCreatedAtMapByActor)

        var createdAtMapByActor = [ActorID: TimeTicket]()
        var removedNodeMap = [ActorID: RGATreeSplitNode<T>]()
        // First we need to collect indexes for change.
        let changes = try self.makeChanges(nodesToKeep, editedAt)

        for node in nodesToDelete {
            // Then make nodes be tombstones and map that.
            if let actorID = node.createdAt.actorID {
                if createdAtMapByActor[actorID] == nil ||
                    node.id.createdAt.after(createdAtMapByActor[actorID]!)
                {
                    createdAtMapByActor[actorID] = node.id.createdAt
                }
            }
            removedNodeMap[node.id.toIDString] = node
            node.remove(editedAt)
        }
        // Finally remove index nodes of tombstones.
        self.deleteIndexNodes(nodesToKeep)

        return (changes, createdAtMapByActor, removedNodeMap)
    }

    private func filterNodes(_ candidates: [RGATreeSplitNode<T>],
                             _ editedAt: TimeTicket,
                             _ latestCreatedAtMapByActor: [ActorID: TimeTicket]?) throws -> ([RGATreeSplitNode<T>], [RGATreeSplitNode<T>?])
    {
        let isRemote = latestCreatedAtMapByActor != nil
        var nodesToDelete = [RGATreeSplitNode<T>]()
        var nodesToKeep = [RGATreeSplitNode<T>?]()

        let (leftEdge, rightEdge) = try self.findEdgesOfCandidates(candidates)
        nodesToKeep.append(leftEdge)

        for node in candidates {
            let latestCreatedAt: TimeTicket

            if isRemote {
                if let actorID = node.createdAt.actorID, let latest = latestCreatedAtMapByActor?[actorID] {
                    latestCreatedAt = latest
                } else {
                    latestCreatedAt = TimeTicket.initial
                }
            } else {
                latestCreatedAt = TimeTicket.max
            }

            if node.canDelete(editedAt, latestCreatedAt) {
                nodesToDelete.append(node)
            } else {
                nodesToKeep.append(node)
            }
        }
        nodesToKeep.append(rightEdge)

        return (nodesToDelete, nodesToKeep)
    }

    /**
     * `findEdgesOfCandidates` finds the edges outside `candidates`,
     * (which has not already been deleted, or be undefined but not yet implemented)
     * right edge is undefined means `candidates` contains the end of text.
     */
    private func findEdgesOfCandidates(_ candidates: [RGATreeSplitNode<T>]) throws -> (RGATreeSplitNode<T>, RGATreeSplitNode<T>?) {
        guard let prev = candidates[0].prev else {
            throw YorkieError.noSuchElement(message: "prev must not nil!")
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
                throw YorkieError.noSuchElement(message: "The next node of leftBoundary is nil")
            }

            fromIdx = try self.findIndexesFromRange(range).0
            if rightBoundary != nil {
                guard let range = rightBoundary!.prev?.createPosRange else {
                    throw YorkieError.noSuchElement(message: "The prev node of rightBoundary is nil")
                }

                toIdx = try self.findIndexesFromRange(range).1
            } else {
                toIdx = self.treeByIndex.length
            }

            if fromIdx < toIdx {
                changes.append(ContentChange<T>(actor: editedAt.actorID!, from: fromIdx, to: toIdx, content: nil))
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

    /**
     * `removedNodesLength` returns size of removed nodes.
     */
    public var removedNodesLength: Int {
        self.removedNodeMap.count
    }

    /**
     * `purgeRemovedNodesBefore` physically purges nodes that have been removed.
     */
    public func purgeRemovedNodesBefore(_ ticket: TimeTicket) -> Int {
        var count = 0

        for (_, node) in self.removedNodeMap {
            if let removedAt = node.removedAt, ticket >= removedAt {
                self.treeByIndex.delete(node)
                self.purge(node)
                self.treeByID.remove(node.id)
                self.removedNodeMap.removeValue(forKey: node.id.toIDString)
                count += 1
            }
        }

        return count
    }

    /**
     * `purge` physically purges the given node from RGATreeSplit.
     */
    public func purge(_ node: RGATreeSplitNode<T>) {
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
    public func makeIterator() -> NodeIterator {
        NodeIterator(head: self.head)
    }

    public class NodeIterator: IteratorProtocol {
        // swiftlint: disable nesting
        typealias Element = RGATreeSplitNode<T>

        private var head: Element?

        init(head: Element?) {
            self.head = head
        }

        public func next() -> Element? {
            let next = self.head
            self.head = self.head?.next
            return next
        }
        // swiftlint: enable nesting
    }
}
