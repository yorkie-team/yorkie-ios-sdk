/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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

import XCTest
@testable import Yorkie

func withTwoClientsAndDocuments(_ title: String,
                                mockingEnabled: Bool = false,
                                syncMode: SyncMode = .manual,
                                detachDocuments: Bool = true,
                                callback: (Client, Document, Client, Document) async throws -> Void) async throws
{
    let rpcAddress = "http://localhost:8080"

    let docKey = "\(Date().description)-\(title)".toDocKey

    let c1 = Client(rpcAddress, isMockingEnabled: mockingEnabled)
    let c2 = Client(rpcAddress, isMockingEnabled: mockingEnabled)

    try await c1.activate()
    try await c2.activate()

    let d1 = Document(key: docKey)
    let d2 = Document(key: docKey)

    try await c1.attach(d1, [:], syncMode)
    try await c2.attach(d2, [:], syncMode)

    try await callback(c1, d1, c2, d2)

    if detachDocuments {
        try await c1.detach(d1)
        try await c2.detach(d2)

        try await c1.deactivate()
        try await c2.deactivate()
    }
}

protocol OperationInfoForDebug {}

struct TreeEditOpInfoForDebug: OperationInfoForDebug {
    let from: Int?
    let to: Int?
    let value: [any JSONTreeNode]?
    let fromPath: [Int]?
    let toPath: [Int]?

    func compare(_ operation: TreeEditOpInfo) {
        if let value = from {
            XCTAssertEqual(value, operation.from)
        }
        if let value = to {
            XCTAssertEqual(value, operation.to)
        }
        if let value = value {
            XCTAssertEqual(value.count, operation.value.count)
            if operation.value.count - 1 >= 0 {
                for idx in 0 ... operation.value.count - 1 {
                    if let exp = value[idx] as? JSONTreeTextNode, let oper = operation.value[idx] as? JSONTreeTextNode {
                        XCTAssertEqual(exp, oper)
                    } else if let exp = value[idx] as? JSONTreeElementNode, let oper = operation.value[idx] as? JSONTreeElementNode {
                        XCTAssertEqual(exp, oper)
                    } else {
                        XCTAssertFalse(true)
                    }
                }
            }
        }
        if let value = fromPath {
            XCTAssertEqual(value, operation.fromPath)
        }
        if let value = toPath {
            XCTAssertEqual(value, operation.toPath)
        }
    }
}

struct TreeStyleOpInfoForDebug: OperationInfoForDebug {
    let from: Int?
    let to: Int?
    let value: TreeStyleOpValue?
    let fromPath: [Int]?
    let toPath: [Int]?

    func compare(_ operation: TreeStyleOpInfo) {
        if let value = from {
            XCTAssertEqual(value, operation.from)
        }
        if let value = to {
            XCTAssertEqual(value, operation.to)
        }
        if let value = value {
            XCTAssertEqual(value, operation.value)
        }
        if let value = fromPath {
            XCTAssertEqual(value, operation.fromPath)
        }
        if let value = toPath {
            XCTAssertEqual(value, operation.toPath)
        }
    }
}

func subscribeDocs(_ d1: Document, _ d2: Document, _ d1Expected: [any OperationInfoForDebug]?, _ d2Expected: [any OperationInfoForDebug]?) async {
    var d1Operations: [any OperationInfo] = []
    var d1Index = 0

    await d1.subscribe("$.t") { event, _ in
        if let event = event as? LocalChangeEvent {
            d1Operations.append(contentsOf: event.value.operations)
        } else if let event = event as? RemoteChangeEvent {
            d1Operations.append(contentsOf: event.value.operations)
        }

        while d1Index <= d1Operations.count - 1 {
            if let d1Expected, let expected = d1Expected[safe: d1Index] as? TreeEditOpInfoForDebug, let operation = d1Operations[safe: d1Index] as? TreeEditOpInfo {
                expected.compare(operation)
            } else if let d1Expected, let expected = d1Expected[safe: d1Index] as? TreeStyleOpInfoForDebug, let operation = d1Operations[safe: d1Index] as? TreeStyleOpInfo {
                expected.compare(operation)
            }

            d1Index += 1
        }
    }

    var d2Operations: [any OperationInfo] = []
    var d2Index = 0

    await d2.subscribe("$.t") { event, _ in
        if let event = event as? LocalChangeEvent {
            d2Operations.append(contentsOf: event.value.operations.compactMap { $0 as? TreeEditOpInfo })
        } else if let event = event as? RemoteChangeEvent {
            d2Operations.append(contentsOf: event.value.operations.compactMap { $0 as? TreeEditOpInfo })
        }

        while d2Index <= d2Operations.count - 1 {
            if let d2Expected, let expected = d2Expected[safe: d2Index] as? TreeEditOpInfoForDebug, let operation = d2Operations[safe: d2Index] as? TreeEditOpInfo {
                expected.compare(operation)
            } else if let d2Expected, let expected = d2Expected[safe: d1Index] as? TreeStyleOpInfoForDebug, let operation = d2Operations[safe: d1Index] as? TreeStyleOpInfo {
                expected.compare(operation)
            }

            d2Index += 1
        }
    }
}

class EventCollector<T: Equatable> {
    private let queue = DispatchQueue(label: "com.yorkie.eventcollector", attributes: .concurrent)
    private var _values: [T] = []

    let doc: Document
    var values: [T] {
        self.queue.sync { self._values }
    }

    var count: Int {
        return self.values.count
    }

    init(doc: Document) {
        self.doc = doc
    }

    func add(event: T) {
        self.queue.async(flags: .barrier) {
            self._values.append(event)
        }
    }

    func asyncStream() -> AsyncStream<T> {
        return AsyncStream<T> { continuation in
            for value in self.values {
                continuation.yield(value)
            }
            continuation.finish()
        }
    }

    func verifyNthValue(at nth: Int, isEqualTo targetValue: T) async {
        if nth > self.values.count {
            XCTFail("Expected \(nth)th value: \(targetValue), but only received \(self.values.count) values")
            return
        }

        var counter = 0
        for await value in self.asyncStream() {
            counter += 1

            if counter == nth {
                XCTAssertTrue(value == targetValue, "Expected \(nth)th value: \(targetValue), actual value: \(value)")
                return
            }
        }

        XCTFail("Stream ended before finding \(nth)th value")
    }

    func subscribeDocumentStatus() async where T == DocumentStatus {
        await self.doc.subscribeStatus { [weak self] event, _ in
            guard let status = (event as? StatusChangedEvent)?.value.status else {
                return
            }
            self?.add(event: status)
        }
    }
}

/**
 * `BroadcastExpectValue` is a helper struct for easy equality comparison in test functions.
 */
struct BroadcastExpectValue: Equatable {
    let topic: String
    let payload: Payload

    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.topic == rhs.topic && lhs.payload == rhs.payload
    }
}
