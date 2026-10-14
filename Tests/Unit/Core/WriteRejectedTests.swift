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

import Connect
import SwiftProtobuf
import XCTest
@testable import Yorkie

// Unit side of yorkie-js-sdk#1462 (packages/sdk/test/unit/client/write_rejected_test.ts). No server
// is needed; the end-to-end cases live in Tests/Integration/WriteRejectedIntegrationTests.swift.

/// Builds the `ResourceExhausted` error the server returns when its size gate refuses a push, with
/// the Yorkie code in the error detail metadata where `errorCodeOf` reads it.
func writeRejection(_ code: YorkieError.Code, _ message: String) -> ConnectError {
    var info = Google_Rpc_ErrorInfo()
    info.metadata = ["code": code.rawValue]
    let payload = (try? info.serializedData()) ?? Data()
    return ConnectError(
        code: .resourceExhausted,
        message: message,
        details: [ConnectError.Detail(type: "google.rpc.ErrorInfo", payload: payload)]
    )
}

final class WriteRejectedTests: XCTestCase {
    @MainActor
    func test_does_not_retry_a_push_the_server_will_never_accept() async {
        let client = Client("http://localhost:8080")

        for code in [YorkieError.Code.errDocumentSizeExceedsLimit, .errChangeTooLarge] {
            let retry = await client.handleConnectError(writeRejection(code, "refused"))
            XCTAssertFalse(retry, "\(code) must stop the sync loop instead of resending")
        }
    }

    @MainActor
    func test_still_retries_a_resource_exhausted_error_that_carries_no_yorkie_code() async {
        let client = Client("http://localhost:8080")

        let retry = await client.handleConnectError(ConnectError(code: .resourceExhausted, message: "slow down"))

        XCTAssertTrue(retry)
    }

    @MainActor
    func test_maps_each_rejection_code_and_ignores_the_rest() {
        XCTAssertEqual(Client.writeRejectionCode(of: writeRejection(.errDocumentSizeExceedsLimit, "m")), .documentSizeExceedsLimit)
        XCTAssertEqual(Client.writeRejectionCode(of: writeRejection(.errChangeTooLarge, "m")), .changeTooLarge)
        XCTAssertNil(Client.writeRejectionCode(of: writeRejection(.errNotAttached, "m")))
        XCTAssertNil(Client.writeRejectionCode(of: ConnectError(code: .resourceExhausted, message: "slow down")))
        XCTAssertNil(Client.writeRejectionCode(of: nil))
    }

    @MainActor
    func test_delivers_the_code_to_a_typed_write_rejected_subscription() {
        // given
        let doc = Document(key: "write-rejected-typed")
        var received = [WriteRejectedValue]()
        var defaults = [DocEventType]()
        doc.subscribeWriteRejected { event, _ in
            if let event = event as? WriteRejectedEvent {
                received.append(event.value)
            }
        }
        doc.subscribe { event, _ in defaults.append(event.type) }

        // when
        doc.publishWriteRejectedEvent(code: .documentSizeExceedsLimit, reason: "document size exceeds limit", method: "PushPull")
        doc.unsubscribeWriteRejected()
        doc.publishWriteRejectedEvent(code: .changeTooLarge, reason: "ignored", method: "PushPull")

        // then
        XCTAssertEqual(received, [WriteRejectedValue(code: .documentSizeExceedsLimit, reason: "document size exceeds limit", method: "PushPull")])
        XCTAssertEqual(defaults, [.writeRejected, .writeRejected])
        XCTAssertEqual(DocEventType.writeRejected.rawValue, "write-rejected")
    }

    @MainActor
    func test_attachment_parks_until_the_mark_is_cleared() {
        let attachment = Attachment(resource: Document(key: "parked"), resourceID: "id")
        XCTAssertFalse(attachment.isWriteRejected())

        attachment.markWriteRejected()
        XCTAssertTrue(attachment.isWriteRejected())

        attachment.clearWriteRejected()
        XCTAssertFalse(attachment.isWriteRejected())
    }
}
