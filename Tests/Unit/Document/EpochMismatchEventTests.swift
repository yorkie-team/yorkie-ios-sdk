/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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

// Ports the epoch-mismatch event wiring from yorkie-js-sdk 0.7.3 (#1193):
//   .doc/js-0.7.3/tests/epoch_mismatch_test.ts
//
// The JS test requires a running Yorkie server with admin CompactDocumentByAdmin
// support (yorkie-team/yorkie#1714) to trigger an actual epoch mismatch over the
// network. That server-compaction scenario cannot be reproduced in a unit test.
// These tests instead verify the iOS event-subscription wiring deterministically:
//   - subscribeEpochMismatch registers a callback
//   - publishEpochMismatchEvent fires it with the correct EpochMismatchEvent
//   - unsubscribeEpochMismatch de-registers the callback
//   - EpochMismatchValue and EpochMismatchEvent carry the expected field values
//
// The full integration scenario (push-pull → server returns ErrEpochMismatch →
// client emits the event → caller detaches and reattaches) requires a live server
// and is not covered here.

import XCTest
@testable import Yorkie

final class EpochMismatchEventTests: XCTestCase {
    // MARK: - Event wiring

    /// Verifies that subscribing to epoch-mismatch and publishing the event
    /// invokes the callback exactly once with the correct event type and method.
    ///
    /// Mirrors JS assertion:
    ///   `expect(event.type).toBe(DocEventType.EpochMismatch)`
    ///   `expect(event.value.method).toBe("PushPull")`
    @MainActor
    func test_subscribe_epoch_mismatch_fires_callback_with_correct_event() {
        // given
        let doc = Document(key: "epoch-mismatch-wiring")
        var receivedEvent: EpochMismatchEvent?
        var callCount = 0

        doc.subscribeEpochMismatch { event, _ in
            receivedEvent = event as? EpochMismatchEvent
            callCount += 1
        }

        // when
        doc.publishEpochMismatchEvent(method: "PushPull")

        // then
        XCTAssertEqual(callCount, 1)
        XCTAssertNotNil(receivedEvent)
        XCTAssertEqual(receivedEvent?.type, .epochMismatch)
        XCTAssertEqual(receivedEvent?.value.method, "PushPull")
    }

    /// Verifies that unsubscribeEpochMismatch prevents further callbacks.
    @MainActor
    func test_unsubscribe_epoch_mismatch_stops_callback() {
        // given
        let doc = Document(key: "epoch-mismatch-unsub")
        var callCount = 0

        doc.subscribeEpochMismatch { _, _ in
            callCount += 1
        }

        // when — first publish reaches the subscriber
        doc.publishEpochMismatchEvent(method: "PushPull")
        XCTAssertEqual(callCount, 1)

        // when — unsubscribe, then publish again
        doc.unsubscribeEpochMismatch()
        doc.publishEpochMismatchEvent(method: "PushPull")

        // then — second publish is not delivered
        XCTAssertEqual(callCount, 1)
    }

    /// Verifies that publishing without any subscriber does not crash.
    @MainActor
    func test_publish_epoch_mismatch_without_subscriber_does_not_crash() {
        // given
        let doc = Document(key: "epoch-mismatch-no-sub")

        // when / then — must not crash
        doc.publishEpochMismatchEvent(method: "PushPull")
    }

    // MARK: - Value types

    /// Verifies EpochMismatchValue carries the method string correctly.
    func test_epoch_mismatch_value_holds_method() {
        // given / when
        let value = EpochMismatchValue(method: "PushPull")

        // then
        XCTAssertEqual(value.method, "PushPull")
    }

    /// Verifies EpochMismatchEvent exposes the correct DocEventType.
    func test_epoch_mismatch_event_has_correct_type() {
        // given / when
        let event = EpochMismatchEvent(value: EpochMismatchValue(method: "PushPull"))

        // then
        XCTAssertEqual(event.type, DocEventType.epochMismatch)
    }

    /// Verifies the DocEventType raw value matches the JS string "epoch-mismatch".
    func test_epoch_mismatch_doc_event_type_raw_value() {
        XCTAssertEqual(DocEventType.epochMismatch.rawValue, "epoch-mismatch")
    }

    /// Verifies the YorkieError.Code for epoch mismatch matches the expected raw value.
    func test_err_epoch_mismatch_error_code_raw_value() {
        XCTAssertEqual(YorkieError.Code.errEpochMismatch.rawValue, "ErrEpochMismatch")
    }

    /// Verifies the callback receives the method string injected via publishEpochMismatchEvent.
    @MainActor
    func test_epoch_mismatch_callback_receives_injected_method() {
        // given
        let doc = Document(key: "epoch-mismatch-method-check")
        var capturedMethod: String?

        doc.subscribeEpochMismatch { event, _ in
            capturedMethod = (event as? EpochMismatchEvent)?.value.method
        }

        // when
        doc.publishEpochMismatchEvent(method: "WatchDocuments")

        // then
        XCTAssertEqual(capturedMethod, "WatchDocuments")
    }
}
