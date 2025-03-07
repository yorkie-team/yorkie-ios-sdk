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
 * `JSONCounter` is a custom data type that is used to counter.
 */
public class JSONCounter<T: YorkieCountable> {
    private let _value: T
    private var context: ChangeContext?
    private var counter: CRDTCounter<T>?

    public init(value: T) {
        self._value = value
    }

    /**
     * `initialize` initialize this text with context and internal text.
     */
    func initialize(context: ChangeContext, counter: CRDTCounter<T>) {
        self.context = context
        self.counter = counter
    }

    /**
     * `id` returns the ID of this text.
     */
    public var id: TimeTicket? {
        self.counter?.id
    }

    /**
     * `value` returns the value of this counter;
     * @internal
     */
    public var value: some YorkieCountable {
        guard let counter else {
            return self._value
        }

        return counter.value
    }

    /**
     * `increase` increases numeric data.
     */
    @discardableResult
    public func increase(value: any BinaryInteger) -> Self {
        do {
            return try self.increaseThrows(value: value)
        } catch {
            Logger.critical(String(describing: error))
            return self
        }
    }

    @discardableResult
    private func increaseThrows(value: any BinaryInteger) throws -> Self {
        guard let context, let counter else {
            let log = "Counter is not initialized yet"
            throw YorkieError(code: .errNotInitialized, message: log)
        }

        guard let primitiveValue = Primitive.type(of: value) else {
            let log = "Unsupported type of value: \(type(of: T.self))"
            throw YorkieError(code: .errInvalidType, message: log)
        }

        let ticket = context.issueTimeTicket
        let primitive = Primitive(value: primitiveValue, createdAt: ticket)

        guard primitive.isNumericType else {
            let log = "Unsupported type of value: \(type(of: T.self))"
            throw YorkieError(code: .errInvalidType, message: log)
        }

        try counter.increase(primitive)

        context.push(operation: IncreaseOperation(parentCreatedAt: counter.createdAt, value: primitive, executedAt: ticket))

        return self
    }

    @discardableResult
    public func increase(value: any BinaryFloatingPoint) -> Self {
        self.increase(value: T(value))
    }
}

extension JSONCounter: CustomDebugStringConvertible {
    public var debugDescription: String {
        "\(self._value)"
    }
}
