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
 * `RGATreeListNode` is a node of RGATreeList.
 */
final class RGATreeListNode: SplayNode<CRDTElement> {
    fileprivate private(set) var previous: RGATreeListNode?
    fileprivate var next: RGATreeListNode?

    override init(_ value: CRDTElement) {
        super.init(value)
    }

    /**
     * `create` creates a new node after the previous node.
     */
    static func create(with value: CRDTElement, previousNode: RGATreeListNode) -> RGATreeListNode {
        let newNode = RGATreeListNode(value)
        let prevNext = previousNode.next
        previousNode.next = newNode
        newNode.previous = previousNode
        newNode.next = prevNext
        if let prevNext = prevNext {
            prevNext.previous = newNode
        }

        return newNode
    }

    /**
     * `length` returns the length of this node.
     */
    override var length: Int {
        return self.value.isRemoved ? 0 : 1
    }

    /**
     * `remove` removes value based on removing time.
     */
    fileprivate func remove(_ removedAt: TimeTicket) -> Bool {
        return self.value.remove(removedAt)
    }

    /**
     * `getCreatedAt` returns creation time of this value
     */
    fileprivate var createdAt: TimeTicket {
        return self.value.createdAt
    }

    /**
     * `getPositionedAt` returns time this element was positioned in the array.
     */
    fileprivate var positionedAt: TimeTicket {
        if let movedAt = self.value.movedAt {
            return movedAt
        }

        return self.value.createdAt
    }

    /**
     * `delete` deletes prev and next node.
     */
    fileprivate func delete() {
        if let previous = self.previous {
            previous.next = self.next
        }
        if let next = self.next {
            next.previous = self.previous
        }
        self.previous = nil
        self.next = nil
    }

    /**
     * `isRemoved` checks if the value was removed.
     */
    fileprivate var isRemoved: Bool {
        return self.value.isRemoved
    }
}

/**
 * `RGATreeList` is replicated growable array.
 */
class RGATreeList {
    private let dummyHead: RGATreeListNode
    private var last: RGATreeListNode
    private let nodeMapByIndex: SplayTree<CRDTElement>
    private var nodeMapByCreatedAt: [TimeTicket: RGATreeListNode]

    init() {
        let dummyValue = Primitive(value: .null, createdAt: .initial)
        dummyValue.removedAt = .initial
        self.dummyHead = RGATreeListNode(dummyValue)
        self.last = self.dummyHead
        self.nodeMapByIndex = SplayTree()
        self.nodeMapByIndex.insert(self.dummyHead)
        self.nodeMapByCreatedAt = [self.dummyHead.createdAt: self.dummyHead]
    }

    /**
     * `length` returns size of RGATreeList.
     */
    var length: Int {
        return self.nodeMapByIndex.length
    }

    /**
     * `findNode` returns the node by the given createdAt and
     * executedAt. It passes through nodes created after executedAt from the
     * given node and returns the next node.
     *
     * - Parameters:
     *   - createdAt: created time
     *   - executedAt: executed time
     * - Returns: next node
     */
    private func findNode(fromCreatedAt createdAt: TimeTicket, executedAt: TimeTicket) throws -> RGATreeListNode {
        guard var node = self.nodeMapByCreatedAt[createdAt] else {
            let log = "can't find the given node: \(createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        while true {
            guard let next = node.next, next.positionedAt.after(executedAt) else {
                break
            }
            node = next
        }

        return node
    }

    private func delete(node: RGATreeListNode) {
        if self.last === node, let previousNode = node.previous {
            self.last = previousNode
        }

        node.delete()
        self.nodeMapByIndex.delete(node)
        self.nodeMapByCreatedAt.removeValue(forKey: node.value.createdAt)
    }

    /**
     * `insert` adds next element of previously created node.
     */
    func insert(_ value: CRDTElement, afterCreatedAt createdAt: TimeTicket, executedAt: TimeTicket? = nil) throws {
        let executedAt: TimeTicket = executedAt ?? value.createdAt

        let previousNode = try findNode(fromCreatedAt: createdAt, executedAt: executedAt)
        let newNode = RGATreeListNode.create(with: value, previousNode: previousNode)
        if previousNode === self.last {
            self.last = newNode
        }

        self.nodeMapByIndex.insert(previousNode: previousNode, newNode: newNode)
        self.nodeMapByCreatedAt[newNode.createdAt] = newNode
    }

    /**
     * `move` moves the given `createdAt` element
     * after the `previousCreatedAt` element.
     */
    func move(createdAt: TimeTicket, afterCreatedAt: TimeTicket, executedAt: TimeTicket) throws {
        guard let previsousNode = self.nodeMapByCreatedAt[afterCreatedAt] else {
            let log = "can't find the given node: \(afterCreatedAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        guard let movingNode = self.nodeMapByCreatedAt[createdAt] else {
            let log = "can't find the given node: \(createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        guard previsousNode !== movingNode else {
            return
        }

        var needToMove = false
        if movingNode.value.movedAt == nil {
            needToMove = true
        } else if let movedAt = movingNode.value.movedAt, executedAt.after(movedAt) {
            needToMove = true
        }

        guard needToMove else {
            return
        }

        self.delete(node: movingNode)
        try self.insert(movingNode.value, afterCreatedAt: previsousNode.createdAt, executedAt: executedAt)
        movingNode.value.setMovedAt(executedAt)
    }

    /**
     * `insert` adds the given element after  the last creation time.
     */
    func insert(_ value: CRDTElement) throws {
        try self.insert(value, afterCreatedAt: self.last.createdAt)
    }

    /**
     * `get` returns the element of the given index.
     */
    func get(createdAt: TimeTicket) throws -> CRDTElement {
        guard let node = self.nodeMapByCreatedAt[createdAt] else {
            let log = "can't find the given node: \(createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        return node.value
    }

    /**
     * `subpath` subpath  of JSONPath based on the creation time of the node.
     */
    func subPath(createdAt: TimeTicket) throws -> String {
        guard let node = self.nodeMapByCreatedAt[createdAt] else {
            let log = "can't find the given node: \(createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        return String(self.nodeMapByIndex.indexOf(node))
    }

    /**
     * `delete` physically purges child element.
     */
    func delete(_ value: CRDTElement) throws {
        guard let node = self.nodeMapByCreatedAt[value.createdAt] else {
            let log = "failed to find the given createdAt: \(value.createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        self.delete(node: node)
    }

    /**
     * `getNode` returns node of the given index.
     */
    func getNode(index: Int) throws -> RGATreeListNode {
        guard index < self.length else {
            let log = "length is smaller than or equal to: \(index)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        let (node, offset) = self.nodeMapByIndex.find(position: index)
        guard let rgaNode = node as? RGATreeListNode else {
            let log = "failed to find the given index: \(index)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        guard (index == 0 && rgaNode === self.dummyHead) || offset >= 1 else {
            return rgaNode
        }

        var nextRgaNode: RGATreeListNode? = rgaNode
        repeat {
            if nextRgaNode == nil {
                break
            }
            nextRgaNode = nextRgaNode?.next

        } while nextRgaNode?.isRemoved == true

        guard let nextRgaNode else {
            let log = "failed to find the given index: \(index)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        return nextRgaNode
    }

    /**
     * `getPreviousCreatedAt` returns a creation time of the previous node.
     */
    func getPreviousCreatedAt(ofCreatedAt createdAt: TimeTicket) throws -> TimeTicket {
        guard let node = self.nodeMapByCreatedAt[createdAt] else {
            let log = "can't find the given node: \(createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }
        var previousNode: RGATreeListNode? = node
        repeat {
            previousNode = previousNode?.previous
        } while self.dummyHead !== previousNode && previousNode?.isRemoved == true

        return previousNode?.value.createdAt ?? self.getHead().createdAt
    }

    /**
     * `remove` removes the node of the given creation time.
     */
    func remove(createdAt: TimeTicket, executedAt: TimeTicket) throws -> CRDTElement {
        guard let node = self.nodeMapByCreatedAt[createdAt] else {
            let log = "can't find the given node: \(createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        let alreadyRemoved = node.isRemoved
        if node.remove(executedAt), alreadyRemoved == false {
            self.nodeMapByIndex.splayNode(node)
        }
        return node.value
    }

    /**
     * `remove` removes the node of the given index.
     */
    func remove(index: Int, executedAt: TimeTicket) throws -> CRDTElement {
        let node = try self.getNode(index: index)

        if node.remove(executedAt) {
            self.nodeMapByIndex.splayNode(node)
        }
        return node.value
    }

    /**
     * `getHead` returns the value of head elements.
     */
    func getHead() -> CRDTElement {
        return self.dummyHead.value
    }

    /**
     * `getLast` returns the value of last elements.
     */
    func getLast() -> CRDTElement {
        return self.last.value
    }

    /**
     * `getLastCreatedAt` returns the creation time of last elements.
     */
    func getLastCreatedAt() -> TimeTicket {
        return self.last.createdAt
    }

    /**
     * `structureAsString` returns a String containing the meta data of the node id
     * for debugging purpose.
     */
    var structureAsString: String {
        var result: [String] = []

        for node in self {
            let value = "\(node.createdAt):\(node.value.toJSON())"
            if node.isRemoved {
                result.append("{\(value)}")
            } else {
                result.append("[\(value)]")
            }
        }

        return result.joined(separator: "-")
    }
}

extension RGATreeList: Sequence {
    typealias Element = RGATreeListNode

    func makeIterator() -> RGATreeListIterator {
        return RGATreeListIterator(self.dummyHead.next)
    }
}

class RGATreeListIterator: IteratorProtocol {
    private weak var iteratorNext: RGATreeListNode?

    init(_ firstNode: RGATreeListNode?) {
        self.iteratorNext = firstNode
    }

    func next() -> RGATreeListNode? {
        guard let result = self.iteratorNext else {
            return nil
        }

        defer {
            self.iteratorNext = result.next
        }
        return result
    }
}
