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

import XCTest
@testable import Yorkie

// Unit coverage for the `disableGC` flag introduced in yorkie 0.7.10 (#1265).
// These tests verify the flag's default value, storage on `Attachment`, and that
// it propagates through the init path — without touching the network.
final class AttachmentDisableGCTests: XCTestCase {
    // MARK: - disableGC default

    @MainActor
    func test_disableGC_defaults_to_false() {
        // given
        let attachment = Attachment(resource: FakeAttachableForGC(), resourceID: "r-1")

        // then
        XCTAssertFalse(attachment.disableGC)
    }

    @MainActor
    func test_disableGC_stores_true_when_set_at_init() {
        // given / when
        let attachment = Attachment(resource: FakeAttachableForGC(), resourceID: "r-1", disableGC: true)

        // then
        XCTAssertTrue(attachment.disableGC)
    }

    @MainActor
    func test_disableGC_stores_false_when_explicitly_set_to_false_at_init() {
        // given / when
        let attachment = Attachment(resource: FakeAttachableForGC(), resourceID: "r-1", disableGC: false)

        // then
        XCTAssertFalse(attachment.disableGC)
    }

    @MainActor
    func test_disableGC_is_independent_of_syncMode() {
        // given — realtime mode with disableGC = true
        let attachment = Attachment(
            resource: FakeAttachableForGC(),
            resourceID: "r-1",
            syncMode: .realtime,
            disableGC: true
        )

        // then — the flag is carried independently of sync mode
        XCTAssertTrue(attachment.disableGC)
        XCTAssertEqual(attachment.syncMode, .realtime)
    }

    @MainActor
    func test_disableGC_is_mutable() {
        // given
        let attachment = Attachment(resource: FakeAttachableForGC(), resourceID: "r-1", disableGC: false)

        // when
        attachment.disableGC = true

        // then
        XCTAssertTrue(attachment.disableGC)
    }
}

// MARK: - Test double

@MainActor
private final class FakeAttachableForGC: Attachable, @unchecked Sendable {
    nonisolated func getKey() -> String { "fake-gc" }
    func getStatus() -> ResourceStatus { .attached }
    func setActor(_: ActorID) {}
    func hasLocalChanges() async -> Bool { false }
    func publish(_: any DocEvent) {}
}
