/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

import XCTest
@testable import Yorkie

let defaultSnapshotThreshold = 500

func maxVectorOf(actors: [String?]) -> VersionVector {
    var actors = actors.compactMap { $0 }

    if actors.isEmpty {
        actors = [ActorIDs.initial]
    }

    var vector: [String: Int64] = [:]
    for actor in actors {
        vector[actor] = TimeTicket.Values.maxLamport
    }

    return VersionVector(vector: vector)
}

struct ActorData {
    let actor: String
    let lamport: Int64
}

func vectorOf(_ actorDatas: [ActorData]) -> VersionVector {
    var vector: [String: Int64] = [:]
    for actorData in actorDatas {
        vector[actorData.actor] = actorData.lamport
    }

    return VersionVector(vector: vector)
}

extension Task where Success == Never, Failure == Never {
    /**
     * `sleep` is a helper function that suspends the current task for the given milliseconds.
     */
    static func sleep(milliseconds: UInt64) async throws {
        try await self.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

func assertTrue(versionVector: VersionVector, actorDatas: [ActorData]) async {
    let result = vectorOf(actorDatas)
    XCTAssertEqual(versionVector, result)
}

func assertPeerElementsEqual(peers1: [PeerElement], peers2: [PeerElement]) {
    let clientIDs1 = peers1.map { $0.clientID }.sorted()
    let clientIDs2 = peers2.map { $0.clientID }.sorted()

    guard clientIDs1 == clientIDs2 else {
        XCTFail("ClientID mismatch: \(clientIDs1) != \(clientIDs2)")
        return
    }

    for clientID in clientIDs1 {
        let presence1 = peers1.first(where: { $0.clientID == clientID })?.presence ?? [:]
        let presence2 = peers2.first(where: { $0.clientID == clientID })?.presence ?? [:]

        guard presence1.count == presence2.count else {
            XCTFail("Presence count mismatch for clientID: \(clientID)")
            return
        }

        for (key, value) in presence1 {
            guard let value1 = value as? String else {
                XCTFail("Value for key '\(key)' in peer1 is not a String for clientID: \(clientID)")
                return
            }
            guard let value2 = presence2[key] as? String else {
                XCTFail("Value for key '\(key)' in peer2 is not a String for clientID: \(clientID)")
                return
            }

            guard value1 == value2 else {
                XCTFail("Mismatch for key '\(key)' in clientID: \(clientID) — '\(value1)' != '\(value2)'")
                return
            }
        }
    }
}

func assertThrows<T: Error>(_ expression: @escaping () async throws -> Void,
                            isExpectedError: (T) -> Bool,
                            message: String? = nil) async
{
    do {
        try await expression()
        XCTFail("Expected to throw \(T.self), but no error was thrown.")
    } catch let error as T {
        XCTAssertTrue(isExpectedError(error), message ?? "Thrown error did not match expected error.")
    } catch {
        XCTFail("Expected to throw \(T.self), but got different error: \(error)")
    }
}

extension Date {
    func timeInterval(before milliseconds: Double) -> TimeInterval {
        return (self - (milliseconds / 1000)).timeIntervalSince1970
    }

    func timeInterval(after milliseconds: Double) -> TimeInterval {
        return (self + (milliseconds / 1000)).timeIntervalSince1970
    }
}

class EventCollector<T: Equatable> {
    struct WaitUntil {
        var continuation: AsyncStream<T>.Continuation
        var stopValue: T
        var startIndex: Int
    }

    private let queue = DispatchQueue(label: "com.yorkie.eventcollector", attributes: .concurrent)
    private var _values: [T] = []
    private var waitUntil: WaitUntil?
    private var lastStreamEndIndex: Int = 0

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

            if let waitUntil = self.waitUntil {
                let currentIndex = self._values.count - 1
                if currentIndex >= waitUntil.startIndex {
                    waitUntil.continuation.yield(event)
                    if event == waitUntil.stopValue {
                        waitUntil.continuation.finish()
                        self.lastStreamEndIndex = currentIndex + 1
                        self.waitUntil = nil
                    }
                }
            }
        }
    }

    func reset() {
        self.queue.async(flags: .barrier) {
            self._values.removeAll()
            self.waitUntil = nil
            self.lastStreamEndIndex = 0
        }
    }

    func valueStream() -> AsyncStream<T> {
        return AsyncStream<T> { continuation in
            for value in self.values {
                continuation.yield(value)
            }
            continuation.finish()
        }
    }

    func waitStream(until stopValue: T) -> AsyncStream<T> where T: Equatable {
        return AsyncStream<T> { continuation in
            self.queue.sync {
                let startIndex = self.lastStreamEndIndex

                // Check if the stopValue exists in unchecked values
                if let stopIndex = self._values[startIndex...].firstIndex(where: { $0 == stopValue }) {
                    // Yield all values from startIndex to stopIndex
                    for value in self._values[startIndex ... stopIndex] {
                        continuation.yield(value)
                    }
                    continuation.finish()
                    self.queue.async(flags: .barrier) {
                        self.lastStreamEndIndex = stopIndex + 1
                    }
                    return
                }

                // If not found, set up to wait for future events
                self.queue.async(flags: .barrier) {
                    // Double-check in case the value arrived between the check and now
                    let checkStartIndex = self.lastStreamEndIndex
                    if let stopIndex = self._values[checkStartIndex...].firstIndex(where: { $0 == stopValue }) {
                        for value in self._values[checkStartIndex ... stopIndex] {
                            continuation.yield(value)
                        }
                        continuation.finish()
                        self.lastStreamEndIndex = stopIndex + 1
                    } else {
                        self.waitUntil = WaitUntil(continuation: continuation, stopValue: stopValue, startIndex: checkStartIndex)
                    }
                }
            }
        }
    }

    func waitAndVerifyNthValue(milliseconds: UInt64, at nth: Int, isEqualTo targetValue: T) async throws {
        await self.verifyNthValue(at: nth, isEqualTo: targetValue)
    }

    func verifyNthValue(at nth: Int, isEqualTo targetValue: T) async {
        if nth > self.values.count {
            XCTFail("Expected \(nth)th value: \(targetValue), but only received \(self.values.count) values")
            return
        }

        var counter = 0
        for await value in self.valueStream() {
            counter += 1

            if counter == nth {
                XCTAssertTrue(value == targetValue, "Expected \(nth)th value: \(targetValue), actual value: \(value)")
                return
            }
        }

        XCTFail("Stream ended before finding \(nth)th value")
    }

    func subscribeDocumentStatus() async where T == DocStatus {
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

@MainActor
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

extension VersionVector: @retroactive Equatable {
    public static func == (lhs: VersionVector, rhs: VersionVector) -> Bool {
        for (key, value) in lhs {
            guard value == rhs.get(key) else { return false }
        }
        guard lhs.size() == rhs.size() else { return false }
        return true
    }
}
