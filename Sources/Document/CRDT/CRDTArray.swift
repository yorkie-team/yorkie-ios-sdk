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
    var createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    private var elements: RGATreeList

    init(createdAt: TimeTicket, elements: RGATreeList = RGATreeList()) {
        self.createdAt = createdAt
        self.elements = elements
    }

    /**
     * `insert` adds a new node after the the given node.
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
        guard let node = try? self.elements.get(createdAt: createdAt), node.isRemoved == false else {
            let log = "can't find the given node: \(createdAt)"
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        return node
    }

    /**
     * `get` returns the element of the given index.
     */
    func get(index: Int) throws -> CRDTElement {
        let node = try self.elements.getNode(index: index)
        return node.value
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
     * `getPreviousCreatedAt` returns the creation time of the previous node.
     */
    func getPreviousCreatedAt(createdAt: TimeTicket) throws -> TimeTicket {
        return try self.elements.getPreviousCreatedAt(ofCreatedAt: createdAt)
    }

    /**
     * `deleteByIndex` deletes the element of given index and executedAt.
     */
    func deleteByIndex(index: Int, executedAt: TimeTicket) throws -> CRDTElement {
        return try self.elements.deleteByIndex(index: index, executedAt: executedAt)
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
     * `getElements` returns an array of elements contained in this RGATreeList.
     */
    func getElements() -> RGATreeList {
        return self.elements
    }
}

extension CRDTArray {
    /**
     * `toJSON` returns the JSON encoding of this array.
     */
    func toJSON() -> String {
        let json = self
            .map { $0.toJSON() }

        return "[\(json.joined(separator: ","))]"
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of this array.
     */
    func toSortedJSON() -> String {
        let json = self
            .map { $0.toSortedJSON() }

        return "[\(json.joined(separator: ","))]"
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> CRDTElement {
        let result = CRDTArray(createdAt: self.createdAt)
        for node in self.elements {
            try? result.elements.insert(node.value.deepcopy(), afterCreatedAt: result.getLastCreatedAt())
        }
        result.remove(self.removedAt)
        return result
    }

    /**
     * `subPath` returns the sub path of the given element.
     */
    func subPath(createdAt: TimeTicket) throws -> String {
        return try self.elements.subPath(createdAt: createdAt)
    }

    /**
     * `purge` physically purges the given element.
     */
    func purge(element: CRDTElement) throws {
        try self.elements.purge(element)
    }

    /**
     * `delete` deletes  the element of the given creation time.
     */
    @discardableResult
    func delete(createdAt: TimeTicket, executedAt: TimeTicket) throws -> CRDTElement {
        return try self.elements.delete(createdAt: createdAt, executedAt: executedAt)
    }

    /**
     * `getDescendants` traverse the descendants of this array.
     */
    func getDescendants(callback: (_ element: CRDTElement, _ parent: CRDTContainer?) -> Bool) {
        for node in self.elements {
            let element = node.value
            if callback(element, self) {
                return
            }

            if let element = element as? CRDTContainer {
                element.getDescendants(callback: callback)
            }
        }
    }

    /**
     * `getDataSize` returns the data size of the array.
     */
    func getDataSize() -> DataSize {
        return .init(
            data: 0,
            meta: self.getMetaUsage()
        )
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
        self.values = rgaTreeList
            .map { $0.value }
            .filter { $0.isRemoved == false }
    }

    func next() -> CRDTElement? {
        defer {
            self.iteratorNext += 1
        }

        guard self.iteratorNext < self.values.count else {
            return nil
        }

        return self.values[self.iteratorNext]
    }
}

extension CRDTArray: CustomDebugStringConvertible {
    var debugDescription: String {
        self.toSortedJSON()
    }
}

/// Represents the size of a resource in bytes.
public struct DataSize {
    /// The size of the data in bytes.
    var data: Int

    /// The size of the metadata in bytes.
    var meta: Int

    /**
     * `addDataSizes` adds the size of a resource to the target resource.
     */
    mutating func addDataSizes(
        functionName: String = #function,
        others: DataSize...
    ) {
        for other in others {
            self.data += other.data
            self.meta += other.meta
        }
    }

    /**
     * `subDataSize` subtracts the size of a resource from the target resource.
     */
    mutating func subDataSize(others: DataSize...) {
        for other in others {
            self.data -= other.data
            self.meta -= other.meta
        }
    }

    /**
     * `totalDataSize` calculates the total size of a resource.
     */
    var totalDataSize: Int {
        return self.data + self.meta
    }
}

/// Represents the size of a document in bytes.
public struct DocSize {
    /// The size of the live document in bytes.
    var live: DataSize

    /// The size of the garbage collected data in bytes.
    var gc: DataSize

    /**
     * `totalDocSize` calculates the total size of a document.
     */
    var totalDocSize: Int {
        return self.gc.totalDataSize + self.live.totalDataSize
    }
}

extension DocSize: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.live == rhs.live && lhs.gc == rhs.gc
    }
}

extension DataSize: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data && lhs.meta == rhs.meta
    }
}
