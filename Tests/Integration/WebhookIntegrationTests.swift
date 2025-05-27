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

final class WebhookIntegrationTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"
    let testAPIID = "admin"
    let testAPIPW = "admin"

    var apiKey = ""

    var webhookServer: WebhookServer!
    var context: YorkieProjectContext!

    override func setUp() async throws {
        self.webhookServer = WebhookServer(port: 3004)
        try self.webhookServer.start()

        self.context = try await YorkieProjectHelper.initializeProject(rpcAddress: self.rpcAddress,
                                                                       username: self.testAPIID,
                                                                       password: self.testAPIPW,
                                                                       webhookURL: self.webhookServer.authWebhookUrl)
        self.apiKey = self.context.apiKey
    }

    override func tearDown() async throws {
        self.webhookServer.stop()

        // Prevents duplication of project ID (based on timeInterval)
        try await Task.sleep(milliseconds: 100)
    }

    func test_initialize_project_successfully() async throws {
        XCTAssertTrue(!self.apiKey.isEmpty)
    }
}
