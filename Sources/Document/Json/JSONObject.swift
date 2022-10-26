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

    func set(_ values: [String: Any]) {
        values.forEach { (key: String, value: Any) in
            if let value = value as? [String: Any] {
                set(key: key, value: JSONObject())
                let jsonObject = get(key: key) as? JSONObject
                jsonObject?.set(value)
//            } else if let value = value as? [Any] {
                // It will be implemented soon.
            } else {
                set(key: key, value: value)
            }
        }
    }

    func set(key: String, values: [String: Any]) {
        self.set(key: key, value: JSONObject())
        let jsonObject = self.get(key: key) as? JSONObject
        jsonObject?.set(values)
    }

    func set<T>(key: String, value: T) {
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
        } else if value is JSONArray {
            let array = CRDTArray(createdAt: self.context.issueTimeTicket())
            self.setValue(key: key, value: array)
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

    func get(keyPath: String) -> Any? {
        let keys = keyPath.components(separatedBy: ".")
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
        let value = try? self.target.get(key: key)
        if let value = value as? Primitive {
            switch value.value {
            case .null:
                return nil
            case .boolean(let result):
                return result
            case .integer(let result):
                return result
            case .long(let result):
                return result
            case .double(let result):
                return result
            case .string(let result):
                return result
            case .bytes(let result):
                return result
            case .date(let result):
                return result
            }
        } else if let object = value as? CRDTObject {
            return JSONObject(target: object, context: self.context)
        } else if let array = value as? CRDTArray {
            return JSONArray(target: array, changeContext: self.context)
        } else {
            Logger.error("The value does not exist. - key: \(key)")
            return nil
        }
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

    subscript(key key: String) -> Any? {
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
