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

/**
 * `JSONArray` represents JSON array, but unlike regular JSON, it has time
 * tickets created by a logical clock to resolve conflicts.
 */
class JSONArray {
    static let notAppend = -1
    static let notFound = -1

    var target: CRDTArray!
    var context: ChangeContext!

    init() {}

    init(target: CRDTArray, changeContext: ChangeContext) {
        self.target = target
        self.context = changeContext
    }

    /**
     * `getID` returns the ID, `TimeTicket` of this Object.
     */
    func getID() -> TimeTicket {
        return self.target.getCreatedAt()
    }

    /**
     * `getElementByID` returns the element for the given ID.
     */
    func getElement(byID createdAt: TimeTicket) -> Any? {
        guard let value = try? target.get(createdAt: createdAt) else {
            Logger.error("The value does not exist. - createdAt: \(createdAt)")
            return nil
        }

        return toWrappedElement(from: value)
    }

    /**
     * `getElement` returns the element for the given index.
     */
    func getElement(byIndex index: Int) -> Any? {
        guard let value = try? target.get(index: index) else {
            Logger.error("The value does not exist. - index: \(index)")
            return nil
        }

        return toWrappedElement(from: value)
    }

    /**
     * `getLast` returns the last element of this array.
     */
    func getLast() -> Any? {
        let value = self.target.getLast()
        return toWrappedElement(from: value)
    }

    /**
     * `remove` removes the element of the given ID.
     */
    func remove(byID createdAt: TimeTicket) throws -> Any? {
        let removed = try removeInternal(byID: createdAt)
        return toWrappedElement(from: removed)
    }

    /**
     * `insertAfter` inserts a value after the given previous element.
     */
    func insertAfter(previousID: TimeTicket, value: Any) throws -> Any? {
        let inserted = try insertAfterInternal(previousCreatedAt: previousID, value: value)
        return toWrappedElement(from: inserted)
    }

    /**
     * `insertBefore` inserts a value before the given next element.
     */
    func insertBefore(nextID: TimeTicket, value: Any) throws -> Any? {
        let inserted = try insertBeforeInternal(nextCreatedAt: nextID, value: value)
        return toWrappedElement(from: inserted)
    }

    /**
     * `moveBefore` moves the element before the given next element.
     */
    func moveBefore(nextID: TimeTicket, id: TimeTicket) throws {
        try self.moveBeforeInternal(nextCreatedAt: nextID, createdAt: id)
    }

    /**
     * `moveAfter` moves the element after the given previous element.
     */
    func moveAfter(previousID: TimeTicket, id: TimeTicket) throws {
        try self.moveAfterInternal(previousCreatedAt: previousID, createdAt: id)
    }

    /**
     * `moveFront` moves the element before the first element.
     */
    func moveFront(id: TimeTicket) throws {
        try self.moveFrontInternal(createdAt: id)
    }

    /**
     * `moveLast` moves the element after the last element.
     */
    func moveLast(id: TimeTicket) throws {
        try self.moveLastInternal(createdAt: id)
    }

    subscript(index: Int) -> Any? {
        guard let value = try? self.target.get(index: index) else {
            return nil
        }
        return toJSONElement(from: value)
    }

    @discardableResult
    func append(_ value: Any) -> Int {
        self.push(value)
    }

    func append(values: [Any]) {
        self.push(values: values)
    }

    func push(values: [Any]) {
        values.forEach { value in
            if let value = value as? [String: Any] {
                let appendedIndex = push(JSONObject())
                let jsonObject = self[appendedIndex] as? JSONObject
                jsonObject?.set(value)
            } else if let value = value as? [Any] {
                let appendedIndex = push(JSONArray())
                let jsonArray = self[appendedIndex] as? JSONArray
                jsonArray?.push(value)
            } else {
                push(value)
            }
        }
    }

    @discardableResult
    func push(_ value: Any) -> Int {
        self.pushInternal(value)
    }

    func length() -> Int {
        return self.target.length
    }

    func remove(index: Int) -> CRDTElement? {
        Logger.trivial("array[\(index)]")
        return self.removeInternal(byIndex: index)
    }

    /**
     * `pushInternal` pushes the value to the target array.
     */
    @discardableResult
    private func pushInternal(_ value: Any) -> Int {
        let appendedElement = try? self.insertAfterInternal(previousCreatedAt: self.target.getLastCreatedAt(), value: value)
        guard appendedElement != nil else {
            return Self.notAppend
        }
        return self.target.length - 1
    }

    /**
     * `moveBeforeInternal` moves the given `createdAt` element
     * after the previously created element.
     */
    private func moveBeforeInternal(nextCreatedAt: TimeTicket, createdAt: TimeTicket) throws {
        let ticket = self.context.issueTimeTicket()
        let previousCreatedAt = try target.getPreviousCreatedAt(createdAt: nextCreatedAt)
        try self.target.move(createdAt: createdAt, afterCreatedAt: previousCreatedAt, executedAt: ticket)
        let operation = MoveOperation(parentCreatedAt: target.getCreatedAt(), previousCreatedAt: previousCreatedAt, createdAt: createdAt, executedAt: ticket)
        self.context.push(operation: operation)
    }

    /**
     * `moveAfterInternal` moves the given `createdAt` element
     * after the specific element.
     */
    private func moveAfterInternal(previousCreatedAt: TimeTicket, createdAt: TimeTicket) throws {
        let ticket = self.context.issueTimeTicket()
        try self.target.move(createdAt: createdAt, afterCreatedAt: previousCreatedAt, executedAt: ticket)
        let operation = MoveOperation(parentCreatedAt: target.getCreatedAt(), previousCreatedAt: previousCreatedAt, createdAt: createdAt, executedAt: ticket)
        self.context.push(operation: operation)
    }

    /**
     * `moveFrontInternal` moves the given `createdAt` element
     * at the first of array.
     */
    private func moveFrontInternal(createdAt: TimeTicket) throws {
        let ticket = self.context.issueTimeTicket()
        let head = self.target.getHead()
        try self.target.move(createdAt: createdAt, afterCreatedAt: head.getCreatedAt(), executedAt: ticket)
        let operation = MoveOperation(parentCreatedAt: target.getCreatedAt(), previousCreatedAt: head.getCreatedAt(), createdAt: createdAt, executedAt: ticket)
        self.context.push(operation: operation)
    }

    /**
     * `moveAfterInternal` moves the given `createdAt` element
     * at the last of array.
     */
    private func moveLastInternal(createdAt: TimeTicket) throws {
        let ticket = self.context.issueTimeTicket()
        let last = self.target.getLastCreatedAt()
        try self.target.move(createdAt: createdAt, afterCreatedAt: last, executedAt: ticket)
        let operation = MoveOperation(parentCreatedAt: self.target.getCreatedAt(), previousCreatedAt: last, createdAt: createdAt, executedAt: ticket)
        self.context.push(operation: operation)
    }

    /**
     * `insertAfterInternal` inserts the value after the previously created element.
     */
    @discardableResult
    private func insertAfterInternal(previousCreatedAt: TimeTicket, value: Any) throws -> CRDTElement {
        let ticket = self.context.issueTimeTicket()

        if let value = Primitive.type(of: value) {
            let primitive = Primitive(value: value, createdAt: ticket)
            let clone = primitive.deepcopy()

            try self.target.insert(value: clone, afterCreatedAt: previousCreatedAt)
            self.context.registerElement(clone, parent: self.target)

            let operation = AddOperation(parentCreatedAt: self.target.getCreatedAt(), previousCreatedAt: previousCreatedAt, value: primitive, executedAt: ticket)
            self.context.push(operation: operation)

            return primitive
        } else if let array = value as? [Any] {
            let crdtArray = CRDTArray(createdAt: ticket)
            guard let clone = crdtArray.deepcopy() as? CRDTArray else {
                throw YorkieError.unexpected(message: "Failed to cast array.deepcopy() to CRDTArray")
            }

            try self.target.insert(value: clone, afterCreatedAt: previousCreatedAt)
            self.context.registerElement(clone, parent: self.target)

            let operation = AddOperation(parentCreatedAt: self.target.getCreatedAt(), previousCreatedAt: previousCreatedAt, value: crdtArray, executedAt: ticket)
            self.context.push(operation: operation)

            let child = JSONArray(target: clone, changeContext: self.context)
            for element in array {
                child.pushInternal(element)
            }
            return crdtArray
        } else if let jsonObject = value as? JSONObject {
            let crdtObject = CRDTObject(createdAt: ticket)

            try self.target.insert(value: crdtObject, afterCreatedAt: previousCreatedAt)
            self.context.registerElement(crdtObject, parent: self.target)

            let operation = AddOperation(parentCreatedAt: self.target.getCreatedAt(), previousCreatedAt: previousCreatedAt, value: crdtObject, executedAt: ticket)
            self.context.push(operation: operation)

            let child = JSONObject(target: crdtObject, context: self.context)
            for (key, value) in jsonObject {
                child.set(key: key, value: value)
            }
            return crdtObject
        }

        throw YorkieError.unimplemented(message: "Unsupported type of value: \(type(of: value))")
    }

    /**
     * `insertBeforeInternal` inserts the value before the previously created element.
     */
    private func insertBeforeInternal(nextCreatedAt: TimeTicket, value: Any) throws -> CRDTElement {
        try self.insertAfterInternal(previousCreatedAt: self.target.getPreviousCreatedAt(createdAt: nextCreatedAt), value: value)
    }

    /**
     * `removeInternal` deletes target element of given index.
     */
    @discardableResult
    private func removeInternal(byIndex index: Int) -> CRDTElement? {
        let ticket = self.context.issueTimeTicket()
        let removed = try? self.target.remove(index: index, executedAt: ticket)

        guard let removed else {
            return nil
        }

        let operation = RemoveOperation(parentCreatedAt: target.getCreatedAt(), createdAt: removed.getCreatedAt(), executedAt: ticket)
        self.context.push(operation: operation)
        self.context.registerRemovedElement(removed)
        return removed
    }

    /**
     * `removeInternal` deletes the element of the given ID.
     */
    @discardableResult
    private func removeInternal(byID createdAt: TimeTicket) throws -> CRDTElement {
        let ticket = self.context.issueTimeTicket()
        let removed = try self.target.remove(createdAt: createdAt, executedAt: ticket)

        let operation = RemoveOperation(parentCreatedAt: self.target.getCreatedAt(), createdAt: removed.getCreatedAt(), executedAt: ticket)
        self.context.push(operation: operation)
        self.context.registerRemovedElement(removed)

        return removed
    }

    /**
     * `splice` is a method to remove elements from the array.
     */
    func splice(start: Int, deleteCount: Int? = nil, items: Any...) throws -> [Any] {
        let length = self.target.length
        let from = start >= 0 ? Swift.min(start, length) : Swift.max(length + start, 0)

        let to: Int
        if let deleteCount {
            if deleteCount < 0 {
                to = from
            } else {
                to = Swift.min(from + deleteCount, length)
            }
        } else {
            to = length
        }

        var removeds: [Any] = []

        for _ in from ..< to {
            if let removed = removeInternal(byIndex: from),
               let element = toJSONElement(from: removed)
            {
                removeds.append(element)
            }
        }

        if items.isEmpty == false {
            var previousID: TimeTicket
            if from == 0 {
                previousID = self.target.getHead().getID()
            } else {
                previousID = try self.target.get(index: from - 1).getID()
            }

            for item in items {
                let newElement = try insertAfterInternal(previousCreatedAt: previousID, value: item)
                previousID = newElement.getID()
            }
        }

        return removeds
    }

    private func adaptedFromIndex(length: Int, fromIndex: Int?) -> Int {
        let result: Int
        if let fromIndex {
            if fromIndex < 0 {
                result = Swift.max(fromIndex + length, 0)
            } else {
                result = fromIndex
            }
        } else {
            result = 0
        }

        return result
    }

    /**
     * `includes` returns true if the given element is in the array.
     */
    func includes(searchElement: Any, fromIndex: Int? = nil) -> Bool {
        let length = self.target.length

        let from = self.adaptedFromIndex(length: length, fromIndex: fromIndex)

        if from >= length {
            return false
        }

        if let searchValue = Primitive.type(of: searchElement) {
            let array = self.target.compactMap { toJSONElement(from: $0) }
            let searchRange = Array(array[from...])
            return searchRange.contains { element in
                guard let value = Primitive.type(of: element) else {
                    return false
                }

                return value == searchValue
            }
        }

        guard let searchId = (searchElement as? JSONDatable)?.crdtElement.getID() else {
            return false
        }

        for index in from ..< length {
            guard let id = try? target.get(index: index).getID() else {
                continue
            }
            if id == searchId {
                return true
            }
        }

        return false
    }

    /**
     * `indexOf` returns the index of the given element.
     */
    func indexOf(searchElement: Any, fromIndex: Int? = nil) -> Int {
        let length = self.target.length
        let from = self.adaptedFromIndex(length: length, fromIndex: fromIndex)

        if from >= length {
            return Self.notFound
        }

        if let searchValue = Primitive.type(of: searchElement) {
            let array = self.target.compactMap { toJSONElement(from: $0) }
            let searchRange = Array(array[from...])
            return searchRange.firstIndex { element in
                guard let value = Primitive.type(of: element) else {
                    return false
                }

                return value == searchValue

            } ?? Self.notFound
        }

        guard let searchId = (searchElement as? JSONDatable)?.crdtElement.getID() else {
            return Self.notFound
        }

        for index in from ..< length {
            guard let id = try? target.get(index: index).getID() else {
                continue
            }
            if id == searchId {
                return index
            }
        }
        return Self.notFound
    }

    /**
     * `lastIndexOf` returns the last index of the given element.
     */
    func lastIndexOf(searchElement: Any, fromIndex: Int? = nil) -> Int {
        let length = self.target.length

        let from: Int
        if let fromIndex {
            if fromIndex >= length {
                from = length - 1
            } else {
                from = fromIndex < 0 ? fromIndex + length : fromIndex
            }
        } else {
            from = length - 1
        }

        if from < 0 {
            return Self.notFound
        }

        if let searchValue = Primitive.type(of: searchElement) {
            let array = self.target.compactMap { toJSONElement(from: $0) }
            let searchRange = Array(array[0 ... from])
            return searchRange.lastIndex { element in
                guard let value = Primitive.type(of: element) else {
                    return false
                }

                return value == searchValue

            } ?? Self.notFound
        }

        guard let searchId = (searchElement as? JSONDatable)?.crdtElement.getID() else {
            return Self.notFound
        }

        for index in stride(from: from, to: 1, by: -1) {
            guard let id = try? self.target.get(index: index).getID() else {
                continue
            }

            if id == searchId {
                return index
            }
        }
        return Self.notFound
    }
}

extension JSONArray: JSONDatable {
    var changeContext: ChangeContext {
        self.context
    }

    var crdtElement: CRDTElement {
        self.target
    }
}

extension JSONArray: Sequence {
    typealias Element = Any

    func makeIterator() -> JSONArrayIterator {
        return JSONArrayIterator(self.target, self.context)
    }
}

class JSONArrayIterator: IteratorProtocol {
    private var values: [CRDTElement]
    private var iteratorNext: Int = 0
    private let context: ChangeContext

    init(_ crdtArray: CRDTArray, _ context: ChangeContext) {
        self.context = context
        self.values = []
        crdtArray.forEach { element in
            values.append(element)
        }
    }

    func next() -> Any? {
        defer {
            self.iteratorNext += 1
        }

        guard self.iteratorNext < self.values.count else {
            return nil
        }

        let value = self.values[self.iteratorNext]
        return ElementConverter.toWrappedElement(from: value, context: self.context)
    }
}
