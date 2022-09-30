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
 * `CRDTArray` represents Array data type containing logical clocks.
 *
 */
class CRDTArray: CRDTContainer {
    private var elements: RGATreeList

    init(createdAt: TimeTicket, elements: RGATreeList = RGATreeList()) {
        self.elements = elements
        super.init(createdAt: createdAt)
    }

    /**
     * `subPath` returns subPath of JSONPath of the given `createdAt` element.
     */
    override func subPath(createdAt: TimeTicket) throws -> String {
        return try self.elements.subPath(createdAt: createdAt)
    }

    /**
     * `purge` physically purge child element.
     */
    override func purge(element: CRDTElement) throws {
        try self.elements.purge(element)
    }

    /**
     * `insert` inserts the given element after the given previous element.
     */
    func insert(value: CRDTElement, afterCreatedAt: TimeTicket) throws {
        try self.elements.insert(value, afterCreatedAt: afterCreatedAt)
    }

    /**
     * `move` moves the given `createdAt` element after the `prevCreatedAt`.
     */
    func move(createdAt: TimeTicket, afterCreatedAt: TimeTicket, executedAt: TimeTicket) throws {
        try self.elements.move(createdAt: createdAt, afterCreatedAt: afterCreatedAt, executedAt: executedAt)
    }

    /**
     * `get` returns the element of the given createAt.
     */
    func get(createdAt: TimeTicket) throws -> CRDTElement {
        guard let node = try? self.elements.get(createdAt: createdAt), node.isRemoved() == false else {
            let log = "can't find the given node: \(createdAt)"
            Logger.fatal(log)
            throw YorkieError.unexpected(message: log)
        }

        return node
    }

    /**
     * `get` returns the element of the given index.
     */
    func get(index: Int) throws -> CRDTElement {
        let node = try self.elements.getNode(index: index)
        return node.getValue()
    }

    /**
     * `getHead` returns dummy head element.
     */
    func getHead() -> CRDTElement {
        return self.elements.getHead()
    }

    /**
     * `getLast` returns last element.
     */
    func getLast() -> CRDTElement {
        return self.elements.getLast()
    }

    /**
     * `getPreviousCreatedAt` returns the creation time of
     * the previous element of the given element.
     */
    func getPreviousCreatedAt(createdAt: TimeTicket) throws -> TimeTicket {
        return try self.elements.getPreviousCreatedAt(ofCreatedAt: createdAt)
    }

    /**
     * `remove` removes the element of the given index.
     */
    @discardableResult
    override func remove(createdAt: TimeTicket, executedAt: TimeTicket) throws -> CRDTElement {
        return try self.elements.remove(createdAt: createdAt, executedAt: executedAt)
    }

    /**
     * `remove` removes the element of given index and editedAt.
     */
    func remove(index: Int, editedAt: TimeTicket) throws -> CRDTElement {
        return try self.elements.remove(index: index, editedAt: editedAt)
    }

    /**
     * `getLastCreatedAt` get last created element.
     */
    func getLastCreatedAt() -> TimeTicket {
        return self.elements.getLastCreatedAt()
    }

    /**
     * `length` returns length of this elements.
     */
    var length: Int {
        return self.elements.length
    }

    /**
     * `getDescendants` traverse the descendants of this array.
     */
    override func getDescendants(callback: (_ element: CRDTElement, _ parent: CRDTContainer) -> Bool) {
        for node in self.elements {
            let element = node.getValue()
            if callback(element, self) {
                return
            }

            if let element = element as? CRDTContainer {
                element.getDescendants(callback: callback)
            }
        }
    }

    /**
     * `toJSON` returns the JSON encoding of this array.
     */
    override func toJSON() -> String {
        let json = self.elements.map { $0.getValue().toJSON() }

        return "[\(json.joined(separator: ","))]"
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of this array.
     */
    override func toSortedJSON() -> String {
        return self.toJSON()
    }

    /**
     * `getElements` returns an array of elements contained in this RGATreeList.
     */
    func getElements() -> RGATreeList {
        return self.elements
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    override func deepcopy() -> CRDTArray {
        let result = CRDTArray(createdAt: self.getCreatedAt())
        for node in self.elements {
            try? result.elements.insert(node.getValue().deepcopy(), afterCreatedAt: result.getLastCreatedAt())
        }
        result.remove(self.getRemovedAt())
        return result
    }
}

extension CRDTArray: Sequence {
    typealias Element = CRDTElement

    func makeIterator() -> CRDTArrayIterator {
        return CRDTArrayIterator(self.elements)
    }
}

class CRDTArrayIterator: IteratorProtocol {
    private var values: [CRDTElement]
    private var iteratorNext: Int = 0

    init(_ rgaTreeList: RGATreeList) {
        self.values = rgaTreeList.map { $0.getValue() }
    }

    func next() -> CRDTElement? {
        defer {
            self.iteratorNext += 1
        }

        repeat {
            guard self.iteratorNext < self.values.count else {
                break
            }

            let result = self.values[self.iteratorNext]
            if result.isRemoved() == false {
                return result
            }

            self.iteratorNext += 1

        } while true

        return nil
    }
}
