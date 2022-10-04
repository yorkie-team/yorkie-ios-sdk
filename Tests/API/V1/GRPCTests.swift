/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

import GRPC
import XCTest
@testable import Yorkie

class GRPCTests: XCTestCase {
    func test_connect_yorkie() {
        let testClientKey = UUID().uuidString
        let group = PlatformSupport.makeEventLoopGroup(loopCount: 1) // EventLoopGroup helpers

        defer {
            try? group.syncShutdownGracefully()
        }

        guard let channel = try? GRPCChannelPool.with(target: .host("localhost", port: 8080),
                                                      transportSecurity: .plaintext,
                                                      eventLoopGroup: group)
        else {
            XCTFail("channel is nil.")
            return
        }

        let client = YorkieServiceNIOClient(channel: channel)
        var activateRequest = ActivateClientRequest()
        activateRequest.clientKey = testClientKey
        let activateResponse = try? client.activateClient(activateRequest, callOptions: nil).response.wait()
        guard let activateResponse else {
            XCTFail("The response of activate is nil.")
            return
        }

        XCTAssertEqual(activateResponse.clientKey, testClientKey)

        var deactivateRequest = DeactivateClientRequest()
        deactivateRequest.clientID = activateResponse.clientID
        guard let deactivatedResponse = try? client.deactivateClient(deactivateRequest).response.wait() else {
            XCTFail("The response of deactivate is nil.")
            return
        }

        XCTAssertEqual(deactivatedResponse.clientID, activateResponse.clientID)
    }

    func test_connect_yorkie_with_async() async throws {
        let testClientKey = UUID().uuidString
        let group = PlatformSupport.makeEventLoopGroup(loopCount: 1) // EventLoopGroup helpers
        defer {
            try? group.syncShutdownGracefully()
        }

        guard let channel = try? GRPCChannelPool.with(target: .host("localhost", port: 8080),
                                                      transportSecurity: .plaintext,
                                                      eventLoopGroup: group)
        else {
            XCTFail("channel is nil.")
            return
        }

        let client = YorkieServiceAsyncClient(channel: channel)
        var activateRequest = ActivateClientRequest()
        activateRequest.clientKey = testClientKey
        let activateResponse = try? await client.activateClient(activateRequest, callOptions: nil)
        guard let activateResponse else {
            XCTFail("The response of activate is nil.")
            return
        }

        XCTAssertEqual(activateResponse.clientKey, testClientKey)

        var deactivateRequest = DeactivateClientRequest()
        deactivateRequest.clientID = activateResponse.clientID
        guard let deactivatedResponse = try? await client.deactivateClient(deactivateRequest) else {
            XCTFail("The response of deactivate is nil.")
            return
        }

        XCTAssertEqual(deactivatedResponse.clientID, activateResponse.clientID)
    }
}
