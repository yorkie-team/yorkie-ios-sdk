/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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
 * `JSONDedupCounter` is a counter that counts unique actors using HyperLogLog
 * deduplication. Use ``add(_:)`` to record a unique actor visit. The ``value``
 * property returns an approximate cardinality estimate (~2 % error rate).
 *
 * ```swift
 * doc.update { root, _ in
 *     root.uv = JSONDedupCounter()
 *     (root.uv as? JSONDedupCounter)?.add("userId-abc")
 * }
 * ```
 *
 * Mirror of JS `DedupCounter` from `document/json/counter.ts`.
 */
public class JSONDedupCounter {
    private var context: ChangeContext?
    private var counter: CRDTCounter<Int32>?

    /// Creates a new dedup counter with an initial value of 0.
    public init() {}

    // MARK: – Internal wiring

    /// Links this proxy to a ``ChangeContext`` and the underlying CRDT counter.
    func initialize(context: ChangeContext, counter: CRDTCounter<Int32>) {
        self.context = context
        self.counter = counter
    }

    // MARK: – Public API

    /// The document-unique identifier of this counter.
    public var id: TimeTicket? {
        self.counter?.id
    }

    /// The current approximate unique-actor count.
    public var value: Int32 {
        self.counter?.value ?? 0
    }

    /// Records `actor` as a unique visitor.
    ///
    /// If `actor` has already been recorded the call is a no-op (HLL
    /// idempotency). Calling this before the counter has been initialized
    /// (i.e. outside a document update closure) throws.
    ///
    /// - Parameter actor: A non-empty string that uniquely identifies the actor.
    /// - Returns: `self` for chaining.
    /// - Throws: ``YorkieError`` when not yet initialized or when `actor` is empty.
    @discardableResult
    public func add(_ actor: String) throws -> Self {
        guard let context, let counter else {
            throw YorkieError(code: .errNotInitialized, message: "DedupCounter is not initialized yet")
        }
        guard !actor.isEmpty else {
            throw YorkieError(code: .errInvalidArgument, message: "actor is required")
        }

        let ticket = context.issueTimeTicket
        let primitive = Primitive(value: .integer(1), createdAt: ticket)

        try counter.increaseDedup(primitive, actor: actor)

        context.push(
            operation: IncreaseOperation(
                parentCreatedAt: counter.createdAt,
                value: primitive,
                executedAt: ticket,
                actor: actor
            )
        )

        return self
    }
}

extension JSONDedupCounter: CustomDebugStringConvertible {
    public var debugDescription: String {
        "\(self.value)"
    }
}
