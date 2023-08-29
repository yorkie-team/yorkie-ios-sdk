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

class ObjectDataHandler {
    let target: CRDTObject
    let context: ChangeContext

    init(target: CRDTObject, context: ChangeContext) {
        self.target = target
        self.context = context
    }

    func set<T>(key: String, value: T) {
        let ticket = self.context.issueTimeTicket

        if let value = value as? Bool {
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
        } else if let value = value as? CRDTObject {
            self.setValue(key: key, value: value, ticket: ticket)
        } else if let value = value as? CRDTArray {
            self.setValue(key: key, value: value, ticket: ticket)
        } else if let value = value as? CRDTCounter<Int32> {
            self.setValue(key: key, value: value, ticket: ticket)
        } else if let value = value as? CRDTCounter<Int64> {
            self.setValue(key: key, value: value, ticket: ticket)
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

    private func setPrimitive(key: String, value: PrimitiveValue, ticket: TimeTicket) {
        let primitive = Primitive(value: value, createdAt: ticket)
        self.setAndRegister(key: key, value: primitive)

        let operation = SetOperation(key: key,
                                     value: primitive,
                                     parentCreatedAt: self.target.createdAt,
                                     executedAt: ticket)
        self.context.push(operation: operation)
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

    private func setValue(key: String, value: CRDTObject, ticket: TimeTicket) {
        self.setAndRegister(key: key, value: value)

        let operation = SetOperation(key: key,
                                     value: value.deepcopy(),
                                     parentCreatedAt: self.target.createdAt,
                                     executedAt: ticket)
        self.context.push(operation: operation)
    }

    private func setValue(key: String, value: CRDTArray, ticket: TimeTicket) {
        self.setAndRegister(key: key, value: value)

        let operation = SetOperation(key: key,
                                     value: value,
                                     parentCreatedAt: self.target.createdAt,
                                     executedAt: ticket)
        self.context.push(operation: operation)
    }

    private func setValue<T: YorkieCountable>(key: String, value: CRDTCounter<T>, ticket: TimeTicket) {
        self.setAndRegister(key: key, value: value)

        let operation = SetOperation(key: key,
                                     value: value,
                                     parentCreatedAt: self.target.createdAt,
                                     executedAt: ticket)
        self.context.push(operation: operation)
    }

    func get(key: String) throws -> Any? {
        let value = self.target.get(key: key)
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
        } else if let result = value as? CRDTObject {
            return result
        } else if let result = value as? CRDTArray {
            return result
        } else {
            let log = "The value does not exist. - key: \(key)"
            Logger.error(log)
            throw YorkieError.unexpected(message: log)
        }
    }

    func remove(key: String) throws {
        guard let removed = try? self.target.deleteByKey(key: key, executedAt: self.context.issueTimeTicket) else {
            return
        }

        let removeOperation = RemoveOperation(parentCreatedAt: self.target.createdAt,
                                              createdAt: removed.createdAt,
                                              executedAt: self.context.issueTimeTicket)
        self.context.push(operation: removeOperation)
        self.context.registerRemovedElement(removed)
    }
}
