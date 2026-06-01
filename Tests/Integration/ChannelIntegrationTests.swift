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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

// Port of yorkie-js-sdk packages/sdk/test/integration/channel_test.ts. These
// tests cover the Channel watch stream end-to-end — remote `ChannelBroadcastEvent`
// and `ChannelPresenceEvent` delivery is wired in `Client.doWatchLoop`.
final class ChannelIntegrationTests: XCTestCase {
    private let rpcAddress = "http://localhost:8080"

    @MainActor
    func test_should_subscribe_to_specific_topic_for_broadcast_events() async throws {
        try await withTwoClientsAndChannels(self.description) { _, ch1, _, ch2 in
            let chatCollector = ChannelEventCollector<Payload>()
            let notificationCollector = ChannelEventCollector<Payload>()

            ch2.subscribeTopic("chat") { chatCollector.add($0.payload) }
            ch2.subscribeTopic("notification") { notificationCollector.add($0.payload) }

            try ch1.broadcast(topic: "chat", payload: Payload(["message": "Hello, world!"]))
            try await chatCollector.waitForValue(at: 1, equals: Payload(["message": "Hello, world!"]))

            try ch1.broadcast(topic: "notification", payload: Payload(["alert": "New message"]))
            try await notificationCollector.waitForValue(at: 1, equals: Payload(["alert": "New message"]))

            XCTAssertEqual(chatCollector.count, 1)
            XCTAssertEqual(notificationCollector.count, 1)

            ch2.unsubscribeTopic("chat")
            ch2.unsubscribeTopic("notification")
        }
    }

    @MainActor
    func test_should_subscribe_to_presence_events() async throws {
        try await withTwoClientsAndChannels(self.description) { _, _, _, ch2 in
            let presenceCollector = ChannelEventCollector<Int>()
            ch2.subscribePresenceChange { presenceCollector.add($0.count) }

            try await ChannelEventCollector<Int>.waitUntil(timeout: 2.0) {
                !presenceCollector.isEmpty
            }

            XCTAssertGreaterThan(presenceCollector.count, 0)
            ch2.unsubscribePresenceChange()
        }
    }

    @MainActor
    func test_should_get_presence_count() async throws {
        try await withTwoClientsAndChannels(self.description) { _, ch1, _, ch2 in
            // ch2's initial attach response carries count=2; ch1 only learns about
            // ch2 through a presence event delivered over the watch stream, which
            // is a separate roundtrip — poll until counts converge.
            try await ChannelEventCollector<Int>.waitUntil(timeout: 2.0) {
                ch1.getSessionCount() >= 2 && ch2.getSessionCount() >= 2
            }

            let count1 = ch1.getSessionCount()
            let count2 = ch2.getSessionCount()

            XCTAssertGreaterThanOrEqual(count1, 2)
            XCTAssertGreaterThanOrEqual(count2, 2)
            XCTAssertEqual(count1, count2)
        }
    }

    @MainActor
    func test_should_support_legacy_broadcast_subscription() async throws {
        try await withTwoClientsAndChannels(self.description) { _, ch1, _, ch2 in
            let collector = ChannelEventCollector<String>()
            let topic = "test-topic"

            ch2.subscribeBroadcast { event in
                guard event.topic == topic else { return }
                if let value: String = event.payload["data"] {
                    collector.add(value)
                }
            }

            try ch1.broadcast(topic: topic, payload: Payload(["data": "test-data"]))
            try await collector.waitForValue(at: 1, equals: "test-data")

            ch2.unsubscribeBroadcast()
        }
    }

    @MainActor
    func test_should_mix_topic_based_and_type_based_subscriptions() async throws {
        try await withTwoClientsAndChannels(self.description) { _, ch1, _, ch2 in
            let chatCollector = ChannelEventCollector<String>()
            let allCollector = ChannelEventCollector<String>()

            ch2.subscribeTopic("chat") { event in
                if let value: String = event.payload["data"] {
                    chatCollector.add(value)
                }
            }
            ch2.subscribeBroadcast { event in
                if let value: String = event.payload["data"] {
                    allCollector.add("\(event.topic):\(value)")
                }
            }

            try ch1.broadcast(topic: "chat", payload: Payload(["data": "message1"]))
            try await chatCollector.waitForValue(at: 1, equals: "message1")

            try ch1.broadcast(topic: "notification", payload: Payload(["data": "message2"]))
            try await Task.sleep(milliseconds: 200)

            XCTAssertEqual(chatCollector.count, 1)
            XCTAssertEqual(allCollector.count, 2)

            ch2.unsubscribeTopic("chat")
            ch2.unsubscribeBroadcast()
        }
    }
}

// MARK: - Helpers

/// Mirrors `withTwoClientsAndDocuments` but for Channels: activates two clients,
/// attaches a channel with the same key on each, runs the test body, then
/// detaches and deactivates.
@MainActor
private func withTwoClientsAndChannels(
    _ title: String,
    callback: (Client, Channel, Client, Channel) async throws -> Void
) async throws {
    let rpcAddress = "http://localhost:8080"
    let channelKey = "ch-\(Int(Date().timeIntervalSince1970))-\(title)"
        .lowercased()
        .replacingOccurrences(of: " ", with: "-")
        .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }

    let c1 = Client(rpcAddress)
    let c2 = Client(rpcAddress)

    try await c1.activate()
    try await c2.activate()

    let ch1 = try Channel(key: channelKey)
    let ch2 = try Channel(key: channelKey)

    _ = try await c1.attachChannel(ch1)
    _ = try await c2.attachChannel(ch2)

    let result: Result<Void, Error>
    do {
        try await callback(c1, ch1, c2, ch2)
        result = .success(())
    } catch {
        result = .failure(error)
    }

    _ = try? await c1.detachChannel(ch1)
    _ = try? await c2.detachChannel(ch2)
    try? await c1.deactivate()
    try? await c2.deactivate()

    try result.get()
}

/// Thread-safe collector for Channel-event tests. `EventCollector` from
/// `YorkieTestHelper` is tied to a `Document`, which channels don't have.
private final class ChannelEventCollector<T: Equatable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yorkie.channelEventCollector", attributes: .concurrent)
    private var _values: [T] = []

    var values: [T] { self.queue.sync { self._values } }
    var count: Int { self.values.count }
    var isEmpty: Bool { self.values.isEmpty }

    func add(_ value: T) {
        self.queue.async(flags: .barrier) {
            self._values.append(value)
        }
    }

    /// Polls until the collector has at least `n` values, then verifies the
    /// `n`th equals the expected value. Times out after `timeout` seconds.
    func waitForValue(at nth: Int, equals expected: T, timeout: TimeInterval = 2.0) async throws {
        try await Self.waitUntil(timeout: timeout) { [weak self] in
            (self?.count ?? 0) >= nth
        }
        let values = self.values
        XCTAssertGreaterThanOrEqual(values.count, nth, "expected at least \(nth) values, got \(values.count)")
        if values.count >= nth {
            XCTAssertEqual(values[nth - 1], expected)
        }
    }

    static func waitUntil(timeout: TimeInterval, _ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        if !predicate() {
            XCTFail("waitUntil timed out after \(timeout)s")
        }
    }
}
