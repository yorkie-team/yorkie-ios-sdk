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

import Connect
import XCTest
@testable import Yorkie

final class AttachmentTests: XCTestCase {
    // MARK: - needRealtimeSync

    @MainActor
    func test_needRealtimeSync_returns_false_when_syncMode_is_nil() async {
        // Channel-style attachment: no syncMode → never needs realtime sync.
        let attachment = Attachment(resource: FakeAttachable(), resourceID: "r-1")
        let needs = await attachment.needRealtimeSync()
        XCTAssertFalse(needs)
    }

    @MainActor
    func test_needRealtimeSync_returns_false_for_realtimeSyncOff() async {
        let resource = FakeAttachable(hasLocalChanges: true)
        let attachment = Attachment(resource: resource, resourceID: "r-1", syncMode: .realtimeSyncOff)
        attachment.changeEventReceived = true

        let needs = await attachment.needRealtimeSync()
        XCTAssertFalse(needs)
    }

    @MainActor
    func test_needRealtimeSync_returns_false_for_manual_even_with_local_changes() async {
        let resource = FakeAttachable(hasLocalChanges: true)
        let attachment = Attachment(resource: resource, resourceID: "r-1", syncMode: .manual)
        attachment.changeEventReceived = true

        let needs = await attachment.needRealtimeSync()
        XCTAssertFalse(needs)
    }

    @MainActor
    func test_needRealtimeSync_realtimePushOnly_depends_on_local_changes() async {
        let with = Attachment(
            resource: FakeAttachable(hasLocalChanges: true),
            resourceID: "r-1",
            syncMode: .realtimePushOnly
        )
        let without = Attachment(
            resource: FakeAttachable(hasLocalChanges: false),
            resourceID: "r-2",
            syncMode: .realtimePushOnly
        )

        let withNeeds = await with.needRealtimeSync()
        let withoutNeeds = await without.needRealtimeSync()
        XCTAssertTrue(withNeeds)
        XCTAssertFalse(withoutNeeds)
    }

    @MainActor
    func test_needRealtimeSync_realtime_triggers_on_local_changes() async {
        let attachment = Attachment(
            resource: FakeAttachable(hasLocalChanges: true),
            resourceID: "r-1",
            syncMode: .realtime,
            changeEventReceived: false
        )

        let needs = await attachment.needRealtimeSync()
        XCTAssertTrue(needs)
    }

    @MainActor
    func test_needRealtimeSync_realtime_triggers_on_changeEventReceived() async {
        let attachment = Attachment(
            resource: FakeAttachable(hasLocalChanges: false),
            resourceID: "r-1",
            syncMode: .realtime,
            changeEventReceived: true
        )

        let needs = await attachment.needRealtimeSync()
        XCTAssertTrue(needs)
    }

    @MainActor
    func test_needRealtimeSync_realtime_returns_false_when_idle() async {
        // No local changes, no remote events received.
        let attachment = Attachment(
            resource: FakeAttachable(hasLocalChanges: false),
            resourceID: "r-1",
            syncMode: .realtime,
            changeEventReceived: false
        )

        let needs = await attachment.needRealtimeSync()
        XCTAssertFalse(needs)
    }

    // MARK: - connectStream

    @MainActor
    func test_connectStream_sets_stream_and_marks_connected() {
        let attachment = Attachment(resource: FakeAttachable(), resourceID: "r-1")
        XCTAssertNil(attachment.remoteWatchStream)

        let counter = CancelCounter()
        attachment.connectStream(YorkieServerStream(FakeServerStream(counter: counter)))

        XCTAssertNotNil(attachment.remoteWatchStream)
        XCTAssertFalse(attachment.isDisconnectedStream)
        XCTAssertEqual(counter.count, 0)
    }

    @MainActor
    func test_connectStream_cancels_previous_stream_when_replaced() {
        let attachment = Attachment(resource: FakeAttachable(), resourceID: "r-1")
        let first = CancelCounter()
        let second = CancelCounter()

        attachment.connectStream(YorkieServerStream(FakeServerStream(counter: first)))
        attachment.connectStream(YorkieServerStream(FakeServerStream(counter: second)))

        XCTAssertEqual(first.count, 1, "previous stream must be cancelled when replaced")
        XCTAssertEqual(second.count, 0, "new stream must not be cancelled")
        XCTAssertNotNil(attachment.remoteWatchStream)
    }

    @MainActor
    func test_connectStream_with_nil_clears_existing_stream() {
        let attachment = Attachment(resource: FakeAttachable(), resourceID: "r-1")
        let counter = CancelCounter()
        attachment.connectStream(YorkieServerStream(FakeServerStream(counter: counter)))

        attachment.connectStream(nil)

        XCTAssertEqual(counter.count, 1, "existing stream must be cancelled")
        XCTAssertNil(attachment.remoteWatchStream)
        // connectStream(nil) leaves isDisconnected == false; only disconnectStream() flips it.
        XCTAssertFalse(attachment.isDisconnectedStream == false && attachment.remoteWatchStream != nil)
    }

    @MainActor
    func test_connectStream_does_not_reset_cancelled_flag() {
        let attachment = Attachment(resource: FakeAttachable(), resourceID: "r-1")
        attachment.cancelWatchStream() // sets cancelled = true, disconnects

        let counter = CancelCounter()
        attachment.connectStream(YorkieServerStream(FakeServerStream(counter: counter)))

        XCTAssertTrue(attachment.cancelled, "cancelled flag must persist across reconnect")
        XCTAssertNotNil(attachment.remoteWatchStream)
    }
}

// MARK: - Test doubles

/// Minimal `Attachable` whose `hasLocalChanges()` returns a configured value.
@MainActor
private final class FakeAttachable: Attachable, @unchecked Sendable {
    private let _hasLocalChanges: Bool

    init(hasLocalChanges: Bool = false) {
        self._hasLocalChanges = hasLocalChanges
    }

    nonisolated func getKey() -> String { "fake" }
    func getStatus() -> ResourceStatus { .attached }
    func setActor(_: ActorID) {}
    func hasLocalChanges() async -> Bool { self._hasLocalChanges }
    func publish(_: any DocEvent) {}
}

/// Counts `cancel()` invocations from `FakeServerStream`. Reference type so the
/// count survives the value-type `YorkieServerStream` wrapper.
private final class CancelCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { self.count += 1 }
}

/// Minimal `ServerOnlyStreamInterface` conformance just so `YorkieServerStream`
/// can be constructed in tests; only `cancel()` is observed via `CancelCounter`.
private struct FakeServerStream: ServerOnlyStreamInterface {
    typealias Input = WatchRequest
    let counter: CancelCounter
    func send(_: WatchRequest) {}
    func cancel() { self.counter.increment() }
}
