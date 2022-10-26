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
 * `JSONObject` represents a JSON object, but unlike regular JSON, it has time
 * tickets created by a logical clock to resolve conflicts.
 */
class JSONObject {
    var target: CRDTObject!
    var context: ChangeContext!

    init() {}

    init(target: CRDTObject, context: ChangeContext) {
        self.target = target
        self.context = context
    }

    private static let keySeparator = "."
    private let reservedCharacterForKey = JSONObject.keySeparator
    private func isValidKey(_ key: String) -> Bool {
        return key.contains(self.reservedCharacterForKey) == false
    }

    func set(_ values: [String: Any]) {
        values.forEach { (key: String, value: Any) in
            if let value = value as? [String: Any] {
                set(key: key, value: JSONObject())
                let jsonObject = get(key: key) as? JSONObject
                jsonObject?.set(value)
            } else if let value = value as? [Any] {
                set(key: key, value: JSONArray())
                let jsonArray = get(key: key) as? JSONArray
                jsonArray?.push(value)
            } else {
                set(key: key, value: value)
            }
        }
    }

    func set<T>(key: String, value: T) {
        guard self.isValidKey(key) else {
            Logger.error("The key \(key) doesn't have the reserved characters: \(self.reservedCharacterForKey)")
            return
        }

        if let value = value as? Bool {
            self.setValue(key: key, value: value)
        } else if let value = value as? Int32 {
            self.setValue(key: key, value: value)
        } else if let value = value as? Int64 {
            self.setValue(key: key, value: value)
        } else if let value = value as? Double {
            self.setValue(key: key, value: value)
        } else if let value = value as? String {
            self.setValue(key: key, value: value)
        } else if let value = value as? Data {
            self.setValue(key: key, value: value)
        } else if let value = value as? Date {
            self.setValue(key: key, value: value)
        } else if value is JSONObject {
            let object = CRDTObject(createdAt: self.context.issueTimeTicket())
            self.setValue(key: key, value: object)
        } else if let value = value as? [String: Any] {
            self.set(key: key, value: JSONObject())
            let jsonObject = self.get(key: key) as? JSONObject
            jsonObject?.set(value)
        } else if value is JSONArray {
            let array = CRDTArray(createdAt: self.context.issueTimeTicket())
            self.setValue(key: key, value: array)
        } else if let value = value as? [Any] {
            let array = CRDTArray(createdAt: self.context.issueTimeTicket())
            self.setValue(key: key, value: array)
            let jsonArray = self.get(key: key) as? JSONArray
            jsonArray?.append(values: value)
        } else {
            Logger.error("The value is not supported. - key: \(key): value: \(value)")
        }
    }

    private func setAndRegister(key: String, value: CRDTElement) {
        let removed = self.target.set(key: key, value: value)
        self.context.registerElement(value, parent: self.target)
        if let removed {
            self.context.registerRemovedElement(removed)
        }
    }

    private func setPrimitive(key: String, value: PrimitiveValue) {
        let primitive = Primitive(value: value, createdAt: context.issueTimeTicket())
        self.setAndRegister(key: key, value: primitive)

        let operation = SetOperation(key: key,
                                     value: primitive,
                                     parentCreatedAt: self.target.getCreatedAt(),
                                     executedAt: self.context.issueTimeTicket())
        self.context.push(operation: operation)
    }

    private func setValue(key: String, value: Bool) {
        self.setPrimitive(key: key, value: .boolean(value))
    }

    private func setValue(key: String, value: Int32) {
        self.setPrimitive(key: key, value: .integer(value))
    }

    private func setValue(key: String, value: Int64) {
        self.setPrimitive(key: key, value: .long(value))
    }

    private func setValue(key: String, value: Double) {
        self.setPrimitive(key: key, value: .double(value))
    }

    private func setValue(key: String, value: String) {
        self.setPrimitive(key: key, value: .string(value))
    }

    private func setValue(key: String, value: Data) {
        self.setPrimitive(key: key, value: .bytes(value))
    }

    private func setValue(key: String, value: Date) {
        self.setPrimitive(key: key, value: .date(value))
    }

    private func setValue(key: String, value: CRDTObject) {
        self.setAndRegister(key: key, value: value)

        let operation = SetOperation(key: key,
                                     value: value.deepcopy(),
                                     parentCreatedAt: self.target.getCreatedAt(),
                                     executedAt: self.context.issueTimeTicket())
        self.context.push(operation: operation)
    }

    private func setValue(key: String, value: CRDTArray) {
        self.setAndRegister(key: key, value: value)

        let operation = SetOperation(key: key,
                                     value: value,
                                     parentCreatedAt: self.target.getCreatedAt(),
                                     executedAt: self.context.issueTimeTicket())
        self.context.push(operation: operation)
    }

    /// Search the value by separating the key with dot and return it.
    func get(keyPath: String) -> Any? {
        let keys = keyPath.components(separatedBy: JSONObject.keySeparator)
        var nested: JSONObject = self
        for key in keys {
            let value = nested.get(key: key)
            if let jsonObject = value as? JSONObject {
                nested = jsonObject
            } else {
                return value
            }
        }

        return nested
    }

    func get(key: String) -> Any? {
        guard let value = try? self.target.get(key: key) else {
            Logger.error("The value does not exist. - key: \(key)")
            return nil
        }

        return toJSONElement(from: value)
    }

    func remove(key: String) {
        Logger.trivial("obj[\(key)]")

        let removed = try? self.target.remove(key: key, executedAt: self.context.issueTimeTicket())
        guard let removed else {
            return
        }

        let removeOperation = RemoveOperation(parentCreatedAt: self.target.getCreatedAt(),
                                              createdAt: removed.getCreatedAt(),
                                              executedAt: self.context.issueTimeTicket())
        self.context.push(operation: removeOperation)
        self.context.registerRemovedElement(removed)
    }

    subscript(keyPath keyPath: String) -> Any? {
        self.get(keyPath: keyPath)
    }

    subscript(key: String) -> Any? {
        get {
            self.get(key: key)
        }
        set {
            self.set(key: key, value: newValue)
        }
    }

    /**
     * `getID` returns the ID(time ticket) of this Object.
     */
    func getID() -> TimeTicket {
        self.target.getCreatedAt()
    }

    /**
     * `toJSON` returns the JSON encoding of this object.
     */
    func toJson() -> String {
        self.target.toJSON()
    }

    private func toSortedJSON() -> String {
        self.target.toSortedJSON()
    }
}

extension JSONObject: CustomStringConvertible {
    var description: String {
        self.toJson()
    }
}

extension JSONObject: CustomDebugStringConvertible {
    var debugDescription: String {
        self.toSortedJSON()
    }
}

extension JSONObject: JSONDatable {
    var changeContext: ChangeContext {
        self.context
    }

    var crdtElement: CRDTElement {
        self.target
    }
}

extension JSONObject: Sequence {
    typealias Element = (key: String, value: CRDTElement)

    func makeIterator() -> JSONObjectIterator {
        return JSONObjectIterator(self.target)
    }
}

class JSONObjectIterator: IteratorProtocol {
    private var values: [(key: String, value: CRDTElement)]
    private var iteratorNext: Int = 0

    init(_ crdtObject: CRDTObject) {
        self.values = []
        crdtObject.forEach { (key: String, value: CRDTElement) in
            values.append((key, value))
        }
    }

    func next() -> (key: String, value: CRDTElement)? {
        defer {
            self.iteratorNext += 1
        }

        guard self.iteratorNext < self.values.count else {
            return nil
        }

        return self.values[self.iteratorNext]
    }
}
