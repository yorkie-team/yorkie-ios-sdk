//
//  YorkieTests.swift
//  YorkieTests
//
//  Created by won on 2022/09/05.
//

import GRPC
import XCTest
@testable import Yorkie

class YorkieTests: XCTestCase {
    func test_요키에_연결한다() {
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

        let client = Yorkie_V1_YorkieServiceNIOClient(channel: channel)
        var activateRequest = Yorkie_V1_ActivateClientRequest()
        activateRequest.clientKey = testClientKey
        let activateResponse = try? client.activateClient(activateRequest, callOptions: nil).response.wait()
        guard let activateResponse = activateResponse else {
            XCTFail("The response of activate is nil.")
            return
        }

        XCTAssertEqual(activateResponse.clientKey, testClientKey)

        var deactivateRequest = Yorkie_V1_DeactivateClientRequest()
        deactivateRequest.clientID = activateResponse.clientID
        guard let deactivatedResponse = try? client.deactivateClient(deactivateRequest).response.wait() else {
            XCTFail("The response of deactivate is nil.")
            return
        }

        XCTAssertEqual(deactivatedResponse.clientID, activateResponse.clientID)
    }

    func test_요키에_async_인터페이스로_연결한다() async throws {
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

        let client = Yorkie_V1_YorkieServiceAsyncClient(channel: channel)
        var activateRequest = Yorkie_V1_ActivateClientRequest()
        activateRequest.clientKey = testClientKey
        let activateResponse = try? await client.activateClient(activateRequest, callOptions: nil)
        guard let activateResponse = activateResponse else {
            XCTFail("The response of activate is nil.")
            return
        }

        XCTAssertEqual(activateResponse.clientKey, testClientKey)

        var deactivateRequest = Yorkie_V1_DeactivateClientRequest()
        deactivateRequest.clientID = activateResponse.clientID
        guard let deactivatedResponse = try? await client.deactivateClient(deactivateRequest) else {
            XCTFail("The response of deactivate is nil.")
            return
        }

        XCTAssertEqual(deactivatedResponse.clientID, activateResponse.clientID)
    }
}
