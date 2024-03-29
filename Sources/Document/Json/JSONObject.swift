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
@dynamicMemberLookup
public class JSONObject {
    static let rootKey = "$"
    static let keySeparator = "."
    private let reservedCharacterForKey = JSONObject.keySeparator
    private func isValidKey(_ key: String) -> Bool {
        return key.contains(self.reservedCharacterForKey) == false
    }

    private var target: CRDTObject!
    private var context: ChangeContext!

    init() {}

    init(target: CRDTObject, context: ChangeContext) {
        self.target = target
        self.context = context
    }

    func set(_ values: [String: Any]) {
        for (key, value) in values {
            self.set(key: key, value: value)
        }
    }

    func set<T>(key: String, value: T) {
        guard self.isValidKey(key) else {
            assertionFailure("The key \(key) doesn't have the reserved characters: \(self.reservedCharacterForKey)")
            return
        }

        let ticket = self.context.issueTimeTicket

        if let optionalValue = value as? OptionalValue, optionalValue.isNil {
            self.setValueNull(key: key, ticket: ticket)
        } else if let value = value as? Bool {
            self.setValue(key: key, value: value, ticket: ticket)
        } else if let value = value as? Int32 {
            self.setValue(key: key, value: value, ticket: ticket)
        } else if let value = value as? Int64 {
            self.setValue(key: key, value: value, ticket: ticket)
        } else if let value = value as? Double {
            self.setValue(key: key, value: value, ticket: ticket)
        } else if let value = value as? String {
            self.setValue(key: key, value: value, ticket: ticket)
        } else if let value = value as? Data {
            self.setValue(key: key, value: value, ticket: ticket)
        } else if let value = value as? Date {
            self.setValue(key: key, value: value, ticket: ticket)
        } else if value is JSONObject {
            let object = CRDTObject(createdAt: ticket)
            self.setValue(key: key, value: object, ticket: ticket)
        } else if let value = value as? [String: Any] {
            self.set(key: key, value: JSONObject())
            let jsonObject = self.get(key: key) as? JSONObject
            jsonObject?.set(value)
        } else if let value = value as? JSONObjectable {
            self.set(key: key, value: JSONObject())
            let jsonObject = self.get(key: key) as? JSONObject
            jsonObject?.set(value.toJsonObject)
        } else if value is JSONArray {
            let array = CRDTArray(createdAt: ticket)
            self.setValue(key: key, value: array, ticket: ticket)
        } else if let value = value as? [Any] {
            let array = CRDTArray(createdAt: ticket)
            self.setValue(key: key, value: array, ticket: ticket)
            let jsonArray = self.get(key: key) as? JSONArray
            jsonArray?.append(values: value.toJsonArray)
        } else if let element = value as? JSONCounter<Int32>, let value = element.value as? Int32 {
            let counter = CRDTCounter<Int32>(value: value, createdAt: ticket)
            element.initialize(context: self.context, counter: counter)
            self.setValue(key: key, value: counter, ticket: ticket)
        } else if let element = value as? JSONCounter<Int64>, let value = element.value as? Int64 {
            let counter = CRDTCounter<Int64>(value: value, createdAt: ticket)
            element.initialize(context: self.context, counter: counter)
            self.setValue(key: key, value: counter, ticket: ticket)
        } else if let element = value as? JSONText {
            let text = CRDTText(rgaTreeSplit: RGATreeSplit(), createdAt: ticket)
            element.initialize(context: self.context, text: text)
            self.setValue(key: key, value: text, ticket: ticket)
        } else if let element = value as? JSONTree {
            guard let root = try? element.buildRoot(context) else {
                Logger.error("Can't build root!")
                assertionFailure()
                return
            }
            let tree = CRDTTree(root: root, createdAt: ticket)
            element.initialize(context: self.context, tree: tree)
            self.setValue(key: key, value: tree, ticket: ticket)
        } else {
            Logger.error("The value is not supported. - key: \(key): value: \(value)")
            assertionFailure()
        }
    }

    private func setToCRDTObject(key: String, value: CRDTElement) {
        let removed = self.target.set(key: key, value: value)
        self.context.registerElement(value, parent: self.target)
        if let removed {
            self.context.registerRemovedElement(removed)
        }
    }

    private func setPrimitive(key: String, value: PrimitiveValue, ticket: TimeTicket) {
        let primitive = Primitive(value: value, createdAt: context.issueTimeTicket)
        self.setToCRDTObject(key: key, value: primitive)

        let operation = SetOperation(key: key,
                                     value: primitive.deepcopy(),
                                     parentCreatedAt: self.target.createdAt,
                                     executedAt: ticket)
        self.context.push(operation: operation)
    }

    private func setValueNull(key: String, ticket: TimeTicket) {
        self.setPrimitive(key: key, value: .null, ticket: ticket)
    }

    private func setValue(key: String, value: Bool, ticket: TimeTicket) {
        self.setPrimitive(key: key, value: .boolean(value), ticket: ticket)
    }

    private func setValue(key: String, value: Int32, ticket: TimeTicket) {
        self.setPrimitive(key: key, value: .integer(value), ticket: ticket)
    }

    private func setValue(key: String, value: Int64, ticket: TimeTicket) {
        self.setPrimitive(key: key, value: .long(value), ticket: ticket)
    }

    private func setValue(key: String, value: Double, ticket: TimeTicket) {
        self.setPrimitive(key: key, value: .double(value), ticket: ticket)
    }

    private func setValue(key: String, value: String, ticket: TimeTicket) {
        self.setPrimitive(key: key, value: .string(value), ticket: ticket)
    }

    private func setValue(key: String, value: Data, ticket: TimeTicket) {
        self.setPrimitive(key: key, value: .bytes(value), ticket: ticket)
    }

    private func setValue(key: String, value: Date, ticket: TimeTicket) {
        self.setPrimitive(key: key, value: .date(value), ticket: ticket)
    }

    private func setValue(key: String, value: CRDTElement, ticket: TimeTicket) {
        self.setToCRDTObject(key: key, value: value)

        let operation = SetOperation(key: key,
                                     value: value.deepcopy(),
                                     parentCreatedAt: self.target.createdAt,
                                     executedAt: ticket)
        self.context.push(operation: operation)
    }

    public func get(key: String) -> Any? {
        guard self.isValidKey(key) else {
            assertionFailure("The key \(key) doesn't have the reserved characters: \(self.reservedCharacterForKey)")
            return nil
        }

        guard let value = self.target.get(key: key) else {
            Logger.error("The value does not exist. - key: \(key)")
            return nil
        }

        return toJSONElement(from: value)
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

    /**
     * `remove` deletes the value of the given key.
     */
    public func remove(key: String) {
        guard let removed = try? self.target.deleteByKey(key: key, executedAt: self.context.issueTimeTicket) else {
            return
        }

        let removeOperation = RemoveOperation(parentCreatedAt: self.target.createdAt,
                                              createdAt: removed.createdAt,
                                              executedAt: self.context.issueTimeTicket)
        self.context.push(operation: removeOperation)
        self.context.registerRemovedElement(removed)
    }

    public subscript(key: String) -> Any? {
        get {
            self.get(key: key)
        }
        set {
            self.set(key: key, value: newValue)
        }
    }

    subscript(keyPath keyPath: String) -> Any? {
        self.get(keyPath: keyPath)
    }

    /**
     * `id` returns the ID(time ticket) of this Object.
     */
    public func getID() -> TimeTicket {
        self.target.createdAt
    }

    /**
     * `toJSON` returns the JSON encoding of this object.
     */
    func toJSON() -> String {
        self.target.toJSON()
    }

    private func toSortedJSON() -> String {
        self.target.toSortedJSON()
    }

    var iterator: [(key: String, value: CRDTElement)] {
        return self.target.map { (key: String, value: CRDTElement) in
            (key, value)
        }
    }
}

extension JSONObject: CustomStringConvertible {
    public var description: String {
        self.toJSON()
    }
}

extension JSONObject: CustomDebugStringConvertible {
    public var debugDescription: String {
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

public extension JSONObject {
    subscript(dynamicMember member: String) -> Any? {
        get {
            self.get(key: member)
        }
        set {
            self.set(key: member, value: newValue)
        }
    }
}
